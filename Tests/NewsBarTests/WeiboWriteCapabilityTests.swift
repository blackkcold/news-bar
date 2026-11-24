import XCTest
@testable import NewsBar

final class WeiboWriteCapabilityTests: XCTestCase {
    private func credentials(
        desktop: String?,
        mobile: String? = nil,
        hasDesktopLogin: Bool = false,
        hasMobileLogin: Bool = false
    ) -> WeiboCredentials {
        WeiboCredentials(
            desktopCookieHeader: desktop,
            mobileCookieHeader: mobile,
            hasDesktopLogin: hasDesktopLogin,
            hasMobileLogin: hasMobileLogin
        )
    }

    func testReadyRequiresDesktopSUBAndXSRF() {
        let value = credentials(
            desktop: "SUB=desktop; XSRF-TOKEN=token",
            hasDesktopLogin: true
        )
        XCTAssertEqual(value.writeCapability, .ready)
        XCTAssertTrue(value.writeCapability.allowsWrites)
    }

    func testDesktopSUBWithoutXSRFIsMissingXSRF() {
        let value = credentials(desktop: "SUB=desktop", hasDesktopLogin: true)
        XCTAssertEqual(value.writeCapability, .missingXSRF)
        XCTAssertFalse(value.writeCapability.allowsWrites)
    }

    func testMobileLoginIsMobileOnly() {
        let value = credentials(
            desktop: nil,
            mobile: "SUB=mobile",
            hasMobileLogin: true
        )
        XCTAssertEqual(value.writeCapability, .mobileOnly)
        XCTAssertFalse(value.writeCapability.allowsWrites)
    }

    func testNoCookieIsSignedOut() {
        XCTAssertEqual(WeiboCredentials.none.writeCapability, .signedOut)
    }

    func testHeaderBeatsStaleLoginFlags() {
        // A stale `hasDesktopLogin == false` must not hide usable cookies.
        let usable = credentials(desktop: "SUB=desktop; XSRF-TOKEN=token")
        XCTAssertEqual(usable.writeCapability, .ready)

        // Conversely, a stale `true` must not invent credentials.
        let staleFlag = credentials(desktop: nil, hasDesktopLogin: true)
        XCTAssertEqual(staleFlag.writeCapability, .signedOut)
    }

    func testCookieParsingIsCaseInsensitiveAndRejectsEmptyValues() {
        let value = credentials(
            desktop: " sub = desktop ; Xsrf-Token = token%3D ; empty= ",
            hasDesktopLogin: true
        )
        XCTAssertEqual(value.writeCapability, .ready)

        let emptyXSRF = credentials(
            desktop: "SUB=desktop; XSRF-TOKEN=",
            hasDesktopLogin: true
        )
        XCTAssertEqual(emptyXSRF.writeCapability, .missingXSRF)
    }

    func testCookieValueKeepsEqualsSignsInsideTheValue() {
        XCTAssertEqual(
            WeiboCookieHeader.value(named: "XSRF-TOKEN", in: "SUB=x; XSRF-TOKEN=a=b%3D"),
            "a=b%3D"
        )
    }
}
