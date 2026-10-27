import XCTest
@testable import NewsBar

final class SourceTierCatalogTests: XCTestCase {
    func testRegistrableDomainUsesMultiPartSuffixes() {
        XCTAssertEqual(
            SourceTierCatalog.registrableDomain("www.people.com.cn"),
            "people.com.cn"
        )
        XCTAssertEqual(SourceTierCatalog.registrableDomain("bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(
            SourceTierCatalog.registrableDomain("news.example.com"),
            "example.com"
        )
        XCTAssertEqual(
            SourceTierCatalog.registrableDomain("mp.weixin.qq.com"),
            "qq.com"
        )
        XCTAssertEqual(SourceTierCatalog.registrableDomain("127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(SourceTierCatalog.registrableDomain("localhost"), "localhost")
    }

    func testKnownTiers() {
        let government = SourceTierCatalog.info(for: "https://www.court.gov.cn/notice")
        XCTAssertEqual(government.tier, .primary)
        XCTAssertTrue(government.isKnown)
        XCTAssertEqual(government.domain, "court.gov.cn")

        let wire = SourceTierCatalog.info(for: "https://www.reuters.com/world")
        XCTAssertEqual(wire.tier, .primary)
        XCTAssertTrue(wire.isKnown)

        let major = SourceTierCatalog.info(for: "https://www.thepaper.cn/newsDetail_forward_1")
        XCTAssertEqual(major.tier, .major)
        XCTAssertTrue(major.isKnown)

        let unknown = SourceTierCatalog.info(for: "https://blog.example.org/post")
        XCTAssertEqual(unknown.tier, .industry)
        XCTAssertFalse(unknown.isKnown)
        XCTAssertEqual(unknown.domain, "example.org")

        let social = SourceTierCatalog.info(for: "https://s.weibo.com/weibo?q=test")
        XCTAssertEqual(social.tier, .social)
        XCTAssertTrue(social.isKnown)
        XCTAssertEqual(social.domain, "weibo.com")

        let wechat = SourceTierCatalog.info(for: "https://mp.weixin.qq.com/s/abc")
        XCTAssertEqual(wechat.tier, .social)
        XCTAssertTrue(wechat.isKnown)
        XCTAssertEqual(wechat.domain, "qq.com")
    }

    func testUniversitySuffixIsTierTwo() {
        let university = SourceTierCatalog.info(for: "https://www.tsinghua.edu.cn/index.htm")
        XCTAssertEqual(university.tier, .major)
        XCTAssertTrue(university.isKnown)
        XCTAssertEqual(university.domain, "tsinghua.edu.cn")
    }

    func testInvalidURLFallsBackToUnknownIndustry() {
        let invalid = SourceTierCatalog.info(for: "not a url")
        XCTAssertEqual(invalid.tier, .industry)
        XCTAssertFalse(invalid.isKnown)
        XCTAssertEqual(invalid.domain, "")
    }
}
