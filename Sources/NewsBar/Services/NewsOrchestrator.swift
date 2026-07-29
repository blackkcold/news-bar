import Foundation

enum AISummaryState: Equatable, Sendable {
    case idle
    case noKey
    case fetching
    case summarizing
    case done(String)
    case truncated(String)
    case error(String)
}

enum SourceLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum NewsBarError: LocalizedError {
    case invalidURL
    case requestFailed
    case parseFailed
    case apiKeyInvalid
    case rateLimited
    case parseFailedWithDetail(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的 URL"
        case .requestFailed: return "网络请求失败"
        case .parseFailed: return "数据解析失败"
        case .parseFailedWithDetail(let detail): return "XML 解析失败: \(detail)"
        case .apiKeyInvalid: return "API Key 无效"
        case .rateLimited: return "刷新频率限制"
        }
    }
}

@MainActor
final class NewsOrchestrator: ObservableObject {

    // MARK: - Published State

    @Published var weiboItems: [NewsItem] = []
    @Published var bilibiliItems: [NewsItem] = []
    @Published var rssItemsMap: [String: [NewsItem]] = [:]

    // Popup summary context
    @Published var aiSummaryState = AISummaryState.idle
    @Published var aiSummaryItems: [NewsItem] = []
    @Published var aiParsedSummary: ParsedSummary?

    // Dashboard summary context
    @Published var dashboardSummaryState = AISummaryState.idle
    @Published var dashboardSummaryItems: [NewsItem] = []
    @Published var dashboardParsedSummary: ParsedSummary?

    @Published var isRefreshing = false
    @Published var sourceStates: [String: SourceLoadState] = [:]
    @Published var manualRefreshWarning: String?
    @Published var batchProgress: (completed: Int, total: Int) = (0, 0)

    // MARK: - Private State

    private let cacheManager = CacheManager()
    private let rateLimiter = RateLimiter()
    var popupLastHash: String?
    var dashboardLastHash: String?
    /// 截断内容哈希：防止对同一截断内容重复生成，成功生成后清除
    var popupLastTruncatedHash: String?
    var dashboardLastTruncatedHash: String?
    /// 连续截断计数：超过阈值时停止自动重试，用户仍可手动重新生成
    var consecutiveTruncationCount = 0
    let maxConsecutiveTruncations = 3
    private var lastSourceRefresh: [String: Date] = [:]

    // MARK: - Context-Aware State Helpers

    private func setSummaryState(_ target: SummaryTarget, _ state: AISummaryState) {
        switch target {
        case .popup: aiSummaryState = state
        case .dashboard: dashboardSummaryState = state
        }
    }

    private func setSummaryItems(_ target: SummaryTarget, _ items: [NewsItem]) {
        switch target {
        case .popup: aiSummaryItems = items
        case .dashboard: dashboardSummaryItems = items
        }
    }

    private func setParsedSummary(_ target: SummaryTarget, _ parsed: ParsedSummary?) {
        switch target {
        case .popup: aiParsedSummary = parsed
        case .dashboard: dashboardParsedSummary = parsed
        }
    }

    private func currentHash(for target: SummaryTarget) -> String? {
        switch target {
        case .popup: return popupLastHash
        case .dashboard: return dashboardLastHash
        }
    }

    private func setHash(_ hash: String?, for target: SummaryTarget) {
        switch target {
        case .popup: popupLastHash = hash
        case .dashboard: dashboardLastHash = hash
        }
    }

    private func currentTruncatedHash(for target: SummaryTarget) -> String? {
        switch target {
        case .popup: return popupLastTruncatedHash
        case .dashboard: return dashboardLastTruncatedHash
        }
    }

    private func setTruncatedHash(_ hash: String?, for target: SummaryTarget) {
        switch target {
        case .popup: popupLastTruncatedHash = hash
        case .dashboard: dashboardLastTruncatedHash = hash
        }
    }

    private func clearTruncatedHash(for target: SummaryTarget) {
        setTruncatedHash(nil, for: target)
    }

    // MARK: - One-Time Format Retry

    /// Static suffix appended to the prompt when a successful-but-unrenderable
    /// summary triggers a single format-enforcement retry. Kept here so tests
    /// can assert behaviour without touching the prompt builder.
    static let formatEnforcementSuffix: String = """
    \n重要：上一条回复未按格式输出。请务必严格使用【趋势概览】和【每日精选】两个板块标记，每个话题用「【标题】」独占一行，下接一段概述，再下接「引用：[#N]」。不要省略任何标记。
    """

    /// Decide whether a successful (non-truncated) summary should be retried
    /// once with the format-enforcement suffix. Returns true only when the
    /// parsed result has zero sections in both categories.
    internal static func needsFormatRetry(_ parsed: ParsedSummary) -> Bool {
        parsed.trendOverview.isEmpty && parsed.dailyEssentials.isEmpty
    }

    // MARK: - Public API

    func loadCached(settings: AppSettings) async {
        let aiBefore = logStateLabel(aiSummaryState)
        var sourceResults: [String: String] = [:]
        // 内存优先: 若已有数据则不覆盖 (避免 stale 缓存清空自动刷新填入的新数据)
        if weiboItems.isEmpty {
            if let cached = await cacheManager.load(for: .weibo) {
                if cached.isStale {
                    sourceStates[NewsSource.weibo.id] = .idle
                    sourceResults[NewsSource.weibo.displayName] = "cacheStale"
                } else {
                    weiboItems = cached.items
                    applyCachedState(.loaded, for: .weibo)
                    sourceResults[NewsSource.weibo.displayName] = "cache/\(cached.items.count)"
                }
            } else {
                if sourceStates[NewsSource.weibo.id] == nil {
                    sourceStates[NewsSource.weibo.id] = .idle
                }
                sourceResults[NewsSource.weibo.displayName] = "noCache"
            }
        } else {
            sourceResults[NewsSource.weibo.displayName] = "skipped/\(weiboItems.count)"
        }
        if bilibiliItems.isEmpty {
            if let cached = await cacheManager.load(for: .bilibili) {
                if cached.isStale {
                    sourceStates[NewsSource.bilibili.id] = .idle
                    sourceResults[NewsSource.bilibili.displayName] = "cacheStale"
                } else {
                    bilibiliItems = cached.items
                    applyCachedState(.loaded, for: .bilibili)
                    sourceResults[NewsSource.bilibili.displayName] = "cache/\(cached.items.count)"
                }
            } else {
                if sourceStates[NewsSource.bilibili.id] == nil {
                    sourceStates[NewsSource.bilibili.id] = .idle
                }
                sourceResults[NewsSource.bilibili.displayName] = "noCache"
            }
        } else {
            sourceResults[NewsSource.bilibili.displayName] = "skipped/\(bilibiliItems.count)"
        }

        for source in settings.activeSources where !source.isBuiltIn {
            if rssItemsMap[source.id, default: []].isEmpty {
                if let entry = await cacheManager.load(for: source) {
                    if entry.isStale {
                        sourceStates[source.id] = .idle
                        sourceResults[source.displayName] = "cacheStale"
                    } else {
                        rssItemsMap[source.id] = entry.items
                        applyCachedState(.loaded, for: source)
                        sourceResults[source.displayName] = "cache/\(entry.items.count)"
                    }
                } else {
                    if sourceStates[source.id] == nil {
                        sourceStates[source.id] = .idle
                    }
                    sourceResults[source.displayName] = "noCache"
                }
            } else {
                let count = rssItemsMap[source.id]?.count ?? 0
                sourceResults[source.displayName] = "skipped/\(count)"
            }
        }

        await RefreshLog.shared.record(
            trigger: .popoverOpen,
            sourceResults: sourceResults,
            aiBefore: aiBefore,
            aiAfter: logStateLabel(aiSummaryState)
        )
    }

    func refreshIfNeeded(settings: AppSettings, trigger: RefreshLog.Trigger = .startup) async {
        await doRefresh(settings: settings, trigger: trigger, isManual: false)
    }

    func manualRefresh(settings: AppSettings) async {
        await doRefresh(settings: settings, trigger: .manual, isManual: true)
    }

    private func doRefresh(
        settings: AppSettings,
        trigger: RefreshLog.Trigger,
        isManual: Bool
    ) async {
        guard !isRefreshing else { return }

        let aiBefore = logStateLabel(aiSummaryState)
        if isManual {
            manualRefreshWarning = await rateLimiter.manualRefreshWarning()
        }

        settings.recordRefresh()
        isRefreshing = true
        markSources(settings.activeSources, as: .loading)
        defer { isRefreshing = false }

        let previousSummaryState = aiSummaryState
        let apiKey: String
        if let cached = settings.cachedAPIKey, !cached.isEmpty {
            apiKey = cached
        } else {
            let store = EncryptedKeyStore()
            if let fallback = await store.readAPIKey(account: settings.currentProvider.apiKeyAccount()),
               !fallback.isEmpty {
                settings.cachedAPIKey = fallback
                apiKey = fallback
            } else {
                apiKey = ""
            }
        }
        if settings.aiSummaryEnabled {
            aiSummaryState = apiKey.isEmpty ? .noKey : .fetching
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.fetchWeibo(useCacheFallback: !isManual) }
            group.addTask { await self.fetchBilibili(useCacheFallback: !isManual) }
        }

        let now = Date()
        let rssSources = settings.activeSources.filter { source in
            !source.isBuiltIn && (
                isManual ||
                sourceStates[source.id] != .loaded ||
                (now.timeIntervalSince(lastSourceRefresh[source.id] ?? .distantPast) > 900)
            )
        }

        if !rssSources.isEmpty {
            let batchSize = 6
            batchProgress = (0, rssSources.count)

            for batchStart in stride(from: 0, to: rssSources.count, by: batchSize) {
                let batch = Array(rssSources[batchStart..<min(batchStart + batchSize, rssSources.count)])

                await withTaskGroup(of: Void.self) { group in
                    for source in batch {
                        group.addTask { await self.fetchRSS(source: source, useCacheFallback: !isManual, settings: settings) }
                    }
                }

                batchProgress.completed = min(batchStart + batchSize, rssSources.count)

                for source in batch {
                    lastSourceRefresh[source.id] = Date()
                }
            }
            batchProgress = (0, 0)
        }

        if isManual {
            await rateLimiter.recordManualRefresh()
            manualRefreshWarning = await rateLimiter.manualRefreshWarning()
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.handleAISummary(
                    settings: settings,
                    apiKey: apiKey,
                    previousState: previousSummaryState,
                    skipHashDedup: isManual
                )
            }
            group.addTask {
                await self.generateDashboardSummaryIfNeeded(settings: settings)
            }
            await group.waitForAll()
        }

        let allItems = allActiveItems(settings: settings)
        if !isManual {
            if settings.hourlyPushEnabled {
                await NotificationService.sendHourlyPush(items: allItems, count: settings.pushCount)
            }
            if settings.dailyPushEnabled {
                NotificationService.rescheduleDailyPush(
                    items: allItems,
                    count: settings.pushCount,
                    hour: settings.dailyPushHour,
                    minute: settings.dailyPushMinute
                )
            }
        }

        await recordRefreshLog(settings: settings, trigger: trigger, aiBefore: aiBefore)
    }

    private func fetchWeibo(useCacheFallback: Bool) async {
        if let items = await fetchAndCache(
            for: .weibo,
            fetcher: { try await WeiboHotService.fetch() }
        ) {
            weiboItems = items
        } else if useCacheFallback, weiboItems.isEmpty,
                  let cached = await cacheManager.load(for: .weibo) {
            weiboItems = cached.items
        }
    }

    private func fetchBilibili(useCacheFallback: Bool) async {
        if let items = await fetchAndCache(
            for: .bilibili,
            fetcher: { try await BilibiliHotService.fetch() }
        ) {
            bilibiliItems = items
        } else if useCacheFallback, bilibiliItems.isEmpty,
                  let cached = await cacheManager.load(for: .bilibili) {
            bilibiliItems = cached.items
        }
    }

    private func fetchRSS(source: NewsSource, useCacheFallback: Bool, settings: AppSettings) async {
        let fetchedItems: [NewsItem]?
        if let items = await fetchAndCache(
            for: source,
            fetcher: {
                try await RSSService.fetch(url: source.id, sourceName: source.displayName)
            }
        ) {
            rssItemsMap[source.id] = items
            fetchedItems = items
        } else if useCacheFallback, rssItemsMap[source.id, default: []].isEmpty,
                  let cached = await cacheManager.load(for: source) {
            rssItemsMap[source.id] = cached.items
            fetchedItems = cached.items
        } else {
            fetchedItems = nil
        }

        // Detect image availability and auto-correct displayMode (only on actual fetch, not empty results)
        if let items = fetchedItems, !items.isEmpty {
            let hasImages = items.contains { $0.imageURL != nil }
            if let idx = settings.rssSources.firstIndex(where: { $0.id == source.id }) {
                let current = settings.rssSources[idx]
                if current.supportsImage != hasImages || (current.displayMode == .image && !hasImages) {
                    settings.rssSources[idx].supportsImage = hasImages
                    if !hasImages && current.displayMode == .image {
                        settings.rssSources[idx].displayMode = .text
                    }
                }
            }
        }
    }

    // MARK: - Popup Summary (generated on refresh)

    private func handleAISummary(
        settings: AppSettings,
        apiKey: String,
        previousState: AISummaryState,
        skipHashDedup: Bool
    ) async {
        guard settings.aiSummaryEnabled else { return }

        let allItems = allActiveItems(settings: settings)
        guard !allItems.isEmpty else {
            if !apiKey.isEmpty {
                aiSummaryState = previousState
            }
            return
        }

        guard !apiKey.isEmpty else {
            aiSummaryState = .noKey
            return
        }

        // Concurrent generation guard (per-target)
        guard AISummaryService.tryAcquireGenerationLock(for: .popup) else {
            aiSummaryState = .error("AI 总结正在生成中")
            return
        }
        defer { AISummaryService.releaseGenerationLock(for: .popup) }

        let newHash = CacheEntry.contentIdentifier(for: allItems)
        let shouldGenerate = skipHashDedup
            || (newHash != popupLastHash && newHash != popupLastTruncatedHash)
            || shouldRecoverAISummary(from: previousState)

        if shouldGenerate {
            AISummaryService.initBudget(
                target: .popup,
                mode: settings.aiBudgetMode,
                baseline: settings.todayAIRequestCount(for: .popup),
                cap: settings.effectiveDailyCap(for: .popup)
            )
            let requestCount = await generateSummary(
                target: .popup,
                items: allItems,
                contentHash: newHash,
                maxWords: settings.aiPopupMaxWords,
                model: settings.aiModel,
                apiKey: apiKey,
                provider: settings.currentProvider,
                settings: settings
            )
            settings.recordAIRequests(requestCount, for: .popup)
        } else {
            aiSummaryState = previousState
        }
    }

    // MARK: - Dashboard Summary (lazy generation)

    /// Lazy dashboard summary generation. Safe to call repeatedly; skips if already
    /// up-to-date. On lock contention (e.g. Popup is generating), returns silently
    /// without error or budget charge — the view can retry by calling this method again.
    func generateDashboardSummaryIfNeeded(settings: AppSettings) async {
        guard settings.aiSummaryEnabled else { return }

        let allItems = allActiveItems(settings: settings)
        guard !allItems.isEmpty else {
            dashboardSummaryState = .idle
            return
        }

        let apiKey = await resolveAPIKey(settings: settings)
        guard !apiKey.isEmpty else {
            dashboardSummaryState = .noKey
            return
        }

        let newHash = CacheEntry.contentIdentifier(for: allItems)
        let shouldGenerate = (newHash != dashboardLastHash && newHash != dashboardLastTruncatedHash)
            || shouldRecoverAISummary(from: dashboardSummaryState)

        guard shouldGenerate else { return }

        // Try per-target lock; if held, return silently — retryable, no error, no budget
        guard AISummaryService.tryAcquireGenerationLock(for: .dashboard) else {
            return
        }
        defer { AISummaryService.releaseGenerationLock(for: .dashboard) }

        AISummaryService.initBudget(
            target: .dashboard,
            mode: settings.aiBudgetMode,
            baseline: settings.todayAIRequestCount(for: .dashboard),
            cap: settings.effectiveDailyCap(for: .dashboard)
        )
        let requestCount = await generateSummary(
            target: .dashboard,
            items: allItems,
            contentHash: newHash,
            maxWords: settings.aiDashboardMaxWords,
            model: settings.aiModel,
            apiKey: apiKey,
            provider: settings.currentProvider,
            settings: settings
        )
        settings.recordAIRequests(requestCount, for: .dashboard)
    }

    // MARK: - Manual Regeneration (Popup context)

    func regenerateAISummary(settings: AppSettings) async {
        let allItems = allActiveItems(settings: settings)
        guard !allItems.isEmpty else { return }

        // Cooldown check — preserve existing summary on denial
        let remaining = AISummaryService.regenerationCooldownRemaining()
        guard remaining == 0 else {
            return
        }

        // Concurrent generation guard — preserve existing summary on denial
        guard AISummaryService.tryAcquireGenerationLock(for: .popup) else {
            return
        }
        defer { AISummaryService.releaseGenerationLock(for: .popup) }

        let apiKey: String
        if let cached = settings.cachedAPIKey, !cached.isEmpty {
            apiKey = cached
        } else {
            let store = EncryptedKeyStore()
            if let fallback = await store.readAPIKey(account: settings.currentProvider.apiKeyAccount()),
               !fallback.isEmpty {
                settings.cachedAPIKey = fallback
                apiKey = fallback
            } else {
                aiSummaryState = .noKey
                return
            }
        }
        AISummaryService.recordManualRegeneration()
        AISummaryService.initBudget(
            target: .popup,
            mode: settings.aiBudgetMode,
            baseline: settings.todayAIRequestCount(for: .popup),
            cap: settings.effectiveDailyCap(for: .popup)
        )
        let newHash = CacheEntry.contentIdentifier(for: allItems)
        let requestCount = await generateSummary(
            target: .popup,
            items: allItems,
            contentHash: newHash,
            maxWords: settings.aiPopupMaxWords,
            model: settings.aiModel,
            apiKey: apiKey,
            provider: settings.currentProvider,
            settings: settings
        )
        settings.recordAIRequests(requestCount, for: .popup)
    }

    // MARK: - Shared Helpers

    private func fetchAndCache(
        for source: NewsSource,
        fetcher: () async throws -> [NewsItem]
    ) async -> [NewsItem]? {
        do {
            let items = try await fetcher()
            guard !items.isEmpty else {
                sourceStates[source.id] = .failed("未返回内容")
                return nil
            }

            let hasNew = await cacheManager.hasNewContent(for: source, newItems: items)
            if hasNew {
                let entry = CacheEntry(
                    items: items,
                    timestamp: Date(),
                    contentHash: CacheEntry.contentIdentifier(for: items)
                )
                await cacheManager.save(entry, for: source)
            }
            sourceStates[source.id] = .loaded
            return items
        } catch {
            NSLog("[NewsOrchestrator] 获取 \(source.displayName) 失败: \(error.localizedDescription)")
            sourceStates[source.id] = .failed(sourceErrorMessage(error))
            return nil
        }
    }

    private func markSources(_ sources: [NewsSource], as state: SourceLoadState) {
        for source in sources {
            sourceStates[source.id] = state
        }
    }

    private func applyCachedState(_ state: SourceLoadState, for source: NewsSource) {
        switch sourceStates[source.id] {
        case .some(.loading):
            return
        case .some(.failed):
            if case .loaded = state {
                sourceStates[source.id] = state
            }
        case .some(.loaded):
            return  // 已完成加载 → 不退回到 idle
        case .some(.idle), .none:
            sourceStates[source.id] = state
        }
    }

    private func logStateLabel(_ state: AISummaryState) -> String {
        switch state {
        case .idle: return "idle"
        case .noKey: return "noKey"
        case .fetching: return "fetching"
        case .summarizing: return "summarizing"
        case .done: return "done"
        case .truncated: return "truncated"
        case .error(let msg): return "error(\(msg))"
        }
    }

    private func collectSourceResults(settings: AppSettings) -> [String: String] {
        var results: [String: String] = [:]
        if let state = sourceStates[NewsSource.weibo.id] {
            results[NewsSource.weibo.displayName] = sourceResultLabel(state, itemCount: weiboItems.count)
        }
        if let state = sourceStates[NewsSource.bilibili.id] {
            results[NewsSource.bilibili.displayName] = sourceResultLabel(state, itemCount: bilibiliItems.count)
        }
        for source in settings.activeSources where !source.isBuiltIn {
            if let state = sourceStates[source.id] {
                let count = rssItemsMap[source.id]?.count ?? 0
                results[source.displayName] = sourceResultLabel(state, itemCount: count)
            }
        }
        return results
    }

    private func sourceResultLabel(_ state: SourceLoadState, itemCount: Int) -> String {
        switch state {
        case .idle: return "idle"
        case .loading: return "loading"
        case .loaded: return "ok/\(itemCount)"
        case .failed(let msg): return "failed/\(msg)"
        }
    }

    private func recordRefreshLog(settings: AppSettings, trigger: RefreshLog.Trigger, aiBefore: String) async {
        await RefreshLog.shared.record(
            trigger: trigger,
            sourceResults: collectSourceResults(settings: settings),
            aiBefore: aiBefore,
            aiAfter: logStateLabel(aiSummaryState)
        )
    }

    private func sourceErrorMessage(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "请求超时"
            case .notConnectedToInternet, .networkConnectionLost:
                return "网络连接失败"
            default:
                return "网络请求失败"
            }
        }

        if let newsBarError = error as? NewsBarError,
           let description = newsBarError.errorDescription {
            return description
        }

        return "加载失败"
    }

    private func shouldRecoverAISummary(from state: AISummaryState) -> Bool {
        switch state {
        case .idle, .noKey, .fetching, .error:
            return true
        case .summarizing, .done, .truncated:
            return false
        }
    }

    /// Resolve the API key from cache or encrypted store. Returns empty string if unavailable.
    private func resolveAPIKey(settings: AppSettings) async -> String {
        if let cached = settings.cachedAPIKey, !cached.isEmpty {
            return cached
        }
        let store = EncryptedKeyStore()
        if let fallback = await store.readAPIKey(account: settings.currentProvider.apiKeyAccount()),
           !fallback.isEmpty {
            settings.cachedAPIKey = fallback
            return fallback
        }
        return ""
    }

    @discardableResult
    private func generateSummary(
        target: SummaryTarget,
        items: [NewsItem],
        contentHash: String,
        maxWords: Int,
        model: String,
        apiKey: String,
        provider: AIProvider,
        settings: AppSettings
    ) async -> Int {
        let budgetMode = settings.aiBudgetMode
        guard !apiKey.isEmpty else {
            setSummaryState(target, .noKey)
            return AISummaryService.readGenerationAttempts(target: target, mode: budgetMode)
        }

        // 连续截断保护：超过阈值时停止自动重试
        guard consecutiveTruncationCount < maxConsecutiveTruncations else {
            setSummaryState(target, .error("AI 连续 \(maxConsecutiveTruncations) 次截断，请检查模型配置或减少新闻条目"))
            return AISummaryService.readGenerationAttempts(target: target, mode: budgetMode)
        }

        setSummaryState(target, .summarizing)

        let (trendRange, dailyRange): (ClosedRange<Int>, ClosedRange<Int>)
        switch target {
        case .popup: (trendRange, dailyRange) = (1...2, 2...3)
        case .dashboard: (trendRange, dailyRange) = (4...5, 4...5)
        }

        do {
            let firstResult = try await AISummaryService.summarize(
                items: items, maxWords: maxWords, provider: provider,
                model: model, apiKey: apiKey,
                target: target,
                budgetMode: budgetMode,
                trendTopicCount: trendRange, dailyTopicCount: dailyRange
            )
            let wbRange = 0..<(weiboItems.count + bilibiliItems.count)

            // Determine the final result. A successful-but-unrenderable response
            // (non-truncated, zero parsed sections) triggers exactly one extra
            // budget-accounted call with a static format-enforcement suffix.
            // The original target/count/model/key/settings are retained; the
            // `.summarizing` state is preserved throughout. No loop: the final
            // state is derived solely from the final result.
            let finalResult: AISummaryService.SummaryResult
            if !firstResult.isTruncated {
                let firstParsed = AISummaryParser.parseDualSummary(
                    firstResult.summary,
                    itemCount: items.count,
                    weiboBilibiliRange: wbRange
                )
                if Self.needsFormatRetry(firstParsed) {
                    NSLog("[NewsOrchestrator] AI summary unrenderable (0 sections), retrying once with format enforcement")
                    finalResult = try await AISummaryService.summarize(
                        items: items, maxWords: maxWords, provider: provider,
                        model: model, apiKey: apiKey,
                        target: target,
                        budgetMode: budgetMode,
                        trendTopicCount: trendRange, dailyTopicCount: dailyRange,
                        formatEnforcementSuffix: Self.formatEnforcementSuffix
                    )
                } else {
                    finalResult = firstResult
                }
            } else {
                finalResult = firstResult
            }

            let requestCount = AISummaryService.readGenerationAttempts(target: target, mode: budgetMode)
            let finalParsed = AISummaryParser.parseDualSummary(
                finalResult.summary,
                itemCount: items.count,
                weiboBilibiliRange: wbRange
            )

            // After the single permitted format-enforcement retry, a non-truncated
            // response that still has zero sections is a format failure: surface a
            // clear error instead of `.done`, and do not publish the raw text/items
            // so the Popup raw-text fallback cannot render the invalid output.
            if !finalResult.isTruncated, Self.needsFormatRetry(finalParsed) {
                setSummaryState(target, .error("AI 响应格式异常，未能解析出摘要板块"))
                return requestCount
            }

            setSummaryItems(target, items)
            setParsedSummary(target, finalParsed)
            if finalResult.isTruncated {
                setTruncatedHash(contentHash, for: target)
                consecutiveTruncationCount += 1
                setSummaryState(target, .truncated(finalResult.summary))
            } else {
                setHash(contentHash, for: target)
                clearTruncatedHash(for: target)
                consecutiveTruncationCount = 0
                setSummaryState(target, .done(finalResult.summary))
            }
            return requestCount
        } catch NewsBarError.apiKeyInvalid {
            setSummaryState(target, .error("API Key 无效"))
        } catch NewsBarError.rateLimited {
            let count = AISummaryService.readGenerationAttempts(target: target, mode: budgetMode)
            let cap = AISummaryService.readGenerationCap(target: target, mode: budgetMode)
            setSummaryState(target, .error("今日 AI 调用次数已达上限（\(count)/\(cap)）"))
        } catch let error as NewsBarError {
            switch error {
            case .parseFailedWithDetail(let detail):
                NSLog("[NewsOrchestrator] AI summary retry exhausted: %@", detail)
                setSummaryState(target, .error("AI 服务暂时不可用（\(detail)）"))
            case .parseFailed:
                setSummaryState(target, .error("AI 响应格式异常"))
            default:
                NSLog("[NewsOrchestrator] AI summary NewsBarError: %@", error.localizedDescription)
                setSummaryState(target, .error("AI 总结生成失败"))
            }
        } catch let error as URLError {
            NSLog("[NewsOrchestrator] AI summary URLError: %@", error.localizedDescription)
            setSummaryState(target, .error(error.code == .timedOut ? "AI 请求超时" : "网络连接失败"))
        } catch let error as DecodingError {
            NSLog("[NewsOrchestrator] AI summary DecodingError: %@", error.localizedDescription)
            setSummaryState(target, .error("AI 响应格式异常"))
        } catch {
            NSLog("[NewsOrchestrator] AI summary failed: %@", error.localizedDescription)
            setSummaryState(target, .error("AI 总结生成失败"))
        }
        return AISummaryService.readGenerationAttempts(target: target, mode: budgetMode)
    }

    func allActiveItems(settings: AppSettings) -> [NewsItem] {
        var all: [NewsItem] = []
        all.append(contentsOf: weiboItems)
        all.append(contentsOf: bilibiliItems)
        for source in settings.activeSources where !source.isBuiltIn {
            if let items = rssItemsMap[source.id] {
                all.append(contentsOf: items)
            }
        }
        return all
    }

    func clearCache() async {
        await cacheManager.clear()
        weiboItems = []
        bilibiliItems = []
        rssItemsMap = [:]
        aiSummaryState = .idle
        aiSummaryItems = []
        aiParsedSummary = nil
        dashboardSummaryState = .idle
        dashboardSummaryItems = []
        dashboardParsedSummary = nil
        sourceStates = [:]
        popupLastHash = nil
        dashboardLastHash = nil
        popupLastTruncatedHash = nil
        dashboardLastTruncatedHash = nil
        consecutiveTruncationCount = 0
    }

    func refreshRSSSource(url: String, name: String) async {
        let source = NewsSource.rss(name: name, url: url)
        sourceStates[source.id] = .loading
        if let items = await fetchAndCache(
            for: source,
            fetcher: {
                try await RSSService.fetch(url: url, sourceName: name)
            }
        ) {
            rssItemsMap[url] = items
        }
    }
}
