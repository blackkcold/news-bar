import WebKit
import XCTest
@testable import NewsBar

private actor MemoryCookiePersistence: ReaderCookiePersisting {
    private var data: Data?
    func load() async throws -> Data? { data }
    func save(_ data: Data) async throws { self.data = data }
    func clear() async throws { data = nil }
}

private actor MemoryHistoryPersistence: ReaderHistoryPersisting {
    private var data: Data?
    func load() async throws -> Data? { data }
    func save(_ data: Data) async throws { self.data = data }
    func clear() async throws { data = nil }
}

final class ReaderCookieVaultTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func cookie(
        _ name: String,
        value: String = "v",
        domain: String = "example.com",
        path: String = "/",
        expires: Date? = nil,
        secure: Bool = false,
        httpOnly: Bool = false
    ) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
            .secure: secure ? "TRUE" : "FALSE",
        ]
        if let expires { properties[.expires] = expires }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: properties)!
    }

    func testOnlyFirstPartyCookiesAreStored() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)

        let count = try await vault.upsert(
            cookies: [
                cookie("sid", domain: ".example.com"),
                cookie("host", domain: "www.example.com"),
                cookie("tracker", domain: "tracker.net"),
            ],
            host: "www.example.com",
            allowEmptyRemoval: false,
            now: now
        )

        XCTAssertEqual(count, 2)
        let sites = await vault.siteSummaries(now: now)
        XCTAssertEqual(sites.map(\.host), ["www.example.com"])
        XCTAssertEqual(Set(sites.first?.cookies.map(\.name) ?? []), ["sid", "host"])
    }

    func testSavedCookiesReplayForSubdomainsButNotLookalikes() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        _ = try await vault.upsert(
            cookies: [cookie("sid", domain: ".example.com")],
            host: "www.example.com",
            allowEmptyRemoval: false,
            now: now
        )

        let subdomain = await vault.cookies(matching: "news.example.com", now: now)
        XCTAssertEqual(subdomain.map(\.name), ["sid"])

        let lookalike = await vault.cookies(matching: "evil-example.com", now: now)
        XCTAssertTrue(lookalike.isEmpty)
    }

    func testExpiredCookiesAreDropped() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        let count = try await vault.upsert(
            cookies: [
                cookie("old", expires: now.addingTimeInterval(-60)),
                cookie("fresh", expires: now.addingTimeInterval(3_600)),
            ],
            host: "example.com",
            allowEmptyRemoval: false,
            now: now
        )

        XCTAssertEqual(count, 1)
        let later = await vault.cookies(matching: "example.com", now: now.addingTimeInterval(7_200))
        XCTAssertTrue(later.isEmpty)
    }

    func testSessionCookiesSurviveForThirtyDays() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        _ = try await vault.upsert(
            cookies: [cookie("sid")],
            host: "example.com",
            allowEmptyRemoval: false,
            now: now
        )

        let within = await vault.cookies(matching: "example.com", now: now.addingTimeInterval(29 * 86_400))
        XCTAssertEqual(within.count, 1)
        XCTAssertNotNil(within.first?.expiresDate)

        let after = await vault.cookies(matching: "example.com", now: now.addingTimeInterval(31 * 86_400))
        XCTAssertTrue(after.isEmpty)
    }

    func testPerSiteCapKeepsAuthCookies() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        let cookies = (0..<(ReaderCookieVault.maxCookiesPerSite + 40)).map {
            cookie("c\($0)", value: "v\($0)")
        } + [
            cookie("SUB", value: "auth"),
            cookie("SESSDATA", value: "bili-auth"),
        ]

        let count = try await vault.upsert(
            cookies: cookies,
            host: "example.com",
            allowEmptyRemoval: false,
            now: now
        )

        XCTAssertEqual(count, ReaderCookieVault.maxCookiesPerSite)
        let sites = await vault.siteSummaries(now: now)
        XCTAssertEqual(sites.first?.cookies.count, ReaderCookieVault.maxCookiesPerSite)
        XCTAssertTrue(sites.first?.cookies.contains { $0.name == "SUB" } == true)
        XCTAssertTrue(sites.first?.cookies.contains { $0.name == "SESSDATA" } == true)
    }

    func testHTTPOnlyFlagSurvivesReplay() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        let original = cookie(
            "SESSDATA",
            value: "auth",
            domain: ".bilibili.com",
            httpOnly: true
        )
        XCTAssertTrue(original.isHTTPOnly)
        _ = try await vault.upsert(
            cookies: [original],
            host: "www.bilibili.com",
            allowEmptyRemoval: false,
            now: now
        )

        let replayed = await vault.cookies(matching: "www.bilibili.com", now: now)
        XCTAssertEqual(replayed.count, 1)
        XCTAssertTrue(replayed.first?.isHTTPOnly == true)
    }

    func testGlobalCapEvictsWholeSites() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)

        for index in 0..<10 {
            let host = "s\(index).example.com"
            let cookies = (0..<80).map { cookie("c\($0)", value: "v\($0)", domain: host) }
            _ = try await vault.upsert(
                cookies: cookies,
                host: host,
                allowEmptyRemoval: false,
                now: now.addingTimeInterval(Double(index))
            )
        }

        let total = await vault.totalCookieCount(now: now.addingTimeInterval(20))
        let sites = await vault.siteSummaries(now: now.addingTimeInterval(20))
        XCTAssertLessThanOrEqual(total, ReaderCookieVault.maxCookiesTotal)
        XCTAssertTrue(sites.allSatisfy { $0.cookies.count == 80 })
        XCTAssertEqual(Set(sites.map(\.host)), Set((3..<10).map { "s\($0).example.com" }))
    }

    func testGlobalCapKeepsAuthSiteWhenOlder() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        let authCookies = [cookie("SESSDATA", value: "auth", domain: "bilibili.com")]
            + (0..<79).map { cookie("c\($0)", value: "v", domain: "bilibili.com") }
        _ = try await vault.upsert(
            cookies: authCookies,
            host: "bilibili.com",
            allowEmptyRemoval: false,
            now: now
        )

        for index in 0..<10 {
            let host = "s\(index).example.com"
            let cookies = (0..<80).map { cookie("c\($0)", value: "v", domain: host) }
            _ = try await vault.upsert(
                cookies: cookies,
                host: host,
                allowEmptyRemoval: false,
                now: now.addingTimeInterval(Double(index + 1))
            )
        }

        let sites = await vault.siteSummaries(now: now.addingTimeInterval(20))
        let total = await vault.totalCookieCount(now: now.addingTimeInterval(20))
        XCTAssertTrue(sites.contains { $0.host == "bilibili.com" })
        XCTAssertTrue(sites.first { $0.host == "bilibili.com" }?.cookies.contains { $0.name == "SESSDATA" } == true)
        XCTAssertLessThanOrEqual(total, ReaderCookieVault.maxCookiesTotal)
    }

    func testRemoveAndClear() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        _ = try await vault.upsert(
            cookies: [cookie("sid")],
            host: "example.com",
            allowEmptyRemoval: false,
            now: now
        )

        try await vault.removeSite("example.com")
        let afterRemove = await vault.siteSummaries(now: now)
        XCTAssertTrue(afterRemove.isEmpty)

        _ = try await vault.upsert(
            cookies: [cookie("sid")],
            host: "example.com",
            allowEmptyRemoval: false,
            now: now
        )
        try await vault.clear()
        let afterClear = await vault.siteSummaries(now: now)
        XCTAssertTrue(afterClear.isEmpty)
    }

    func testUnchangedCookiesDoNotRewriteTheVault() async throws {
        let persistence = MemoryCookiePersistence()
        let vault = ReaderCookieVault(persistence: persistence)
        await vault.prepare(now: now)

        let cookies = [cookie("sid")]
        _ = try await vault.upsert(cookies: cookies, host: "example.com", allowEmptyRemoval: false, now: now)
        let first = try await persistence.load()
        XCTAssertNotNil(first)

        _ = try await vault.upsert(
            cookies: cookies,
            host: "example.com",
            allowEmptyRemoval: false,
            now: now.addingTimeInterval(60)
        )
        let second = try await persistence.load()
        XCTAssertEqual(first, second)
    }

    func testDomainCookieKeepsSubdomainScope() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        _ = try await vault.upsert(
            cookies: [cookie("SUB", value: "auth", domain: ".weibo.com")],
            host: "weibo.com",
            allowEmptyRemoval: false,
            now: now
        )

        let sites = await vault.siteSummaries(now: now)
        XCTAssertEqual(sites.first?.cookies.first?.domain, ".weibo.com")

        let subdomain = await vault.cookies(matching: "passport.weibo.com", now: now)
        XCTAssertEqual(subdomain.map(\.name), ["SUB"])
        XCTAssertEqual(subdomain.first?.domain, ".weibo.com")
    }

    func testHostOnlyCookieDoesNotReplayToSubdomains() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        _ = try await vault.upsert(
            cookies: [cookie("SUB", value: "auth", domain: "weibo.com")],
            host: "weibo.com",
            allowEmptyRemoval: false,
            now: now
        )

        let subdomain = await vault.cookies(matching: "passport.weibo.com", now: now)
        XCTAssertTrue(subdomain.isEmpty)

        let sameHost = await vault.cookies(matching: "weibo.com", now: now)
        XCTAssertEqual(sameHost.map(\.name), ["SUB"])
    }

    func testLegacyV1MigrationPromotesKnownAuthCookie() async throws {
        let persistence = MemoryCookiePersistence()
        let legacyCookie = try XCTUnwrap(ReaderStoredCookie(
            cookie: cookie("SUB", value: "auth", domain: "weibo.com"),
            now: now
        ))
        let legacy = ReaderCookieSnapshot(
            version: 1,
            sites: [
                ReaderSavedSite(
                    host: "weibo.com",
                    title: nil,
                    savedAt: now,
                    updatedAt: now,
                    cookies: [legacyCookie]
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try await persistence.save(encoder.encode(legacy))

        let vault = ReaderCookieVault(persistence: persistence)
        await vault.prepare(now: now)

        let sites = await vault.siteSummaries(now: now)
        XCTAssertEqual(sites.first?.cookies.first?.domain, ".weibo.com")
        let subdomain = await vault.cookies(matching: "passport.weibo.com", now: now)
        XCTAssertEqual(subdomain.map(\.name), ["SUB"])
    }

    func testLegacyV1MigrationLeavesUnknownHostOnlyCookie() async throws {
        let persistence = MemoryCookiePersistence()
        let legacyCookie = try XCTUnwrap(ReaderStoredCookie(
            cookie: cookie("theme", value: "dark", domain: "weibo.com"),
            now: now
        ))
        let legacy = ReaderCookieSnapshot(
            version: 1,
            sites: [
                ReaderSavedSite(
                    host: "weibo.com",
                    title: nil,
                    savedAt: now,
                    updatedAt: now,
                    cookies: [legacyCookie]
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try await persistence.save(encoder.encode(legacy))

        let vault = ReaderCookieVault(persistence: persistence)
        await vault.prepare(now: now)

        let sites = await vault.siteSummaries(now: now)
        XCTAssertEqual(sites.first?.cookies.first?.domain, "weibo.com")
        let subdomain = await vault.cookies(matching: "passport.weibo.com", now: now)
        XCTAssertTrue(subdomain.isEmpty)
    }

    func testV2MigrationGroupsPageHostsUnderSiteKey() async throws {
        let persistence = MemoryCookiePersistence()
        let sessdata = try XCTUnwrap(ReaderStoredCookie(
            cookie: cookie("SESSDATA", value: "auth", domain: ".bilibili.com"),
            now: now
        ))
        let buvid = try XCTUnwrap(ReaderStoredCookie(
            cookie: cookie("buvid3", value: "device", domain: "www.bilibili.com"),
            now: now
        ))
        let legacy = ReaderCookieSnapshot(
            version: 2,
            sites: [
                ReaderSavedSite(
                    host: "www.bilibili.com",
                    title: "B站",
                    savedAt: now,
                    updatedAt: now.addingTimeInterval(10),
                    cookies: [sessdata]
                ),
                ReaderSavedSite(
                    host: "passport.bilibili.com",
                    title: nil,
                    savedAt: now,
                    updatedAt: now.addingTimeInterval(20),
                    cookies: [buvid]
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try await persistence.save(encoder.encode(legacy))

        let vault = ReaderCookieVault(persistence: persistence)
        await vault.prepare(now: now.addingTimeInterval(30))

        let sites = await vault.siteSummaries(now: now.addingTimeInterval(30))
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites.first?.host, "bilibili.com")
        XCTAssertEqual(Set(sites.first?.cookies.map(\.name) ?? []), ["SESSDATA", "buvid3"])
        XCTAssertEqual(sites.first?.title, "B站")
    }

    func testV2MigrationDoesNotPromoteHostOnlyAuthCookieAgain() async throws {
        let persistence = MemoryCookiePersistence()
        let hostOnlySub = try XCTUnwrap(ReaderStoredCookie(
            cookie: cookie("SUB", value: "auth", domain: "weibo.com"),
            now: now
        ))
        let legacy = ReaderCookieSnapshot(
            version: 2,
            sites: [
                ReaderSavedSite(
                    host: "weibo.com",
                    title: nil,
                    savedAt: now,
                    updatedAt: now,
                    cookies: [hostOnlySub]
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try await persistence.save(encoder.encode(legacy))

        let vault = ReaderCookieVault(persistence: persistence)
        await vault.prepare(now: now)

        let sites = await vault.siteSummaries(now: now)
        XCTAssertEqual(sites.first?.cookies.first?.domain, "weibo.com")
        let subdomain = await vault.cookies(matching: "passport.weibo.com", now: now)
        XCTAssertTrue(subdomain.isEmpty)
    }

    func testEmptyCaptureKeepsSavedSite() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        _ = try await vault.upsert(
            cookies: [cookie("SUB", domain: ".weibo.com")],
            host: "weibo.com",
            allowEmptyRemoval: false,
            now: now
        )

        let count = try await vault.upsert(
            cookies: [],
            host: "passport.weibo.com",
            allowEmptyRemoval: false,
            now: now.addingTimeInterval(60)
        )

        XCTAssertEqual(count, 0)
        let hasSite = await vault.hasSite("weibo.com")
        XCTAssertTrue(hasSite)
        let subdomain = await vault.cookies(matching: "weibo.com", now: now.addingTimeInterval(60))
        XCTAssertEqual(subdomain.map(\.name), ["SUB"])
    }

    func testDuplicateIdentityIsDeduplicatedAcrossSites() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        let sub = cookie("SUB", value: "auth", domain: ".weibo.com")
        _ = try await vault.upsert(
            cookies: [sub],
            host: "weibo.com",
            allowEmptyRemoval: false,
            now: now
        )
        _ = try await vault.upsert(
            cookies: [sub],
            host: "passport.weibo.com",
            allowEmptyRemoval: false,
            now: now.addingTimeInterval(60)
        )

        let total = await vault.totalCookieCount(now: now.addingTimeInterval(120))
        XCTAssertEqual(total, 1)
    }

    func testAliasInjectionIncludesShortLinkSiteCookies() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        _ = try await vault.upsert(
            cookies: [cookie("SESSDATA", value: "auth", domain: ".bilibili.com")],
            host: "www.bilibili.com",
            allowEmptyRemoval: false,
            now: now
        )

        let hosts = ReaderCookieSiteScope.injectionHosts(for: "https://b23.tv/BV1xx")
        let injected = await vault.cookies(forInjectionHosts: hosts, now: now)
        XCTAssertEqual(injected.map(\.name), ["SESSDATA"])

        let lookalike = await vault.cookies(forInjectionHosts: ["evil-bilibili.com"], now: now)
        XCTAssertTrue(lookalike.isEmpty)
    }

    func testAliasCaptureUpdatesSiblingEntryWithoutLosingAuthCookie() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        let sessdata = cookie("SESSDATA", value: "auth", domain: ".bilibili.com")
        let buvid = cookie("buvid3", value: "device", domain: "www.bilibili.com")
        _ = try await vault.upsert(
            cookies: [sessdata, buvid],
            host: "www.bilibili.com",
            allowEmptyRemoval: false,
            now: now
        )

        let count = try await vault.upsert(
            cookies: [sessdata, buvid],
            host: "b23.tv",
            allowEmptyRemoval: false,
            now: now.addingTimeInterval(60)
        )

        XCTAssertEqual(count, 2)
        let sites = await vault.siteSummaries(now: now.addingTimeInterval(120))
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites.first?.host, "bilibili.com")
        XCTAssertEqual(Set(sites.first?.cookies.map(\.name) ?? []), ["SESSDATA", "buvid3"])
    }

    func testAliasLookupAndRemovalCoversSiblingHosts() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        _ = try await vault.upsert(
            cookies: [cookie("SESSDATA", value: "auth", domain: ".bilibili.com")],
            host: "www.bilibili.com",
            allowEmptyRemoval: false,
            now: now
        )

        let hasSite = await vault.hasSite("b23.tv")
        XCTAssertTrue(hasSite)

        try await vault.removeSites(forSite: "b23.tv")
        let sites = await vault.siteSummaries(now: now)
        XCTAssertTrue(sites.isEmpty)
    }

    func testWeiboAliasCaptureIncludesWeiboCNCookie() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        let sub = cookie("SUB", value: "auth", domain: ".weibo.com")
        let cn = cookie("SUB", value: "auth-cn", domain: ".weibo.cn")
        _ = try await vault.upsert(
            cookies: [sub, cn],
            host: "s.weibo.com",
            allowEmptyRemoval: false,
            now: now
        )

        let sites = await vault.siteSummaries(now: now)
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites.first?.host, "weibo.com")
        XCTAssertEqual(
            Set(sites.first?.cookies.map(\.domain) ?? []),
            Set([".weibo.com", ".weibo.cn"])
        )

        let injected = await vault.cookies(forInjectionHosts: ["s.weibo.com"], now: now)
        XCTAssertEqual(Set(injected.map(\.domain)), Set([".weibo.com", ".weibo.cn"]))

        try await vault.removeSites(forSite: "t.cn")
        let afterRemoval = await vault.siteSummaries(now: now)
        XCTAssertTrue(afterRemoval.isEmpty)
    }

    /// A site jar that fills `total` slots, optionally carrying one sign-in cookie.
    private func savedSite(
        _ host: String,
        updatedAt: Date,
        total: Int,
        signInCookie: String? = nil
    ) throws -> ReaderSavedSite {
        var cookies: [ReaderStoredCookie] = []
        if let signInCookie {
            cookies.append(try XCTUnwrap(ReaderStoredCookie(
                cookie: cookie(signInCookie, value: "auth", domain: "." + host), now: updatedAt
            )))
        }
        for index in cookies.count..<total {
            cookies.append(try XCTUnwrap(ReaderStoredCookie(
                cookie: cookie("filler\(index)", value: "v", domain: "." + host), now: updatedAt
            )))
        }
        return ReaderSavedSite(host: host, title: nil, savedAt: updatedAt, updatedAt: updatedAt, cookies: cookies)
    }

    private func save(_ snapshot: ReaderCookieSnapshot, to persistence: MemoryCookiePersistence) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try await persistence.save(encoder.encode(snapshot))
    }

    /// `buvid3`/`b_nut` are handed out to anonymous visitors, so an anonymous
    /// Bilibili visit must not be promoted over sites the user is signed into.
    func testAnonymousDeviceCookiesDoNotOutrankSignInSites() async throws {
        let persistence = MemoryCookiePersistence()
        try await save(
            ReaderCookieSnapshot(version: 3, sites: [
                try savedSite("bilibili.com", updatedAt: now.addingTimeInterval(1), total: 160, signInCookie: "buvid3"),
                try savedSite("signin.example", updatedAt: now.addingTimeInterval(10), total: 160, signInCookie: "SESSDATA"),
                try savedSite("ord1.example", updatedAt: now.addingTimeInterval(9), total: 160),
                try savedSite("ord2.example", updatedAt: now.addingTimeInterval(8), total: 160),
                try savedSite("ord3.example", updatedAt: now.addingTimeInterval(7), total: 160),
            ]),
            to: persistence
        )

        let vault = ReaderCookieVault(persistence: persistence)
        await vault.prepare(now: now.addingTimeInterval(60))

        let sites = await vault.siteSummaries(now: now.addingTimeInterval(60))
        XCTAssertFalse(sites.contains { $0.host == "bilibili.com" })
        XCTAssertTrue(sites.contains { $0.host == "signin.example" })
    }

    /// Several signed-in sites can exceed the global budget between them. Each
    /// sign-in cookie must keep a slot; only filler cookies compete for the rest.
    func testSignInCookiesSurviveTheGlobalBudgetAcrossSites() async throws {
        let persistence = MemoryCookiePersistence()
        try await save(
            ReaderCookieSnapshot(version: 3, sites: [
                try savedSite("one.example", updatedAt: now.addingTimeInterval(4), total: 160, signInCookie: "SESSDATA"),
                try savedSite("two.example", updatedAt: now.addingTimeInterval(3), total: 160, signInCookie: "SUB"),
                try savedSite("three.example", updatedAt: now.addingTimeInterval(2), total: 160, signInCookie: "bili_jct"),
                try savedSite("four.example", updatedAt: now.addingTimeInterval(1), total: 160, signInCookie: "wbpsess"),
            ]),
            to: persistence
        )

        let vault = ReaderCookieVault(persistence: persistence)
        await vault.prepare(now: now.addingTimeInterval(60))

        let sites = await vault.siteSummaries(now: now.addingTimeInterval(60))
        let names = Set(sites.flatMap { $0.cookies.map(\.name) })
        XCTAssertTrue(
            names.isSuperset(of: ["SESSDATA", "SUB", "bili_jct", "wbpsess"]),
            "missing sign-in cookies: \(names)"
        )
        let total = await vault.totalCookieCount(now: now.addingTimeInterval(60))
        XCTAssertLessThanOrEqual(total, ReaderCookieVault.maxCookiesTotal)
    }

    /// A v3 store written before `bili2233.cn` joined the alias table can hold
    /// two entries for one sign-in site. Loading it must merge them instead of
    /// leaving two rows with the same host.
    func testPrepareMergesDuplicateHostsFromAnOlderAliasTable() async throws {
        let persistence = MemoryCookiePersistence()
        try await save(
            ReaderCookieSnapshot(version: 3, sites: [
                try savedSite("bilibili.com", updatedAt: now.addingTimeInterval(10), total: 3, signInCookie: "SESSDATA"),
                try savedSite("bili2233.cn", updatedAt: now.addingTimeInterval(5), total: 2, signInCookie: "buvid3"),
            ]),
            to: persistence
        )

        let vault = ReaderCookieVault(persistence: persistence)
        await vault.prepare(now: now.addingTimeInterval(60))

        let sites = await vault.siteSummaries(now: now.addingTimeInterval(60))
        XCTAssertEqual(sites.map(\.host), ["bilibili.com"])
        XCTAssertEqual(sites.first?.cookies.count, 5)
    }

    /// The number returned to the UI must be what the vault actually kept, not
    /// what was offered before the global budget trimmed the jar.
    func testUpsertReportsWhatTheBudgetActuallyKept() async throws {
        let persistence = MemoryCookiePersistence()
        try await save(
            ReaderCookieSnapshot(version: 3, sites: [
                try savedSite("ord1.example", updatedAt: now.addingTimeInterval(1), total: 160),
                try savedSite("ord2.example", updatedAt: now.addingTimeInterval(2), total: 160),
                try savedSite("ord3.example", updatedAt: now.addingTimeInterval(3), total: 160),
                try savedSite("ord4.example", updatedAt: now.addingTimeInterval(4), total: 110),
            ]),
            to: persistence
        )
        let vault = ReaderCookieVault(persistence: persistence)
        await vault.prepare(now: now.addingTimeInterval(60))

        var fresh = [cookie("SESSDATA", value: "auth", domain: ".signin.example")]
        for index in 0..<19 {
            fresh.append(cookie("filler\(index)", domain: ".signin.example"))
        }
        let returned = try await vault.upsert(
            cookies: fresh,
            host: "signin.example",
            allowEmptyRemoval: false,
            now: now.addingTimeInterval(120)
        )

        let stored = await vault.siteSummaries(now: now.addingTimeInterval(120))
            .first { $0.host == "signin.example" }?
            .cookies.count
        XCTAssertEqual(returned, stored)
    }
}

final class ReaderHistoryStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCanonicalURLDeduplicatesAndCountsVisits() async throws {
        let store = ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        await store.prepare(now: now)

        _ = try await store.record(
            url: "https://example.com/a?utm_source=x#top",
            title: "First",
            host: "example.com",
            now: now
        )
        _ = try await store.record(
            url: "https://example.com/a",
            title: "Second",
            host: "example.com",
            now: now.addingTimeInterval(60)
        )

        let entries = await store.all()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.visitCount, 2)
        XCTAssertEqual(entries.first?.title, "Second")
        XCTAssertEqual(entries.first?.host, "example.com")
    }

    func testRetentionDropsOldEntries() async throws {
        let store = ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        await store.prepare(now: now)

        _ = try await store.record(
            url: "https://example.com/old",
            title: "Old",
            host: "example.com",
            now: now.addingTimeInterval(-100 * 86_400)
        )
        _ = try await store.record(
            url: "https://example.com/new",
            title: "New",
            host: "example.com",
            now: now
        )

        let entries = await store.all()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.title, "New")
    }

    func testEntryCapKeepsNewestThreeHundred() async throws {
        let store = ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        await store.prepare(now: now)

        for index in 0..<(ReaderHistoryStore.maxEntries + 5) {
            _ = try await store.record(
                url: "https://example.com/story/\(index)",
                title: "Story \(index)",
                host: "example.com",
                now: now.addingTimeInterval(Double(index))
            )
        }

        let entries = await store.all()
        XCTAssertEqual(entries.count, ReaderHistoryStore.maxEntries)
        XCTAssertEqual(entries.first?.title, "Story \(ReaderHistoryStore.maxEntries + 4)")
    }

    func testRemoveAndClear() async throws {
        let store = ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        await store.prepare(now: now)
        let entry = try await store.record(
            url: "https://example.com/story",
            title: "Story",
            host: "example.com",
            now: now
        )

        try await store.remove(id: entry.id)
        let afterRemove = await store.all()
        XCTAssertTrue(afterRemove.isEmpty)

        _ = try await store.record(
            url: "https://example.com/story",
            title: "Story",
            host: "example.com",
            now: now
        )
        try await store.clear()
        let afterClear = await store.all()
        XCTAssertTrue(afterClear.isEmpty)
    }
}

/// Sign-out cleanup: an empty capture must not erase a saved sign-in unless the
/// page is the site's own log-out destination.
@MainActor
final class BrowserDataControllerCookieTests: XCTestCase {
    private func cookie(
        _ name: String,
        value: String = "v",
        domain: String = "example.com"
    ) -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/",
            .secure: "FALSE",
        ])!
    }

    private func makeController() -> BrowserDataController {
        BrowserDataController(
            vault: ReaderCookieVault(persistence: MemoryCookiePersistence()),
            historyStore: ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        )
    }

    func testEmptyCaptureKeepsSavedSiteByDefault() async {
        let controller = makeController()
        _ = await controller.capture(
            cookies: [cookie("SUB", domain: ".weibo.com")],
            host: "s.weibo.com",
            title: nil
        )
        XCTAssertTrue(controller.hasSite("s.weibo.com"))

        _ = await controller.capture(cookies: [], host: "s.weibo.com", title: nil)

        XCTAssertTrue(controller.hasSite("s.weibo.com"))
    }

    func testEmptyCaptureRemovesSavedSiteWhenLogoutIsExplicit() async {
        let controller = makeController()
        _ = await controller.capture(
            cookies: [cookie("SUB", domain: ".weibo.com")],
            host: "s.weibo.com",
            title: nil
        )
        XCTAssertTrue(controller.hasSite("s.weibo.com"))

        _ = await controller.capture(
            cookies: [],
            host: "s.weibo.com",
            title: nil,
            allowEmptyRemoval: true
        )

        XCTAssertFalse(controller.hasSite("s.weibo.com"))
        XCTAssertTrue(controller.sites.isEmpty)
    }

    func testLogoutDestinationRecognisesSignOutPaths() {
        XCTAssertTrue(ReaderNavigationPolicy.isLogoutDestination("https://passport.bilibili.com/login/exit?vmid=1"))
        XCTAssertTrue(ReaderNavigationPolicy.isLogoutDestination("https://passport.weibo.com/sso/signout"))
        XCTAssertTrue(ReaderNavigationPolicy.isLogoutDestination("https://weibo.com/logout"))
    }

    func testLogoutDestinationIgnoresOrdinaryPages() {
        XCTAssertFalse(ReaderNavigationPolicy.isLogoutDestination("https://www.bilibili.com/video/BV1xx"))
        XCTAssertFalse(ReaderNavigationPolicy.isLogoutDestination("https://passport.weibo.com/sso/signin"))
        XCTAssertFalse(ReaderNavigationPolicy.isLogoutDestination("https://example.com/exitpoll"))
        XCTAssertFalse(ReaderNavigationPolicy.isLogoutDestination(nil))
    }
}

/// Boundary guard: the cookies the vault builds must be accepted by WebKit's
/// ephemeral store, including a domain cookie and an HTTP-only cookie. A silent
/// drop here would look exactly like a failed sign-in replay.
final class ReaderCookieInjectionStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func cookie(
        _ name: String,
        value: String,
        domain: String,
        httpOnly: Bool = false
    ) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/",
            .secure: "TRUE",
        ]
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: properties)!
    }

    func testVaultCookiesSurviveInjectionIntoAnEphemeralStore() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        _ = try await vault.upsert(
            cookies: [
                cookie("SESSDATA", value: "auth", domain: ".bilibili.com", httpOnly: true),
                cookie("buvid3", value: "device", domain: "www.bilibili.com"),
            ],
            host: "b23.tv",
            allowEmptyRemoval: false,
            now: now
        )

        let hosts = ReaderCookieSiteScope.injectionHosts(for: "https://b23.tv/BV1xx")
        let cookies = await vault.cookies(forInjectionHosts: hosts, now: now)
        XCTAssertEqual(cookies.count, 2)

        let store = WKWebsiteDataStore.nonPersistent()
        let cookieStore = store.httpCookieStore
        for cookie in cookies {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                cookieStore.setCookie(cookie) { continuation.resume() }
            }
        }

        let installed = await cookieStore.allCookies()
        let identities = Set(installed.map { "\($0.name)|\($0.domain)|\($0.path)" })
        XCTAssertTrue(identities.contains("SESSDATA|.bilibili.com|/"), "\(identities)")
        XCTAssertTrue(identities.contains("buvid3|www.bilibili.com|/"), "\(identities)")
    }
}
