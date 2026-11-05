import XCTest
@testable import NewsBar

final class ReaderImageFetchPolicyTests: XCTestCase {
    private actor ResolverCounter {
        private(set) var count = 0
        func called() { count += 1 }
    }

    func testCrossOriginRefererDisclosesOnlyOrigin() throws {
        let destination = try XCTUnwrap(URL(string: "https://cdn.example.com/image.png"))
        let value = ReaderImageFetchPolicy.referer(
            article: "https://news.example.com/private/article?token=fictional#fragment",
            destination: destination
        )
        XCTAssertEqual(value, "https://news.example.com/")
    }

    func testSameOriginRefererKeepsPathAndQueryButNotFragment() throws {
        let destination = try XCTUnwrap(URL(string: "https://news.example.com/image.png"))
        let value = ReaderImageFetchPolicy.referer(
            article: "https://news.example.com/article?id=12#fragment", destination: destination
        )
        XCTAssertEqual(value, "https://news.example.com/article?id=12")
    }

    func testRedirectHeaderRebuildNeverSendsCookiesToAnotherDomain() throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".example.com", .path: "/", .name: "fixture", .value: "fictional", .secure: "TRUE"
        ]))
        let destination = try XCTUnwrap(URL(string: "https://thirdparty.org/image.png"))
        var request = URLRequest(url: destination)
        request.setValue("fixture=fictional", forHTTPHeaderField: "Cookie")
        request.setValue("https://news.example.com/private?token=fictional", forHTTPHeaderField: "Referer")
        let rebuilt = ReaderImageFetchPolicy.prepare(
            request, cookies: [cookie], article: "https://news.example.com/private?token=fictional"
        )
        XCTAssertNil(rebuilt.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(rebuilt.value(forHTTPHeaderField: "Referer"), "https://news.example.com/")
    }

    func testCookieIsReplayedOnlyForItsAllowedHostAndPath() throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".example.com", .path: "/assets", .name: "fixture", .value: "fictional", .secure: "TRUE"
        ]))
        let matching = try XCTUnwrap(URL(string: "https://cdn.example.com/assets/image.png"))
        let mismatchedPath = try XCTUnwrap(URL(string: "https://cdn.example.com/assets-other/image.png"))
        let allowed = ReaderImageFetchPolicy.prepare(URLRequest(url: matching), cookies: [cookie], article: nil)
        let rejected = ReaderImageFetchPolicy.prepare(URLRequest(url: mismatchedPath), cookies: [cookie], article: nil)
        XCTAssertEqual(allowed.value(forHTTPHeaderField: "Cookie"), "fixture=fictional")
        XCTAssertNil(rejected.value(forHTTPHeaderField: "Cookie"))
    }

    func testDestinationAllowsOnlyPublicOrExplicitlyAuthorizedFakeIP() async throws {
        let url = try XCTUnwrap(URL(string: "https://image.example.com/a.png"))
        let publicAllowed = await ReaderImageFetchPolicy.allows(
            url, proxyResolves: false, resolve: { _ in .publicDestination }, allowsFakeIP: { false }
        )
        let privateAllowed = await ReaderImageFetchPolicy.allows(
            url, proxyResolves: false, resolve: { _ in .privateDestination }, allowsFakeIP: { true }
        )
        let fakeAllowed = await ReaderImageFetchPolicy.allows(
            url, proxyResolves: false, resolve: { _ in .fakeIPDestination }, allowsFakeIP: { true }
        )
        let fakeBlocked = await ReaderImageFetchPolicy.allows(
            url, proxyResolves: false, resolve: { _ in .fakeIPDestination }, allowsFakeIP: { false }
        )
        XCTAssertTrue(publicAllowed)
        XCTAssertFalse(privateAllowed)
        XCTAssertTrue(fakeAllowed)
        XCTAssertFalse(fakeBlocked)
    }

    func testTrustedProxyOwnsDNSResolutionButNotURLValidation() async throws {
        let counter = ResolverCounter()
        let url = try XCTUnwrap(URL(string: "https://image.example.com/a.png"))
        let allowed = await ReaderImageFetchPolicy.allows(
            url, proxyResolves: true,
            resolve: { _ in await counter.called(); return .privateDestination },
            allowsFakeIP: { false }
        )
        let badURL = try XCTUnwrap(URL(string: "https://127.0.0.1/a.png"))
        let invalid = await ReaderImageFetchPolicy.allows(
            badURL, proxyResolves: true,
            resolve: { _ in await counter.called(); return .publicDestination },
            allowsFakeIP: { true }
        )
        XCTAssertTrue(allowed)
        XCTAssertFalse(invalid)
        let calls = await counter.count
        XCTAssertEqual(calls, 0)
    }
}
