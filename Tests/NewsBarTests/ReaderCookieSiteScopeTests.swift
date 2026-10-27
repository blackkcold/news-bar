import XCTest
@testable import NewsBar

final class ReaderCookieSiteScopeTests: XCTestCase {
    func testBilibiliShortLinkAndSubdomainsShareSite() {
        XCTAssertEqual(ReaderCookieSiteScope.site(for: "b23.tv"), "bilibili.com")
        XCTAssertEqual(ReaderCookieSiteScope.site(for: "www.bilibili.com"), "bilibili.com")
        XCTAssertEqual(ReaderCookieSiteScope.site(for: "passport.bilibili.com"), "bilibili.com")
        XCTAssertEqual(ReaderCookieSiteScope.site(for: "bili2233.cn"), "bilibili.com")
    }

    func testWeiboSubdomainsAndShortLinkShareSite() {
        XCTAssertEqual(ReaderCookieSiteScope.site(for: "s.weibo.com"), "weibo.com")
        XCTAssertEqual(ReaderCookieSiteScope.site(for: "passport.weibo.com"), "weibo.com")
        XCTAssertEqual(ReaderCookieSiteScope.site(for: "weibo.cn"), "weibo.com")
        XCTAssertEqual(ReaderCookieSiteScope.site(for: "t.cn"), "weibo.com")
    }

    func testLookalikeHostKeepsOwnSite() {
        XCTAssertEqual(ReaderCookieSiteScope.site(for: "evil-bilibili.com"), "evil-bilibili.com")
        XCTAssertEqual(ReaderCookieSiteScope.site(for: "b23.tv.evil.com"), "b23.tv.evil.com")
        let hosts = ReaderCookieSiteScope.injectionHosts(for: "https://evil-bilibili.com/watch")
        XCTAssertFalse(hosts.contains("bilibili.com"))
    }

    func testInjectionHostsIncludeSiteAndAliases() {
        let hosts = ReaderCookieSiteScope.injectionHosts(for: "https://b23.tv/BV1xx")
        XCTAssertTrue(hosts.contains("b23.tv"))
        XCTAssertTrue(hosts.contains("bilibili.com"))
        XCTAssertTrue(hosts.contains("bili2233.cn"))
        XCTAssertTrue(hosts.contains("www.bilibili.com"))
    }

    func testCookieDomainBelongsToSite() {
        XCTAssertTrue(ReaderCookieHost.belongsToSite(domain: ".bilibili.com", site: "bilibili.com"))
        XCTAssertTrue(ReaderCookieHost.belongsToSite(domain: "www.bilibili.com", site: "bilibili.com"))
        XCTAssertTrue(ReaderCookieHost.belongsToSite(domain: "b23.tv", site: "bilibili.com"))
        XCTAssertTrue(ReaderCookieHost.belongsToSite(domain: ".weibo.cn", site: "weibo.com"))
        XCTAssertTrue(ReaderCookieHost.belongsToSite(domain: "t.cn", site: "weibo.com"))
        XCTAssertFalse(ReaderCookieHost.belongsToSite(domain: "evil-bilibili.com", site: "bilibili.com"))
        XCTAssertFalse(ReaderCookieHost.belongsToSite(domain: "bilibili.com.evil.com", site: "bilibili.com"))
    }

    func testInvalidURLHasNoInjectionHosts() {
        XCTAssertTrue(ReaderCookieSiteScope.injectionHosts(for: "").isEmpty)
        XCTAssertTrue(ReaderCookieSiteScope.injectionHosts(for: "not a url").isEmpty)
    }
}
