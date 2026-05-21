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

final class NewsOrchestrator: ObservableObject {

    @Published var weiboItems: [NewsItem] = []
    @Published var bilibiliItems: [NewsItem] = []
    @Published var rssItemsMap: [String: [NewsItem]] = [:]
    @Published var aiSummaryState = AISummaryState.idle
    @Published var isRefreshing = false
    @Published var errorMessage: String?
    @Published var manualRefreshWarning: String?

    private let cacheManager = CacheManager()
    private let rateLimiter = RateLimiter()
    private var lastBatchHash: String?

    func loadCached() async {
        if let cached = await cacheManager.load(for: .weibo) {
            weiboItems = cached.isStale ? [] : cached.items
        }
        if let cached = await cacheManager.load(for: .bilibili) {
            bilibiliItems = cached.isStale ? [] : cached.items
        }

        let settings = AppSettings()
        for source in settings.activeSources where !source.isBuiltIn {
            if let entry = await cacheManager.load(for: source) {
                rssItemsMap[source.id] = entry.isStale ? [] : entry.items
            }
        }
    }

    func refreshIfNeeded(settings: AppSettings) async {
        let previousSummaryState = aiSummaryState
        let apiKey = settings.cachedAPIKey ?? ""
        if settings.aiSummaryEnabled {
            aiSummaryState = apiKey.isEmpty ? .noKey : .fetching
        }

        let newWeibo = await fetchAndCache(
            for: .weibo,
            fetcher: { try await WeiboHotService.fetch() }
        )
        if let items = newWeibo {
            weiboItems = items
        } else if weiboItems.isEmpty {
            if let cached = await cacheManager.load(for: .weibo) {
                weiboItems = cached.items
            }
        }

        let newBilibili = await fetchAndCache(
            for: .bilibili,
            fetcher: { try await BilibiliHotService.fetch() }
        )
        if let items = newBilibili {
            bilibiliItems = items
        } else if bilibiliItems.isEmpty {
            if let cached = await cacheManager.load(for: .bilibili) {
                bilibiliItems = cached.items
            }
        }

        for source in settings.activeSources where !source.isBuiltIn {
            let newRSS = await fetchAndCache(
                for: source,
                fetcher: {
                    try await RSSService.fetch(
                        url: source.id, sourceName: source.displayName
                    )
                }
            )
            if let items = newRSS {
                rssItemsMap[source.id] = items
            }
        }

        guard settings.aiSummaryEnabled else { return }

        let allNewItems = allActiveItems(settings: settings)
        guard !allNewItems.isEmpty else {
            if !apiKey.isEmpty {
                aiSummaryState = previousSummaryState
            }
            return
        }

        guard !apiKey.isEmpty else {
            aiSummaryState = .noKey
            return
        }

        let newHash = CacheEntry.hashForItems(allNewItems)
        if newHash != lastBatchHash || shouldRecoverAISummary(from: previousSummaryState) {
            let didGenerate = await generateSummary(
                items: allNewItems,
                maxWords: settings.aiMaxWords,
                model: settings.aiModel,
                apiKey: apiKey
            )
            if didGenerate {
                lastBatchHash = newHash
            }
        } else {
            aiSummaryState = previousSummaryState
        }
    }

    func manualRefresh(settings: AppSettings) async {
        manualRefreshWarning = await rateLimiter.manualRefreshWarning()

        isRefreshing = true
        errorMessage = nil
        let previousSummaryState = aiSummaryState
        let apiKey = settings.cachedAPIKey ?? ""
        if settings.aiSummaryEnabled {
            aiSummaryState = apiKey.isEmpty ? .noKey : .fetching
        }

        if let items = await fetchAndCache(
            for: .weibo,
            fetcher: { try await WeiboHotService.fetch() }
        ) {
            weiboItems = items
        }

        if let items = await fetchAndCache(
            for: .bilibili,
            fetcher: { try await BilibiliHotService.fetch() }
        ) {
            bilibiliItems = items
        }

        for source in settings.activeSources where !source.isBuiltIn {
            if let items = await fetchAndCache(
                for: source,
                fetcher: {
                    try await RSSService.fetch(url: source.id, sourceName: source.displayName)
                }
            ) {
                rssItemsMap[source.id] = items
            }
        }

        await rateLimiter.recordManualRefresh()
        manualRefreshWarning = await rateLimiter.manualRefreshWarning()

        if settings.aiSummaryEnabled {
            let allItems = allActiveItems(settings: settings)
            if allItems.isEmpty {
                if !apiKey.isEmpty {
                    aiSummaryState = previousSummaryState
                }
            } else {
                let newHash = CacheEntry.hashForItems(allItems)
                let didGenerate = await generateSummary(
                    items: allItems,
                    maxWords: settings.aiMaxWords,
                    model: settings.aiModel,
                    apiKey: apiKey
                )
                if didGenerate {
                    lastBatchHash = newHash
                }
            }
        }

        isRefreshing = false
    }

    private func fetchAndCache(
        for source: NewsSource,
        fetcher: () async throws -> [NewsItem]
    ) async -> [NewsItem]? {
        do {
            let items = try await fetcher()
            guard !items.isEmpty else { return nil }

            let hasNew = await cacheManager.hasNewContent(for: source, newItems: items)
            if hasNew {
                let entry = CacheEntry(
                    items: items,
                    timestamp: Date(),
                    contentHash: CacheEntry.hashForItems(items)
                )
                await cacheManager.save(entry, for: source)
            }
            return items
        } catch {
            if source.isBuiltIn {
                errorMessage = "\(source.displayName) 加载失败"
            }
            return nil
        }
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
    private func generateSummary(items: [NewsItem], maxWords: Int, model: String, apiKey: String) async -> Bool {
        guard !apiKey.isEmpty else {
            aiSummaryState = .noKey
            return false
        }
        aiSummaryState = .summarizing
        do {
            let result = try await DeepSeekService.summarize(
                items: items, maxWords: maxWords, model: model, apiKey: apiKey
            )
            if result.isTruncated {
                aiSummaryState = .truncated(result.summary)
            } else {
                aiSummaryState = .done(result.summary)
            }
            return true
        } catch {
            if case NewsBarError.apiKeyInvalid = error {
                aiSummaryState = .error("API Key 无效")
            } else {
                aiSummaryState = .error("AI 总结生成失败")
            }
            return false
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
        lastBatchHash = nil
    }

    func regenerateAISummary(settings: AppSettings) async {
        let allItems = allActiveItems(settings: settings)
        guard !allItems.isEmpty else { return }
        guard let apiKey = settings.cachedAPIKey, !apiKey.isEmpty else {
            aiSummaryState = .noKey
            return
        }
        await generateSummary(
            items: allItems, maxWords: settings.aiMaxWords,
            model: settings.aiModel, apiKey: apiKey
        )
    }

    func refreshRSSSource(url: String, name: String) async {
        let source = NewsSource.rss(name: name, url: url)
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
