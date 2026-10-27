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

    /// Weibo hot-search rows available to burst detection (up to 20). The
    /// visible `weiboItems` list stays at five rows.
    var weiboDetectionItems: [NewsItem] = []
    /// Popover chip counts; refreshed from ResearchStore after record changes.
    var researchSummary = ResearchSummary.zero
    /// Three most recent records for the Dashboard sidebar.
    var researchHighlights: [ResearchIndexEntry] = []

    // Shared summary context — Popup and Dashboard render the same generated result.
    var aiSummaryState = AISummaryState.idle
    var aiSummaryItems: [NewsItem] = []
    var aiParsedSummary: ParsedSummary?
    var aiSummaryManifest: SummaryManifest?

    var isRefreshing = false
    var sourceStates: [String: SourceLoadState] = [:]
    var manualRefreshWarning: String?
    var batchProgress = BatchProgress.zero

    // MARK: - Private State

    private let cacheManager = CacheManager()
    private let translationCacheStore = TranslationCacheStore()
    private let trendHistoryStore = TrendHistoryStore.shared
    private let rateLimiter = RateLimiter()
    private let researchStore = ResearchStore.shared
    private let researchCacheStore = ResearchCacheStore.shared
    private let researchSearchRouter = SearchRouter()
    private let researchLedger = ResearchLedger.shared
    @ObservationIgnored private var researchObserver: NSObjectProtocol?
    private var legacyResearchImported = false
    private var aiSummaryCacheStore: AISummaryCacheStore {
        AISummaryCacheStore(language: L10n.currentLanguage)
    }
    private var isLoadingCachedState = false
    /// Source set whose disk cache has already been folded into memory. Kept so
    /// opening the popover after the dashboard (or vice versa) does not re-read
    /// every cache entry and re-run interest ingestion on the first frame.
    private var loadedCacheSourceIDs: Set<String> = []
    private var refreshWaiters: [RefreshWaiter] = []
    private var pendingManualRefresh = false
    var sharedSummaryLastHash: String?
    /// 截断内容哈希：防止对同一截断内容重复生成，成功生成后清除。
    var sharedSummaryLastTruncatedHash: String?
    var sharedSummaryConsecutiveTruncationCount = 0
    let maxConsecutiveTruncations = 3
    private var lastHotRefresh: Date?
    private var lastSourceRefresh: [String: Date] = [:]
    private var lastSourceAttempt: [String: Date] = [:]
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
    private var researchStateLoaded = false
    private var lastResearchAt: Date?
    private var latestTrendSummary = TrendChangeSummary.none
    /// The shared result uses the detailed Dashboard prompt. Popup limits rows at render time.
    static let sharedSummaryTarget: SummaryTarget = .dashboard

    init() {
        researchObserver = NotificationCenter.default.addObserver(
            forName: .researchRecordsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshResearchSummary()
            }
        }
    }

    deinit {
        if let researchObserver {
            NotificationCenter.default.removeObserver(researchObserver)
        }
    }

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
        let sourceIDs = Set(settings.activeSources.map(\.id))
        guard loadedCacheSourceIDs != sourceIDs else { return }
        guard !isLoadingCachedState else { return }
        await loadCachedState(settings: settings, logTrigger: .popoverOpen)
        await updateInterestCandidates(settings: settings)
        loadedCacheSourceIDs = sourceIDs
    }

    func preloadCached(settings: AppSettings) async {
        let sourceIDs = Set(settings.activeSources.map(\.id))
        guard loadedCacheSourceIDs != sourceIDs else { return }
        guard !isLoadingCachedState else { return }
        await loadCachedState(settings: settings, logTrigger: nil)
        await updateInterestCandidates(settings: settings)
        loadedCacheSourceIDs = sourceIDs
    }

    private func loadCachedState(settings: AppSettings, logTrigger: RefreshLog.Trigger?) async {
        await InterestController.shared.prepare()
        guard !isLoadingCachedState else { return }
        isLoadingCachedState = true
        defer { isLoadingCachedState = false }

        let aiBefore = logStateLabel(aiSummaryState)
        var sourceResults: [String: String] = [:]
        // Stage every cached read in locals and commit once. Writing each
        // source into the observable properties made the popover rebuild its
        // whole feed N times while the first frame was still being drawn.
        var hotItems = weiboItems
        var videoItems = bilibiliItems
        var feeds = rssItemsMap
        var states = sourceStates

        // 内存优先: 若已有数据则不覆盖 (避免 stale 缓存清空自动刷新填入的新数据)
        if hotItems.isEmpty {
            if let cached = await cacheManager.load(for: .weibo) {
                hotItems = cached.items
                let validatedAt = cached.lastValidatedAt ?? cached.timestamp
                lastHotRefresh = max(lastHotRefresh ?? .distantPast, validatedAt)
                if cached.isStale {
                    states[NewsSource.weibo.id] = .idle
                    sourceResults[NewsSource.weibo.displayName] = "cacheStale"
                } else {
                    if let next = cachedState(.loaded, for: .weibo, in: states) {
                        states[NewsSource.weibo.id] = next
                    }
                    sourceResults[NewsSource.weibo.displayName] = "cache/\(cached.items.count)"
                }
            } else {
                if states[NewsSource.weibo.id] == nil {
                    states[NewsSource.weibo.id] = .idle
                }
                sourceResults[NewsSource.weibo.displayName] = "noCache"
            }
        } else {
            sourceResults[NewsSource.weibo.displayName] = "skipped/\(hotItems.count)"
        }
        if videoItems.isEmpty {
            if let cached = await cacheManager.load(for: .bilibili) {
                videoItems = cached.items
                let validatedAt = cached.lastValidatedAt ?? cached.timestamp
                lastHotRefresh = max(lastHotRefresh ?? .distantPast, validatedAt)
                if cached.isStale {
                    states[NewsSource.bilibili.id] = .idle
                    sourceResults[NewsSource.bilibili.displayName] = "cacheStale"
                } else {
                    if let next = cachedState(.loaded, for: .bilibili, in: states) {
                        states[NewsSource.bilibili.id] = next
                    }
                    sourceResults[NewsSource.bilibili.displayName] = "cache/\(cached.items.count)"
                }
            } else {
                if states[NewsSource.bilibili.id] == nil {
                    states[NewsSource.bilibili.id] = .idle
                }
                sourceResults[NewsSource.bilibili.displayName] = "noCache"
            }
        } else {
            sourceResults[NewsSource.bilibili.displayName] = "skipped/\(videoItems.count)"
        }

        for source in settings.activeSources where !source.isBuiltIn {
            if feeds[source.id, default: []].isEmpty {
                if let entry = await cacheManager.load(for: source) {
                    lastSourceRefresh[source.id] = entry.lastValidatedAt ?? entry.timestamp
                    if entry.isExpired {
                        states[source.id] = .idle
                        sourceResults[source.displayName] = "cacheExpired"
                    } else {
                        feeds[source.id] = entry.items
                        if entry.isStale {
                            states[source.id] = .idle
                            sourceResults[source.displayName] = "cacheStale"
                        } else {
                            if let next = cachedState(.loaded, for: source, in: states) {
                                states[source.id] = next
                            }
                            sourceResults[source.displayName] = "cache/\(entry.items.count)"
                        }
                    }
                } else {
                    if states[source.id] == nil {
                        states[source.id] = .idle
                    }
                    sourceResults[source.displayName] = "noCache"
                }
            } else {
                let count = feeds[source.id]?.count ?? 0
                sourceResults[source.displayName] = "skipped/\(count)"
            }
        }

        if hotItems != weiboItems { weiboItems = hotItems }
        if weiboDetectionItems.isEmpty { weiboDetectionItems = hotItems }
        if videoItems != bilibiliItems { bilibiliItems = videoItems }
        if feeds != rssItemsMap { rssItemsMap = feeds }
        if states != sourceStates { sourceStates = states }

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
                lastRefresh: lastSourceAttempt[source.id] ?? lastSourceRefresh[source.id],
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
            batchProgress = BatchProgress(completed: 0, total: rssSources.count)

            for range in RSSRefreshPlanner.batches(count: rssSources.count) {
                let batch = Array(rssSources[range])
                for source in batch {
                    lastSourceAttempt[source.id] = Date()
                }

                let outcomes = await withTaskGroup(of: RSSFetchOutcome.self, returning: [RSSFetchOutcome].self) { group in
                    for source in batch {
                        group.addTask { await self.fetchRSS(source: source, useCacheFallback: !isManual, settings: settings) }
                    }
                    var collected: [RSSFetchOutcome] = []
                    collected.reserveCapacity(batch.count)
                    for await outcome in group {
                        collected.append(outcome)
                    }
                    return collected
                }

                applyRSSBatch(outcomes)
                rssChanged = rssChanged || outcomes.contains(where: \.changed)
                batchProgress = BatchProgress(
                    completed: range.upperBound,
                    total: rssSources.count
                )

            }
            batchProgress = .zero
        }

        if isManual {
            await rateLimiter.recordManualRefresh()
            manualRefreshWarning = await rateLimiter.manualRefreshWarning()
        }

        await updateInterestCandidates(settings: settings)
        await handleSharedAISummary(
            settings: settings,
            previousState: previousSummaryState,
            isManualRefresh: isManual,
            hotChanged: hotChanged,
            rssChanged: rssChanged,
            trendSummary: trendSummary
        )

        await handleBurstTopics(settings: settings)
        await handleKeywordTopics(settings: settings)

        let allItems = allActiveItems(settings: settings)
        if !isManual {
            let notificationItems = NotificationSelectionPolicy.select(items: allItems, state: InterestController.shared.state, count: settings.pushCount)
            let now = Date()
            if settings.hourlyPushEnabled,
               trigger == .startup || now.timeIntervalSince(lastHourlyPushAt ?? .distantPast) >= 60 * 60 {
                await NotificationService.sendHourlyPush(items: notificationItems, count: settings.pushCount)
                lastHourlyPushAt = now
            }
            if settings.dailyPushEnabled {
                NotificationService.rescheduleDailyPush(
                    items: notificationItems,
                    count: settings.pushCount,
                    hour: settings.dailyPushHour,
                    minute: settings.dailyPushMinute
                )
            }
        }

        await recordRefreshLog(settings: settings, trigger: trigger, aiBefore: aiBefore)
    }

    private func fetchWeibo(useCacheFallback: Bool) async -> Bool {
        do {
            let feed = try await WeiboHotService.fetchFeed()
            guard !feed.displayItems.isEmpty else {
                sourceStates[NewsSource.weibo.id] = .failed("error.noContent".localized)
                return false
            }
            if !feed.hotLabelsAvailable {
                NSLog("[NewsOrchestrator] Weibo hot labels unavailable (HTML fallback); burst detection disabled this round")
            }

            let now = Date()
            let existing = await cacheManager.load(for: .weibo)
            let contentHash = CacheEntry.contentIdentifier(for: feed.displayItems)
            let hasNew = existing?.contentHash != contentHash
            let entry = CacheEntry(
                items: feed.displayItems,
                timestamp: hasNew ? now : (existing?.timestamp ?? now),
                contentHash: contentHash,
                lastValidatedAt: now,
                eTag: existing?.eTag,
                lastModified: existing?.lastModified
            )
            await cacheManager.save(entry, for: .weibo)
            weiboItems = feed.displayItems
            weiboDetectionItems = feed.detectionItems
            sourceStates[NewsSource.weibo.id] = .loaded
            return hasNew
        } catch {
            NSLog("[NewsOrchestrator] 获取 \(NewsSource.weibo.displayName) 失败: \(error.localizedDescription)")
            sourceStates[NewsSource.weibo.id] = .failed(sourceErrorMessage(error))
            if useCacheFallback, weiboItems.isEmpty,
               let cached = await cacheManager.load(for: .weibo) {
                weiboItems = cached.items
                weiboDetectionItems = cached.items
            }
            return false
        }
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

    /// Result of one RSS fetch. Observable state is committed by the caller in
    /// one batch so a 6-source batch invalidates the UI once, not 12 times.
    private struct RSSFetchOutcome {
        let source: NewsSource
        let state: SourceLoadState
        /// `nil` leaves the existing map entry untouched.
        let itemsUpdate: [NewsItem]?
        let changed: Bool
    }

    private func fetchRSS(source: NewsSource, useCacheFallback: Bool, settings: AppSettings) async -> RSSFetchOutcome {
        let existing = await cacheManager.load(for: source)
        let fetchedItems: [NewsItem]?
        let changed: Bool
        var outcomeItems: [NewsItem]?
        var outcomeState = SourceLoadState.loaded

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
                outcomeItems = validated.items
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
                outcomeItems = translatedItems
                fetchedItems = translatedItems
                if changed {
                    rssUnchangedRefreshCounts[source.id] = 0
                    rssLastChangedAt[source.id] = now
                } else {
                    rssUnchangedRefreshCounts[source.id, default: 0] += 1
                }
            }
            rssFailureCounts[source.id] = 0
            lastSourceRefresh[source.id] = Date()
        } catch {
            NSLog("[NewsOrchestrator] 获取 \(source.displayName) 失败: \(error.localizedDescription)")
            outcomeState = .failed(sourceErrorMessage(error))
            rssFailureCounts[source.id, default: 0] += 1
            changed = false
            if existing?.isExpired == true {
                outcomeItems = []
                fetchedItems = nil
            } else if useCacheFallback, rssItemsMap[source.id, default: []].isEmpty, let existing {
                outcomeItems = existing.items
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
        return RSSFetchOutcome(
            source: source,
            state: outcomeState,
            itemsUpdate: outcomeItems,
            changed: changed
        )
    }

    /// Commits a whole fetch batch into the observable dictionaries at once.
    private func applyRSSBatch(_ outcomes: [RSSFetchOutcome]) {
        guard !outcomes.isEmpty else { return }
        var feeds = rssItemsMap
        var states = sourceStates
        for outcome in outcomes {
            if let items = outcome.itemsUpdate {
                feeds[outcome.source.id] = items
            }
            states[outcome.source.id] = outcome.state
        }
        if feeds != rssItemsMap { rssItemsMap = feeds }
        if states != sourceStates { sourceStates = states }
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
    /// realtime `webSearchEnabled` toggle. The Firecrawl key is read from the
    /// encrypted store, with the legacy UserDefaults value as a fallback during
    /// migration.
    private func makeSearchConfig(settings: AppSettings, forceSearch: Bool) async -> WebSearchService.Config? {
        let enabled = forceSearch || settings.webSearchEnabled
        guard enabled else { return nil }
        let key = await SearchKeyStore.key(for: .firecrawl, fallback: settings.firecrawlAPIKey)
        return WebSearchService.Config(
            provider: .firecrawl,
            apiKey: key,
            maxResults: 6
        )
    }

    // MARK: - Burst (爆) topic push

    /// Detects new Weibo "爆" topics and pushes a single notification each with
    /// AI research pre-generated. De-duplicates by title and respects a cooldown.
    private func handleBurstTopics(settings: AppSettings) async {
        // `researchAutoEnabled` is the single master switch. `burstPushEnabled`
        // only decides whether the finished report also raises a notification.
        guard settings.researchAutoEnabled else { return }
        let now = Date()
        let epoch = InterestController.shared.state.consentEpoch

        let candidates = weiboDetectionItems.filter { $0.hotLabel == "爆" }
        guard !candidates.isEmpty else { return }

        let selected = ResearchSelectionPolicy.select(
            items: candidates,
            state: InterestController.shared.state,
            limit: settings.researchDetectionLimit
        ).map(\.item)

        var notifiedChanged = false
        for burst in selected {
            guard epoch == InterestController.shared.state.consentEpoch else { return }
            guard let record = await ResearchRecordProvisioner.ensureRecord(
                for: burst,
                origin: .burst,
                store: researchStore,
                now: now
            ) else { continue }

            if !notifiedBurstTopics.contains(burst.title) {
                notifiedBurstTopics.insert(burst.title)
                notifiedChanged = true
            }

            let neverStarted = record.run.startedAt == nil
            let cooledDown = now.timeIntervalSince(record.updatedAt) >= 6 * 3_600
            if neverStarted || (!record.status.isActive && cooledDown) {
                await scheduleResearch(
                    recordID: record.id,
                    settings: settings,
                    forceSearch: false,
                    notify: settings.burstPushEnabled
                )
            }
        }

        if notifiedChanged {
            await persistResearchState(epoch: epoch)
        }
        await refreshResearchSummary()
    }

    func refreshResearchSummary() async {
        researchSummary = await researchStore.burstSummary()
        let entries = await researchStore.index()
        researchHighlights = entries
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
            .prefix(3)
            .map { $0 }
    }

    func markResearchRead(recordID: String) async {
        guard var record = await researchStore.record(id: recordID) else { return }
        guard !record.isRead else { return }
        record.isRead = true
        try? await researchStore.save(record)
        NotificationCenter.default.post(name: .researchRecordsChanged, object: nil)
        await refreshResearchSummary()
    }

    /// Exact topic lookup used by the legacy burst notification shim.
    func recordID(forTopic title: String) async -> String? {
        await researchStore.latestRecord(topicKey: TopicFingerprint.key(for: title))?.id
    }

    /// Manual verification from any news row. Reuses an exact topic record and
    /// re-runs research unless it is already queued or running.
    func startManualResearch(item: NewsItem, settings: AppSettings) async -> String? {
        await InterestController.shared.prepare()
        guard let record = await ResearchRecordProvisioner.ensureRecord(
            for: item,
            origin: .manual,
            store: researchStore
        ) else { return nil }

        // A finished record opens as-is; re-running is an explicit action from
        // the detail view, not a side effect of clicking "verify" again.
        if record.run.startedAt == nil {
            await scheduleResearch(recordID: record.id, settings: settings, forceSearch: false)
        }
        await refreshResearchSummary()
        return record.id
    }

    func startManualResearch(title: String, settings: AppSettings) async -> String? {
        let item = weiboItems.first { $0.title == title }
            ?? NewsItem(title: title, url: "https://s.weibo.com", source: .weibo)
        return await startManualResearch(item: item, settings: settings)
    }

    private func scheduleResearch(
        recordID: String,
        settings: AppSettings,
        forceSearch: Bool,
        notify: Bool = true
    ) async {
        await ResearchCoordinator.shared.setMaxConcurrent(settings.researchMaxConcurrent)
        await ResearchCoordinator.shared.schedule(recordID: recordID, notify: notify) { [weak self] record, progress in
            guard let self else {
                return .failure(L10n.string("research.error.unavailable", language: settings.appLanguage))
            }
            return await self.executeResearch(
                record: record,
                settings: settings,
                forceSearch: forceSearch,
                progress: progress
            )
        }
    }

    /// Runs the evidence-backed pipeline for one record. The coordinator owns
    /// status/persistence; this method only resolves credentials and builds the
    /// injected dependencies.
    func executeResearch(
        record: ResearchRecord,
        settings: AppSettings,
        forceSearch: Bool = false,
        progress: @escaping @Sendable (ResearchRun) async -> Void
    ) async -> ResearchExecution {
        await InterestController.shared.prepare()
        let epoch = InterestController.shared.state.consentEpoch
        let item = weiboItems.first { $0.title == record.topic }
            ?? NewsItem(
                title: record.topic,
                url: record.seed.url ?? "https://s.weibo.com",
                source: record.seed.source,
                publishedAt: record.seed.publishedAt
            )

        let apiKey = await resolveAPIKey(settings: settings)
        guard let configuration = await validatedConfiguration(settings: settings, apiKey: apiKey) else {
            return .failure(L10n.string("research.error.noAIKey", language: settings.appLanguage))
        }

        let keys = await resolveSearchKeys(settings: settings)
        let searchConfiguration = SearchRouterConfiguration(
            enabled: settings.enabledSearchProviders,
            keys: keys
        )
        let pipeline = ResearchPipeline(
            ai: HTTPAIChatClient(
                connection: configuration.connection,
                apiKey: configuration.apiKey,
                model: configuration.model,
                disableDeepSeekThinking: settings.aiDisableDeepSeekThinking
            ),
            searchRouter: researchSearchRouter,
            pageReader: PageReader(
                cache: researchCacheStore,
                isScrapeEnabled: settings.enabledSearchProviders.contains(.firecrawl)
                    && !(keys[.firecrawl] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ),
            ledger: researchLedger
        )
        let pipelineConfiguration = ResearchPipelineConfiguration(
            record: record,
            depth: settings.researchDepth,
            language: settings.appLanguage,
            trendContext: latestTrendSummary.context,
            defaultRecency: settings.researchDefaultRecency,
            searchConfiguration: searchConfiguration,
            firecrawlAPIKey: keys[.firecrawl] ?? "",
            aiDailyCap: settings.researchDailyAICap,
            taskDailyCap: settings.researchDailyTaskCap,
            seedSourceName: item.source.displayName,
            isAllowed: {
                await MainActor.run {
                    InterestController.shared.state.consentEpoch == epoch
                        && settings.isCurrentAIConfiguration(configuration)
                        && !Task.isCancelled
                }
            }
        )

        let execution = await pipeline.run(
            configuration: pipelineConfiguration,
            progress: progress
        )
        NSLog(
            "[ResearchPipeline] status=%@ pages=%ld queries=%ld ai=%ld search=%ld partial=%@",
            execution.research.searchStatus.rawValue,
            execution.pagesRead,
            execution.queries.count,
            execution.aiCalls,
            execution.searchCalls,
            execution.isPartial ? "yes" : "no"
        )
        guard epoch == InterestController.shared.state.consentEpoch,
              settings.isCurrentAIConfiguration(configuration) else {
            return .failure(L10n.string("research.error.cancelled", language: settings.appLanguage))
        }
        return execution
    }

    /// Search keys live in the encrypted store, with the legacy Firecrawl
    /// UserDefaults value kept as a migration fallback.
    private func resolveSearchKeys(settings: AppSettings) async -> [SearchProviderID: String] {
        var keys = await SearchKeyStore.loadAll()
        if keys[.firecrawl]?.isEmpty ?? true, !settings.firecrawlAPIKey.isEmpty {
            keys[.firecrawl] = settings.firecrawlAPIKey
        }
        return keys
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
        await InterestController.shared.prepare()
        let epoch = InterestController.shared.state.consentEpoch
        let apiKey = await resolveAPIKey(settings: settings)
        guard let configuration = await validatedConfiguration(settings: settings, apiKey: apiKey) else { return BurstResearch() }
        let research = await BurstResearchService.research(
            BurstResearchService.ResearchInput(
                item: burst,
                trendContext: latestTrendSummary.context,
                apiKey: configuration.apiKey,
                connection: configuration.connection,
                model: configuration.model,
                summaryLanguage: settings.appLanguage,
                disableDeepSeekThinking: settings.aiDisableDeepSeekThinking,
                searchConfig: await makeSearchConfig(settings: settings, forceSearch: false),
                dailyCap: settings.burstDailyCap,
                maxRefetchURLs: 3,
                isAllowed: { await MainActor.run { InterestController.shared.state.consentEpoch == epoch && settings.isCurrentAIConfiguration(configuration) } }
            )
        )
        settings.recordBurstResearchRequests(BurstResearchService.readDailyCount())
        guard epoch == InterestController.shared.state.consentEpoch, settings.isCurrentAIConfiguration(configuration) else { return BurstResearch() }
        burstResearchCache[burst.title] = research
        await persistResearchState(epoch: epoch)
        return research
    }

    // MARK: - Custom keyword topic push

    /// Tracks which (keyword,title) pairs have already been researched to avoid
    /// re-notifying the same match across refreshes.
    private var notifiedKeywordPairs: Set<String> = []

    /// Detects news items whose titles match a user keyword and enqueues a
    /// research record for each new match. Keyword research shares the same
    /// coordinator, pipeline and budget ledger as burst research; the old
    /// inline call and the shared 15-minute cooldown are gone, so a keyword
    /// match no longer blocks (or is blocked by) burst research.
    private func handleKeywordTopics(settings: AppSettings) async {
        guard settings.researchAutoEnabled, settings.keywordTrackingEnabled else { return }
        let active = settings.activeKeywords
        guard !active.isEmpty else { return }

        let now = Date()
        let epoch = InterestController.shared.state.consentEpoch

        var matches: [(keyword: String, item: NewsItem)] = []
        for item in allActiveItems(settings: settings) {
            guard settings.keywordMatches(item.title) else { continue }
            guard !InterestController.shared.state.isBlocked(item), !notifiedBurstTopics.contains(item.title),
                  let keyword = active.first(where: { TitleFeatures.matches($0, in: item.title) }) else { continue }
            let pair = "\(keyword)\n\(item.title)"
            guard !notifiedKeywordPairs.contains(pair) else { continue }
            matches.append((keyword, item))
        }
        guard !matches.isEmpty else { return }
        let apiKey = await resolveAPIKey(settings: settings)
        guard await validatedConfiguration(settings: settings, apiKey: apiKey) != nil else { return }

        let prioritizedIDs = ResearchSelectionPolicy.select(items: matches.map(\.item), state: InterestController.shared.state, limit: 2).map { $0.item.id }
        matches.sort { (prioritizedIDs.firstIndex(of: $0.item.id) ?? Int.max) < (prioritizedIDs.firstIndex(of: $1.item.id) ?? Int.max) }

        var notifiedChanged = false
        for match in matches.prefix(2) {
            guard epoch == InterestController.shared.state.consentEpoch else { return }
            guard let record = await ResearchRecordProvisioner.ensureRecord(
                for: match.item,
                origin: .keyword,
                store: researchStore,
                now: now
            ) else { continue }

            let pair = "\(match.keyword)\n\(match.item.title)"
            if !notifiedKeywordPairs.contains(pair) {
                notifiedKeywordPairs.insert(pair)
                notifiedChanged = true
            }

            let neverStarted = record.run.startedAt == nil
            let cooledDown = now.timeIntervalSince(record.updatedAt) >= 6 * 3_600
            if neverStarted || (!record.status.isActive && cooledDown) {
                await scheduleResearch(recordID: record.id, settings: settings, forceSearch: false)
            }
        }

        if notifiedChanged {
            await persistResearchState(epoch: epoch)
        }
        await refreshResearchSummary()
    }

    // MARK: - Developer test: fake burst push

    /// Fires a fake Weibo "爆" push (developer test mode). Opens the detail
    /// window immediately (showing its loading state), then runs the research
    /// pipeline in the background, fills the cache, and posts the notification.
    /// The developer toggle always forces web search so the full pipeline is
    /// exercised; the window polls for the result via `isBurstResearchInFlight`.
    func fireFakeBurstPush(settings: AppSettings) async {
        await InterestController.shared.prepare()
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
        guard let record = await ResearchRecordProvisioner.ensureRecord(
            for: fake,
            origin: .burst,
            store: researchStore
        ) else { return }

        await scheduleResearch(recordID: record.id, settings: settings, forceSearch: true)
        openBurstDetail(title: trimmedTopic)
        await refreshResearchSummary()
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
        previousState: AISummaryState,
        isManualRefresh: Bool,
        hotChanged: Bool,
        rssChanged: Bool,
        trendSummary: TrendChangeSummary
    ) async {
        guard settings.aiSummaryEnabled else { return }

        let allItems = allActiveItems(settings: settings)
        guard !allItems.isEmpty else {
            aiSummaryState = previousState
            return
        }

        let apiKey = await resolveAPIKey(settings: settings)
        guard let configuration = await validatedConfiguration(settings: settings, apiKey: apiKey) else { return }

        guard AISummaryService.tryAcquireGenerationLock(for: Self.sharedSummaryTarget) else {
            aiSummaryState = .error("error.aiGenerating".localized)
            return
        }
        defer { AISummaryService.releaseGenerationLock(for: Self.sharedSummaryTarget) }

        let newHash = summaryGenerationHash(items: allItems, settings: settings)
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
                configuration: configuration,
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
        guard let configuration = await validatedConfiguration(settings: settings, apiKey: apiKey) else { return }

        let newHash = summaryGenerationHash(items: allItems, settings: settings)
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
            configuration: configuration,
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

        let apiKey = await resolveAPIKey(settings: settings)
        guard let configuration = await validatedConfiguration(settings: settings, apiKey: apiKey) else { return }
        AISummaryService.recordManualRegeneration()
        AISummaryService.initBudget(
            target: Self.sharedSummaryTarget,
            mode: .shared,
            baseline: settings.todayAIRequestCount,
            cap: settings.aiDailyCap
        )
        let newHash = summaryGenerationHash(items: allItems, settings: settings)
        let requestCount = await generateSummary(
            items: allItems,
            contentHash: newHash,
            maxWords: settings.aiDashboardMaxWords,
            configuration: configuration,
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
        guard !sources.isEmpty else { return }
        var states = sourceStates
        for source in sources {
            states[source.id] = state
        }
        if states != sourceStates { sourceStates = states }
    }

    private func cachedState(
        _ state: SourceLoadState,
        for source: NewsSource,
        in states: [String: SourceLoadState]
    ) -> SourceLoadState? {
        switch states[source.id] {
        case .some(.loading):
            return nil
        case .some(.failed):
            if case .loaded = state { return state }
            return nil
        case .some(.loaded):
            return nil  // 已完成加载 → 不退回到 idle
        case .some(.idle), .none:
            return state
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
        let revision = settings.modelCatalogRevision
        let store = EncryptedKeyStore()
        if let fallback = await store.readAPIKey(account: settings.activeAPIKeyAccount),
           !fallback.isEmpty {
            guard revision == settings.modelCatalogRevision else { return "" }
            settings.cachedAPIKey = fallback
            return fallback
        }
        return ""
    }

    private func validatedConfiguration(settings: AppSettings, apiKey: String) async -> ValidatedAIConfiguration? {
        guard !apiKey.isEmpty else { aiSummaryState = .noKey; return nil }
        guard let configuration = await settings.validatedAIConfiguration(apiKey: apiKey) else {
            if let error = settings.modelCatalogError { aiSummaryState = .error(error.message(language: settings.appLanguage)) }
            return nil
        }
        return configuration
    }

    private func restoreCachedSummaryIfPossible(settings: AppSettings) async {
        guard settings.aiSummaryEnabled,
              sharedSummaryLastHash == nil,
              let cached = await aiSummaryCacheStore.load() else { return }
        let currentItems = allActiveItems(settings: settings)
        guard !currentItems.isEmpty,
              summaryGenerationHash(items: currentItems, settings: settings) == cached.contentHash else { return }

        let trendIndices = cached.manifest?.trendIndices ?? Set(cached.items.enumerated().filter { $0.element.source.isBuiltIn }.map(\.offset))
        aiSummaryItems = cached.items
        aiSummaryManifest = cached.manifest
        aiParsedSummary = AISummaryParser.parseDualSummary(
            cached.summary,
            itemCount: cached.items.count,
            trendIndices: trendIndices
        )
        sharedSummaryLastHash = cached.contentHash
        sharedSummaryLastTruncatedHash = nil
        sharedSummaryConsecutiveTruncationCount = 0
        lastSummaryGeneratedAt = cached.generatedAt
        aiSummaryState = .done(cached.summary)
    }

    @discardableResult
    private func generateSummary(
        items candidateItems: [NewsItem],
        contentHash: String,
        maxWords: Int,
        configuration: ValidatedAIConfiguration,
        settings: AppSettings,
        trendHistoryContext: String,
        trendHistoryHash: String,
        burstTriggered: Bool = false,
        summaryLanguage: AppLanguage = .zh
    ) async -> Int {
        let budgetMode: AISummaryBudgetMode = .shared
        let model = configuration.model
        let apiKey = configuration.apiKey
        let connection = configuration.connection
        let interest = InterestController.shared
        let epoch = interest.state.consentEpoch
        defer {
            if epoch != interest.state.consentEpoch || !settings.isCurrentAIConfiguration(configuration),
               aiSummaryState == .summarizing || aiSummaryState == .fetching { aiSummaryState = .idle }
        }
        let state = interest.state
        let activeIDs = Set(settings.activeSources.map(\.id))
        let now = Date()
        let archive = state.contents.values.filter {
            activeIDs.contains($0.item.source.id) && now.timeIntervalSince($0.lastSeen) <= 24 * 3600
        }.map(\.item)
        let inputItems = candidateItems.filter { activeIDs.contains($0.source.id) } + archive
        let selected = await Task.detached(priority: .userInitiated) {
            SummarySelectionPolicy.select(items: inputItems, state: state, now: now)
        }.value
        guard epoch == interest.state.consentEpoch, settings.isCurrentAIConfiguration(configuration) else { return 0 }
        let manifest = SummaryManifest(items: selected, profileVersion: state.learningEnabled ? state.profileVersion : 0,
                                       model: model, provider: ContentIdentity.digest(connection.baseURL), language: summaryLanguage, maxWords: maxWords,
                                       asOf: now, coverageStart: max(now.addingTimeInterval(-24 * 3600), state.archiveStartedAt ?? now), trendHistoryHash: trendHistoryHash)
        let items = manifest.items
        let frozenThinking = settings.aiDisableDeepSeekThinking
        guard !items.isEmpty else { aiSummaryState = .idle; return 0 }
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
                disableDeepSeekThinking: frozenThinking,
                requestAllowed: { await MainActor.run { InterestController.shared.state.consentEpoch == epoch && settings.isCurrentAIConfiguration(configuration) } }
            )
            guard epoch == interest.state.consentEpoch, settings.isCurrentAIConfiguration(configuration) else {
                return AISummaryService.readGenerationAttempts(target: Self.sharedSummaryTarget, mode: budgetMode)
            }

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
                    trendIndices: manifest.trendIndices
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
                        disableDeepSeekThinking: frozenThinking,
                        requestAllowed: { await MainActor.run { InterestController.shared.state.consentEpoch == epoch && settings.isCurrentAIConfiguration(configuration) } }
                    )
                } else {
                    finalResult = firstResult
                }
            } else {
                finalResult = firstResult
            }

            let requestCount = AISummaryService.readGenerationAttempts(target: Self.sharedSummaryTarget, mode: budgetMode)
            guard epoch == interest.state.consentEpoch, settings.isCurrentAIConfiguration(configuration) else { return requestCount }
            let finalParsed = AISummaryParser.parseDualSummary(
                finalResult.summary,
                itemCount: items.count,
                trendIndices: manifest.trendIndices
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
            aiSummaryManifest = manifest
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
                await AISummaryCacheStore(language: summaryLanguage).save(
                    AISummaryCacheEntry(
                        summary: finalResult.summary,
                        items: items,
                        contentHash: contentHash,
                        trendHistoryHash: trendHistoryHash,
                        generatedAt: generatedAt,
                        trendItemCount: manifest.trendIndices.count,
                        language: summaryLanguage,
                        manifest: manifest
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

    private func summaryGenerationHash(items: [NewsItem], settings: AppSettings) -> String {
        SummaryManifest.generationIdentity(items: items, model: settings.aiModel,
                                           provider: ContentIdentity.digest(settings.resolvedAIConnection.baseURL),
                                           language: settings.appLanguage, maxWords: settings.aiDashboardMaxWords)
    }

    private func updateInterestCandidates(settings: AppSettings) async {
        let interest = InterestController.shared
        let activeIDs = Set(settings.activeSources.map(\.id))
        let current = allActiveItems(settings: settings).filter { activeIDs.contains($0.source.id) }
        await interest.ingest(current)
        await restoreResearchStateIfNeeded()
        let archive = interest.state.contents.values.filter {
            activeIDs.contains($0.item.source.id) && Date().timeIntervalSince($0.lastSeen) <= 24 * 3600
        }.map(\.item)
        interest.rankCandidates(current + archive)
    }

    func restoreResearchStateIfNeeded() async {
        let interest = InterestController.shared
        await interest.prepare()
        if !researchStateLoaded, interest.isReady {
            let saved = interest.state.research
            burstResearchCache = saved.artifacts
            notifiedBurstTopics = saved.notifiedBursts
            notifiedKeywordPairs = saved.notifiedKeywords
            lastResearchAt = saved.lastResearchAt
            researchStateLoaded = true
            await importLegacyResearchIfNeeded(saved)
            await refreshResearchSummary()
        }
    }

    /// Copies legacy burst artifacts into `ResearchStore` once, then clears the
    /// BLOB copy now that the research center owns history. A failed import
    /// leaves both the artifacts and the version marker untouched so the next
    /// launch retries; successful records are deduplicated by key+timestamp.
    private func importLegacyResearchIfNeeded(_ saved: PersistedResearchState) async {
        let meta = await researchStore.meta()
        if meta.legacyImportVersion >= 1 {
            legacyResearchImported = true
        }
        guard !saved.artifacts.isEmpty else { return }

        let outcome = await LegacyResearchImporter.importArtifacts(
            saved.artifacts,
            stateUpdatedAt: saved.updatedAt,
            currentItems: weiboItems,
            store: researchStore
        )
        guard !outcome.failed else { return }

        legacyResearchImported = true
        var research = saved
        research.artifacts = [:]
        let epoch = InterestController.shared.state.consentEpoch
        InterestController.shared.updateResearch(research, epoch: epoch)
        await InterestController.shared.flush()
    }

    private func persistResearchState(epoch: UUID) async {
        var persisted = PersistedResearchState()
        if legacyResearchImported {
            persisted.artifacts = [:]
        } else {
            persisted.artifacts = Dictionary(uniqueKeysWithValues: burstResearchCache.sorted { $0.key < $1.key }.prefix(500).map { ($0.key, $0.value) })
        }
        persisted.notifiedBursts = Set(notifiedBurstTopics.sorted().prefix(2000))
        persisted.notifiedKeywords = Set(notifiedKeywordPairs.sorted().prefix(2000))
        persisted.lastResearchAt = lastResearchAt
        InterestController.shared.updateResearch(persisted, epoch: epoch)
        await InterestController.shared.flush()
    }

    func clearPersonalizedArtifacts() async {
        NotificationService.clearPersonalizedNotifications()
        for language in AppLanguage.allCases { await AISummaryCacheStore(language: language).clear() }
        aiSummaryState = .idle
        aiSummaryItems = []
        aiParsedSummary = nil
        aiSummaryManifest = nil
        sharedSummaryLastHash = nil
        sharedSummaryLastTruncatedHash = nil
        notifiedBurstTopics = []
        notifiedKeywordPairs = []
        burstResearchCache = [:]
        researchStateLoaded = false
        lastResearchAt = nil
        weiboDetectionItems = []
        researchSummary = .zero
        researchHighlights = []
        legacyResearchImported = true
        ResearchCoordinator.shared.cancelAll()
        try? await researchStore.deleteAll()
    }

    func clearCache() async {
        await cacheManager.clear()
        await aiSummaryCacheStore.clear()
        await trendHistoryStore.clear()
        weiboItems = []
        weiboDetectionItems = []
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
        loadedCacheSourceIDs = []
        lastHourlyPushAt = nil
        latestTrendSummary = .none
        notifiedBurstTopics = []
        notifiedKeywordPairs = []
        burstResearchCache = [:]
        researchStateLoaded = false
        aiSummaryManifest = nil
    }

    func refreshRSSSource(url: String, name: String, settings: AppSettings) async {
        let source = NewsSource.rss(name: name, url: url)
        await refreshRSSSource(source, settings: settings)
    }

    func refreshRSSSource(_ source: NewsSource, settings: AppSettings) async {
        guard !source.isBuiltIn else { return }
        guard sourceStates[source.id] != .loading else { return }

        markSources([source], as: .loading)
        let outcome = await fetchRSS(source: source, useCacheFallback: false, settings: settings)
        applyRSSBatch([outcome])
        await updateInterestCandidates(settings: settings)
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
