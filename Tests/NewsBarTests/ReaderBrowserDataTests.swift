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
        secure: Bool = false
    ) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
            .secure: secure ? "TRUE" : "FALSE",
        ]
        if let expires { properties[.expires] = expires }
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
        } + [cookie("SUB", value: "auth")]

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
