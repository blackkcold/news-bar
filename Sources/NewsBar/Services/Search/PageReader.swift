import Foundation

/// Why a page could not be turned into evidence. The pipeline keeps the reason
/// instead of collapsing every failure into "unreadable", so the UI can say
/// whether the network, the provider, or the page itself was at fault.
enum PageReadFailure: String, Sendable, Equatable {
    case timeout
    case transport
    case blocked
    case empty
    case unknown
}

enum PageReadOutcome: Sendable, Equatable {
    case document(ResearchDocument)
    case tooShort(Int)
    case failed(PageReadFailure)
}

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

    func read(_ hit: SearchHit, apiKey: String) async throws -> ResearchDocument? {
        guard case .document(let document) = try await readOutcome(hit, apiKey: apiKey) else {
            return nil
        }
        return document
    }

    /// Typed version of `read`. Callers that show retrieval status need to
    /// distinguish "the page was short" from "the network failed"; the old
    /// `nil` erased that difference.
    func readOutcome(_ hit: SearchHit, apiKey: String) async throws -> PageReadOutcome {
        // Cancellation is a first-class outcome: it must never look like an
        // unreadable page, otherwise the pipeline keeps scheduling work after
        // the user closed the panel.
        try Task.checkCancellation()
        let cacheEpoch = await cache.writeEpoch()
        var shortInline: Int?
        if let inline = hit.inlineContent?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if inline.count >= Self.minInlineCharacters {
                let document = ResearchDocument(
                    url: hit.url,
                    title: hit.title,
                    text: String(inline.prefix(DepthProfile.maxPageCharacters)),
                    publishedAt: hit.publishedAt,
                    fetchedAt: now(),
                    source: .inline
                )
                await store(document, epoch: cacheEpoch)
                return .document(document)
            }
            shortInline = inline.count
        }

        if let cached = await load(canonicalURL: hit.canonicalURL) {
            let text = cached.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= Self.minScrapedCharacters else {
                return .tooShort(text.count)
            }
            return .document(cached)
        }

        var shortScraped: Int?
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
                    await store(document, epoch: cacheEpoch)
                    return .document(document)
                }
                shortScraped = text.count
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Firecrawl is a paid third party; a failure is expected when
                // its quota is exhausted, so fall through to the direct reader.
            }
        }

        try Task.checkCancellation()
        let document: ResearchDocument
        do {
            document = try await direct.read(urlString: hit.url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A failed direct read is an unavailable page, not a failed run.
            if let shortInline { return .tooShort(shortInline) }
            if let shortScraped { return .tooShort(shortScraped) }
            return .failed(Self.failure(from: error))
        }
        // Direct reads have their own 40-character floor. The evidence reader
        // applies the 200-character evidence floor; the research pipeline's
        // `read` keeps its historical behaviour and returns the document.
        await store(document, epoch: cacheEpoch)
        return .document(document)
    }

    /// Maps a reader error to the coarse reason the UI shows. The mapping is
    /// deliberately conservative: an unknown error becomes `.unknown`, never a
    /// confident "timeout".
    static func failure(from error: Error) -> PageReadFailure {
        if let pageError = error as? PageReadError {
            switch pageError {
            case .blocked:
                return .blocked
            case .http(let status) where status == 401 || status == 403 || status == 429:
                return .blocked
            case .emptyContent:
                return .empty
            case .dnsFailure, .http, .tooLarge, .unsupportedContentType, .redirectLimit:
                return .transport
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return .timeout
            case NSURLErrorCancelled:
                return .unknown
            default:
                return .transport
            }
        }
        return .unknown
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

    private func store(_ document: ResearchDocument, epoch: Int) async {
        let page = CachedPage(
            url: document.url,
            title: document.title,
            text: document.text,
            publishedAt: document.publishedAt,
            fetchedAt: document.fetchedAt,
            source: document.source
        )
        guard let data = try? JSONEncoder().encode(page) else { return }
        await cache.store(
            data,
            kind: .pages,
            key: document.canonicalURL,
            now: document.fetchedAt,
            epoch: epoch
        )
    }
}
