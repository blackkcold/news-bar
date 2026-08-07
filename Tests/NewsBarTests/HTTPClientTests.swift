import XCTest
@testable import NewsBar

final class HTTPClientTests: XCTestCase {

    // MARK: - validateResponseSize: Declared Content-Length

    func testValidate_DeclaredLengthUnderCeiling_Passes() {
        XCTAssertTrue(HTTPClient.validateResponseSize(
            declaredContentLength: 100,
            receivedByteCount: 100,
            maxBodySize: 1024
        ))
    }

    func testValidate_DeclaredLengthEqualsCeiling_Passes() {
        XCTAssertTrue(HTTPClient.validateResponseSize(
            declaredContentLength: 1024,
            receivedByteCount: 1024,
            maxBodySize: 1024
        ))
    }

    func testValidate_DeclaredLengthExceedsCeiling_Rejects() {
        XCTAssertFalse(HTTPClient.validateResponseSize(
            declaredContentLength: 1025,
            receivedByteCount: 0,
            maxBodySize: 1024
        ))
    }

    // MARK: - validateResponseSize: Received bytes (authoritative)

    func testValidate_ReceivedBytesUnderCeiling_Passes() {
        XCTAssertTrue(HTTPClient.validateResponseSize(
            declaredContentLength: nil,
            receivedByteCount: 512,
            maxBodySize: 1024
        ))
    }

    func testValidate_ReceivedBytesEqualCeiling_Passes() {
        XCTAssertTrue(HTTPClient.validateResponseSize(
            declaredContentLength: nil,
            receivedByteCount: 1024,
            maxBodySize: 1024
        ))
    }

    func testValidate_ReceivedBytesExceedCeiling_Rejects() {
        XCTAssertFalse(HTTPClient.validateResponseSize(
            declaredContentLength: nil,
            receivedByteCount: 1025,
            maxBodySize: 1024
        ))
    }

    // MARK: - validateResponseSize: Missing Content-Length (MUST NOT permit oversized body)

    func testValidate_MissingContentLength_OversizedBody_Rejects() {
        XCTAssertFalse(HTTPClient.validateResponseSize(
            declaredContentLength: nil,
            receivedByteCount: 10 * 1024 * 1024,
            maxBodySize: 1024
        ))
    }

    func testValidate_MissingContentLength_UndersizedBody_Passes() {
        XCTAssertTrue(HTTPClient.validateResponseSize(
            declaredContentLength: nil,
            receivedByteCount: 10,
            maxBodySize: 1024
        ))
    }

    // MARK: - validateResponseSize: Under-declaration (server lies)

    func testValidate_DeclaredUnderReceived_RejectsOnReceived() {
        XCTAssertFalse(HTTPClient.validateResponseSize(
            declaredContentLength: 10,
            receivedByteCount: 2048,
            maxBodySize: 1024
        ))
    }

    func testValidate_DeclaredOverReceived_RejectsOnDeclared() {
        XCTAssertFalse(HTTPClient.validateResponseSize(
            declaredContentLength: 2048,
            receivedByteCount: 10,
            maxBodySize: 1024
        ))
    }

    // MARK: - validateResponseSize: Invalid ceiling semantics

    func testValidate_ZeroCeiling_Rejects() {
        XCTAssertFalse(HTTPClient.validateResponseSize(
            declaredContentLength: nil,
            receivedByteCount: 1024,
            maxBodySize: 0
        ))
    }

    func testValidate_NegativeCeiling_Rejects() {
        XCTAssertFalse(HTTPClient.validateResponseSize(
            declaredContentLength: nil,
            receivedByteCount: 1024,
            maxBodySize: -1
        ))
    }

    func testValidate_ZeroCeiling_DeclaredLengthRejects() {
        XCTAssertFalse(HTTPClient.validateResponseSize(
            declaredContentLength: Int.max,
            receivedByteCount: 0,
            maxBodySize: 0
        ))
    }

    // MARK: - validateResponseSize: Boundary exactness

    func testValidate_ExactBoundary_Passes() {
        let ceiling = 4 * 1024 * 1024
        XCTAssertTrue(HTTPClient.validateResponseSize(
            declaredContentLength: ceiling,
            receivedByteCount: ceiling,
            maxBodySize: ceiling
        ))
    }

    func testValidate_OneByteOverBoundary_Rejects() {
        let ceiling = 4 * 1024 * 1024
        XCTAssertFalse(HTTPClient.validateResponseSize(
            declaredContentLength: ceiling + 1,
            receivedByteCount: ceiling + 1,
            maxBodySize: ceiling
        ))
    }

    // MARK: - Config invariants: every preset has a sane, positive body ceiling

    func testConfig_Weibo_HasPositiveBodyCeiling() {
        XCTAssertGreaterThan(HTTPClient.Config.weibo.maxBodySize, 0)
        XCTAssertEqual(HTTPClient.Config.weibo.timeout, 10)
    }

    func testConfig_Bilibili_HasPositiveBodyCeiling() {
        XCTAssertGreaterThan(HTTPClient.Config.bilibili.maxBodySize, 0)
        XCTAssertEqual(HTTPClient.Config.bilibili.timeout, 8)
    }

    func testConfig_RSS_HasPositiveBodyCeiling() {
        XCTAssertGreaterThan(HTTPClient.Config.rss.maxBodySize, 0)
        XCTAssertEqual(HTTPClient.Config.rss.timeout, 8)
    }

    func testConfig_AI_HasPositiveBodyCeiling() {
        XCTAssertGreaterThan(HTTPClient.Config.ai.maxBodySize, 0)
        XCTAssertEqual(HTTPClient.Config.ai.timeout, 30)
    }

    func testConfig_RSSCeiling_GreaterOrEqualAI() {
        XCTAssertGreaterThanOrEqual(
            HTTPClient.Config.rss.maxBodySize,
            HTTPClient.Config.ai.maxBodySize
        )
    }

    // MARK: - Config invariants: existing headers/timeouts preserved

    func testConfig_Weibo_PreservesExtraHeaders() {
        XCTAssertEqual(HTTPClient.Config.weibo.extraHeaders["Referer"], "https://weibo.com/")
        XCTAssertEqual(HTTPClient.Config.weibo.extraHeaders["X-Requested-With"], "XMLHttpRequest")
    }

    func testConfig_Bilibili_PreservesReferer() {
        XCTAssertEqual(HTTPClient.Config.bilibili.extraHeaders["Referer"], "https://www.bilibili.com")
    }

    func testConfig_RSS_EmptyExtraHeaders() {
        XCTAssertTrue(HTTPClient.Config.rss.extraHeaders.isEmpty)
    }

    func testConfig_RSSBrowserHeaders_ContainCompatibilityHeaders() {
        XCTAssertFalse(HTTPClient.Config.rssBrowserHeaders["User-Agent", default: ""].isEmpty)
        XCTAssertTrue(
            HTTPClient.Config.rssBrowserHeaders["Accept", default: ""]
                .contains("application/rss+xml")
        )
    }

    func testConfig_AI_EmptyExtraHeaders() {
        XCTAssertTrue(HTTPClient.Config.ai.extraHeaders.isEmpty)
    }

    // MARK: - Deterministic end-to-end validation via the pure seam

    func testEndToEnd_RSSFeed_PayloadWithinCeiling_Accepted() {
        let rssPayload = "<rss><channel><item><title>x</title></item></channel></rss>"
        let bytes = rssPayload.utf8.count
        XCTAssertTrue(HTTPClient.validateResponseSize(
            declaredContentLength: bytes,
            receivedByteCount: bytes,
            maxBodySize: HTTPClient.Config.rss.maxBodySize
        ))
    }

    func testEndToEnd_RSSFeed_PayloadExceedsCeiling_Rejected() {
        let oversized = 2 * HTTPClient.Config.rss.maxBodySize
        XCTAssertFalse(HTTPClient.validateResponseSize(
            declaredContentLength: oversized,
            receivedByteCount: oversized,
            maxBodySize: HTTPClient.Config.rss.maxBodySize
        ))
    }

    func testEndToEnd_AIResponse_PayloadWithinCeiling_Accepted() {
        let aiPayload = "{\"summary\":\"ok\"}"
        let bytes = aiPayload.utf8.count
        XCTAssertTrue(HTTPClient.validateResponseSize(
            declaredContentLength: bytes,
            receivedByteCount: bytes,
            maxBodySize: HTTPClient.Config.ai.maxBodySize
        ))
    }

    func testEndToEnd_AIResponse_PayloadExceedsCeiling_Rejected() {
        let oversized = 2 * HTTPClient.Config.ai.maxBodySize
        XCTAssertFalse(HTTPClient.validateResponseSize(
            declaredContentLength: nil,
            receivedByteCount: oversized,
            maxBodySize: HTTPClient.Config.ai.maxBodySize
        ))
    }
}
