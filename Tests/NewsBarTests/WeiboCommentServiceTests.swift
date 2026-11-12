import XCTest
@testable import NewsBar

private final class WeiboCommentURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var requests: [URLRequest] = []
    static var error: Error?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        if let error = Self.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class WeiboCommentServiceTests: XCTestCase {
    private var service: WeiboUserFeedService!

    private var desktopCredentials: WeiboCredentials {
        WeiboCredentials(
            desktopCookieHeader: "SUB=desktop; XSRF-TOKEN=token",
            mobileCookieHeader: nil,
            hasDesktopLogin: true,
            hasMobileLogin: false
        )
    }

    private var mobileCredentials: WeiboCredentials {
        WeiboCredentials(
            desktopCookieHeader: nil,
            mobileCookieHeader: "SUB=mobile",
            hasDesktopLogin: false,
            hasMobileLogin: true
        )
    }

    private var bothCredentials: WeiboCredentials {
        WeiboCredentials(
            desktopCookieHeader: "SUB=desktop",
            mobileCookieHeader: "SUB=mobile",
            hasDesktopLogin: true,
            hasMobileLogin: true
        )
    }

    override func setUp() async throws {
        try await super.setUp()
        WeiboCommentURLProtocol.requests = []
        WeiboCommentURLProtocol.handler = nil
        WeiboCommentURLProtocol.error = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WeiboCommentURLProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        service = WeiboUserFeedService(session: URLSession(configuration: configuration))
    }

    override func tearDown() async throws {
        WeiboCommentURLProtocol.handler = nil
        WeiboCommentURLProtocol.requests = []
        WeiboCommentURLProtocol.error = nil
        service = nil
        try await super.tearDown()
    }

    private func response(_ request: URLRequest, status: Int = 200) throws -> HTTPURLResponse {
        try XCTUnwrap(
            HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )
    }

    private func desktopPayload() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "ok": 1,
            "data": [
                [
                    "idstr": "11",
                    "text": "第一条评论",
                    "created_at": "刚刚",
                    "user": ["id": 77, "screen_name": "读者"],
                ],
            ],
            "total_number": 2,
            "max_id": 12345,
        ])
    }

    func testDesktopRequestUsesExistingSessionAndCursor() async throws {
        WeiboCommentURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.host, "weibo.com")
            XCTAssertEqual(url.path, "/ajax/statuses/buildComments")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(items.first(where: { $0.name == "id" })?.value, "9001")
            XCTAssertEqual(items.first(where: { $0.name == "uid" })?.value, "77")
            XCTAssertEqual(items.first(where: { $0.name == "max_id" })?.value, "500")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "SUB=desktop; XSRF-TOKEN=token")
            return (try self.response(request), try self.desktopPayload())
        }

        let outcome = await service.fetchComments(
            mid: "9001",
            uid: "77",
            authorUID: "77",
            cursor: "500",
            credentials: desktopCredentials,
            now: Date()
        )

        guard case .success(let page, _) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(page.tier, .desktop)
        XCTAssertEqual(page.total, 2)
        XCTAssertEqual(page.nextCursor, "12345")
        XCTAssertEqual(page.comments.first?.text, "第一条评论")
        XCTAssertTrue(page.comments.first?.isAuthor == true)
    }

    func testMobileOnlyCredentialsUseFreeMobileEndpoint() async throws {
        WeiboCommentURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.host, "m.weibo.cn")
            XCTAssertEqual(url.path, "/comments/hotflow")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(items.first(where: { $0.name == "id" })?.value, "9002")
            XCTAssertEqual(items.first(where: { $0.name == "max_id" })?.value, "88")
            let body = try JSONSerialization.data(withJSONObject: [
                ["id": 21, "text": "移动评论", "created_at": "1分钟前", "user": ["id": 8, "screen_name": "读者乙"]],
            ])
            return (try self.response(request), body)
        }

        let outcome = await service.fetchComments(
            mid: "9002",
            uid: "88",
            authorUID: "88",
            cursor: "88",
            credentials: mobileCredentials,
            now: Date()
        )

        guard case .success(let page, _) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(page.tier, .mobile)
        XCTAssertNil(page.total)
        XCTAssertEqual(page.comments.first?.text, "移动评论")
    }

    func testDesktopAuthFailureFallsBackToMobileOnlyOnce() async throws {
        WeiboCommentURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.host == "weibo.com" {
                return (try self.response(request), Data(#"{"ok":-100}"#.utf8))
            }
            XCTAssertEqual(url.host, "m.weibo.cn")
            let body = try JSONSerialization.data(withJSONObject: [
                ["id": 31, "text": "fallback", "user": ["id": 9, "screen_name": "读者丙"]],
            ])
            return (try self.response(request), body)
        }

        let outcome = await service.fetchComments(
            mid: "9003",
            uid: "99",
            authorUID: nil,
            cursor: nil,
            credentials: bothCredentials,
            now: Date()
        )

        guard case .success(let page, _) = outcome else {
            return XCTFail("expected fallback success, got \(outcome)")
        }
        XCTAssertEqual(page.tier, .mobile)
        XCTAssertEqual(WeiboCommentURLProtocol.requests.count, 2)
    }

    func testDesktopShapeChangeFallsBackToFreeMobile() async throws {
        WeiboCommentURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.host == "weibo.com" {
                return (try self.response(request), Data(#"{"ok":1,"unexpected":true}"#.utf8))
            }
            let body = try JSONSerialization.data(withJSONObject: [
                ["id": 41, "text": "mobile fallback", "user": ["id": 10, "screen_name": "读者丁"]],
            ])
            return (try self.response(request), body)
        }

        let outcome = await service.fetchComments(
            mid: "9004",
            uid: "100",
            authorUID: nil,
            cursor: "77",
            credentials: bothCredentials,
            now: Date()
        )

        guard case .success(let page, _) = outcome else {
            return XCTFail("expected mobile fallback, got \(outcome)")
        }
        XCTAssertEqual(page.tier, .mobile)
        XCTAssertEqual(page.comments.first?.text, "mobile fallback")
        XCTAssertEqual(WeiboCommentURLProtocol.requests.count, 2)
        let mobileURL = try XCTUnwrap(WeiboCommentURLProtocol.requests.last?.url)
        let items = URLComponents(url: mobileURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "max_id" })?.value, "77")
    }

    func testNoCredentialsFailsWithoutNetwork() async {
        let outcome = await service.fetchComments(
            mid: "1",
            uid: "2",
            authorUID: nil,
            cursor: nil,
            credentials: .none,
            now: Date()
        )
        XCTAssertEqual(outcome, .failure(.authRequired))
        XCTAssertTrue(WeiboCommentURLProtocol.requests.isEmpty)
    }

    func testRateLimitStopsWithoutMobileFallback() async throws {
        WeiboCommentURLProtocol.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "7", "Content-Type": "application/json"]
                )
            )
            return (response, Data(#"{"ok":0}"#.utf8))
        }

        let outcome = await service.fetchComments(
            mid: "1",
            uid: "2",
            authorUID: nil,
            cursor: nil,
            credentials: bothCredentials,
            now: Date()
        )
        XCTAssertEqual(outcome, .failure(.rateLimited(retryAfter: 7)))
        XCTAssertEqual(WeiboCommentURLProtocol.requests.count, 1, "A rate limit must not be retried on another endpoint")
    }

    func testShapeChangeIsReportedAsParseChanged() async throws {
        WeiboCommentURLProtocol.handler = { request in
            (try self.response(request), Data(#"{"ok":1,"unexpected":true}"#.utf8))
        }
        let outcome = await service.fetchComments(
            mid: "1",
            uid: "2",
            authorUID: nil,
            cursor: nil,
            credentials: desktopCredentials,
            now: Date()
        )
        XCTAssertEqual(outcome, .failure(.parseChanged))
    }

    func testHTMLChallengeIsReportedAsChallenge() async throws {
        WeiboCommentURLProtocol.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )
            )
            return (response, Data("<!doctype html><html>verify</html>".utf8))
        }
        let outcome = await service.fetchComments(
            mid: "1",
            uid: "2",
            authorUID: nil,
            cursor: nil,
            credentials: desktopCredentials,
            now: Date()
        )
        XCTAssertEqual(outcome, .failure(.challenge))
    }
}
