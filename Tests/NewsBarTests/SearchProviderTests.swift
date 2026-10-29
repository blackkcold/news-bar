import XCTest
@testable import NewsBar

final class SearchProviderTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [URLRequest] = []

        func append(_ request: URLRequest) {
            lock.lock()
            values.append(request)
            lock.unlock()
        }

        var last: URLRequest? {
            lock.lock()
            defer { lock.unlock() }
            return values.last
        }
    }

    private func http(_ status: Int, url: String = "https://api.example.com") -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }

    private func query(_ text: String = "某事件 时间线", recency: SearchRecency = .week) -> SearchQuery {
        SearchQuery(text: text, recency: recency, maxResults: 5)
    }

    // MARK: - Tavily

    func testTavilyRequestAndResponse() async throws {
        let recorder = Recorder()
        let payload = """
        {"results":[
          {"title":"报道一","url":"https://www.reuters.com/a","content":"摘要一","raw_content":"\(String(repeating: "正文", count: 300))","published_date":"2026-10-01"},
          {"title":"报道二","url":"https://www.bbc.com/b","content":"摘要二","raw_content":"太短"}
        ]}
        """
        let provider = TavilySearchProvider(transport: { request in
            recorder.append(request)
            return (Data(payload.utf8), self.http(200))
        })

        let hits = try await provider.search(query(), key: "tvly-key")

        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].provider, .tavily)
        XCTAssertEqual(hits[0].publishedAt.map { TimelineDateParser.dayKey($0) }, "2026-10-01")
        XCTAssertNotNil(hits[0].inlineContent)
        XCTAssertNil(hits[1].inlineContent)

        let request = try XCTUnwrap(recorder.last)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tvly-key")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["query"] as? String, "某事件 时间线")
        XCTAssertEqual(body["days"] as? Int, 7)
        XCTAssertEqual(body["topic"] as? String, "news")
        XCTAssertEqual(body["include_raw_content"] as? Bool, true)
    }

    func testTavilyAllRecencyOmitsDaysAndUsesGeneralTopic() async throws {
        let recorder = Recorder()
        let provider = TavilySearchProvider(transport: { request in
            recorder.append(request)
            return (Data(#"{"results":[]}"#.utf8), self.http(200))
        })

        _ = try await provider.search(query(recency: .all), key: "k")

        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: recorder.last!.httpBody!) as? [String: Any])
        XCTAssertNil(body["days"])
        XCTAssertEqual(body["topic"] as? String, "general")
    }

    // MARK: - Firecrawl

    func testFirecrawlKeylessRequestAndResponse() async throws {
        let recorder = Recorder()
        let payload = """
        {"success":true,"data":{"web":[{"url":"https://example.com/a","title":"A","description":"desc"}]}}
        """
        let provider = FirecrawlSearchProvider(transport: { request in
            recorder.append(request)
            return (Data(payload.utf8), self.http(200))
        })

        let hits = try await provider.search(query(recency: .month), key: "")

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].snippet, "desc")
        XCTAssertNil(hits[0].inlineContent)

        let request = try XCTUnwrap(recorder.last)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["tbs"] as? String, "qdr:m")
        XCTAssertEqual(body["limit"] as? Int, 5)
    }

    func testFirecrawlSendsBearerWhenKeyPresent() async throws {
        let recorder = Recorder()
        let provider = FirecrawlSearchProvider(transport: { request in
            recorder.append(request)
            return (Data(#"{"data":{"web":[]}}"#.utf8), self.http(200))
        })

        _ = try await provider.search(query(), key: "fc-key")
        XCTAssertEqual(recorder.last?.value(forHTTPHeaderField: "Authorization"), "Bearer fc-key")
    }

    // MARK: - Brave

    func testBraveRequestAndPageAge() async throws {
        let recorder = Recorder()
        let payload = """
        {"web":{"results":[{"title":"Brave A","url":"https://www.reuters.com/a","description":"<b>desc</b>","page_age":"2026-10-02T08:00:00"}]}}
        """
        let provider = BraveSearchProvider(transport: { request in
            recorder.append(request)
            return (Data(payload.utf8), self.http(200))
        })

        let hits = try await provider.search(query(recency: .day), key: "brave-key")

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].snippet, "desc")
        XCTAssertEqual(hits[0].publishedAt.map { TimelineDateParser.dayKey($0) }, "2026-10-02")

        let request = try XCTUnwrap(recorder.last)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Subscription-Token"), "brave-key")
        let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["q"], "某事件 时间线")
        XCTAssertEqual(items["freshness"], "pd")
        XCTAssertEqual(items["count"], "5")
    }

    func testBraveQuarterWidensToMonthBucket() async throws {
        let recorder = Recorder()
        let provider = BraveSearchProvider(transport: { request in
            recorder.append(request)
            return (Data(#"{"web":{"results":[]}}"#.utf8), self.http(200))
        })

        _ = try await provider.search(query(recency: .quarter), key: "k")
        let components = try XCTUnwrap(URLComponents(url: recorder.last!.url!, resolvingAgainstBaseURL: false))
        XCTAssertTrue((components.queryItems ?? []).contains { $0.name == "freshness" && $0.value == "pm" })
    }

    // MARK: - Error mapping

    func testHTTPErrorMapping() async {
        for (status, expected) in [
            (401, SearchProviderError.unauthorized),
            (402, .quotaExhausted),
            (429, .rateLimited(retryAfter: nil)),
            (500, .server(500)),
        ] {
            let provider = TavilySearchProvider(transport: { _ in (Data(), self.http(status)) })
            do {
                _ = try await provider.search(query(), key: "k")
                XCTFail("expected \(expected)")
            } catch let error as SearchProviderError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testTransportTimeoutMapping() async {
        let provider = BraveSearchProvider(transport: { _ in throw URLError(.timedOut) })
        do {
            _ = try await provider.search(query(), key: "k")
            XCTFail("expected timeout")
        } catch let error as SearchProviderError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
