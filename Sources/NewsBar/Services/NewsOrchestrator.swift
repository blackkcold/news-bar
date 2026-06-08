import Foundation

enum AISummaryState: Equatable {
    case idle
    case noKey
    case fetching
    case summarizing
    case done(String)
    case truncated(String)
    case error(String)
}

enum SourceLoadState: Equatable {
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

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的 URL"
        case .requestFailed: return "网络请求失败"
        case .parseFailed: return "数据解析失败"
        case .apiKeyInvalid: return "API Key 无效"
        case .rateLimited: return "刷新频率限制"
        }
    }
}

@MainActor
final class NewsOrchestrator: ObservableObject {

    @Published var weiboItems: [NewsItem] = []
    @Published var bilibiliItems: [NewsItem] = []
    @Published var rssItemsMap: [String: [NewsItem]] = [:]
    @Published var aiSummaryState = AISummaryState.idle
    @Published var isRefreshing = false
    @Published var sourceStates: [String: SourceLoadState] = [:]
    @Published var manualRefreshWarning: String?

    private let cacheManager = CacheManager()
    private let rateLimiter = RateLimiter()
    private var lastBatchHash: String?

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
        let apiKey = settings.cachedAPIKey ?? ""
        if settings.aiSummaryEnabled {
            aiSummaryState = apiKey.isEmpty ? .noKey : .fetching
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.fetchWeibo(useCacheFallback: !isManual) }
            group.addTask { await self.fetchBilibili(useCacheFallback: !isManual) }
            for source in settings.activeSources where !source.isBuiltIn {
                group.addTask { await self.fetchRSS(source: source, useCacheFallback: !isManual) }
            }
        }

        if isManual {
            await rateLimiter.recordManualRefresh()
            manualRefreshWarning = await rateLimiter.manualRefreshWarning()
        }

        await handleAISummary(
            settings: settings,
            apiKey: apiKey,
            previousState: previousSummaryState,
            skipHashDedup: isManual
        )
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

    private func fetchRSS(source: NewsSource, useCacheFallback: Bool) async {
        if let items = await fetchAndCache(
            for: source,
            fetcher: {
                try await RSSService.fetch(url: source.id, sourceName: source.displayName)
            }
        ) {
            rssItemsMap[source.id] = items
        } else if useCacheFallback, rssItemsMap[source.id, default: []].isEmpty,
                  let cached = await cacheManager.load(for: source) {
            rssItemsMap[source.id] = cached.items
        }
    }

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

        let newHash = CacheEntry.contentIdentifier(for: allItems)
        let shouldGenerate = skipHashDedup
            || newHash != lastBatchHash
            || shouldRecoverAISummary(from: previousState)

        if shouldGenerate {
            let requestCount = await generateSummary(
                items: allItems,
                maxWords: settings.aiMaxWords,
                model: settings.aiModel,
                apiKey: apiKey,
                provider: settings.currentProvider
            )
            if requestCount > 0 {
                settings.recordAIRequests(requestCount)
                lastBatchHash = newHash
            }
        } else {
            aiSummaryState = previousState
        }
    }

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

    @discardableResult
    private func generateSummary(items: [NewsItem], maxWords: Int, model: String, apiKey: String, provider: AIProvider) async -> Int {
        guard !apiKey.isEmpty else {
            aiSummaryState = .noKey
            return 0
        }
        aiSummaryState = .summarizing
        do {
            let result = try await AISummaryService.summarize(
                items: items, maxWords: maxWords, provider: provider,
                model: model, apiKey: apiKey
            )
            if result.isTruncated {
                aiSummaryState = .truncated(result.summary)
            } else {
                aiSummaryState = .done(result.summary)
            }
            return result.requestCount
        } catch {
            if case NewsBarError.apiKeyInvalid = error {
                aiSummaryState = .error("API Key 无效")
            } else {
                aiSummaryState = .error("AI 总结生成失败")
            }
            return 0
        }
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
        sourceStates = [:]
        lastBatchHash = nil
    }

    func regenerateAISummary(settings: AppSettings) async {
        let allItems = allActiveItems(settings: settings)
        guard !allItems.isEmpty else { return }
        guard let apiKey = settings.cachedAPIKey, !apiKey.isEmpty else {
            aiSummaryState = .noKey
            return
        }
        let requestCount = await generateSummary(
            items: allItems, maxWords: settings.aiMaxWords,
            model: settings.aiModel, apiKey: apiKey,
            provider: settings.currentProvider
        )
        settings.recordAIRequests(requestCount)
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
