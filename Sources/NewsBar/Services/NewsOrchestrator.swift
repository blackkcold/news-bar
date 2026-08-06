import Foundation
import Observation

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
        case .invalidURL: return "error.invalidURL".localized
        case .requestFailed: return "error.requestFailed".localized
        case .parseFailed: return "error.parseFailed".localized
        case .parseFailedWithDetail(let detail): return L10n.string("error.parseFailedDetail", detail)
        case .apiKeyInvalid: return "error.apiKeyInvalid".localized
        case .rateLimited: return "error.rateLimited".localized
        }
    }
}

@MainActor
@Observable
final class NewsOrchestrator {

    // MARK: - Published State

    var weiboItems: [NewsItem] = []
    var bilibiliItems: [NewsItem] = []
    var rssItemsMap: [String: [NewsItem]] = [:]

    // Shared summary context — Popup and Dashboard render the same generated result.
    var aiSummaryState = AISummaryState.idle
    var aiSummaryItems: [NewsItem] = []
    var aiParsedSummary: ParsedSummary?

    var isRefreshing = false
    var sourceStates: [String: SourceLoadState] = [:]
    var manualRefreshWarning: String?
    var batchProgress = BatchProgress.zero

    // MARK: - Private State

    private let cacheManager = CacheManager()
    private let translationCacheStore = TranslationCacheStore()
    private let trendHistoryStore = TrendHistoryStore.shared
    private let rateLimiter = RateLimiter()
    private var aiSummaryCacheStore: AISummaryCacheStore {
        AISummaryCacheStore(language: L10n.currentLanguage)
    }
    private var isLoadingCachedState = false
    private var refreshWaiters: [RefreshWaiter] = []
    private var pendingManualRefresh = false
    var sharedSummaryLastHash: String?
    /// 截断内容哈希：防止对同一截断内容重复生成，成功生成后清除。
    var sharedSummaryLastTruncatedHash: String?
    var sharedSummaryConsecutiveTruncationCount = 0
    let maxConsecutiveTruncations = 3
    private var lastHotRefresh: Date?
    private var lastSourceRefresh: [String: Date] = [:]
    private var rssUnchangedRefreshCounts: [String: Int] = [:]
    private var rssLastChangedAt: [String: Date] = [:]
    private var rssFailureCounts: [String: Int] = [:]
    private var lastSummaryGeneratedAt: Date?
    /// Last summary triggered by a Weibo "爆" label, to throttle repeats.
    private var lastBurstSummaryAt: Date?
    private var lastHourlyPushAt: Date?
    /// Titles of Weibo "爆" topics already pushed, to avoid re-notifying the same one.
    private var notifiedBurstTopics: Set<String> = []
    /// Latest research keyed by burst topic title, cached for the detail window.
    private var burstResearchCache: [String: BurstResearch] = [:]
    private var latestTrendSummary = TrendChangeSummary.none
    /// The shared result uses the detailed Dashboard prompt. Popup limits rows at render time.
    static let sharedSummaryTarget: SummaryTarget = .dashboard

    static func budgetBaseline(settings: AppSettings, target: SummaryTarget) -> Int {
        settings.aiBudgetMode == .shared
            ? settings.todayAIRequestCount
            : settings.todayAIRequestCount(for: target)
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

    /// True when the parsed result has real content in both categories.
    internal static func hasBothSections(_ parsed: ParsedSummary) -> Bool {
        !parsed.trendOverview.isEmpty && !parsed.dailyEssentials.isEmpty
    }

    internal static func shouldGenerateSummary(
        hasCachedSummary: Bool,
        hasNewContent: Bool,
        isManualRefresh: Bool,
        hotChanged: Bool,
        rssChanged: Bool,
        trendIsSignificant: Bool,
        elapsedSinceSummary: TimeInterval,
        shouldRecover: Bool,
        hasBurstWeibo: Bool = false,
        elapsedSinceBurstSummary: TimeInterval = .infinity
    ) -> Bool {
        // A Weibo "爆" label triggers an immediate summary, unless a burst
        // summary was generated very recently (burstSummaryCooldown).
        if hasBurstWeibo {
            return elapsedSinceBurstSummary >= RefreshPolicy.burstSummaryCooldown
        }
        return !hasCachedSummary
            || (isManualRefresh && hasNewContent)
            || (hotChanged && trendIsSignificant
                && hasNewContent
                && elapsedSinceSummary >= RefreshPolicy.autoSummaryInterval)
            || (rssChanged
                && hasNewContent
                && elapsedSinceSummary >= RefreshPolicy.autoSummaryInterval)
            || (hasNewContent && shouldRecover)
    }

    // MARK: - Public API

    func loadCached(settings: AppSettings) async {
        await loadCachedState(settings: settings, logTrigger: .popoverOpen)
    }

    func preloadCached(settings: AppSettings) async {
        await loadCachedState(settings: settings, logTrigger: nil)
    }

    private func loadCachedState(settings: AppSettings, logTrigger: RefreshLog.Trigger?) async {
        guard !isLoadingCachedState else { return }
        isLoadingCachedState = true
        defer { isLoadingCachedState = false }

        let aiBefore = logStateLabel(aiSummaryState)
        var sourceResults: [String: String] = [:]
        // 内存优先: 若已有数据则不覆盖 (避免 stale 缓存清空自动刷新填入的新数据)
        if weiboItems.isEmpty {
            if let cached = await cacheManager.load(for: .weibo) {
                weiboItems = cached.items
                let validatedAt = cached.lastValidatedAt ?? cached.timestamp
                lastHotRefresh = max(lastHotRefresh ?? .distantPast, validatedAt)
                if cached.isStale {
                    sourceStates[NewsSource.weibo.id] = .idle
                    sourceResults[NewsSource.weibo.displayName] = "cacheStale"
                } else {
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
                bilibiliItems = cached.items
                let validatedAt = cached.lastValidatedAt ?? cached.timestamp
                lastHotRefresh = max(lastHotRefresh ?? .distantPast, validatedAt)
                if cached.isStale {
                    sourceStates[NewsSource.bilibili.id] = .idle
                    sourceResults[NewsSource.bilibili.displayName] = "cacheStale"
                } else {
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
                    rssItemsMap[source.id] = entry.items
                    lastSourceRefresh[source.id] = entry.lastValidatedAt ?? entry.timestamp
                    if entry.isStale {
                        sourceStates[source.id] = .idle
                        sourceResults[source.displayName] = "cacheStale"
                    } else {
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

        await restoreCachedSummaryIfPossible(settings: settings)

        if let logTrigger {
            await RefreshLog.shared.record(
                trigger: logTrigger,
                sourceResults: sourceResults,
                aiBefore: aiBefore,
                aiAfter: logStateLabel(aiSummaryState)
            )
        }
    }

    func refreshIfNeeded(settings: AppSettings, trigger: RefreshLog.Trigger = .startup) async {
        await enqueueRefresh(
            settings: settings,
            trigger: trigger,
            isManual: false,
            refreshHot: true,
            rssSources: settings.activeSources.filter { !$0.isBuiltIn }
        )
    }

    func manualRefresh(settings: AppSettings) async {
        await enqueueRefresh(
            settings: settings,
            trigger: .manual,
            isManual: true,
            refreshHot: true,
            rssSources: settings.activeSources.filter { !$0.isBuiltIn }
        )
    }

    func refreshScheduled(
        settings: AppSettings,
        visibility: RefreshVisibility,
        trigger: RefreshLog.Trigger = .scheduled,
        now: Date = Date()
    ) async {
        let hotDue = RefreshPolicy.isDue(
            lastRefresh: lastHotRefresh,
            interval: RefreshPolicy.hotInterval(for: visibility),
            key: "hot",
            now: now
        )
        let rssSources = settings.activeSources.filter { source in
            guard !source.isBuiltIn else { return false }
            let failureCount = rssFailureCounts[source.id, default: 0]
            let interval = failureCount > 0
                ? RefreshPolicy.rssFailureRetryInterval(failureCount: failureCount)
                : RefreshPolicy.rssInterval(
                    unchangedRefreshCount: rssUnchangedRefreshCounts[source.id, default: 0],
                    changedRecently: now.timeIntervalSince(rssLastChangedAt[source.id] ?? .distantPast)
                        < 6 * 60 * 60,
                    visibility: visibility
                )
            return RefreshPolicy.isDue(
                lastRefresh: lastSourceRefresh[source.id],
                interval: interval,
                key: source.id,
                now: now
            )
        }

        guard hotDue || !rssSources.isEmpty else { return }
        await enqueueRefresh(
            settings: settings,
            trigger: trigger,
            isManual: false,
            refreshHot: hotDue,
            rssSources: rssSources
        )
    }

    private func enqueueRefresh(
        settings: AppSettings,
        trigger: RefreshLog.Trigger,
        isManual: Bool,
        refreshHot: Bool,
        rssSources: [NewsSource]
    ) async {
        if isRefreshing {
            if isManual { pendingManualRefresh = true }
            let waiter = RefreshWaiter()
            refreshWaiters.append(waiter)
            await withTaskCancellationHandler {
                await waiter.awaitResume()
            } onCancel: {
                Task { @MainActor in
                    refreshWaiters.removeAll { $0 === waiter }
                    waiter.resumeOnce()
                }
            }
            return
        }

        isRefreshing = true
        await runRefreshCycle(
            settings: settings,
            trigger: trigger,
            isManual: isManual,
            refreshHot: refreshHot,
            rssSources: rssSources
        )

        if pendingManualRefresh {
            pendingManualRefresh = false
            await runRefreshCycle(
                settings: settings,
                trigger: .manual,
                isManual: true,
                refreshHot: true,
                rssSources: settings.activeSources.filter { !$0.isBuiltIn }
            )
        }

        isRefreshing = false
        let waiters = refreshWaiters
        refreshWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resumeOnce() }
    }

    private func runRefreshCycle(
        settings: AppSettings,
        trigger: RefreshLog.Trigger,
        isManual: Bool,
        refreshHot: Bool,
        rssSources: [NewsSource]
    ) async {

        let aiBefore = logStateLabel(aiSummaryState)
        if isManual {
            manualRefreshWarning = await rateLimiter.manualRefreshWarning()
        }

        settings.recordRefresh()
        var sourcesToLoad = rssSources
        if refreshHot {
            sourcesToLoad.insert(.bilibili, at: 0)
            sourcesToLoad.insert(.weibo, at: 0)
        }
        markSources(sourcesToLoad, as: .loading)

        let previousSummaryState = aiSummaryState
        let apiKey: String
        if let cached = settings.cachedAPIKey, !cached.isEmpty {
            apiKey = cached
        } else {
            let store = EncryptedKeyStore()
            if let fallback = await store.readAPIKey(account: settings.activeAPIKeyAccount),
               !fallback.isEmpty {
                settings.cachedAPIKey = fallback
                apiKey = fallback
            } else {
                apiKey = ""
            }
        }
        var hotChanged = false
        var trendSummary = latestTrendSummary
        if refreshHot {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask { await self.fetchWeibo(useCacheFallback: !isManual) }
                group.addTask { await self.fetchBilibili(useCacheFallback: !isManual) }
                for await changed in group {
                    hotChanged = hotChanged || changed
                }
            }
            lastHotRefresh = Date()
            if !weiboItems.isEmpty || !bilibiliItems.isEmpty {
                trendSummary = await trendHistoryStore.record(
                    weibo: weiboItems,
                    bilibili: bilibiliItems
                )
                latestTrendSummary = trendSummary
            }
        }

        var rssChanged = false
        if !rssSources.isEmpty {
            let batchSize = 6
            batchProgress = BatchProgress(completed: 0, total: rssSources.count)

            for batchStart in stride(from: 0, to: rssSources.count, by: batchSize) {
                let batch = Array(rssSources[batchStart..<min(batchStart + batchSize, rssSources.count)])

                await withTaskGroup(of: Bool.self) { group in
                    for source in batch {
                        group.addTask { await self.fetchRSS(source: source, useCacheFallback: !isManual, settings: settings) }
                    }
                    for await changed in group {
                        rssChanged = rssChanged || changed
                    }
                }

                batchProgress.completed = min(batchStart + batchSize, rssSources.count)

                for source in batch {
                    lastSourceRefresh[source.id] = Date()
                }
            }
            batchProgress = .zero
        }

        if isManual {
            await rateLimiter.recordManualRefresh()
            manualRefreshWarning = await rateLimiter.manualRefreshWarning()
        }

        await handleSharedAISummary(
            settings: settings,
            apiKey: apiKey,
            previousState: previousSummaryState,
            isManualRefresh: isManual,
            hotChanged: hotChanged,
            rssChanged: rssChanged,
            trendSummary: trendSummary
        )

        await handleBurstTopics(settings: settings, apiKey: apiKey)
        await handleKeywordTopics(settings: settings, apiKey: apiKey)

        let allItems = allActiveItems(settings: settings)
        if !isManual {
            let now = Date()
            if settings.hourlyPushEnabled,
               trigger == .startup || now.timeIntervalSince(lastHourlyPushAt ?? .distantPast) >= 60 * 60 {
                await NotificationService.sendHourlyPush(items: allItems, count: settings.pushCount)
                lastHourlyPushAt = now
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

    private func fetchWeibo(useCacheFallback: Bool) async -> Bool {
        if let result = await fetchAndCache(
            for: .weibo,
            fetcher: { try await WeiboHotService.fetch() }
        ) {
            weiboItems = result.items
            return result.changed
        } else if useCacheFallback, weiboItems.isEmpty,
                  let cached = await cacheManager.load(for: .weibo) {
            weiboItems = cached.items
        }
        return false
    }

    private func fetchBilibili(useCacheFallback: Bool) async -> Bool {
        if let result = await fetchAndCache(
            for: .bilibili,
            fetcher: { try await BilibiliHotService.fetch() }
        ) {
            bilibiliItems = result.items
            return result.changed
        } else if useCacheFallback, bilibiliItems.isEmpty,
                  let cached = await cacheManager.load(for: .bilibili) {
            bilibiliItems = cached.items
        }
        return false
    }

    private func fetchRSS(source: NewsSource, useCacheFallback: Bool, settings: AppSettings) async -> Bool {
        let existing = await cacheManager.load(for: source)
        let fetchedItems: [NewsItem]?
        let changed: Bool

        do {
            let result = try await RSSService.fetchConditional(
                url: source.id,
                sourceName: source.displayName,
                eTag: existing?.eTag,
                lastModified: existing?.lastModified
            )
            switch result {
            case .notModified(let eTag, let lastModified):
                guard let validated = await cacheManager.markValidated(
                    for: source,
                    eTag: eTag,
                    lastModified: lastModified
                ) else {
                    throw NewsBarError.requestFailed
                }
                rssItemsMap[source.id] = validated.items
                fetchedItems = validated.items
                changed = false
                rssUnchangedRefreshCounts[source.id, default: 0] += 1

            case .modified(let items, let eTag, let lastModified):
                guard !items.isEmpty else {
                    throw NewsBarError.parseFailed
                }
                let translatedItems = await translateRSSItemsIfNeeded(items, settings: settings)
                let now = Date()
                let contentHash = CacheEntry.contentIdentifier(for: translatedItems)
                changed = existing?.contentHash != contentHash
                let entry = CacheEntry(
                    items: translatedItems,
                    timestamp: changed ? now : (existing?.timestamp ?? now),
                    contentHash: contentHash,
                    lastValidatedAt: now,
                    eTag: eTag,
                    lastModified: lastModified
                )
                await cacheManager.save(entry, for: source)
                rssItemsMap[source.id] = translatedItems
                fetchedItems = translatedItems
                if changed {
                    rssUnchangedRefreshCounts[source.id] = 0
                    rssLastChangedAt[source.id] = now
                } else {
                    rssUnchangedRefreshCounts[source.id, default: 0] += 1
                }
            }
            sourceStates[source.id] = .loaded
            rssFailureCounts[source.id] = 0
        } catch {
            NSLog("[NewsOrchestrator] 获取 \(source.displayName) 失败: \(error.localizedDescription)")
            sourceStates[source.id] = .failed(sourceErrorMessage(error))
            rssFailureCounts[source.id, default: 0] += 1
            changed = false
            if useCacheFallback, rssItemsMap[source.id, default: []].isEmpty, let existing {
                rssItemsMap[source.id] = existing.items
                fetchedItems = existing.items
            } else {
                fetchedItems = nil
            }
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
        return changed
    }

    // MARK: - RSS Title Translation

    /// Translate RSS titles when English UI + translation are enabled.
    /// Uses the file cache to avoid re-translating and hitting the free API rate limit.
    /// Falls back to the original title on any failure.
    private func translateRSSItemsIfNeeded(_ items: [NewsItem], settings: AppSettings) async -> [NewsItem] {
        guard settings.rssTitleTranslationEnabled, settings.appLanguage == .en else {
            return items
        }
        let targetLang = settings.appLanguage.bcp47
        var translated: [NewsItem] = []
        for item in items {
            if let cached = await translationCacheStore.cachedTranslation(for: item.title, targetLang: targetLang) {
                translated.append(item.withTranslatedTitle(cached))
            } else {
                let result = await TranslationService.translate(item.title, from: "zh-CN", to: targetLang)
                if result != item.title {
                    await translationCacheStore.saveTranslation(result, for: item.title, targetLang: targetLang)
                    translated.append(item.withTranslatedTitle(result))
                } else {
                    translated.append(item)
                }
            }
        }
        return translated
    }

    /// Titles currently being researched (avoids duplicate work when the detail
    /// window opens while a fake push is still researching in the background).
    private var burstResearchInFlight: Set<String> = []

    /// Builds the burst research search config, honoring the given `forceSearch`
    /// flag (used by the developer test to always run web search) or the user's
    /// realtime `webSearchEnabled` toggle.
    private func makeSearchConfig(settings: AppSettings, forceSearch: Bool) -> WebSearchService.Config? {
        let enabled = forceSearch || settings.webSearchEnabled
        guard enabled else { return nil }
        return WebSearchService.Config(
            provider: .firecrawl,
            apiKey: settings.firecrawlAPIKey,
            maxResults: 6
        )
    }

    // MARK: - Burst (爆) topic push

    /// Detects new Weibo "爆" topics and pushes a single notification each with
    /// AI research pre-generated. De-duplicates by title and respects a cooldown.
    private func handleBurstTopics(settings: AppSettings, apiKey: String) async {
        guard settings.burstPushEnabled else { return }
        guard !apiKey.isEmpty else { return }
        let now = Date()
        let cooldown = now.timeIntervalSince(lastBurstSummaryAt ?? .distantPast)
        guard cooldown >= RefreshPolicy.burstSummaryCooldown else { return }

        let newBursts = weiboItems
            .filter { $0.hotLabel == "爆" && !notifiedBurstTopics.contains($0.title) }
        guard !newBursts.isEmpty else { return }
        lastBurstSummaryAt = now

        let trendContext = latestTrendSummary.context
        for burst in newBursts.prefix(2) {
            notifiedBurstTopics.insert(burst.title)
            let research = await BurstResearchService.research(
                BurstResearchService.ResearchInput(
                    item: burst,
                    trendContext: trendContext,
                    apiKey: apiKey,
                    connection: settings.resolvedAIConnection,
                    model: settings.aiModel,
                    summaryLanguage: settings.appLanguage,
                    disableDeepSeekThinking: settings.aiDisableDeepSeekThinking,
                    searchConfig: makeSearchConfig(settings: settings, forceSearch: false),
                    dailyCap: settings.burstDailyCap,
                    maxRefetchURLs: 3
                )
            )
            settings.recordBurstResearchRequests(BurstResearchService.readDailyCount())
            if !research.summary.isEmpty {
                burstResearchCache[burst.title] = research
                let title = L10n.string("notif.burstTitle", language: settings.appLanguage)
                    + " \(burst.title)"
                NotificationService.sendBurstNotification(
                    title: title,
                    summary: research.summary,
                    eventID: burst.title
                )
            }
            await RefreshLog.shared.recordBurst(
                topic: burst.title,
                searchStatus: research.searchStatus.rawValue,
                requestCount: BurstResearchService.readDailyCount()
            )
        }
    }

    /// Returns cached research for a burst topic, or nil when none was pre-generated.
    func cachedBurstResearch(for title: String) -> BurstResearch? {
        burstResearchCache[title]
    }

    /// True while a research pass for the title is still in progress.
    func isBurstResearchInFlight(for title: String) -> Bool {
        burstResearchInFlight.contains(title)
    }

    /// Force-recomputes research for a burst topic (used by the detail window's
    /// retry action). Returns a freshly generated research value.
    func regenerateBurstResearch(for burst: NewsItem, settings: AppSettings) async -> BurstResearch {
        let apiKey = await resolveAPIKey(settings: settings)
        guard !apiKey.isEmpty else { return BurstResearch() }
        let research = await BurstResearchService.research(
            BurstResearchService.ResearchInput(
                item: burst,
                trendContext: latestTrendSummary.context,
                apiKey: apiKey,
                connection: settings.resolvedAIConnection,
                model: settings.aiModel,
                summaryLanguage: settings.appLanguage,
                disableDeepSeekThinking: settings.aiDisableDeepSeekThinking,
                searchConfig: makeSearchConfig(settings: settings, forceSearch: false),
                dailyCap: settings.burstDailyCap,
                maxRefetchURLs: 3
            )
        )
        burstResearchCache[burst.title] = research
        return research
    }

    // MARK: - Custom keyword topic push

    /// Tracks which (keyword,title) pairs have already been researched to avoid
    /// re-notifying the same match across refreshes.
    private var notifiedKeywordPairs: Set<String> = []

    /// Detects news items whose titles match a user keyword and pushes a single
    /// notification with AI research pre-generated, reusing the burst pipeline.
    /// Scans Weibo + Bilibili + all enabled RSS. De-duplicates by
    /// (keyword,title) and applies a global research cooldown.
    private func handleKeywordTopics(settings: AppSettings, apiKey: String) async {
        guard settings.keywordTrackingEnabled else { return }
        guard !apiKey.isEmpty else { return }
        let active = settings.activeKeywords
        guard !active.isEmpty else { return }

        let now = Date()
        let cooldown = now.timeIntervalSince(lastBurstSummaryAt ?? .distantPast)
        guard cooldown >= RefreshPolicy.burstSummaryCooldown else { return }

        var matches: [(keyword: String, item: NewsItem)] = []
        for item in allActiveItems(settings: settings) {
            guard settings.keywordMatches(item.title) else { continue }
            let foldedTitle = item.title.folding(options: [.caseInsensitive], locale: .current)
            guard let keyword = active.first(where: { kw in
                foldedTitle.contains(kw.folding(options: [.caseInsensitive], locale: .current))
            }) else { continue }
            let pair = "\(keyword)\n\(item.title)"
            guard !notifiedKeywordPairs.contains(pair) else { continue }
            matches.append((keyword, item))
        }
        guard !matches.isEmpty else { return }
        lastBurstSummaryAt = now

        let trendContext = latestTrendSummary.context
        for match in matches.prefix(2) {
            let pair = "\(match.keyword)\n\(match.item.title)"
            notifiedKeywordPairs.insert(pair)
            let research = await BurstResearchService.research(
                BurstResearchService.ResearchInput(
                    item: match.item,
                    trendContext: trendContext,
                    apiKey: apiKey,
                    connection: settings.resolvedAIConnection,
                    model: settings.aiModel,
                    summaryLanguage: settings.appLanguage,
                    disableDeepSeekThinking: settings.aiDisableDeepSeekThinking,
                    searchConfig: makeSearchConfig(settings: settings, forceSearch: false),
                    dailyCap: settings.burstDailyCap,
                    maxRefetchURLs: 3
                )
            )
            settings.recordBurstResearchRequests(BurstResearchService.readDailyCount())
            if !research.summary.isEmpty {
                burstResearchCache[match.item.title] = research
                let title = L10n.string("notif.keywordTitle", language: settings.appLanguage)
                    + " \(match.keyword) · \(match.item.title)"
                NotificationService.sendBurstNotification(
                    title: title,
                    summary: research.summary,
                    eventID: match.item.title
                )
            }
            await RefreshLog.shared.recordBurst(
                topic: match.item.title,
                searchStatus: research.searchStatus.rawValue,
                requestCount: BurstResearchService.readDailyCount()
            )
        }
    }

    // MARK: - Developer test: fake burst push

    /// Fires a fake Weibo "爆" push (developer test mode). Opens the detail
    /// window immediately (showing its loading state), then runs the research
    /// pipeline in the background, fills the cache, and posts the notification.
    /// The developer toggle always forces web search so the full pipeline is
    /// exercised; the window polls for the result via `isBurstResearchInFlight`.
    func fireFakeBurstPush(settings: AppSettings) async {
        guard settings.burstTestMode else { return }
        let trimmedTopic = settings.burstTestTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTopic.isEmpty else { return }
        let fake = NewsItem(
            title: trimmedTopic,
            url: "https://s.weibo.com",
            source: .weibo,
            rank: 1,
            hotLabel: "爆"
        )
        let apiKey = await resolveAPIKey(settings: settings)
        guard !apiKey.isEmpty else { return }

        // 1) Open the detail window right away so the user sees the loading state.
        openBurstDetail(title: trimmedTopic)

        // 2) Mark in-flight so the window's load() waits instead of re-researching.
        burstResearchInFlight.insert(trimmedTopic)
        defer { burstResearchInFlight.remove(trimmedTopic) }

        let research = await BurstResearchService.research(
            BurstResearchService.ResearchInput(
                item: fake,
                trendContext: latestTrendSummary.context,
                apiKey: apiKey,
                connection: settings.resolvedAIConnection,
                model: settings.aiModel,
                summaryLanguage: settings.appLanguage,
                disableDeepSeekThinking: settings.aiDisableDeepSeekThinking,
                searchConfig: makeSearchConfig(settings: settings, forceSearch: true),
                dailyCap: settings.burstDailyCap,
                maxRefetchURLs: 3
            )
        )
        settings.recordBurstResearchRequests(BurstResearchService.readDailyCount())
        burstResearchCache[trimmedTopic] = research
        let notifTitle = L10n.string("notif.burstTitle", language: settings.appLanguage) + " \(trimmedTopic)"
        NotificationService.sendBurstNotification(
            title: notifTitle,
            summary: research.summary.isEmpty ? "burst.noSummary".localized : research.summary,
            eventID: trimmedTopic
        )
        await RefreshLog.shared.recordBurst(
            topic: trimmedTopic,
            searchStatus: research.searchStatus.rawValue,
            requestCount: BurstResearchService.readDailyCount()
        )
    }

    /// Fills the test-mode topic field with the current Weibo #1 hot search title.
    func fillBurstTestWithTopTrend() async -> String {
        guard let top = weiboItems.first else { return "" }
        return top.title
    }

    private func openBurstDetail(title: String) {
        NotificationCenter.default.post(
            name: .burstDetailRequest,
            object: nil,
            userInfo: ["title": title]
        )
    }

    // MARK: - Shared Summary (generated on refresh)

    private func handleSharedAISummary(
        settings: AppSettings,
        apiKey: String,
        previousState: AISummaryState,
        isManualRefresh: Bool,
        hotChanged: Bool,
        rssChanged: Bool,
        trendSummary: TrendChangeSummary
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

        guard AISummaryService.tryAcquireGenerationLock(for: Self.sharedSummaryTarget) else {
            aiSummaryState = .error("error.aiGenerating".localized)
            return
        }
        defer { AISummaryService.releaseGenerationLock(for: Self.sharedSummaryTarget) }

        let newHash = CacheEntry.contentIdentifier(for: allItems)
        let hasNewContent = newHash != sharedSummaryLastHash
            && newHash != sharedSummaryLastTruncatedHash
        let elapsed = Date().timeIntervalSince(lastSummaryGeneratedAt ?? .distantPast)
        let hasBurstWeibo = weiboItems.contains { $0.hotLabel == "爆" }
        let elapsedSinceBurst = Date().timeIntervalSince(lastBurstSummaryAt ?? .distantPast)
        let shouldGenerate = Self.shouldGenerateSummary(
            hasCachedSummary: sharedSummaryLastHash != nil,
            hasNewContent: hasNewContent,
            isManualRefresh: isManualRefresh,
            hotChanged: hotChanged,
            rssChanged: rssChanged,
            trendIsSignificant: trendSummary.isSignificant,
            elapsedSinceSummary: elapsed,
            shouldRecover: shouldRecoverAISummary(from: previousState),
            hasBurstWeibo: hasBurstWeibo,
            elapsedSinceBurstSummary: elapsedSinceBurst
        )

        if shouldGenerate {
            aiSummaryState = .fetching
            AISummaryService.initBudget(
                target: Self.sharedSummaryTarget,
                mode: .shared,
                baseline: settings.todayAIRequestCount,
                cap: settings.aiDailyCap
            )
            let requestCount = await generateSummary(
                items: allItems,
                contentHash: newHash,
                maxWords: settings.aiDashboardMaxWords,
                model: settings.aiModel,
                apiKey: apiKey,
                connection: settings.resolvedAIConnection,
                settings: settings,
                trendHistoryContext: trendSummary.context,
                trendHistoryHash: trendSummary.historyHash,
                burstTriggered: hasBurstWeibo,
                summaryLanguage: settings.appLanguage
            )
            settings.recordAIRequests(requestCount)
        } else {
            aiSummaryState = previousState
        }
    }

    // MARK: - Shared Summary Recovery

    /// Safe to call when either UI opens. It only generates if no current shared result exists.
    func generateSharedSummaryIfNeeded(settings: AppSettings) async {
        guard settings.aiSummaryEnabled else { return }

        let allItems = allActiveItems(settings: settings)
        guard !allItems.isEmpty else {
            aiSummaryState = .idle
            return
        }

        let apiKey = await resolveAPIKey(settings: settings)
        guard !apiKey.isEmpty else {
            aiSummaryState = .noKey
            return
        }

        let newHash = CacheEntry.contentIdentifier(for: allItems)
        let shouldGenerate = (newHash != sharedSummaryLastHash && newHash != sharedSummaryLastTruncatedHash)
            || shouldRecoverAISummary(from: aiSummaryState)

        guard shouldGenerate else { return }

        guard AISummaryService.tryAcquireGenerationLock(for: Self.sharedSummaryTarget) else {
            return
        }
        defer { AISummaryService.releaseGenerationLock(for: Self.sharedSummaryTarget) }

        AISummaryService.initBudget(
            target: Self.sharedSummaryTarget,
            mode: .shared,
            baseline: settings.todayAIRequestCount,
            cap: settings.aiDailyCap
        )
        let requestCount = await generateSummary(
            items: allItems,
            contentHash: newHash,
            maxWords: settings.aiDashboardMaxWords,
            model: settings.aiModel,
            apiKey: apiKey,
            connection: settings.resolvedAIConnection,
            settings: settings,
            trendHistoryContext: latestTrendSummary.context,
            trendHistoryHash: latestTrendSummary.historyHash,
            summaryLanguage: settings.appLanguage
        )
        settings.recordAIRequests(requestCount)
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
        guard AISummaryService.tryAcquireGenerationLock(for: Self.sharedSummaryTarget) else {
            return
        }
        defer { AISummaryService.releaseGenerationLock(for: Self.sharedSummaryTarget) }

        let apiKey: String
        if let cached = settings.cachedAPIKey, !cached.isEmpty {
            apiKey = cached
        } else {
            let store = EncryptedKeyStore()
            let account = settings.activeAPIKeyAccount
            if let fallback = await store.readAPIKey(account: account),
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
            target: Self.sharedSummaryTarget,
            mode: .shared,
            baseline: settings.todayAIRequestCount,
            cap: settings.aiDailyCap
        )
        let newHash = CacheEntry.contentIdentifier(for: allItems)
        let requestCount = await generateSummary(
            items: allItems,
            contentHash: newHash,
            maxWords: settings.aiDashboardMaxWords,
            model: settings.aiModel,
            apiKey: apiKey,
            connection: settings.resolvedAIConnection,
            settings: settings,
            trendHistoryContext: latestTrendSummary.context,
            trendHistoryHash: latestTrendSummary.historyHash,
            summaryLanguage: settings.appLanguage
        )
        settings.recordAIRequests(requestCount)
    }

    // MARK: - Shared Helpers

    private struct SourceFetchResult {
        let items: [NewsItem]
        let changed: Bool
    }

    private func fetchAndCache(
        for source: NewsSource,
        fetcher: () async throws -> [NewsItem]
    ) async -> SourceFetchResult? {
        do {
            let items = try await fetcher()
            guard !items.isEmpty else {
                sourceStates[source.id] = .failed("error.noContent".localized)
                return nil
            }

            let now = Date()
            let existing = await cacheManager.load(for: source)
            let contentHash = CacheEntry.contentIdentifier(for: items)
            let hasNew = existing?.contentHash != contentHash
            let entry = CacheEntry(
                items: items,
                timestamp: hasNew ? now : (existing?.timestamp ?? now),
                contentHash: contentHash,
                lastValidatedAt: now,
                eTag: existing?.eTag,
                lastModified: existing?.lastModified
            )
            await cacheManager.save(entry, for: source)
            sourceStates[source.id] = .loaded
            return SourceFetchResult(items: items, changed: hasNew)
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
                return "error.timeout".localized
            case .notConnectedToInternet, .networkConnectionLost:
                return "error.noNetwork".localized
            default:
                return "error.requestFailed".localized
            }
        }

        if let newsBarError = error as? NewsBarError,
           let description = newsBarError.errorDescription {
            return description
        }

        return "error.loadFailed".localized
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
        if let fallback = await store.readAPIKey(account: settings.activeAPIKeyAccount),
           !fallback.isEmpty {
            settings.cachedAPIKey = fallback
            return fallback
        }
        return ""
    }

    private func restoreCachedSummaryIfPossible(settings: AppSettings) async {
        guard settings.aiSummaryEnabled,
              sharedSummaryLastHash == nil,
              let cached = await aiSummaryCacheStore.load() else { return }
        let currentItems = allActiveItems(settings: settings)
        guard !currentItems.isEmpty,
              CacheEntry.contentIdentifier(for: currentItems) == cached.contentHash else { return }

        let trendCount = min(cached.trendItemCount, cached.items.count)
        aiSummaryItems = cached.items
        aiParsedSummary = AISummaryParser.parseDualSummary(
            cached.summary,
            itemCount: cached.items.count,
            weiboBilibiliRange: 0..<trendCount
        )
        sharedSummaryLastHash = cached.contentHash
        sharedSummaryLastTruncatedHash = nil
        sharedSummaryConsecutiveTruncationCount = 0
        lastSummaryGeneratedAt = cached.generatedAt
        aiSummaryState = .done(cached.summary)
    }

    @discardableResult
    private func generateSummary(
        items: [NewsItem],
        contentHash: String,
        maxWords: Int,
        model: String,
        apiKey: String,
        connection: ResolvedAIConnection,
        settings: AppSettings,
        trendHistoryContext: String,
        trendHistoryHash: String,
        burstTriggered: Bool = false,
        summaryLanguage: AppLanguage = .zh
    ) async -> Int {
        let budgetMode: AISummaryBudgetMode = .shared
        guard !apiKey.isEmpty else {
            aiSummaryState = .noKey
            return AISummaryService.readGenerationAttempts(target: Self.sharedSummaryTarget, mode: budgetMode)
        }

        // 连续截断保护：超过阈值时停止自动重试
        guard sharedSummaryConsecutiveTruncationCount < maxConsecutiveTruncations else {
            aiSummaryState = .error(L10n.string("error.aiTruncated", maxConsecutiveTruncations))
            return AISummaryService.readGenerationAttempts(target: Self.sharedSummaryTarget, mode: budgetMode)
        }

        aiSummaryState = .summarizing
        let trendRange = 4...5
        let dailyRange = 4...5

        do {
            let firstResult = try await AISummaryService.summarize(
                items: items, maxWords: maxWords, connection: connection,
                model: model, apiKey: apiKey,
                target: Self.sharedSummaryTarget,
                budgetMode: budgetMode,
                trendTopicCount: trendRange, dailyTopicCount: dailyRange,
                trendHistoryContext: trendHistoryContext,
                summaryLanguage: summaryLanguage,
                disableDeepSeekThinking: settings.aiDisableDeepSeekThinking
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
                        items: items, maxWords: maxWords, connection: connection,
                        model: model, apiKey: apiKey,
                        target: Self.sharedSummaryTarget,
                        budgetMode: budgetMode,
                        trendTopicCount: trendRange, dailyTopicCount: dailyRange,
                        formatEnforcementSuffix: Self.formatEnforcementSuffix,
                        trendHistoryContext: trendHistoryContext,
                        summaryLanguage: summaryLanguage,
                        disableDeepSeekThinking: settings.aiDisableDeepSeekThinking
                    )
                } else {
                    finalResult = firstResult
                }
            } else {
                finalResult = firstResult
            }

            let requestCount = AISummaryService.readGenerationAttempts(target: Self.sharedSummaryTarget, mode: budgetMode)
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
                aiSummaryState = .error("error.aiFormat".localized)
                return requestCount
            }

            aiSummaryItems = items
            aiParsedSummary = finalParsed
            // A `length`-truncated response that still yields both sections with
            // real content is treated as complete: the truncation only clipped
            // trailing prose, not the substance users see.
            if finalResult.isTruncated, !Self.hasBothSections(finalParsed) {
                sharedSummaryLastTruncatedHash = contentHash
                sharedSummaryConsecutiveTruncationCount += 1
                aiSummaryState = .truncated(finalResult.summary)
            } else {
                sharedSummaryLastHash = contentHash
                sharedSummaryLastTruncatedHash = nil
                sharedSummaryConsecutiveTruncationCount = 0
                let generatedAt = Date()
                lastSummaryGeneratedAt = generatedAt
                if burstTriggered {
                    lastBurstSummaryAt = generatedAt
                }
                aiSummaryState = .done(finalResult.summary)
                await aiSummaryCacheStore.save(
                    AISummaryCacheEntry(
                        summary: finalResult.summary,
                        items: items,
                        contentHash: contentHash,
                        trendHistoryHash: trendHistoryHash,
                        generatedAt: generatedAt,
                        trendItemCount: weiboItems.count + bilibiliItems.count,
                        language: summaryLanguage
                    )
                )
            }
            return requestCount
        } catch NewsBarError.apiKeyInvalid {
            aiSummaryState = .error("error.aiKeyInvalid".localized)
        } catch NewsBarError.rateLimited {
            let count = AISummaryService.readGenerationAttempts(target: Self.sharedSummaryTarget, mode: budgetMode)
            let cap = AISummaryService.readGenerationCap(target: Self.sharedSummaryTarget, mode: budgetMode)
            aiSummaryState = .error(L10n.string("error.aiCapReached", count, cap))
        } catch let error as NewsBarError {
            switch error {
            case .parseFailedWithDetail(let detail):
                NSLog("[NewsOrchestrator] AI summary retry exhausted: %@", detail)
                aiSummaryState = .error(L10n.string("error.aiUnavailable", detail))
            case .parseFailed:
                aiSummaryState = .error("error.aiBadFormat".localized)
            default:
                NSLog("[NewsOrchestrator] AI summary NewsBarError: %@", error.localizedDescription)
                aiSummaryState = .error("error.aiFailed".localized)
            }
        } catch let error as URLError {
            NSLog("[NewsOrchestrator] AI summary URLError: %@", error.localizedDescription)
            aiSummaryState = .error(error.code == .timedOut ? "error.aiTimeout".localized : "error.aiNoNetwork".localized)
        } catch let error as DecodingError {
            NSLog("[NewsOrchestrator] AI summary DecodingError: %@", error.localizedDescription)
            aiSummaryState = .error("error.aiBadFormat".localized)
        } catch {
            NSLog("[NewsOrchestrator] AI summary failed: %@", error.localizedDescription)
            aiSummaryState = .error("error.aiFailed".localized)
        }
        return AISummaryService.readGenerationAttempts(target: Self.sharedSummaryTarget, mode: budgetMode)
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
        await aiSummaryCacheStore.clear()
        await trendHistoryStore.clear()
        weiboItems = []
        bilibiliItems = []
        rssItemsMap = [:]
        aiSummaryState = .idle
        aiSummaryItems = []
        aiParsedSummary = nil
        sourceStates = [:]
        sharedSummaryLastHash = nil
        sharedSummaryLastTruncatedHash = nil
        sharedSummaryConsecutiveTruncationCount = 0
        lastSummaryGeneratedAt = nil
        lastHotRefresh = nil
        lastSourceRefresh = [:]
        rssUnchangedRefreshCounts = [:]
        rssLastChangedAt = [:]
        rssFailureCounts = [:]
        lastHourlyPushAt = nil
        latestTrendSummary = .none
        notifiedBurstTopics = []
        notifiedKeywordPairs = []
        burstResearchCache = [:]
    }

    func refreshRSSSource(url: String, name: String, settings: AppSettings) async {
        let source = NewsSource.rss(name: name, url: url)
        await refreshRSSSource(source, settings: settings)
    }

    func refreshRSSSource(_ source: NewsSource, settings: AppSettings) async {
        guard !source.isBuiltIn else { return }
        guard sourceStates[source.id] != .loading else { return }

        sourceStates[source.id] = .loading
        _ = await fetchRSS(source: source, useCacheFallback: false, settings: settings)
        if case .some(.loaded) = sourceStates[source.id] {
            lastSourceRefresh[source.id] = Date()
        }
    }
}

/// Waits for an in-flight refresh and resumes exactly once, even when the
/// waiting task is cancelled. A continuation may be resumed at most once, so
/// this boxes it to prevent a cancelled waiter from double-resuming.
@MainActor
private final class RefreshWaiter {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isResumed = false

    func awaitResume() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
            if isResumed {
                continuation.resume()
            }
        }
    }

    func resumeOnce() {
        guard !isResumed else { return }
        isResumed = true
        continuation?.resume()
        continuation = nil
    }
}
