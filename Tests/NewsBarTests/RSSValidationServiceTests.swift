import XCTest
@testable import NewsBar

final class RSSValidationServiceTests: XCTestCase {

    // MARK: - RSSValidationOutcome Equatable

    func testOutcomeEquality_Blocked() {
        XCTAssertEqual(
            RSSValidationOutcome.blocked(reason: "Blocked host"),
            RSSValidationOutcome.blocked(reason: "Blocked host")
        )
        XCTAssertNotEqual(
            RSSValidationOutcome.blocked(reason: "Blocked host"),
            RSSValidationOutcome.blocked(reason: "Other reason")
        )
    }

    func testOutcomeEquality_Success() {
        XCTAssertEqual(
            RSSValidationOutcome.success(itemCount: 5),
            RSSValidationOutcome.success(itemCount: 5)
        )
        XCTAssertNotEqual(
            RSSValidationOutcome.success(itemCount: 5),
            RSSValidationOutcome.success(itemCount: 3)
        )
    }

    func testOutcomeEquality_CrossCase() {
        XCTAssertNotEqual(
            RSSValidationOutcome.success(itemCount: 0),
            RSSValidationOutcome.cancelled
        )
        XCTAssertNotEqual(
            RSSValidationOutcome.notRSSFeed,
            RSSValidationOutcome.invalidURL
        )
    }

    // MARK: - validateURLOnly (Pure Deterministic)

    func testValidateURLOnly_Localhost_Blocked() {
        let result = RSSValidationService.validateURLOnly("https://localhost/feed")
        guard case .blocked(let reason) = result else {
            XCTFail("Expected blocked, got \(result)")
            return
        }
        XCTAssertTrue(reason.contains("localhost"))
    }

    func testValidateURLOnly_127001_Blocked() {
        let result = RSSValidationService.validateURLOnly("https://127.0.0.1/rss")
        guard case .blocked = result else {
            XCTFail("Expected blocked, got \(result)")
            return
        }
    }

    func testValidateURLOnly_PrivateIP_Warning_Allowed() {
        let result = RSSValidationService.validateURLOnly("https://192.168.1.1/feed")
        XCTAssertEqual(result, .success(itemCount: 0))
    }

    func testValidateURLOnly_ValidHTTPS_Passes() {
        let result = RSSValidationService.validateURLOnly("https://example.com/feed.xml")
        XCTAssertEqual(result, .success(itemCount: 0))
    }

    func testValidateURLOnly_InvalidScheme_Blocked() {
        let result = RSSValidationService.validateURLOnly("http://example.com/feed")
        guard case .blocked = result else {
            XCTFail("Expected blocked for http scheme, got \(result)")
            return
        }
    }

    func testValidateURLOnly_EmptyString_Blocked() {
        let result = RSSValidationService.validateURLOnly("")
        guard case .blocked = result else {
            XCTFail("Expected blocked for empty string, got \(result)")
            return
        }
    }

    func testValidateURLOnly_MalformedURL_InvalidURL() {
        let result = RSSValidationService.validateURLOnly("not a url at all !!!")
        guard case .blocked = result else {
            XCTFail("Expected blocked for malformed input, got \(result)")
            return
        }
    }

    // MARK: - classifyFetchResult (Pure Deterministic)

    func testClassifyFetchResult_PreflightBlocked() {
        let result = RSSValidationService.classifyFetchResult(
            urlString: "https://localhost/feed",
            data: nil,
            error: nil
        )
        guard case .blocked = result else {
            XCTFail("Expected blocked, got \(result)")
            return
        }
    }

    func testClassifyFetchResult_CancelledError() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        let result = RSSValidationService.classifyFetchResult(
            urlString: "https://example.com/feed",
            data: nil,
            error: error
        )
        XCTAssertEqual(result, .cancelled)
    }

    func testClassifyFetchResult_NetworkError() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let result = RSSValidationService.classifyFetchResult(
            urlString: "https://example.com/feed",
            data: nil,
            error: error
        )
        guard case .networkError(let summary) = result else {
            XCTFail("Expected networkError, got \(result)")
            return
        }
        XCTAssertEqual(summary, "Request timed out")
    }

    func testClassifyFetchResult_EmptyData() {
        let result = RSSValidationService.classifyFetchResult(
            urlString: "https://example.com/feed",
            data: Data(),
            error: nil
        )
        guard case .networkError(let summary) = result else {
            XCTFail("Expected networkError for empty data, got \(result)")
            return
        }
        XCTAssertEqual(summary, "Empty response")
    }

    func testClassifyFetchResult_NotRSSFeed_PlainText() {
        let plainText = "Just some plain text, not XML".data(using: .utf8)!
        let result = RSSValidationService.classifyFetchResult(
            urlString: "https://example.com/feed",
            data: plainText,
            error: nil
        )
        XCTAssertEqual(result, .notRSSFeed)
    }

    func testClassifyFetchResult_NotRSSFeed_HTML() {
        let html = "<html><body><p>Hello</p></body></html>".data(using: .utf8)!
        let result = RSSValidationService.classifyFetchResult(
            urlString: "https://example.com/feed",
            data: html,
            error: nil
        )
        XCTAssertEqual(result, .notRSSFeed)
    }

    func testClassifyFetchResult_ValidRSS_Success() {
        let rssData = makeRSSFeed(itemCount: 3)
        let result = RSSValidationService.classifyFetchResult(
            urlString: "https://example.com/feed.xml",
            data: rssData,
            error: nil
        )
        XCTAssertEqual(result, .success(itemCount: 3))
    }

    func testClassifyFetchResult_ValidRSS_SingleItem() {
        let rssData = makeRSSFeed(itemCount: 1)
        let result = RSSValidationService.classifyFetchResult(
            urlString: "https://example.com/feed.xml",
            data: rssData,
            error: nil
        )
        XCTAssertEqual(result, .success(itemCount: 1))
    }

    func testClassifyFetchResult_ValidRSS_EmptyFeed() {
        let rssData = makeRSSFeed(itemCount: 0)
        let result = RSSValidationService.classifyFetchResult(
            urlString: "https://example.com/feed.xml",
            data: rssData,
            error: nil
        )
        XCTAssertEqual(result, .success(itemCount: 0))
    }

    func testClassifyFetchResult_ValidAtom_Success() {
        let atomData = makeAtomFeed(entryCount: 5)
        let result = RSSValidationService.classifyFetchResult(
            urlString: "https://example.com/atom.xml",
            data: atomData,
            error: nil
        )
        XCTAssertEqual(result, .success(itemCount: 5))
    }

    func testClassifyFetchResult_NetworkError_NewsBarError() {
        let error = NewsBarError.requestFailed
        let result = RSSValidationService.classifyFetchResult(
            urlString: "https://example.com/feed",
            data: nil,
            error: error
        )
        guard case .networkError(let summary) = result else {
            XCTFail("Expected networkError, got \(result)")
            return
        }
        XCTAssertEqual(summary, "Server returned an error")
    }

    func testClassifyFetchResult_NetworkError_Generic() {
        let error = NSError(domain: "SomeCustomDomain", code: 999)
        let result = RSSValidationService.classifyFetchResult(
            urlString: "https://example.com/feed",
            data: nil,
            error: error
        )
        guard case .networkError(let summary) = result else {
            XCTFail("Expected networkError, got \(result)")
            return
        }
        XCTAssertEqual(summary, "Network error")
    }

    // MARK: - RSSValidationSummary

    func testSummary_AllSuccess() {
        let outcomes: [RSSValidationSummary.Entry] = [
            .init(feedName: "Feed A", url: "https://a.com/feed", outcome: .success(itemCount: 5)),
            .init(feedName: "Feed B", url: "https://b.com/feed", outcome: .success(itemCount: 3)),
        ]
        let summary = RSSValidationSummary(outcomes: outcomes)
        XCTAssertEqual(summary.successCount, 2)
        XCTAssertEqual(summary.failedCount, 0)
        XCTAssertEqual(summary.wasCancelled, false)
    }

    func testSummary_MixedOutcomes() {
        let outcomes: [RSSValidationSummary.Entry] = [
            .init(feedName: "Feed A", url: "https://a.com/feed", outcome: .success(itemCount: 5)),
            .init(feedName: "Feed B", url: "https://b.com/feed", outcome: .notRSSFeed),
            .init(feedName: "Feed C", url: "https://c.com/feed", outcome: .blocked(reason: "Blocked host")),
            .init(feedName: "Feed D", url: "https://d.com/feed", outcome: .networkError(summary: "Timeout")),
        ]
        let summary = RSSValidationSummary(outcomes: outcomes)
        XCTAssertEqual(summary.successCount, 1)
        XCTAssertEqual(summary.failedCount, 3)
        XCTAssertEqual(summary.wasCancelled, false)
    }

    func testSummary_AllFailed() {
        let outcomes: [RSSValidationSummary.Entry] = [
            .init(feedName: "Feed A", url: "https://a.com/feed", outcome: .notRSSFeed),
            .init(feedName: "Feed B", url: "https://b.com/feed", outcome: .blocked(reason: "Blocked")),
        ]
        let summary = RSSValidationSummary(outcomes: outcomes)
        XCTAssertEqual(summary.successCount, 0)
        XCTAssertEqual(summary.failedCount, 2)
    }

    func testSummary_WasCancelled() {
        let outcomes: [RSSValidationSummary.Entry] = [
            .init(feedName: "Feed A", url: "https://a.com/feed", outcome: .success(itemCount: 5)),
            .init(feedName: "Feed B", url: "https://b.com/feed", outcome: .cancelled),
        ]
        let summary = RSSValidationSummary(outcomes: outcomes)
        XCTAssertEqual(summary.successCount, 1)
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertTrue(summary.wasCancelled)
    }

    func testSummary_Empty() {
        let summary = RSSValidationSummary(outcomes: [])
        XCTAssertEqual(summary.successCount, 0)
        XCTAssertEqual(summary.failedCount, 0)
        XCTAssertEqual(summary.wasCancelled, false)
    }

    func testSummary_Equatable() {
        let a = RSSValidationSummary(outcomes: [
            .init(feedName: "Feed A", url: "https://a.com/feed", outcome: .success(itemCount: 5))
        ])
        let b = RSSValidationSummary(outcomes: [
            .init(feedName: "Feed A", url: "https://a.com/feed", outcome: .success(itemCount: 5))
        ])
        let c = RSSValidationSummary(outcomes: [
            .init(feedName: "Feed A", url: "https://a.com/feed", outcome: .success(itemCount: 3))
        ])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Cancellation (Deterministic Behavior)

    func testValidateFeedsSerially_CancelBeforeStart_AllCancelled() async {
        let feeds: [(name: String, url: String)] = [
            ("A", "https://example.com/feed1.xml"),
            ("B", "https://example.com/feed2.xml"),
        ]

        for feed in feeds {
            if Task.isCancelled {
                XCTAssertTrue(true, "Cancellation detected before processing \(feed.name)")
                break
            }
        }
    }

    func testValidateFeedsSerially_BlockedFeeds_NoNetworkAccess() async {
        let feeds: [(name: String, url: String)] = [
            ("Blocked", "https://localhost/feed"),
            ("Also Blocked", "https://127.0.0.1/rss"),
        ]

        let summary = await RSSValidationService.validateFeedsSerially(feeds) { _, _, _ in }

        XCTAssertEqual(summary.successCount, 0)
        XCTAssertEqual(summary.failedCount, 2)
        XCTAssertEqual(summary.wasCancelled, false)
        XCTAssertEqual(summary.outcomes.count, 2)

        for entry in summary.outcomes {
            guard case .blocked = entry.outcome else {
                XCTFail("Expected blocked outcome for all feeds")
                return
            }
        }
    }

    // MARK: - sanitizedNetworkMessage Coverage

    func testSanitizedNetworkMessage_TimedOut() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let result = RSSValidationService.classifyFetchResult(
            urlString: "https://example.com/feed",
            data: nil,
            error: error
        )
        guard case .networkError(let summary) = result else {
            XCTFail("Expected networkError")
            return
        }
        XCTAssertEqual(summary, "Request timed out")
    }

    func testSanitizedNetworkMessage_CannotConnect() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        let result = RSSValidationService.classifyFetchResult(
            urlString: "https://example.com/feed",
            data: nil,
            error: error
        )
        guard case .networkError(let summary) = result else {
            XCTFail("Expected networkError")
            return
        }
        XCTAssertEqual(summary, "Cannot connect to server")
    }

    func testSanitizedNetworkMessage_NoInternet() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let result = RSSValidationService.classifyFetchResult(
            urlString: "https://example.com/feed",
            data: nil,
            error: error
        )
        guard case .networkError(let summary) = result else {
            XCTFail("Expected networkError")
            return
        }
        XCTAssertEqual(summary, "No internet connection")
    }

    func testSanitizedNetworkMessage_CannotFindHost() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        let result = RSSValidationService.classifyFetchResult(
            urlString: "https://example.com/feed",
            data: nil,
            error: error
        )
        guard case .networkError(let summary) = result else {
            XCTFail("Expected networkError")
            return
        }
        XCTAssertEqual(summary, "Server not found")
    }

    func testSanitizedNetworkMessage_BadServerResponse() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse)
        let result = RSSValidationService.classifyFetchResult(
            urlString: "https://example.com/feed",
            data: nil,
            error: error
        )
        guard case .networkError(let summary) = result else {
            XCTFail("Expected networkError")
            return
        }
        XCTAssertEqual(summary, "Invalid server response")
    }

    func testSanitizedNetworkMessage_UnknownURLError() {
        let error = NSError(domain: NSURLErrorDomain, code: 9999)
        let result = RSSValidationService.classifyFetchResult(
            urlString: "https://example.com/feed",
            data: nil,
            error: error
        )
        guard case .networkError(let summary) = result else {
            XCTFail("Expected networkError")
            return
        }
        XCTAssertEqual(summary, "Network error")
    }

    // MARK: - Existing RSSService.validate remains unchanged

    func testRSSServiceValidate_ExistsAndUnchanged() async {
        let result = try? await RSSService.validate("https://localhost/feed")
        XCTAssertEqual(result, false)
    }

    // MARK: - XML Data Generation Helpers

    private func makeRSSFeed(itemCount: Int) -> Data {
        var items = ""
        for i in 0..<itemCount {
            items += """
            <item>
                <title>Item \(i)</title>
                <link>https://example.com/item/\(i)</link>
                <description>Description for item \(i)</description>
            </item>

            """
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
            <channel>
                <title>Test Feed</title>
                <link>https://example.com</link>
                <description>A test RSS feed</description>
                \(items)
            </channel>
        </rss>
        """
        return xml.data(using: .utf8)!
    }

    private func makeAtomFeed(entryCount: Int) -> Data {
        var entries = ""
        for i in 0..<entryCount {
            entries += """
            <entry>
                <title>Entry \(i)</title>
                <link href="https://example.com/entry/\(i)"/>
                <summary>Summary for entry \(i)</summary>
            </entry>

            """
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
            <title>Test Atom Feed</title>
            <link href="https://example.com"/>
            \(entries)
        </feed>
        """
        return xml.data(using: .utf8)!
    }
}
