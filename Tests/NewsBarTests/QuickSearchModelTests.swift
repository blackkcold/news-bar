import XCTest
@testable import NewsBar

private actor QuickSearchTestProvider: SearchProvider {
    enum Response: Sendable {
        case hits([SearchHit])
        case failure(SearchProviderError)
    }

    nonisolated let id: SearchProviderID = .tavily
    private let response: Response

    init(response: Response) {
        self.response = response
    }

    func search(_ query: SearchQuery, key: String) async throws -> [SearchHit] {
        switch response {
        case .hits(let hits): return hits
        case .failure(let error): throw error
        }
    }
}

private actor DelayedQuickSearchProvider: SearchProvider {
    nonisolated let id: SearchProviderID = .tavily
    private let hit: SearchHit
    private var requests = 0

    init(hit: SearchHit) {
        self.hit = hit
    }

    func search(_ query: SearchQuery, key: String) async throws -> [SearchHit] {
        requests += 1
        try await Task.sleep(for: .milliseconds(250))
        return [hit]
    }

    func requestCount() -> Int { requests }
}

@MainActor
final class QuickSearchModelTests: XCTestCase {
    func testLocalSearchMatchesNewsReaderHistoryAndArchiveFields() {
        let model = QuickSearchModel()
        let news = NewsItem(
            title: "Latest news",
            url: "https://news.example/needle-story",
            source: .rss(name: "Example feed", url: "https://feed.example/rss")
        )
        let history = historyEntry(title: "History NEEDLE", url: "https://history.example/visited")
        let archives = [
            archiveEntry(query: "Question Needle", pageTitle: "Unmatched", summary: "Unmatched"),
            archiveEntry(query: "Unmatched", pageTitle: "Page Needle", summary: "Unmatched"),
            archiveEntry(query: "Unmatched", pageTitle: "Unmatched", summary: "Answer Needle"),
        ]

        model.searchLocal(
            query: "nEeDlE",
            newsItems: [news],
            readingHistory: [history],
            archiveEntries: archives
        )

        let newsResults = model.localResults.compactMap { result -> NewsItem? in
            guard case .news(let item) = result else { return nil }
            return item
        }
        let historyResults = model.localResults.compactMap { result -> ReaderHistoryEntry? in
            guard case .readerHistory(let entry) = result else { return nil }
            return entry
        }
        let archiveResults = model.localResults.compactMap { result -> AISearchArchiveEntry? in
            guard case .archive(let entry) = result else { return nil }
            return entry
        }

        XCTAssertEqual(newsResults.map(\.id), [news.id])
        XCTAssertEqual(historyResults.map(\.id), [history.id])
        XCTAssertEqual(Set(archiveResults.map(\.id)), Set(archives.map(\.id)))
    }

    func testLocalSearchIsCaseInsensitiveAndBounded() {
        let model = QuickSearchModel()
        let news = (0..<35).map { index in
            NewsItem(
                title: "News item \(index)",
                url: "https://news.example/needle-\(index)",
                source: .weibo
            )
        }
        let history = (0..<35).map { index in
            historyEntry(title: "Needle history \(index)", url: "https://history.example/\(index)")
        }
        let archives = (0..<35).map { index in
            archiveEntry(
                query: "Needle question \(index)",
                pageTitle: "Shared page",
                summary: "Answer \(index)",
                pageURL: "https://archive.example/shared"
            )
        }

        model.searchLocal(
            query: "nEeDlE",
            newsItems: news,
            readingHistory: history,
            archiveEntries: archives
        )

        XCTAssertEqual(model.localResults.filter { if case .news = $0 { true } else { false } }.count, 30)
        XCTAssertEqual(model.localResults.filter { if case .readerHistory = $0 { true } else { false } }.count, 30)
        XCTAssertEqual(model.localResults.filter { if case .archive = $0 { true } else { false } }.count, 30)
        let firstIDs = model.localResults.map(\.id)
        model.searchLocal(query: "NEEDLE", newsItems: news, readingHistory: history, archiveEntries: archives)
        XCTAssertEqual(model.localResults.map(\.id), firstIDs)
    }

    func testLocalSearchDeduplicatesCanonicalURLsButKeepsArchiveActions() {
        let model = QuickSearchModel()
        let news = NewsItem(
            title: "Needle news",
            url: "https://same.example/article?utm_source=feed#news",
            source: .weibo
        )
        let history = historyEntry(
            title: "Needle history",
            url: "https://same.example/article#history"
        )
        let firstArchive = archiveEntry(
            query: "Needle duplicate question",
            pageTitle: "Same page",
            summary: "Saved answer",
            pageURL: "https://same.example/article"
        )
        let secondArchive = archiveEntry(
            query: "Needle duplicate question",
            pageTitle: "Same page",
            summary: "Saved answer",
            pageURL: "https://same.example/article"
        )

        model.searchLocal(
            query: "needle",
            newsItems: [news],
            readingHistory: [history],
            archiveEntries: [firstArchive, secondArchive]
        )

        XCTAssertEqual(model.localResults.filter { if case .news = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(model.localResults.filter { if case .readerHistory = $0 { true } else { false } }.count, 0)
        XCTAssertEqual(model.localResults.filter { if case .archive = $0 { true } else { false } }.count, 2)
    }

    func testWebFailureIsRetryableAndDoesNotEraseLocalResults() async throws {
        let model = QuickSearchModel()
        let news = NewsItem(title: "Local result", url: "https://news.example/local", source: .weibo)
        model.searchLocal(query: "local", newsItems: [news], readingHistory: [], archiveEntries: [])
        let originalLocalIDs = model.localResults.map(\.id)

        let failingGateway = ManualSearchGateway(router: SearchRouter(
            providers: [QuickSearchTestProvider(response: .failure(.transport("offline")))],
            cache: ResearchCacheStore(directoryURL: try researchTestDirectory())
        ))
        await model.searchWeb(
            query: "retryable query",
            language: .en,
            enabledProviders: [.tavily],
            keys: [:],
            gateway: failingGateway
        )

        XCTAssertFalse(model.isSearching)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.localResults.map(\.id), originalLocalIDs)

        let hit = SearchHit(
            url: "https://search.example/retry",
            title: "Recovered result",
            snippet: "Online result",
            provider: .tavily,
            providerRank: 1
        )
        let succeedingGateway = ManualSearchGateway(router: SearchRouter(
            providers: [QuickSearchTestProvider(response: .hits([hit]))],
            cache: ResearchCacheStore(directoryURL: try researchTestDirectory())
        ))
        await model.searchWeb(
            query: "retryable query",
            language: .en,
            enabledProviders: [.tavily],
            keys: [:],
            gateway: succeedingGateway
        )

        XCTAssertFalse(model.isSearching)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.webHits, [hit])
        XCTAssertEqual(model.localResults.map(\.id), originalLocalIDs)
    }

    func testConcurrentWebSubmissionsDispatchOnlyOnce() async throws {
        let hit = SearchHit(
            url: "https://search.example/one-result",
            title: "One result",
            snippet: "Search result",
            provider: .tavily,
            providerRank: 1
        )
        let provider = DelayedQuickSearchProvider(hit: hit)
        let gateway = ManualSearchGateway(router: SearchRouter(
            providers: [provider],
            cache: ResearchCacheStore(directoryURL: try researchTestDirectory())
        ))
        let model = QuickSearchModel()
        let first = Task {
            await model.searchWeb(
                query: "same query",
                language: .en,
                enabledProviders: [.tavily],
                keys: [:],
                gateway: gateway
            )
        }

        let deadline = Date().addingTimeInterval(2)
        while !model.isSearching && Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(model.isSearching)

        let second = Task {
            await model.searchWeb(
                query: "same query",
                language: .en,
                enabledProviders: [.tavily],
                keys: [:],
                gateway: gateway
            )
        }
        await first.value
        await second.value

        let requestCount = await provider.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(model.webHits, [hit])
        XCTAssertFalse(model.isSearching)
    }
}

private func historyEntry(title: String, url: String) -> ReaderHistoryEntry {
    ReaderHistoryEntry(
        id: UUID(),
        url: url,
        canonicalURL: ContentIdentity.canonicalURL(url),
        title: title,
        host: URL(string: url)?.host ?? "",
        firstOpenedAt: Date(),
        lastOpenedAt: Date(),
        visitCount: 1
    )
}

private func archiveEntry(
    query: String,
    pageTitle: String?,
    summary: String,
    pageURL: String? = "https://archive.example/article"
) -> AISearchArchiveEntry {
    AISearchArchiveEntry(
        query: query,
        scope: .web,
        origin: .readerSearch,
        pageTitle: pageTitle,
        pageURL: pageURL,
        providerName: "Test provider",
        answer: AnswerDocument(
            kind: .term,
            oneLine: summary,
            blocks: [],
            sources: [],
            mode: .web,
            model: "test-model",
            thinking: .medium,
            generatedAt: Date(),
            question: nil
        )
    )
}
