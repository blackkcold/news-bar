import XCTest
@testable import NewsBar

private final class PageCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class DirectHTMLReaderTests: XCTestCase {
    private func http(
        _ status: Int,
        headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://www.reuters.com/story")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    private func reader(
        transport: @escaping DirectHTMLReader.Transport,
        resolver: @escaping DirectHTMLReader.Resolver = { _ in ["93.184.216.34"] }
    ) -> DirectHTMLReader {
        DirectHTMLReader(transport: transport, resolver: resolver, now: { Date() })
    }

    func testExtractsReadableTextAndTitleWithoutScripts() async throws {
        let html = """
        <html><head><title>标题 &amp; 副标题</title><script>alert('should vanish')</script></head>
        <body><p>正文第一段，包含足够多的文字用于通过长度检查。</p><p>正文第二段，继续补充一些可读内容。</p></body></html>
        """
        let reader = reader(
            transport: { _ in (Data(html.utf8), self.http(200, headers: ["Content-Type": "text/html; charset=utf-8"])) }
        )

        let document = try await reader.read(urlString: "https://www.reuters.com/story")

        XCTAssertEqual(document.source, .direct)
        XCTAssertEqual(document.title, "标题 & 副标题")
        XCTAssertTrue(document.text.contains("正文第一段"))
        XCTAssertFalse(document.text.contains("should vanish"))
    }

    func testRejectsRedirectToPrivateAddress() async {
        let reader = reader(
            transport: { _ in
                (Data(), self.http(302, headers: ["Location": "https://192.168.1.1/secret"]))
            }
        )
        do {
            _ = try await reader.read(urlString: "https://www.reuters.com/story")
            XCTFail("expected blocked redirect")
        } catch let error as PageReadError {
            guard case .blocked = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRejectsRedirectLoop() async {
        let reader = reader(
            transport: { _ in
                (Data(), self.http(302, headers: ["Location": "https://www.reuters.com/next"]))
            }
        )
        do {
            _ = try await reader.read(urlString: "https://www.reuters.com/story")
            XCTFail("expected redirect limit")
        } catch let error as PageReadError {
            XCTAssertEqual(error, .redirectLimit)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRejectsOversizedDeclaredBody() async {
        let reader = reader(
            transport: { _ in
                (
                    Data("<html></html>".utf8),
                    self.http(200, headers: [
                        "Content-Type": "text/html",
                        "Content-Length": String(DirectHTMLReader.maxResponseBytes + 1),
                    ])
                )
            }
        )
        do {
            _ = try await reader.read(urlString: "https://www.reuters.com/story")
            XCTFail("expected too large")
        } catch let error as PageReadError {
            XCTAssertEqual(error, .tooLarge)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRejectsUnsupportedContentType() async {
        let reader = reader(
            transport: { _ in (Data("{}".utf8), self.http(200, headers: ["Content-Type": "application/json"])) }
        )
        do {
            _ = try await reader.read(urlString: "https://www.reuters.com/story")
            XCTFail("expected content type rejection")
        } catch let error as PageReadError {
            XCTAssertEqual(error, .unsupportedContentType("application/json"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRejectsHostResolvingToPrivateAddress() async {
        let reader = reader(
            transport: { _ in (Data(), self.http(200, headers: ["Content-Type": "text/html"])) },
            resolver: { _ in ["10.0.0.5"] }
        )
        do {
            _ = try await reader.read(urlString: "https://www.reuters.com/story")
            XCTFail("expected blocked DNS")
        } catch let error as PageReadError {
            guard case .blocked = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRejectsEmptyContent() async {
        let reader = reader(
            transport: { _ in
                (Data("<html><body><script>var x = 1</script></body></html>".utf8),
                 self.http(200, headers: ["Content-Type": "text/html"]))
            }
        )
        do {
            _ = try await reader.read(urlString: "https://www.reuters.com/story")
            XCTFail("expected empty content")
        } catch let error as PageReadError {
            XCTAssertEqual(error, .emptyContent)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

final class PageReaderTests: XCTestCase {
    private func hit(
        url: String = "https://www.reuters.com/story",
        inline: String? = nil
    ) -> SearchHit {
        SearchHit(
            url: url,
            title: "Title",
            snippet: "snippet",
            publishedAt: nil,
            inlineContent: inline,
            provider: .tavily,
            providerRank: 1
        )
    }

    private func failingDirect() -> DirectHTMLReader {
        DirectHTMLReader(
            transport: { _ in throw PageReadError.http(500) },
            resolver: { _ in ["93.184.216.34"] },
            now: { Date() }
        )
    }

    func testInlineContentWinsWithoutScraping() async throws {
        let scrapeCalls = PageCallCounter()
        let directCalls = PageCallCounter()
        let reader = PageReader(
            cache: ResearchCacheStore(directoryURL: try researchTestDirectory()),
            scrape: { _, _ in
                scrapeCalls.increment()
                return String(repeating: "抓取正文", count: 100)
            },
            direct: DirectHTMLReader(
                transport: { _ in directCalls.increment(); throw PageReadError.http(500) },
                resolver: { _ in ["93.184.216.34"] },
                now: { Date() }
            )
        )

        let readResult = await reader.read(
            hit(inline: String(repeating: "内联正文内容", count: 100)),
            apiKey: ""
        )
        let document = try XCTUnwrap(readResult)

        XCTAssertEqual(document.source, .inline)
        XCTAssertEqual(scrapeCalls.count, 0)
        XCTAssertEqual(directCalls.count, 0)
        XCTAssertLessThanOrEqual(document.text.count, DepthProfile.maxPageCharacters)
    }

    func testShortInlineFallsThroughToScrape() async throws {
        let reader = PageReader(
            cache: ResearchCacheStore(directoryURL: try researchTestDirectory()),
            scrape: { _, _ in String(repeating: "抓取正文", count: 100) },
            direct: failingDirect()
        )

        let shortInlineResult = await reader.read(hit(inline: "太短"), apiKey: "")
        let document = try XCTUnwrap(shortInlineResult)
        XCTAssertEqual(document.source, .firecrawl)
    }

    func testFetchedPageIsCachedForNextRead() async throws {
        let directory = try researchTestDirectory()
        let cache = ResearchCacheStore(directoryURL: directory)
        let firstScrapeCalls = PageCallCounter()
        let first = PageReader(
            cache: cache,
            scrape: { _, _ in
                firstScrapeCalls.increment()
                return String(repeating: "抓取正文", count: 100)
            },
            direct: failingDirect()
        )

        let firstResult = await first.read(hit(), apiKey: "")
        let firstDocument = try XCTUnwrap(firstResult)
        XCTAssertEqual(firstDocument.source, .firecrawl)
        XCTAssertEqual(firstScrapeCalls.count, 1)

        let secondScrapeCalls = PageCallCounter()
        let second = PageReader(
            cache: cache,
            scrape: { _, _ in
                secondScrapeCalls.increment()
                return String(repeating: "不应调用", count: 100)
            },
            direct: failingDirect()
        )
        let cachedResult = await second.read(hit(), apiKey: "")
        let cached = try XCTUnwrap(cachedResult)

        XCTAssertEqual(cached.source, .firecrawl)
        XCTAssertEqual(cached.text, firstDocument.text)
        XCTAssertEqual(secondScrapeCalls.count, 0)
    }

    func testFallsBackToDirectReaderWhenScrapeFails() async throws {
        let html = "<html><head><title>Direct</title></head><body><p>直连抓取到的正文，内容足够长以通过检查。这里再补充一段文字，确保可读正文超过四十个字符的限制，从而能够被直接读取器接受。</p></body></html>"
        let reader = PageReader(
            cache: ResearchCacheStore(directoryURL: try researchTestDirectory()),
            scrape: { _, _ in throw NewsBarError.requestFailed },
            direct: DirectHTMLReader(
                transport: { _ in
                    (
                        Data(html.utf8),
                        HTTPURLResponse(
                            url: URL(string: "https://www.reuters.com/story")!,
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: ["Content-Type": "text/html"]
                        )!
                    )
                },
                resolver: { _ in ["93.184.216.34"] },
                now: { Date() }
            )
        )

        let directResult = await reader.read(hit(), apiKey: "")
        let document = try XCTUnwrap(directResult)
        XCTAssertEqual(document.source, .direct)
        XCTAssertTrue(document.text.contains("直连抓取到的正文"))
    }

    func testReturnsNilWhenAllReadersFail() async throws {
        let reader = PageReader(
            cache: ResearchCacheStore(directoryURL: try researchTestDirectory()),
            scrape: { _, _ in throw NewsBarError.requestFailed },
            direct: failingDirect()
        )
        let document = await reader.read(hit(), apiKey: "")
        XCTAssertNil(document)
    }
}

final class WebScrapeServiceTests: XCTestCase {
    private func http(
        _ status: Int,
        headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.firecrawl.dev/v2/scrape")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    func testRejectsNonPublicTarget() async {
        do {
            _ = try await WebScrapeService.scrape(
                urlString: "http://www.reuters.com/story",
                apiKey: "",
                transport: { _ in (Data(), self.http(200)) }
            )
            XCTFail("expected invalid URL")
        } catch NewsBarError.invalidURL {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testReturnsMarkdown() async throws {
        let payload = "{\"data\":{\"markdown\":\"# hello\"}}"
        let markdown = try await WebScrapeService.scrape(
            urlString: "https://www.reuters.com/story",
            apiKey: "fc",
            transport: { _ in
                (Data(payload.utf8), self.http(200, headers: ["Content-Type": "application/json"]))
            }
        )
        XCTAssertEqual(markdown, "# hello")
    }

    func testRejectsHTMLResponseAndOversizedBody() async {
        do {
            _ = try await WebScrapeService.scrape(
                urlString: "https://www.reuters.com/story",
                apiKey: "",
                transport: { _ in (Data(), self.http(200, headers: ["Content-Type": "text/html"])) }
            )
            XCTFail("expected request failure")
        } catch NewsBarError.requestFailed {
        } catch {
            XCTFail("unexpected error \(error)")
        }

        do {
            _ = try await WebScrapeService.scrape(
                urlString: "https://www.reuters.com/story",
                apiKey: "",
                transport: { _ in
                    (Data(), self.http(200, headers: [
                        "Content-Type": "application/json",
                        "Content-Length": String(WebScrapeService.maxResponseBytes + 1),
                    ]))
                }
            )
            XCTFail("expected size rejection")
        } catch NewsBarError.requestFailed {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
