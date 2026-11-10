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

    static func content(_ text: String, wasTruncated: Bool) -> AISummaryState {
        wasTruncated ? .truncated(text) : .done(text)
    }

    /// The text a completed result carries. `.idle` means "no active work",
    /// not "no content": a cached result can be on screen while idle.
    var completedText: String? {
        switch self {
        case .done(let text), .truncated(let text): return text
        case .idle, .noKey, .fetching, .summarizing, .error: return nil
        }
    }
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
    var aiSummaryText: String?
    var aiParsedSummary: ParsedSummary?
    var aiSummaryManifest: SummaryManifest?
    /// Set when the visible result came from disk. The UI labels it as the
    /// previous result instead of pretending it is fresh.
    var aiSummaryRestoredAt: Date?
    /// A refresh is running while a previous result stays on screen.
    var aiSummaryUpdating = false
    /// A failed refresh that kept the previous result visible.
    var aiSummaryUpdateError: String?

    var hasRenderableSummary: Bool {
        aiSummaryText != nil && !aiSummaryItems.isEmpty
    }

    var isSummaryQuotaBlockedForToday: Bool {
        guard let burstQuotaBlockedOn else { return false }
        return Calendar.current.isDate(burstQuotaBlockedOn, inSameDayAs: Date())
    }

    var isRefreshing = false
    var sourceStates: [String: SourceLoadState] = [:]
    var manualRefreshWarning: String?
    var batchProgress = BatchProgress.zero

    // MARK: - Private State

    private let cacheManager = CacheManager()
    private let translationCacheStore = TranslationCacheStore()
    private let trendHistoryStore = TrendHistoryStore.shared
    private let cacheWriteGeneration = CacheWriteGeneration()
    private var cacheClearDepth = 0
    private let rateLimiter = RateLimiter()
    private let researchStore = ResearchStore.shared
    private let researchCacheStore = ResearchCacheStore.shared
    private let researchSearchRouter = SearchRouter(ledger: .shared, quota: .shared)
    private let researchLedger = ResearchLedger.shared
    private let researchClearIntentStore = ResearchClearIntentStore()
    /// True from the moment a clear starts until every stage is verified. New
    /// burst/keyword work is refused while it is set.
    private(set) var isClearingResearchHistory = false
    /// A damaged or future-version intent keeps automation paused rather than
    /// risking a re-import of artifacts the user asked to delete.
    private(set) var isResearchClearBlocked = false
    private var researchClearGeneration = 0
    @ObservationIgnored private var researchObserver: NSObjectProtocol?
    private var legacyResearchImported = false
    // A stable actor per language serializes saves and clears of the same file.
    private let chineseSummaryCache: AISummaryCacheStore
    private let englishSummaryCache: AISummaryCacheStore
    private func summaryCache(for language: AppLanguage) -> AISummaryCacheStore {
        switch language {
        case .zh: return chineseSummaryCache
        case .en: return englishSummaryCache
        }
    }
    private var aiSummaryCacheStore: AISummaryCacheStore {
        summaryCache(for: L10n.currentLanguage)
    }
    private func isCurrentCacheWork(_ token: CacheWriteToken) -> Bool {
        cacheClearDepth == 0 && token.isCurrent
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
    private var lastBurstSummaryKey: String?
    private var burstQuotaBlockedOn: Date?
    private var lastHourlyPushAt: Date?
    /// Titles of Weibo "爆" topics already pushed, to avoid re-notifying the same one.
    private var notifiedBurstTopics: Set<String> = []
    /// Staging buffer for legacy artifact migration only. Runtime detail views
    /// read `ResearchRecord`; this cache is never a second source of truth.
    private var legacyBurstArtifacts: [String: BurstResearch] = [:]
    private var researchStateLoaded = false
    private var lastResearchAt: Date?
    /// Persisted start of the most recent feed-triggered run. The automatic
    /// budget is global: burst and keyword share this one timestamp.
    private var lastAutomaticStartedAt: Date?
    /// Last selector check that spent the hourly paid-triage window, or started
    /// a run. Cheap skips use `lastCheapCheckAt` instead.
    private var lastAutomaticCheckAt: Date?
    /// In-memory throttle for cheap selector passes. It only prevents repeated
    /// ranking after an empty pool or a keyword pass; it is intentionally not
    /// persisted so a relaunch can re-check immediately.
    private var lastCheapCheckAt: Date?
    private var lastAutomaticDecision: ResearchAutomaticDecision?
    private var triageCache: [String: ResearchTriageRecord] = [:]
    private var latestTrendSummary = TrendChangeSummary.none
    /// The shared result uses the detailed Dashboard prompt. Popup limits rows at render time.
    static let sharedSummaryTarget: SummaryTarget = .dashboard

    init(
        chineseSummaryCache: AISummaryCacheStore = AISummaryCacheStore(language: .zh),
        englishSummaryCache: AISummaryCacheStore = AISummaryCacheStore(language: .en)
    ) {
        self.chineseSummaryCache = chineseSummaryCache
        self.englishSummaryCache = englishSummaryCache
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
        elapsedSinceBurstSummary: TimeInterval = .infinity,
        isRepeatedTruncation: Bool = false
    ) -> Bool {
        // Do not repeatedly spend on exactly the same truncated result, even
        // when no previous complete summary exists or a burst is present.
        guard !isRepeatedTruncation else { return false }
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

    internal static func canAttemptSummary(
        consecutiveTruncations: Int, limit: Int, isManualRegeneration: Bool
    ) -> Bool {
        isManualRegeneration || consecutiveTruncations < limit
    }

    /// Identity of the current "爆" topic set. Sorting makes a reorder from the
    /// feed harmless; a new title or link changes the key and allows one new
    /// generation.
    nonisolated internal static func burstIdentity(items: [NewsItem]) -> String? {
        let burst = items.filter { $0.hotLabel == "爆" }
        guard !burst.isEmpty else { return nil }
        let seed = burst
            .sorted { $0.url == $1.url ? $0.title < $1.title : $0.url < $1.url }
            .map { "\($0.title)\n\($0.url)" }
            .joined(separator: "\n")
        return ContentIdentity.digest(seed)
    }

    internal static func shouldRecoverSharedSummary(
        hasNewContent: Bool, isRepeatedTruncation: Bool, state: AISummaryState
    ) -> Bool {
        guard !isRepeatedTruncation else { return false }
        return hasNewContent || shouldRecoverAISummary(from: state)
    }

    // MARK: - Public API

    /// Key-chain work runs after the cached summary is already on screen. It
    /// must not blank that result while it resolves which key to use.
    func resetSummaryStateForKeyLookup() {
        guard !hasRenderableSummary else { return }
        aiSummaryState = .idle
    }

    func loadCached(settings: AppSettings) async {
        guard cacheClearDepth == 0 else { return }
        let token = cacheWriteGeneration.capture()
        let sourceIDs = Set(settings.activeSources.map(\.id))
        guard loadedCacheSourceIDs != sourceIDs else { return }
        guard !isLoadingCachedState else { return }
        await loadCachedState(settings: settings, logTrigger: .popoverOpen, token: token)
        guard isCurrentCacheWork(token) else { return }
        await updateInterestCandidates(settings: settings, token: token)
        guard isCurrentCacheWork(token) else { return }
        loadedCacheSourceIDs = sourceIDs
    }

    func preloadCached(settings: AppSettings) async {
        guard cacheClearDepth == 0 else { return }
        let token = cacheWriteGeneration.capture()
        let sourceIDs = Set(settings.activeSources.map(\.id))
        guard loadedCacheSourceIDs != sourceIDs else { return }
        guard !isLoadingCachedState else { return }
        await loadCachedState(settings: settings, logTrigger: nil, token: token)
        guard isCurrentCacheWork(token) else { return }
        await updateInterestCandidates(settings: settings, token: token)
        guard isCurrentCacheWork(token) else { return }
        loadedCacheSourceIDs = sourceIDs
    }

    private func loadCachedState(
        settings: AppSettings, logTrigger: RefreshLog.Trigger?, token: CacheWriteToken
    ) async {
        await InterestController.shared.prepare()
        guard isCurrentCacheWork(token) else { return }
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
            let cached = await cacheManager.load(for: .weibo)
            guard isCurrentCacheWork(token) else { return }
            if let cached {
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
            let cached = await cacheManager.load(for: .bilibili)
            guard isCurrentCacheWork(token) else { return }
            if let cached {
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
                let entry = await cacheManager.load(for: source)
                guard isCurrentCacheWork(token) else { return }
                if let entry {
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

        await restoreCachedSummaryIfPossible(settings: settings, token: token)
        guard isCurrentCacheWork(token) else { return }

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
        guard cacheClearDepth == 0 else { return }
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
            rssSources: rssSources,
            token: cacheWriteGeneration.capture()
        )

        if pendingManualRefresh, cacheClearDepth == 0 {
            pendingManualRefresh = false
            await runRefreshCycle(
                settings: settings,
                trigger: .manual,
                isManual: true,
                refreshHot: true,
                rssSources: settings.activeSources.filter { !$0.isBuiltIn },
                token: cacheWriteGeneration.capture()
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
        rssSources: [NewsSource],
        token: CacheWriteToken
    ) async {
        guard isCurrentCacheWork(token) else { return }
        let aiBefore = logStateLabel(aiSummaryState)
        if isManual {
            let warning = await rateLimiter.manualRefreshWarning()
            guard isCurrentCacheWork(token) else { return }
            manualRefreshWarning = warning
        }

        settings.recordRefresh()
        var sourcesToLoad = rssSources
        if refreshHot {
            sourcesToLoad.insert(.bilibili, at: 0)
            sourcesToLoad.insert(.weibo, at: 0)
        }
        markSources(sourcesToLoad, as: .loading)

        var hotChanged = false
        var trendSummary = latestTrendSummary
        if refreshHot {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask { await self.fetchWeibo(useCacheFallback: !isManual, token: token) }
                group.addTask { await self.fetchBilibili(useCacheFallback: !isManual, token: token) }
                for await changed in group {
                    hotChanged = hotChanged || changed
                }
            }
            guard isCurrentCacheWork(token) else { return }
            lastHotRefresh = Date()
            if !weiboItems.isEmpty || !bilibiliItems.isEmpty {
                trendSummary = await trendHistoryStore.record(
                    weibo: weiboItems,
                    bilibili: bilibiliItems,
                    token: token
                )
                guard isCurrentCacheWork(token) else { return }
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

                let outcomes = await withTaskGroup(of: RSSFetchOutcome?.self, returning: [RSSFetchOutcome].self) { group in
                    for source in batch {
                        group.addTask {
                            await self.fetchRSS(source: source, useCacheFallback: !isManual, settings: settings, token: token)
                        }
                    }
                    var collected: [RSSFetchOutcome] = []
                    collected.reserveCapacity(batch.count)
                    for await outcome in group {
                        if let outcome { collected.append(outcome) }
                    }
                    return collected
                }

                guard isCurrentCacheWork(token) else { return }
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
            guard isCurrentCacheWork(token) else { return }
            let warning = await rateLimiter.manualRefreshWarning()
            guard isCurrentCacheWork(token) else { return }
            manualRefreshWarning = warning
        }

        await updateInterestCandidates(settings: settings, token: token)
        guard isCurrentCacheWork(token) else { return }
        await handleSharedAISummary(
            settings: settings,
            isManualRefresh: isManual,
            hotChanged: hotChanged,
            rssChanged: rssChanged,
            trendSummary: trendSummary,
            token: token
        )
        guard isCurrentCacheWork(token) else { return }

        let automaticScheduled = await handleAutomaticResearch(settings: settings, token: token)
        guard isCurrentCacheWork(token) else { return }
        if !automaticScheduled {
            await handleKeywordTopics(settings: settings, token: token)
            guard isCurrentCacheWork(token) else { return }
        }

        let allItems = allActiveItems(settings: settings)
        if !isManual {
            let notificationItems = NotificationSelectionPolicy.select(items: allItems, state: InterestController.shared.state, count: settings.pushCount)
            let now = Date()
            if settings.hourlyPushEnabled,
               trigger == .startup || now.timeIntervalSince(lastHourlyPushAt ?? .distantPast) >= 60 * 60 {
                await NotificationService.sendHourlyPush(items: notificationItems, count: settings.pushCount)
                guard isCurrentCacheWork(token) else { return }
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

    private func fetchWeibo(useCacheFallback: Bool, token: CacheWriteToken) async -> Bool {
        do {
            let feed = try await WeiboHotService.fetchFeed()
            guard isCurrentCacheWork(token) else { return false }
            guard !feed.displayItems.isEmpty else {
                sourceStates[NewsSource.weibo.id] = .failed("error.noContent".localized)
                return false
            }
            if !feed.hotLabelsAvailable {
                NSLog("[NewsOrchestrator] Weibo hot labels unavailable (HTML fallback); burst detection disabled this round")
            }

            let now = Date()
            let existing = await cacheManager.load(for: .weibo)
            guard isCurrentCacheWork(token) else { return false }
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
            await cacheManager.save(entry, for: .weibo, token: token)
            guard isCurrentCacheWork(token) else { return false }
            weiboItems = feed.displayItems
            weiboDetectionItems = feed.detectionItems
            sourceStates[NewsSource.weibo.id] = .loaded
            return hasNew
        } catch {
            guard isCurrentCacheWork(token) else { return false }
            NSLog("[NewsOrchestrator] 获取 \(NewsSource.weibo.displayName) 失败: \(error.localizedDescription)")
            sourceStates[NewsSource.weibo.id] = .failed(sourceErrorMessage(error))
            if useCacheFallback, weiboItems.isEmpty {
                let cached = await cacheManager.load(for: .weibo)
                guard isCurrentCacheWork(token) else { return false }
                if let cached {
                    weiboItems = cached.items
                    weiboDetectionItems = cached.items
                }
            }
            return false
        }
    }

    private func fetchBilibili(useCacheFallback: Bool, token: CacheWriteToken) async -> Bool {
        if let result = await fetchAndCache(
            for: .bilibili,
            token: token,
            fetcher: { try await BilibiliHotService.fetch() }
        ) {
            guard isCurrentCacheWork(token) else { return false }
            bilibiliItems = result.items
            return result.changed
        } else if isCurrentCacheWork(token), useCacheFallback, bilibiliItems.isEmpty {
            let cached = await cacheManager.load(for: .bilibili)
            guard isCurrentCacheWork(token) else { return false }
            if let cached { bilibiliItems = cached.items }
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

    private func fetchRSS(
        source: NewsSource, useCacheFallback: Bool, settings: AppSettings, token: CacheWriteToken
    ) async -> RSSFetchOutcome? {
        let existing = await cacheManager.load(for: source)
        guard isCurrentCacheWork(token) else { return nil }
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
            guard isCurrentCacheWork(token) else { return nil }
            switch result {
            case .notModified(let eTag, let lastModified):
                let validated = await cacheManager.markValidated(
                    for: source,
                    eTag: eTag,
                    lastModified: lastModified,
                    token: token
                )
                guard isCurrentCacheWork(token) else { return nil }
                guard let validated else {
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
                let translatedItems = await translateRSSItemsIfNeeded(items, settings: settings, token: token)
                guard isCurrentCacheWork(token) else { return nil }
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
                await cacheManager.save(entry, for: source, token: token)
                guard isCurrentCacheWork(token) else { return nil }
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
            guard isCurrentCacheWork(token) else { return nil }
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
    private func translateRSSItemsIfNeeded(
        _ items: [NewsItem], settings: AppSettings, token: CacheWriteToken
    ) async -> [NewsItem] {
        guard settings.rssTitleTranslationEnabled, settings.appLanguage == .en else {
            return items
        }
        let targetLang = settings.appLanguage.bcp47
        var translated: [NewsItem] = []
        for item in items {
            guard isCurrentCacheWork(token) else { return items }
            let cached = await translationCacheStore.cachedTranslation(for: item.title, targetLang: targetLang)
            guard isCurrentCacheWork(token) else { return items }
            if let cached {
                translated.append(item.withTranslatedTitle(cached))
            } else {
                let result = await TranslationService.translate(item.title, from: "zh-CN", to: targetLang)
                guard isCurrentCacheWork(token) else { return items }
                if result != item.title {
                    await translationCacheStore.saveTranslation(result, for: item.title, targetLang: targetLang, token: token)
                    guard isCurrentCacheWork(token) else { return items }
                    translated.append(item.withTranslatedTitle(result))
                } else {
                    translated.append(item)
                }
            }
        }
        return translated
    }

    // MARK: - Automatic research

    /// Picks at most one automatic research topic per hour from bursts, the
    /// local interest profile and the public chart. The AI triage call is the
    /// only paid step and runs at most once per hour, before any record exists.
    /// When nothing is worth researching the hour is skipped instead of
    /// spending a run on a weak topic.
    private func handleAutomaticResearch(settings: AppSettings, token: CacheWriteToken) async -> Bool {
        // `researchAutoEnabled` is the single master switch. `burstPushEnabled`
        // only decides whether the finished report also raises a notification.
        guard settings.researchAutoEnabled,
              isCurrentCacheWork(token),
              !isClearingResearchHistory,
              !isResearchClearBlocked else { return false }
        let now = Date()
        let epoch = InterestController.shared.state.consentEpoch
        guard automaticCheckAllows(now: now) else { return false }

        let state = InterestController.shared.state
        let personalizationEnabled = settings.researchUsePersonalization && state.learningEnabled
        let index = await researchStore.index()
        guard isCurrentCacheWork(token) else { return false }
        let recentRecords = index.sorted { $0.lastSeenAt > $1.lastSeenAt }
        let knownKeys = Set(index.filter {
            now.timeIntervalSince($0.lastSeenAt) <= 7 * 86_400
        }.map(\.topicKey))
        let keywordMatch: (NewsItem) -> Bool = { item in
            settings.keywordTrackingEnabled && settings.keywordMatches(item.title)
        }

        var pool = weiboDetectionItems
        pool.append(contentsOf: bilibiliItems)
        for source in settings.activeSources where !source.isBuiltIn {
            if let items = rssItemsMap[source.id] { pool.append(contentsOf: items) }
        }

        let candidates = ResearchCandidateBuilder.build(
            items: pool,
            state: state,
            now: now,
            limit: settings.researchDetectionLimit,
            excludingTopicKeys: knownKeys,
            includePersonal: personalizationEnabled,
            isKeywordMatch: keywordMatch
        )

        guard !candidates.isEmpty else {
            await recordAutomaticSkip(.skippedNoCandidates, candidateCount: 0,
                                      reasonKey: "research.auto.skip.noCandidates",
                                      settings: settings, epoch: epoch, now: now)
            return false
        }
        guard ResearchCandidateBuilder.hasPlausibleCandidate(
            candidates,
            personalizationEnabled: personalizationEnabled
        ) else {
            await recordAutomaticSkip(.skippedNoWorthy, candidateCount: candidates.count,
                                      reasonKey: "research.auto.skip.noWorthy",
                                      settings: settings, epoch: epoch, now: now)
            return false
        }
        guard automaticBudgetAllows(now: now) else {
            await recordAutomaticSkip(.skippedBudget, candidateCount: candidates.count,
                                      reasonKey: "research.auto.skip.budget",
                                      settings: settings, epoch: epoch, now: now)
            return false
        }

        // Decide the keyword priority before paying for triage. A burst still
        // wins, but anything else must yield to an actionable keyword match.
        let keywordPriority = hasExplicitKeywordCandidate(settings: settings)
        if keywordPriority, !candidates.contains(where: { $0.kind == .burst }) {
            await recordAutomaticSkip(
                .skippedKeywordPriority,
                candidateCount: candidates.count,
                reasonKey: "research.auto.skip.keywordPriority",
                settings: settings, epoch: epoch, now: now
            )
            return false
        }

        var cache = (state.research.triage ?? [:]).filter {
            now.timeIntervalSince($0.value.evaluatedAt) <= 7 * 86_400
        }
        var decisions: [ResearchTriageDecision] = []
        var uncached: [ResearchCandidateItem] = []
        for candidate in candidates {
            if let cached = cache[candidate.topicKey] {
                decisions.append(ResearchTriageDecision(
                    id: candidate.item.id,
                    sameEventAs: cached.sameEventAs,
                    sameAngleAs: cached.sameAngleAs,
                    worth: cached.worth,
                    confidence: cached.confidence,
                    reason: cached.reason
                ))
            } else {
                uncached.append(candidate)
            }
        }

        if !uncached.isEmpty {
            if let client = await makeTriageClient(settings: settings) {
                let request = ResearchTriage.request(
                    candidates: uncached,
                    recent: recentRecords,
                    language: settings.appLanguage,
                    now: now
                )
                guard !Task.isCancelled else { return false }
                _ = researchLedger.recordAICalls(1, origin: .burst)
                do {
                    let response = try await client.complete(request)
                    let parsed = ResearchTriage.parse(response.text)
                    decisions.append(contentsOf: parsed)
                    for decision in parsed {
                        guard let candidate = uncached.first(where: { $0.item.id == decision.id }) else { continue }
                        cache[candidate.topicKey] = ResearchTriageRecord(
                            topicKey: candidate.topicKey,
                            sameEventAs: decision.sameEventAs,
                            sameAngleAs: decision.sameAngleAs,
                            worth: decision.worth,
                            confidence: decision.confidence,
                            reason: decision.reason,
                            evaluatedAt: now
                        )
                    }
                } catch AIChatError.quotaUnavailable {
                    triageCache = cache
                    await recordAutomaticSkip(.skippedBudget, candidateCount: candidates.count,
                                              reasonKey: "research.auto.skip.budget",
                                              settings: settings, epoch: epoch, now: now)
                    return false
                } catch {
                    NSLog("[Research] triage failed: %@", String(describing: error))
                }
            }
        }

        triageCache = cache
        let knownIDs = Set(recentRecords.map(\.id))
        if let chosen = ResearchTriage.choose(
            candidates: candidates,
            decisions: decisions,
            knownRecordIDs: knownIDs
        ) {
            // Explicit keywords outrank inferred interest. A burst still wins;
            // anything else yields so the keyword pass can run this round.
            if chosen.kind != .burst, keywordPriority {
                await recordAutomaticSkip(
                    .skippedKeywordPriority,
                    candidateCount: candidates.count,
                    reasonKey: "research.auto.skip.keywordPriority",
                    settings: settings, epoch: epoch, now: now
                )
                return false
            }
            return await startOrRecordFailure(chosen, settings: settings, epoch: epoch, now: now)
        }

        // No usable verdict: keep only a very hot burst that has not already
        // been judged. A cached "not worth it" is a verdict and must not be
        // overridden by this fallback.
        if let fallback = ResearchTriage.fallbackBurst(candidates: candidates, decisions: decisions) {
            return await startOrRecordFailure(fallback, settings: settings, epoch: epoch, now: now)
        }

        // A cached batch that produced decisions is a real "not worth it"
        // result; an empty batch means the AI never answered.
        let evaluated = !decisions.isEmpty
        await recordAutomaticSkip(
            evaluated ? .skippedNoWorthy : .triageFailed,
            candidateCount: candidates.count,
            reasonKey: evaluated ? "research.auto.skip.noWorthy" : "research.auto.skip.triageFailed",
            settings: settings, epoch: epoch, now: now
        )
        return false
    }

    private func automaticCheckAllows(now: Date) -> Bool {
        guard ResearchAutomationPolicy.cheapCheckAllows(now: now, lastCheapCheckAt: lastCheapCheckAt) else {
            return false
        }
        guard let lastAutomaticCheckAt else { return true }
        return now.timeIntervalSince(lastAutomaticCheckAt) >= ResearchAutomationPolicy.minimumInterval
    }

    /// True when the user has typed a keyword that matches a currently loaded
    /// item. The explicit keyword path must get its turn before inferred
    /// interest, matching the documented priority order.
    private func hasExplicitKeywordCandidate(settings: AppSettings) -> Bool {
        guard settings.keywordTrackingEnabled, !settings.keywordList.isEmpty else { return false }
        let state = InterestController.shared.state
        return ResearchKeywordPriority.hasUnprocessedMatch(
            items: allActiveItems(settings: settings),
            keywords: settings.activeKeywords,
            handledPairs: notifiedKeywordPairs,
            handledTitles: notifiedBurstTopics,
            isBlocked: { state.isBlocked($0) }
        )
    }

    private func makeTriageClient(settings: AppSettings) async -> HTTPAIChatClient? {
        guard let bound = await resolveAPIKey(settings: settings, reportError: false) else { return nil }
        // Use the settings-level validator directly: the summary-facing helper
        // also mutates `aiSummaryState`, which a background check must not do.
        guard let configuration = await settings.validatedAIConfiguration(boundKey: bound) else {
            return nil
        }
        return HTTPAIChatClient(
            connection: configuration.connection,
            apiKey: configuration.apiKey,
            model: configuration.model,
            disableDeepSeekThinking: settings.aiDisableDeepSeekThinking,
            timeout: 12,
            quota: .tracked(
                origin: .triage,
                policy: settings.aiQuotaPolicy,
                price: configuration.connection.customPrice
                    ?? AIPriceCatalog.price(for: configuration.connection.providerID, model: configuration.model)
            )
        )
    }

    private func recordAutomaticSkip(
        _ kind: ResearchAutomaticDecision.Kind,
        candidateCount: Int,
        reasonKey: String,
        settings: AppSettings,
        epoch: UUID,
        now: Date
    ) async {
        if ResearchAutomationPolicy.skipConsumesCheckWindow(kind) {
            lastAutomaticCheckAt = now
        } else {
            lastCheapCheckAt = now
        }
        let reason = L10n.string(reasonKey, language: settings.appLanguage)
        lastAutomaticDecision = ResearchAutomaticDecision(
            at: now,
            kind: kind,
            candidateCount: candidateCount,
            reason: reason
        )
        settings.updateResearchLastAutomaticDecision(Self.automaticDecisionText(now: now, reason: reason))
        await persistResearchState(epoch: epoch)
    }

    private static let automaticDecisionTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func automaticDecisionText(now: Date, reason: String) -> String {
        "\(automaticDecisionTimeFormatter.string(from: now)) · \(reason)"
    }

    /// A paid triage verdict must always consume this hour's check, even when
    /// record creation or admission then refuses to start. Otherwise the next
    /// refresh would pay for the same judgement again five minutes later.
    private func startOrRecordFailure(
        _ candidate: ResearchCandidateItem,
        settings: AppSettings,
        epoch: UUID,
        now: Date
    ) async -> Bool {
        if await startAutomaticResearch(candidate, settings: settings, epoch: epoch, now: now) {
            return true
        }
        await recordAutomaticSkip(
            .skippedNotStarted,
            candidateCount: 1,
            reasonKey: "research.auto.skip.notStarted",
            settings: settings, epoch: epoch, now: now
        )
        return false
    }

    private func startAutomaticResearch(
        _ candidate: ResearchCandidateItem,
        settings: AppSettings,
        epoch: UUID,
        now: Date
    ) async -> Bool {
        guard epoch == InterestController.shared.state.consentEpoch,
              automaticBudgetAllows(now: now) else { return false }
        let origin: ResearchOrigin = candidate.kind == .burst ? .burst : .interest
        guard let record = await ResearchRecordProvisioner.ensureRecord(
            for: candidate.item,
            origin: origin,
            store: researchStore,
            now: now
        ) else { return false }
        guard ResearchAutoAdmission.allows(record, now: now) else { return false }
        let scheduled = await scheduleResearch(
            recordID: record.id,
            settings: settings,
            notify: settings.burstPushEnabled,
            trigger: origin
        )
        guard scheduled else { return false }
        lastAutomaticStartedAt = now
        lastAutomaticCheckAt = now
        lastCheapCheckAt = now
        lastAutomaticDecision = ResearchAutomaticDecision(
            at: now,
            kind: .started,
            candidateCount: 1,
            reason: nil
        )
        settings.updateResearchLastAutomaticDecision(Self.automaticDecisionText(
            now: now,
            reason: L10n.string("research.auto.started", language: settings.appLanguage, candidate.item.title)
        ))
        notifiedBurstTopics.insert(candidate.item.title)
        await persistResearchState(epoch: epoch)
        await refreshResearchSummary()
        return true
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
        // A corrupt or newer-version placeholder is read-only; writing it would
        // destroy bytes this build does not understand.
        guard record.status != .corrupt, record.loadIssue == nil else { return }
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
            await scheduleResearch(recordID: record.id, settings: settings)
        }
        await refreshResearchSummary()
        return record.id
    }

    func startManualResearch(title: String, settings: AppSettings) async -> String? {
        let item = weiboItems.first { $0.title == title }
            ?? NewsItem(title: title, url: "https://s.weibo.com", source: .weibo)
        return await startManualResearch(item: item, settings: settings)
    }

    @discardableResult
    private func scheduleResearch(
        recordID: String,
        settings: AppSettings,
        notify: Bool = true,
        trigger: ResearchOrigin = .manual
    ) async -> Bool {
        ResearchCoordinator.shared.setMaxConcurrent(settings.researchMaxConcurrent)
        let outcome = await ResearchCoordinator.shared.schedule(recordID: recordID, notify: notify, trigger: trigger) { [weak self] record, progress in
            guard let self else {
                return .failure(L10n.string("research.error.unavailable", language: settings.appLanguage))
            }
            return await self.executeResearch(
                record: record,
                settings: settings,
                progress: progress
            )
        }
        return outcome == .accepted
    }

    /// Runs the evidence-backed pipeline for one record. The coordinator owns
    /// status/persistence; this method only resolves credentials and builds the
    /// injected dependencies.
    func executeResearch(
        record: ResearchRecord,
        settings: AppSettings,
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

        guard let bound = await resolveAPIKey(settings: settings) else {
            if case let .error(message) = aiSummaryState { return .failure(message) }
            return .failure(L10n.string("research.error.noAIKey", language: settings.appLanguage))
        }
        guard let configuration = await validatedConfiguration(settings: settings, bound: bound) else {
            if case let .error(message) = aiSummaryState { return .failure(message) }
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
            quotaPolicy: settings.aiQuotaPolicy,
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

    /// Settings-facing snapshot of the same router that runs research. It
    /// contains no key, fingerprint, query or raw provider error.
    func searchProviderStatuses(settings: AppSettings) async -> [SearchProviderStatus] {
        let keys = await resolveSearchKeys(settings: settings)
        let configuration = SearchRouterConfiguration(
            enabled: settings.enabledSearchProviders,
            keys: keys
        )
        return await researchSearchRouter.statusSnapshot(configuration: configuration)
    }

    /// Clears only this provider's auth block. Never sends a request, never
    /// clears a quota cooldown and never touches the ledger.
    func clearSearchAuthBlock(for provider: SearchProviderID) async {
        await researchSearchRouter.clearAuthBlock(for: provider)
    }

    /// Search keys live in the encrypted store, with the legacy Firecrawl
    /// UserDefaults value kept as a migration fallback.
    private func resolveSearchKeys(settings: AppSettings) async -> [SearchProviderID: String] {
        var keys = await SearchKeyStore.loadAll()
        let firecrawl = await SearchKeyStore.key(for: .firecrawl, fallback: settings.firecrawlAPIKey)
        if firecrawl.isEmpty { keys.removeValue(forKey: .firecrawl) }
        else { keys[.firecrawl] = firecrawl }
        return keys
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
    private func handleKeywordTopics(settings: AppSettings, token: CacheWriteToken) async {
        guard settings.researchAutoEnabled,
              isCurrentCacheWork(token),
              settings.keywordTrackingEnabled,
              !isClearingResearchHistory,
              !isResearchClearBlocked else { return }
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
        guard let bound = await resolveAPIKey(settings: settings),
              await validatedConfiguration(settings: settings, bound: bound) != nil else { return }

        let prioritizedIDs = ResearchSelectionPolicy.select(items: matches.map(\.item), state: InterestController.shared.state, limit: 2).map { $0.item.id }
        matches.sort { (prioritizedIDs.firstIndex(of: $0.item.id) ?? Int.max) < (prioritizedIDs.firstIndex(of: $1.item.id) ?? Int.max) }

        var notifiedChanged = false
        var scheduled = false
        for match in matches.prefix(2) {
            guard epoch == InterestController.shared.state.consentEpoch else { return }
            guard automaticBudgetAllows(now: now) else { break }
            guard let record = await ResearchRecordProvisioner.ensureRecord(
                for: match.item,
                origin: .keyword,
                store: researchStore,
                now: now
            ) else { continue }

            guard ResearchAutoAdmission.allows(record, now: now) else { continue }
            scheduled = await scheduleResearch(recordID: record.id, settings: settings, trigger: .keyword)
            if scheduled {
                lastAutomaticStartedAt = now
                let pair = "\(match.keyword)\n\(match.item.title)"
                if notifiedKeywordPairs.insert(pair).inserted { notifiedChanged = true }
                break
            }
        }

        if notifiedChanged || scheduled {
            await persistResearchState(epoch: epoch)
        }
        await refreshResearchSummary()
    }

    /// Single gate for every feed-triggered run. Callers must consult it before
    /// creating a record, not after: an admission failure must never persist.
    private func automaticBudgetAllows(now: Date) -> Bool {
        ResearchAutomationPolicy.allows(
            now: now,
            lastStartedAt: lastAutomaticStartedAt,
            activeAutomaticRuns: ResearchCoordinator.shared.activeAutomaticRunCount()
        )
    }

    // MARK: - Developer test: fake burst push

    /// Fires a fake Weibo "爆" push (developer test mode). Queues the same
    /// coordinator job a real burst uses, then opens its record in the research
    /// center. The developer toggle always forces web search so the full
    /// pipeline is exercised; the detail polls the record, not a side cache.
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

        await scheduleResearch(recordID: record.id, settings: settings)
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
        isManualRefresh: Bool,
        hotChanged: Bool,
        rssChanged: Bool,
        trendSummary: TrendChangeSummary,
        token: CacheWriteToken
    ) async {
        guard settings.aiSummaryEnabled, isCurrentCacheWork(token) else { return }
        let summaryRevision = settings.aiSummaryRunRevision
        let isCurrentRun = { self.isCurrentCacheWork(token) && settings.isCurrentAISummaryRun(summaryRevision) }

        let allItems = allActiveItems(settings: settings)
        guard !allItems.isEmpty else { return }

        guard AISummaryService.tryAcquireGenerationLock(for: Self.sharedSummaryTarget) else {
            return
        }
        defer { AISummaryService.releaseGenerationLock(for: Self.sharedSummaryTarget) }

        guard let bound = await resolveAPIKey(settings: settings, reportIf: isCurrentRun), isCurrentRun(),
              let configuration = await validatedConfiguration(settings: settings, bound: bound, reportIf: isCurrentRun),
              isCurrentRun() else { return }

        let newHash = summaryGenerationHash(items: allItems, settings: settings)
        let hasNewContent = newHash != sharedSummaryLastHash
            && newHash != sharedSummaryLastTruncatedHash
        let elapsed = Date().timeIntervalSince(lastSummaryGeneratedAt ?? .distantPast)
        let hasBurstWeibo = weiboItems.contains { $0.hotLabel == "爆" }
        let burstKey = Self.burstIdentity(items: weiboItems)
        let repeatedBurst = burstKey != nil && burstKey == lastBurstSummaryKey
        if let burstKey, !repeatedBurst {
            let today = Calendar.current.startOfDay(for: Date())
            if burstQuotaBlockedOn == today { return }
            let snapshot = AIQuotaStore.shared.snapshot()
            let policy = settings.aiQuotaPolicy
            if snapshot.isUsable, policy.blocks(count: snapshot.count, costMicros: snapshot.costMicros) {
                // The ledger is exhausted for today. Keep any previous result
                // and stop asking; midnight (or a new day) starts a fresh check.
                burstQuotaBlockedOn = today
                let message = "error.aiQuotaExhausted".localized
                if hasRenderableSummary {
                    aiSummaryUpdateError = message
                } else {
                    aiSummaryState = .error(message)
                }
                return
            }
        }
        let elapsedSinceBurst = Date().timeIntervalSince(lastBurstSummaryAt ?? .distantPast)
        let shouldGenerate = Self.shouldGenerateSummary(
            hasCachedSummary: sharedSummaryLastHash != nil,
            hasNewContent: hasNewContent,
            isManualRefresh: isManualRefresh,
            hotChanged: hotChanged,
            rssChanged: rssChanged,
            trendIsSignificant: trendSummary.isSignificant,
            elapsedSinceSummary: elapsed,
            shouldRecover: Self.shouldRecoverAISummary(from: aiSummaryState),
            hasBurstWeibo: hasBurstWeibo,
            elapsedSinceBurstSummary: elapsedSinceBurst,
            isRepeatedTruncation: newHash == sharedSummaryLastTruncatedHash || repeatedBurst
        )

        if shouldGenerate {
            let hadRenderableSummary = hasRenderableSummary
            if !hadRenderableSummary { aiSummaryState = .fetching }
            aiSummaryUpdating = hadRenderableSummary
            aiSummaryUpdateError = nil
            AISummaryService.initBudget(
                target: Self.sharedSummaryTarget,
                mode: .shared,
                policy: settings.aiQuotaPolicy
            )
            _ = await generateSummary(
                items: allItems,
                contentHash: newHash,
                maxWords: settings.aiDashboardMaxWords,
                configuration: configuration,
                settings: settings,
                trendHistoryContext: trendSummary.context,
                trendHistoryHash: trendSummary.historyHash,
                burstTriggered: hasBurstWeibo,
                summaryLanguage: settings.appLanguage,
                summaryRevision: summaryRevision,
                cacheToken: token
            )
            if let burstKey,
               aiSummaryUpdateError == nil,
               sharedSummaryLastHash == newHash || sharedSummaryLastTruncatedHash == newHash {
                lastBurstSummaryKey = burstKey
            }
            settings.refreshAIUsageMirror()
        }
    }

    // MARK: - Shared Summary Recovery

    /// Safe to call when either UI opens. It only generates if no current shared result exists.
    func generateSharedSummaryIfNeeded(settings: AppSettings) async {
        guard settings.aiSummaryEnabled, cacheClearDepth == 0 else { return }
        let token = cacheWriteGeneration.capture()
        let summaryRevision = settings.aiSummaryRunRevision
        let isCurrentRun = { self.isCurrentCacheWork(token) && settings.isCurrentAISummaryRun(summaryRevision) }

        let allItems = allActiveItems(settings: settings)
        guard !allItems.isEmpty else { return }

        guard AISummaryService.tryAcquireGenerationLock(for: Self.sharedSummaryTarget) else {
            return
        }
        defer { AISummaryService.releaseGenerationLock(for: Self.sharedSummaryTarget) }

        guard let bound = await resolveAPIKey(settings: settings, reportIf: isCurrentRun), isCurrentRun(),
              let configuration = await validatedConfiguration(settings: settings, bound: bound, reportIf: isCurrentRun),
              isCurrentRun() else { return }

        let newHash = summaryGenerationHash(items: allItems, settings: settings)
        let shouldGenerate = Self.shouldRecoverSharedSummary(
            hasNewContent: newHash != sharedSummaryLastHash && newHash != sharedSummaryLastTruncatedHash,
            isRepeatedTruncation: newHash == sharedSummaryLastTruncatedHash,
            state: aiSummaryState
        )

        guard shouldGenerate else { return }

        AISummaryService.initBudget(
            target: Self.sharedSummaryTarget,
            mode: .shared,
            policy: settings.aiQuotaPolicy
        )
        _ = await generateSummary(
            items: allItems,
            contentHash: newHash,
            maxWords: settings.aiDashboardMaxWords,
            configuration: configuration,
            settings: settings,
            trendHistoryContext: latestTrendSummary.context,
            trendHistoryHash: latestTrendSummary.historyHash,
            summaryLanguage: settings.appLanguage,
            summaryRevision: summaryRevision,
            cacheToken: token
        )
        settings.refreshAIUsageMirror()
    }

    // MARK: - Manual Regeneration (Popup context)

    func regenerateAISummary(settings: AppSettings) async {
        guard settings.aiSummaryEnabled, cacheClearDepth == 0 else { return }
        let token = cacheWriteGeneration.capture()
        let summaryRevision = settings.aiSummaryRunRevision
        let isCurrentRun = { self.isCurrentCacheWork(token) && settings.isCurrentAISummaryRun(summaryRevision) }
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

        guard let bound = await resolveAPIKey(settings: settings, reportIf: isCurrentRun), isCurrentRun(),
              let configuration = await validatedConfiguration(settings: settings, bound: bound, reportIf: isCurrentRun),
              isCurrentRun() else { return }
        AISummaryService.initBudget(
            target: Self.sharedSummaryTarget,
            mode: .shared,
            policy: settings.aiQuotaPolicy
        )
        let previousAttempts = AISummaryService.readGenerationAttempts(target: Self.sharedSummaryTarget, mode: .shared)
        let newHash = summaryGenerationHash(items: allItems, settings: settings)
        let attempts = await generateSummary(
            items: allItems,
            contentHash: newHash,
            maxWords: settings.aiDashboardMaxWords,
            configuration: configuration,
            settings: settings,
            trendHistoryContext: latestTrendSummary.context,
            trendHistoryHash: latestTrendSummary.historyHash,
            summaryLanguage: settings.appLanguage,
            summaryRevision: summaryRevision,
            cacheToken: token,
            isManualRegeneration: true
        )
        if attempts > previousAttempts { AISummaryService.recordManualRegeneration() }
        settings.refreshAIUsageMirror()
    }

    // MARK: - Shared Helpers

    private struct SourceFetchResult {
        let items: [NewsItem]
        let changed: Bool
    }

    private func fetchAndCache(
        for source: NewsSource,
        token: CacheWriteToken,
        fetcher: () async throws -> [NewsItem]
    ) async -> SourceFetchResult? {
        do {
            let items = try await fetcher()
            guard isCurrentCacheWork(token) else { return nil }
            guard !items.isEmpty else {
                sourceStates[source.id] = .failed("error.noContent".localized)
                return nil
            }

            let now = Date()
            let existing = await cacheManager.load(for: source)
            guard isCurrentCacheWork(token) else { return nil }
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
            await cacheManager.save(entry, for: source, token: token)
            guard isCurrentCacheWork(token) else { return nil }
            sourceStates[source.id] = .loaded
            return SourceFetchResult(items: items, changed: hasNew)
        } catch {
            guard isCurrentCacheWork(token) else { return nil }
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

    private static func shouldRecoverAISummary(from state: AISummaryState) -> Bool {
        switch state {
        case .idle, .noKey, .fetching, .error:
            return true
        case .summarizing, .done, .truncated:
            return false
        }
    }

    /// Keep missing, unreadable and stale credentials distinct across every entry point.
    private func resolveAPIKey(
        settings: AppSettings, reportError: Bool = true, reportIf: () -> Bool = { true }
    ) async -> ProviderBoundKey? {
        do {
            let bound = try await settings.resolveBoundAPIKey(expected: settings.aiKeyContext)
            guard settings.isCurrentAIKey(bound) else { throw AISearchError.configurationChanged }
            guard !bound.key.isEmpty || bound.context.providerID == AIProvider.ollamaCloud.rawValue else {
                if reportError && reportIf() {
                    reportSummaryFailure("dash.state.noKey".localized, fallbackState: .noKey)
                }
                return nil
            }
            return bound
        } catch is CancellationError {
            return nil
        } catch let error as AISearchError {
            if reportError && reportIf() {
                reportSummaryFailure(error.message(settings.appLanguage))
            }
            return nil
        } catch {
            if reportError && reportIf() {
                reportSummaryFailure(AISearchError.keyReadFailed.message(settings.appLanguage))
            }
            return nil
        }
    }

    private func validatedConfiguration(
        settings: AppSettings, bound: ProviderBoundKey, reportIf: () -> Bool = { true }
    ) async -> ValidatedAIConfiguration? {
        guard let configuration = await settings.validatedAIConfiguration(boundKey: bound) else {
            guard reportIf() else { return nil }
            if !settings.isCurrentAIKey(bound) {
                reportSummaryFailure(AISearchError.configurationChanged.message(settings.appLanguage))
            } else if let error = settings.modelCatalogError {
                reportSummaryFailure(error.message(language: settings.appLanguage))
            }
            return nil
        }
        return configuration
    }

    private func restoreCachedSummaryIfPossible(settings: AppSettings, token: CacheWriteToken) async {
        let summaryRevision = settings.aiSummaryRunRevision
        let isEligible = {
            self.isCurrentCacheWork(token)
                && settings.isCurrentAISummaryRun(summaryRevision) && self.aiSummaryState == .idle
                && self.sharedSummaryLastHash == nil && self.sharedSummaryLastTruncatedHash == nil
        }
        guard let cached = await AISummaryCacheRestore.loadIfEligible(
            isEligible: isEligible,
            load: { await self.aiSummaryCacheStore.load() }
        ) else { return }
        // A generation can hold the lock while it resolves its model/key,
        // before it has changed the visible state from .idle.
        guard AISummaryService.tryAcquireGenerationLock(for: Self.sharedSummaryTarget) else { return }
        defer { AISummaryService.releaseGenerationLock(for: Self.sharedSummaryTarget) }
        guard isEligible() else { return }
        // Cache first: the last completed result is the best thing to show
        // while the feed catches up. It is labelled with its generation time
        // and a manual update button, never silently discarded because the
        // current item hash changed.
        let trendIndices = cached.manifest?.trendIndices ?? Set(cached.items.enumerated().filter { $0.element.source.isBuiltIn }.map(\.offset))
        aiSummaryItems = cached.items
        aiSummaryText = cached.summary
        aiSummaryManifest = cached.manifest
        aiParsedSummary = AISummaryParser.parseDualSummary(
            cached.summary,
            itemCount: cached.items.count,
            trendIndices: trendIndices
        )
        sharedSummaryLastHash = cached.completedContentHash
        sharedSummaryLastTruncatedHash = cached.truncatedContentHash
        sharedSummaryConsecutiveTruncationCount = 0
        lastSummaryGeneratedAt = cached.generatedAt
        aiSummaryRestoredAt = cached.generatedAt
        aiSummaryUpdateError = nil
        aiSummaryUpdating = false
        aiSummaryState = cached.presentationState
    }

    /// Keeps a completed result on screen when a refresh fails. Only a run with
    /// nothing to show falls back to the full error state.
    private func failSummary(_ message: String, fallbackState: AISummaryState? = nil) {
        if aiSummaryUpdating, hasRenderableSummary {
            aiSummaryUpdateError = message
        } else if let fallbackState {
            aiSummaryState = fallbackState
        } else {
            aiSummaryState = .error(message)
        }
        aiSummaryUpdating = false
    }

    /// Used before `generateSummary` starts. There is no `aiSummaryUpdating`
    /// flag yet, so content presence alone decides whether the error replaces
    /// the card or appears beside it.
    private func reportSummaryFailure(_ message: String, fallbackState: AISummaryState? = nil) {
        if hasRenderableSummary {
            aiSummaryUpdateError = message
        } else if let fallbackState {
            aiSummaryState = fallbackState
        } else {
            aiSummaryState = .error(message)
        }
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
        summaryLanguage: AppLanguage = .zh,
        summaryRevision: UUID,
        cacheToken: CacheWriteToken,
        isManualRegeneration: Bool = false
    ) async -> Int {
        let budgetMode: AISummaryBudgetMode = .shared
        let model = configuration.model
        let apiKey = configuration.apiKey
        let connection = configuration.connection
        let interest = InterestController.shared
        let epoch = interest.state.consentEpoch
        let isCurrentRun = {
            self.isCurrentCacheWork(cacheToken)
                && epoch == interest.state.consentEpoch && settings.isCurrentAISummaryRun(summaryRevision)
                && settings.isCurrentAIConfiguration(configuration)
        }
        // Capture the previous result before any guard can change the state.
        // A failed refresh keeps it visible instead of replacing it with an
        // error card.
        let hadRenderableSummary = hasRenderableSummary
        aiSummaryUpdating = hadRenderableSummary
        aiSummaryUpdateError = nil
        defer {
            aiSummaryUpdating = false
            if !isCurrentRun(),
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
        guard isCurrentRun() else { return 0 }
        let manifest = SummaryManifest(items: selected, profileVersion: state.learningEnabled ? state.profileVersion : 0,
                                       model: model, provider: ContentIdentity.digest(connection.baseURL), language: summaryLanguage, maxWords: maxWords,
                                       asOf: now, coverageStart: max(now.addingTimeInterval(-24 * 3600), state.archiveStartedAt ?? now), trendHistoryHash: trendHistoryHash)
        let items = manifest.items
        let frozenThinking = settings.aiSummaryThinking
        guard !items.isEmpty else {
            if !hasRenderableSummary { aiSummaryState = .idle }
            return 0
        }
        guard !apiKey.isEmpty || configuration.providerID == AIProvider.ollamaCloud.rawValue else {
            failSummary("dash.state.noKey".localized, fallbackState: .noKey)
            return AISummaryService.readGenerationAttempts(target: Self.sharedSummaryTarget, mode: budgetMode)
        }

        // 连续截断保护：超过阈值时停止自动重试
        guard Self.canAttemptSummary(
            consecutiveTruncations: sharedSummaryConsecutiveTruncationCount,
            limit: maxConsecutiveTruncations,
            isManualRegeneration: isManualRegeneration
        ) else {
            failSummary(L10n.string("error.aiTruncated", maxConsecutiveTruncations))
            return AISummaryService.readGenerationAttempts(target: Self.sharedSummaryTarget, mode: budgetMode)
        }

        if !hadRenderableSummary {
            aiSummaryState = .summarizing
        }
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
                thinking: frozenThinking,
                requestAllowed: { await MainActor.run {
                    self.isCurrentCacheWork(cacheToken)
                        && InterestController.shared.state.consentEpoch == epoch
                        && settings.isCurrentAISummaryRun(summaryRevision)
                        && settings.isCurrentAIConfiguration(configuration)
                } }
            )
            guard isCurrentRun() else {
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
                        thinking: frozenThinking,
                        requestAllowed: { await MainActor.run {
                            self.isCurrentCacheWork(cacheToken)
                                && InterestController.shared.state.consentEpoch == epoch
                                && settings.isCurrentAISummaryRun(summaryRevision)
                                && settings.isCurrentAIConfiguration(configuration)
                        } }
                    )
                } else {
                    finalResult = firstResult
                }
            } else {
                finalResult = firstResult
            }

            let requestCount = AISummaryService.readGenerationAttempts(target: Self.sharedSummaryTarget, mode: budgetMode)
            guard isCurrentRun() else { return requestCount }
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
                failSummary("error.aiFormat".localized)
                return requestCount
            }

            aiSummaryItems = items
            aiSummaryText = finalResult.summary
            aiSummaryManifest = manifest
            aiParsedSummary = finalParsed
            aiSummaryUpdating = false
            aiSummaryUpdateError = nil
            aiSummaryRestoredAt = nil
            // A truncated result with both sections may be cached to avoid
            // repeated requests, but it must still be presented as incomplete.
            if finalResult.isTruncated, !Self.hasBothSections(finalParsed) {
                sharedSummaryLastTruncatedHash = contentHash
                sharedSummaryConsecutiveTruncationCount += 1
                aiSummaryState = .truncated(finalResult.summary)
            } else {
                if finalResult.isTruncated {
                    sharedSummaryLastTruncatedHash = contentHash
                    sharedSummaryConsecutiveTruncationCount += 1
                } else {
                    sharedSummaryLastHash = contentHash
                    sharedSummaryLastTruncatedHash = nil
                    sharedSummaryConsecutiveTruncationCount = 0
                }
                let generatedAt = Date()
                lastSummaryGeneratedAt = generatedAt
                if burstTriggered {
                    lastBurstSummaryAt = generatedAt
                }
                aiSummaryState = .content(finalResult.summary, wasTruncated: finalResult.isTruncated)
                await summaryCache(for: summaryLanguage).save(
                    AISummaryCacheEntry(
                        summary: finalResult.summary,
                        items: items,
                        contentHash: contentHash,
                        trendHistoryHash: trendHistoryHash,
                        generatedAt: generatedAt,
                        trendItemCount: manifest.trendIndices.count,
                        language: summaryLanguage,
                        manifest: manifest,
                        wasTruncated: finalResult.isTruncated
                    ),
                    token: cacheToken
                )
            }
            return requestCount
        } catch is CancellationError {
            if isCurrentRun() {
                aiSummaryUpdating = false
                if !hasRenderableSummary { aiSummaryState = .idle }
            }
        } catch NewsBarError.apiKeyInvalid {
            guard isCurrentRun() else { return AISummaryService.readGenerationAttempts(target: Self.sharedSummaryTarget, mode: budgetMode) }
            failSummary("error.aiKeyInvalid".localized)
        } catch NewsBarError.rateLimited {
            guard isCurrentRun() else { return AISummaryService.readGenerationAttempts(target: Self.sharedSummaryTarget, mode: budgetMode) }
            let snapshot = AIQuotaStore.shared.snapshot()
            let mode = AISummaryService.readGenerationLimitMode(
                target: Self.sharedSummaryTarget,
                mode: budgetMode
            )
            if mode == .cost {
                failSummary(L10n.string(
                    "error.aiCostCapReached",
                    AICostFormat.yuan(snapshot.costMicros),
                    AICostFormat.yuan(settings.aiCostCapMicros)
                ))
            } else {
                let cap = AISummaryService.readGenerationCap(
                    target: Self.sharedSummaryTarget,
                    mode: budgetMode
                ) ?? 0
                failSummary(L10n.string("error.aiCapReached", snapshot.count, cap))
            }
        } catch let error as NewsBarError {
            guard isCurrentRun() else { return AISummaryService.readGenerationAttempts(target: Self.sharedSummaryTarget, mode: budgetMode) }
            switch error {
            case .parseFailedWithDetail(let detail):
                NSLog("[NewsOrchestrator] AI summary retry exhausted: %@", detail)
                failSummary(L10n.string("error.aiUnavailable", detail))
            case .parseFailed:
                failSummary("error.aiBadFormat".localized)
            default:
                NSLog("[NewsOrchestrator] AI summary NewsBarError: %@", error.localizedDescription)
                failSummary("error.aiFailed".localized)
            }
        } catch let error as URLError {
            guard isCurrentRun() else { return AISummaryService.readGenerationAttempts(target: Self.sharedSummaryTarget, mode: budgetMode) }
            NSLog("[NewsOrchestrator] AI summary URLError: %@", error.localizedDescription)
            failSummary(error.code == .timedOut ? "error.aiTimeout".localized : "error.aiNoNetwork".localized)
        } catch let error as DecodingError {
            guard isCurrentRun() else { return AISummaryService.readGenerationAttempts(target: Self.sharedSummaryTarget, mode: budgetMode) }
            NSLog("[NewsOrchestrator] AI summary DecodingError: %@", error.localizedDescription)
            failSummary("error.aiBadFormat".localized)
        } catch {
            guard isCurrentRun() else { return AISummaryService.readGenerationAttempts(target: Self.sharedSummaryTarget, mode: budgetMode) }
            NSLog("[NewsOrchestrator] AI summary failed: %@", error.localizedDescription)
            failSummary("error.aiFailed".localized)
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

    private func updateInterestCandidates(settings: AppSettings, token: CacheWriteToken) async {
        let interest = InterestController.shared
        await interest.prepare()
        guard isCurrentCacheWork(token), interest.isReady else { return }
        let activeIDs = Set(settings.activeSources.map(\.id))
        let current = allActiveItems(settings: settings).filter { activeIDs.contains($0.source.id) }
        await interest.ingest(current)
        guard isCurrentCacheWork(token) else { return }
        await restoreResearchStateIfNeeded()
        guard isCurrentCacheWork(token) else { return }
        let archive = interest.state.contents.values.filter {
            activeIDs.contains($0.item.source.id) && Date().timeIntervalSince($0.lastSeen) <= 24 * 3600
        }.map(\.item)
        interest.rankCandidates(current + archive)
    }

    func restoreResearchStateIfNeeded() async {
        let interest = InterestController.shared
        await interest.prepare()
        if !researchStateLoaded, interest.isReady {
            switch researchClearIntentStore.load() {
            case .pending:
                // Do not load legacy artifacts: the user already asked for
                // them to be discarded. Finish that work first.
                researchStateLoaded = true
                let saved = interest.state.research
                notifiedBurstTopics = saved.notifiedBursts
                notifiedKeywordPairs = saved.notifiedKeywords
                legacyBurstArtifacts = [:]
                let clearResult = await clearResearchHistory()
                if !clearResult.isComplete {
                    // The intent file is still there; keep automation paused
                    // so nothing can import artifacts back while it is pending.
                    isResearchClearBlocked = true
                }
                await refreshResearchSummary()
                return
            case .unsupportedVersion:
                researchStateLoaded = true
                isResearchClearBlocked = true
                legacyBurstArtifacts = [:]
                await refreshResearchSummary()
                return
            case .none:
                break
            }
            let saved = interest.state.research
            legacyBurstArtifacts = saved.artifacts
            notifiedBurstTopics = saved.notifiedBursts
            notifiedKeywordPairs = saved.notifiedKeywords
            lastResearchAt = saved.lastResearchAt
            lastAutomaticStartedAt = saved.lastAutomaticStartedAt
            lastAutomaticCheckAt = saved.lastAutomaticCheckAt
            lastAutomaticDecision = saved.lastAutomaticDecision
            triageCache = saved.triage ?? [:]
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
        // Conflicts and unverified writes keep both the artifacts and the
        // marker so the next launch retries instead of losing history.
        guard outcome.isComplete else { return }

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
            persisted.artifacts = Dictionary(uniqueKeysWithValues: legacyBurstArtifacts.sorted { $0.key < $1.key }.prefix(500).map { ($0.key, $0.value) })
        }
        persisted.notifiedBursts = Set(notifiedBurstTopics.sorted().prefix(2000))
        persisted.notifiedKeywords = Set(notifiedKeywordPairs.sorted().prefix(2000))
        persisted.lastResearchAt = lastResearchAt
        persisted.lastAutomaticStartedAt = lastAutomaticStartedAt
        persisted.lastAutomaticCheckAt = lastAutomaticCheckAt
        persisted.lastAutomaticDecision = lastAutomaticDecision
        persisted.triage = triageCache.isEmpty ? nil : triageCache
        InterestController.shared.updateResearch(persisted, epoch: epoch)
        await InterestController.shared.flush()
    }

    /// Single entry point for every "clear research history" action.
    ///
    /// Order matters: a durable intent is written first, then automation stops,
    /// then the disposable cache, the authoritative records and the legacy
    /// artifacts are cleared, each stage recorded. The intent is removed only
    /// after the result is verified, so a crash resumes instead of re-importing.
    @discardableResult
    func clearResearchHistory() async -> ResearchClearResult {
        let existingIntent: ResearchClearIntent?
        switch researchClearIntentStore.load() {
        case .pending(let intent):
            existingIntent = intent
        case .unsupportedVersion:
            isResearchClearBlocked = true
            return ResearchClearResult(error: "clear-intent-unsupported")
        case .none:
            existingIntent = nil
        }
        return await performClearResearchHistory(existing: existingIntent)
    }

    private func performClearResearchHistory(
        existing: ResearchClearIntent?
    ) async -> ResearchClearResult {
        guard !isClearingResearchHistory else {
            return ResearchClearResult(error: "clear already running")
        }
        isClearingResearchHistory = true
        researchClearGeneration += 1
        let generation = researchClearGeneration
        defer { isClearingResearchHistory = false }

        // Once the user has asked to clear history, no later persistence pass
        // may write the in-memory artifacts back, even if a stage fails.
        legacyBurstArtifacts = [:]
        legacyResearchImported = true

        await InterestController.shared.prepare()
        let interest = InterestController.shared
        let clearer = ResearchHistoryClearer(
            store: researchStore,
            cache: researchCacheStore,
            intentStore: researchClearIntentStore,
            cancelResearch: {
                // Existing tasks are cancelled; late writes are additionally
                // blocked by the coordinator's generation check and the
                // store's deleted-ID tombstones.
                ResearchCoordinator.shared.cancelAll()
            },
            clearArtifacts: {
                let epoch = interest.state.consentEpoch
                var research = interest.state.research
                research.artifacts = [:]
                interest.updateResearch(research, epoch: epoch)
                let targetRevision = interest.state.revision
                return await interest.flush(revision: targetRevision)
            },
            verifyArtifactsCleared: {
                interest.state.research.artifacts.isEmpty
            }
        )

        let result = await clearer.run(existing: existing, generation: generation)
        guard result.isComplete else { return result }

        isResearchClearBlocked = false
        researchSummary = .zero
        researchHighlights = []
        postResearchRecordsChanged()
        return result
    }

    private func postResearchRecordsChanged() {
        NotificationCenter.default.post(name: .researchRecordsChanged, object: nil)
    }

    func clearPersonalizedArtifacts() async {
        cacheClearDepth += 1
        defer { cacheClearDepth -= 1 }
        cacheWriteGeneration.invalidate()
        NotificationService.clearPersonalizedNotifications()
        for language in AppLanguage.allCases { await summaryCache(for: language).clear() }
        await PageSummaryCacheStore.shared.clear()
        aiSummaryState = .idle
        aiSummaryItems = []
        aiSummaryText = nil
        aiParsedSummary = nil
        aiSummaryManifest = nil
        aiSummaryRestoredAt = nil
        aiSummaryUpdating = false
        aiSummaryUpdateError = nil
        sharedSummaryLastHash = nil
        sharedSummaryLastTruncatedHash = nil
        sharedSummaryConsecutiveTruncationCount = 0
        lastBurstSummaryAt = nil
        lastBurstSummaryKey = nil
        burstQuotaBlockedOn = nil
        notifiedBurstTopics = []
        notifiedKeywordPairs = []
        legacyBurstArtifacts = [:]
        researchStateLoaded = false
        lastResearchAt = nil
        lastAutomaticStartedAt = nil
        lastAutomaticCheckAt = nil
        lastAutomaticDecision = nil
        triageCache = [:]
        weiboDetectionItems = []
        researchSummary = .zero
        researchHighlights = []
        legacyResearchImported = true
        batchProgress = .zero
        manualRefreshWarning = nil
        // A clear that lands mid-refresh must not leave sources stuck on
        // "loading" after the cycle is refused.
        for (id, state) in sourceStates where state == .loading {
            sourceStates[id] = .idle
        }
        _ = await clearResearchHistory()
    }

    func clearCache() async {
        cacheClearDepth += 1
        cacheWriteGeneration.invalidate()
        defer { cacheClearDepth -= 1 }
        // Invalidate and empty the observable state before any actor hop. A
        // refresh that started earlier must not publish back into this state.
        await PageSummaryCacheStore.shared.clear()
        weiboItems = []
        weiboDetectionItems = []
        bilibiliItems = []
        rssItemsMap = [:]
        aiSummaryState = .idle
        aiSummaryItems = []
        aiSummaryText = nil
        aiParsedSummary = nil
        aiSummaryManifest = nil
        aiSummaryRestoredAt = nil
        aiSummaryUpdating = false
        aiSummaryUpdateError = nil
        sourceStates = [:]
        sharedSummaryLastHash = nil
        sharedSummaryLastTruncatedHash = nil
        sharedSummaryConsecutiveTruncationCount = 0
        lastSummaryGeneratedAt = nil
        lastBurstSummaryAt = nil
        lastBurstSummaryKey = nil
        burstQuotaBlockedOn = nil
        lastHotRefresh = nil
        lastSourceRefresh = [:]
        lastSourceAttempt = [:]
        rssUnchangedRefreshCounts = [:]
        rssLastChangedAt = [:]
        rssFailureCounts = [:]
        loadedCacheSourceIDs = []
        pendingManualRefresh = false
        batchProgress = .zero
        manualRefreshWarning = nil
        lastHourlyPushAt = nil
        latestTrendSummary = .none
        notifiedBurstTopics = []
        notifiedKeywordPairs = []
        legacyBurstArtifacts = [:]
        researchStateLoaded = false
        lastAutomaticStartedAt = nil
        lastAutomaticCheckAt = nil
        lastCheapCheckAt = nil
        lastAutomaticDecision = nil
        triageCache = [:]
        aiSummaryManifest = nil
        await cacheManager.clear()
        await translationCacheStore.clear()
        for language in AppLanguage.allCases { await summaryCache(for: language).clear() }
        await trendHistoryStore.clear()
    }

    func refreshRSSSource(url: String, name: String, settings: AppSettings) async {
        let source = NewsSource.rss(name: name, url: url)
        await refreshRSSSource(source, settings: settings)
    }

    func refreshRSSSource(_ source: NewsSource, settings: AppSettings) async {
        guard !source.isBuiltIn, cacheClearDepth == 0 else { return }
        guard sourceStates[source.id] != .loading else { return }
        let token = cacheWriteGeneration.capture()

        markSources([source], as: .loading)
        let outcome = await fetchRSS(source: source, useCacheFallback: false, settings: settings, token: token)
        guard isCurrentCacheWork(token), let outcome else { return }
        applyRSSBatch([outcome])
        await updateInterestCandidates(settings: settings, token: token)
    }

    /// Health rows for the settings surface. Derived from the same source
    /// state the feed renders, so the two can never disagree.
    func rssHealthSnapshot(settings: AppSettings) -> [RSSSourceHealth] {
        settings.activeSources.filter { !$0.isBuiltIn }.map { source in
            let state = sourceStates[source.id]
            let status: RSSSourceHealth.Status
            let detail: String?
            switch state {
            case .loaded:
                status = .loaded
                detail = nil
            case .loading:
                status = .loading
                detail = nil
            case .failed(let message):
                status = .failed
                detail = message
            case .idle, .none:
                status = .idle
                detail = nil
            }
            return RSSSourceHealth(
                id: source.id,
                name: source.displayName,
                status: status,
                detail: detail,
                lastAttempt: lastSourceAttempt[source.id] ?? lastSourceRefresh[source.id]
            )
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
