import XCTest
@testable import NewsBar

final class ReaderUserAgentTests: XCTestCase {
    func testCurrentSafariVersionOnModernMacOS() {
        let ua = ReaderUserAgent.value(operatingSystemVersion: .init(majorVersion: 26, minorVersion: 4, patchVersion: 0))
        XCTAssertEqual(
            ua,
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 26_4) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.4 Safari/605.1.15"
        )
    }

    func testSafariMajorStaysThreeAheadOnPre26MacOS() {
        let ua = ReaderUserAgent.value(operatingSystemVersion: .init(majorVersion: 15, minorVersion: 5, patchVersion: 0))
        XCTAssertEqual(
            ua,
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
        )
        XCTAssertTrue(ua.hasSuffix("Version/18.5 Safari/605.1.15"))
        XCTAssertFalse(ua.contains("Chrome"))
        XCTAssertFalse(ua.contains("Edg"))
    }

    func testNegativeVersionComponentsAreClamped() {
        let ua = ReaderUserAgent.value(operatingSystemVersion: .init(majorVersion: -1, minorVersion: -2, patchVersion: 0))
        XCTAssertFalse(ua.contains("_-"))
        XCTAssertFalse(ua.contains("Version/-"))
    }
}
