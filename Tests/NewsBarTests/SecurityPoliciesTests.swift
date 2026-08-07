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

    // MARK: - RSS endpoint normalization and response classification

    func testCanonicalRSSURL_Migrates36krApexFeed() {
        XCTAssertEqual(
            SecurityPolicies.canonicalRSSURL("https://36kr.com/feed"),
            "https://www.36kr.com/feed"
        )
        XCTAssertEqual(
            SecurityPolicies.canonicalRSSURL("https://36kr.com/feed/"),
            "https://www.36kr.com/feed"
        )
    }

    func testCanonicalRSSURL_LeavesOtherURLsUnchanged() {
        XCTAssertEqual(
            SecurityPolicies.canonicalRSSURL("https://example.com/feed"),
            "https://example.com/feed"
        )
    }

    func testIsLikelyHTMLResponse_DetectsChallengePage() {
        let html = "\u{FEFF}<!doctype html><html><body>verify</body></html>"
            .data(using: .utf8)!
        XCTAssertTrue(SecurityPolicies.isLikelyHTMLResponse(html))
    }

    func testIsLikelyHTMLResponse_DoesNotRejectRSS() {
        let rss = "<?xml version=\"1.0\"?><rss><channel></channel></rss>"
            .data(using: .utf8)!
        XCTAssertFalse(SecurityPolicies.isLikelyHTMLResponse(rss))
    }

    // MARK: - sanitizeXMLEntities

    func testSanitizeXMLEntities_BareAmpersand_Repaired() {
        let input = "a&b".data(using: .utf8)!
        let result = SecurityPolicies.sanitizeXMLEntities(input)
        XCTAssertEqual(String(data: result, encoding: .utf8), "a&amp;b")
    }

    func testSanitizeXMLEntities_ValidEntities_Preserved() {
        let input = "&amp; &lt; &gt; &quot; &apos; &#65; &#x41;".data(using: .utf8)!
        let result = SecurityPolicies.sanitizeXMLEntities(input)
        XCTAssertEqual(String(data: result, encoding: .utf8), "&amp; &lt; &gt; &quot; &apos; &#65; &#x41;")
    }

    func testSanitizeXMLEntities_CDATA_AmpersandUntouched() {
        let input = "<![CDATA[a&b]]>".data(using: .utf8)!
        let result = SecurityPolicies.sanitizeXMLEntities(input)
        XCTAssertEqual(String(data: result, encoding: .utf8), "<![CDATA[a&b]]>")
    }

    func testSanitizeXMLEntities_Comment_AmpersandUntouched() {
        let input = "<!-- a&b -->".data(using: .utf8)!
        let result = SecurityPolicies.sanitizeXMLEntities(input)
        XCTAssertEqual(String(data: result, encoding: .utf8), "<!-- a&b -->")
    }

    func testSanitizeXMLEntities_AttributeValue_BareAmpersandRepaired() {
        let input = "<rss foo=\"a&b\">".data(using: .utf8)!
        let result = SecurityPolicies.sanitizeXMLEntities(input)
        XCTAssertEqual(String(data: result, encoding: .utf8), "<rss foo=\"a&amp;b\">")
    }

    func testSanitizeXMLEntities_NoBareAmpersand_ReturnsOriginalData() {
        let input = "<rss><channel><title>Hello</title></channel></rss>".data(using: .utf8)!
        let result = SecurityPolicies.sanitizeXMLEntities(input)
        XCTAssertTrue(result == input, "Expected zero-copy fast path to return original Data")
    }

    func testSanitizeXMLEntities_GBKBytes_Repaired() {
        // GBK-encoded bytes for "中文" (0xD6 0xD0 0xCE 0xC4) with a bare '&' (0x26) between them.
        var gbkBytes: [UInt8] = [0xD6, 0xD0, 0x26, 0xCE, 0xC4]
        let input = Data(gbkBytes)
        let result = SecurityPolicies.sanitizeXMLEntities(input)
        let out = [UInt8](result)
        XCTAssertEqual(out, [0xD6, 0xD0, 0x26, 0x61, 0x6D, 0x70, 0x3B, 0xCE, 0xC4])
    }

    func testSanitizeXMLEntities_IfanrStyleBase64URL_Repaired() {
        // Mimics ifanr's bug: a base64 URL ending in a bare '&' before </image>.
        let input = "<image>data:image/png;base64,AAAA&</image>".data(using: .utf8)!
        let result = SecurityPolicies.sanitizeXMLEntities(input)
        XCTAssertEqual(String(data: result, encoding: .utf8), "<image>data:image/png;base64,AAAA&amp;</image>")
    }

    func testSanitizeXMLEntities_HTMLNamedEntityOutsideCDATA_Escaped() {
        // &nbsp; is an HTML entity, not one of the 5 XML predefined entities. Outside CDATA it must
        // be escaped to &amp;nbsp; so XMLParser treats it as text instead of an undeclared entity.
        let input = "作者&nbsp;|&nbsp;张子怡".data(using: .utf8)!
        let result = SecurityPolicies.sanitizeXMLEntities(input)
        XCTAssertEqual(String(data: result, encoding: .utf8), "作者&amp;nbsp;|&amp;nbsp;张子怡")
    }

    func testSanitizeXMLEntities_CopyEntityOutsideCDATA_Escaped() {
        let input = "©&copy;2026".data(using: .utf8)!
        let result = SecurityPolicies.sanitizeXMLEntities(input)
        XCTAssertEqual(String(data: result, encoding: .utf8), "©&amp;copy;2026")
    }

    func testSanitizeXMLEntities_PredefinedEntitiesStillPreserved() {
        // The 5 XML predefined entities plus numeric character references remain untouched.
        let input = "a&nbsp;b &amp;c&lt;d&gt;e&quot;f&apos;g&#65;h&#x41;i".data(using: .utf8)!
        let result = SecurityPolicies.sanitizeXMLEntities(input)
        XCTAssertEqual(String(data: result, encoding: .utf8), "a&amp;nbsp;b &amp;c&lt;d&gt;e&quot;f&apos;g&#65;h&#x41;i")
    }

    func testSanitizeXMLEntities_HTMLWithNbspOutsideCDATA_EndToEndNoError() {
        // A feed fragment with an HTML entity in plain (non-CDATA) text must sanitize to valid XML.
        let input = "<rss><channel><title>新闻&nbsp;速递</title></channel></rss>".data(using: .utf8)!
        let clean = SecurityPolicies.sanitizeXMLEntities(input)
        let parser = XMLParser(data: clean)
        SecurityPolicies.configureXMLParser(parser)
        XCTAssertTrue(parser.parse(), "Sanitized feed with &nbsp; outside CDATA should parse without error")
    }
}
