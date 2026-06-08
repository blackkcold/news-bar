import XCTest
@testable import NewsBar

final class SecurityPoliciesTests: XCTestCase {
    func testSanitizeHTMLContent_RemovesScriptTags() {
        let input = "<script>alert('xss')</script>Hello"
        let result = SecurityPolicies.sanitizeHTMLContent(input)
        XCTAssertFalse(result.contains("<script>"))
        XCTAssertTrue(result.contains("Hello"))
    }

    func testValidateURL_HTTPS_Valid() {
        let url = SecurityPolicies.validateURL("https://example.com")
        XCTAssertNotNil(url)
    }

    func testValidateURL_HTTP_Invalid() {
        let url = SecurityPolicies.validateURL("http://example.com")
        XCTAssertNil(url)
    }

    func testValidateRSSURL_Localhost_Blocked() {
        let result = SecurityPolicies.validateRSSURL("https://localhost/feed")
        if case .blocked = result {
            // expected
        } else {
            XCTFail("Expected blocked for localhost")
        }
    }

    func testValidateRSSURL_PrivateIP_Warning() {
        let result = SecurityPolicies.validateRSSURL("https://192.168.1.1/feed")
        if case .warning = result {
            // expected
        } else {
            XCTFail("Expected warning for private IP")
        }
    }
}
