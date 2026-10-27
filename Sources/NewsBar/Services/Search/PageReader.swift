import Foundation

/// Reads one search hit into a document. Order is fixed by the design:
/// Tavily inline content → page cache → Firecrawl → direct HTTPS → give up.
/// The pipeline turns a `nil` into a snippet-only document and marks the report
/// partial; a single unreadable page never aborts the whole research task.
struct PageReader: Sendable {
    typealias Scrape = @Sendable (_ url: String, _ apiKey: String) async throws -> String

    private struct CachedPage: Codable {
        let url: String
        let title: String
        let text: String
        let publishedAt: Date?
        let fetchedAt: Date
        let source: PageContentSource
    }

    static let minInlineCharacters = 400
    static let minScrapedCharacters = 200

    let cache: ResearchCacheStore
    let scrape: Scrape
    let direct: DirectHTMLReader
    /// False when Firecrawl is disabled or has no API key. The reader then goes
    /// straight to the local direct reader and never contacts the third party.
    let isScrapeEnabled: Bool
    let now: @Sendable () -> Date

    init(
        cache: ResearchCacheStore = ResearchCacheStore(),
        scrape: @escaping Scrape = { url, apiKey in
            try await WebScrapeService.scrape(urlString: url, apiKey: apiKey)
        },
        direct: DirectHTMLReader = DirectHTMLReader(),
        isScrapeEnabled: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cache = cache
        self.scrape = scrape
        self.direct = direct
        self.isScrapeEnabled = isScrapeEnabled
        self.now = now
    }

    func read(_ hit: SearchHit, apiKey: String) async -> ResearchDocument? {
        if let inline = hit.inlineContent?.trimmingCharacters(in: .whitespacesAndNewlines),
           inline.count >= Self.minInlineCharacters {
            let document = ResearchDocument(
                url: hit.url,
                title: hit.title,
                text: String(inline.prefix(DepthProfile.maxPageCharacters)),
                publishedAt: hit.publishedAt,
                fetchedAt: now(),
                source: .inline
            )
            await store(document)
            return document
        }

        if let cached = await load(canonicalURL: hit.canonicalURL) {
            return cached
        }

        if isScrapeEnabled {
            do {
                let text = try await scrape(hit.url, apiKey)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count >= Self.minScrapedCharacters {
                    let document = ResearchDocument(
                        url: hit.url,
                        title: hit.title,
                        text: String(text.prefix(DepthProfile.maxPageCharacters)),
                        publishedAt: hit.publishedAt,
                        fetchedAt: now(),
                        source: .firecrawl
                    )
                    await store(document)
                    return document
                }
            } catch is CancellationError {
                return nil
            } catch {
                // Firecrawl is a paid third party; a failure is expected when
                // its quota is exhausted, so fall through to the direct reader.
            }
        }

        guard let document = try? await direct.read(urlString: hit.url) else {
            return nil
        }
        await store(document)
        return document
    }

    // MARK: - Cache

    private func load(canonicalURL: String) async -> ResearchDocument? {
        guard let data = await cache.load(kind: .pages, key: canonicalURL),
              let page = try? JSONDecoder().decode(CachedPage.self, from: data) else {
            return nil
        }
        return ResearchDocument(
            url: page.url,
            title: page.title,
            text: page.text,
            publishedAt: page.publishedAt,
            fetchedAt: page.fetchedAt,
            source: page.source
        )
    }

    private func store(_ document: ResearchDocument) async {
        let page = CachedPage(
            url: document.url,
            title: document.title,
            text: document.text,
            publishedAt: document.publishedAt,
            fetchedAt: document.fetchedAt,
            source: document.source
        )
        guard let data = try? JSONEncoder().encode(page) else { return }
        await cache.store(data, kind: .pages, key: document.canonicalURL, now: document.fetchedAt)
    }
}
