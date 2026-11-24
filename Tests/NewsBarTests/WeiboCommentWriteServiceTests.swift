import XCTest
@testable import NewsBar

private final class WeiboWriteURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var error: Error?

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

    /// URLSession turns `httpBody` into a stream before URLProtocol sees it.
    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

final class WeiboCommentWriteServiceTests: XCTestCase {
    private var service: WeiboCommentWriteService!

    private let credentials = WeiboCredentials(
        desktopCookieHeader: "SUB=desktop; XSRF-TOKEN=token",
        mobileCookieHeader: nil,
        hasDesktopLogin: true,
        hasMobileLogin: false
    )

    private let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        WeiboWriteURLProtocol.handler = nil
        WeiboWriteURLProtocol.requests = []
        WeiboWriteURLProtocol.error = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WeiboWriteURLProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        service = WeiboCommentWriteService(session: URLSession(configuration: configuration))
    }

    override func tearDown() {
        WeiboWriteURLProtocol.handler = nil
        WeiboWriteURLProtocol.requests = []
        WeiboWriteURLProtocol.error = nil
        service = nil
        super.tearDown()
    }

    // MARK: - Likes

    func testLikeSendsUpdateLikeWithCapturedFields() async throws {
        respond(#"{"ok":1,"result":true}"#)

        let outcome = await service.setLike(
            commentID: "123",
            liked: true,
            credentials: credentials,
            now: createdAt
        )

        XCTAssertEqual(outcome, .liked(true))
        let request = try XCTUnwrap(WeiboWriteURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://weibo.com/ajax/statuses/updateLike")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-xsrf-token"), "token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Requested-With"), "XMLHttpRequest")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("SUB=desktop") == true)

        let body = String(
            decoding: try XCTUnwrap(WeiboWriteURLProtocol.body(of: request)),
            as: UTF8.self
        )
        XCTAssertEqual(body, "object_id=123&object_type=comment")
    }

    func testUnlikeSendsDestroyLike() async throws {
        respond(#"{"result":true,"ok":1}"#)

        let outcome = await service.setLike(
            commentID: "123",
            liked: false,
            credentials: credentials,
            now: createdAt
        )

        XCTAssertEqual(outcome, .liked(false))
        let request = try XCTUnwrap(WeiboWriteURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://weibo.com/ajax/statuses/destroyLike")
    }

    func testLikeBudgetStopsAfterTwelve() async throws {
        respond(#"{"ok":1,"result":true}"#)
        var now = createdAt

        for _ in 0..<12 {
            let outcome = await service.setLike(
                commentID: "1",
                liked: true,
                credentials: credentials,
                now: now
            )
            XCTAssertEqual(outcome, .liked(true))
            now = now.addingTimeInterval(3)
        }

        let blocked = await service.setLike(
            commentID: "1",
            liked: true,
            credentials: credentials,
            now: now
        )

        guard case .failure(.localLimit(let retryAfter)) = blocked else {
            return XCTFail("expected localLimit, got \(blocked)")
        }
        XCTAssertGreaterThan(retryAfter, 0)
        XCTAssertEqual(WeiboWriteURLProtocol.requests.count, 12)
    }

    func testTwoWritesCloserThanSerialIntervalBlockTheSecond() async throws {
        respond(#"{"ok":1,"result":true}"#)

        _ = await service.setLike(
            commentID: "1",
            liked: true,
            credentials: credentials,
            now: createdAt
        )
        let second = await service.setLike(
            commentID: "2",
            liked: true,
            credentials: credentials,
            now: createdAt.addingTimeInterval(1)
        )

        guard case .failure(.localLimit(let retryAfter)) = second else {
            return XCTFail("expected localLimit, got \(second)")
        }
        XCTAssertEqual(retryAfter, 1.5, accuracy: 0.01)
        XCTAssertEqual(WeiboWriteURLProtocol.requests.count, 1)
    }

    func testMissingXSRFIsAuthRequiredAndSendsNothing() async throws {
        let weak = WeiboCredentials(
            desktopCookieHeader: "SUB=desktop",
            mobileCookieHeader: nil,
            hasDesktopLogin: true,
            hasMobileLogin: false
        )

        let outcome = await service.setLike(
            commentID: "1",
            liked: true,
            credentials: weak,
            now: createdAt
        )

        XCTAssertEqual(outcome, .failure(.authRequired))
        XCTAssertTrue(WeiboWriteURLProtocol.requests.isEmpty)
    }

    func testForbiddenMapsToRateLimited() async throws {
        respond(#"{"ok":0}"#, status: 403)

        let outcome = await service.setLike(
            commentID: "1",
            liked: true,
            credentials: credentials,
            now: createdAt
        )

        guard case .failure(.rateLimited) = outcome else {
            return XCTFail("expected rateLimited, got \(outcome)")
        }
    }

    func testFalseResultIsRejected() async throws {
        respond(#"{"ok":1,"result":false}"#)

        let outcome = await service.setLike(
            commentID: "1",
            liked: true,
            credentials: credentials,
            now: createdAt
        )

        XCTAssertEqual(outcome, .failure(.unknown))
    }

    // MARK: - Replies

    func testReplySendsCapturedFormAndParsesCreatedComment() async throws {
        respond(
            """
            {"ok":1,"data":{"id":5368788372427081,"mid":"5368788372427081",
            "created_at":"Tue Nov 24 14:39:18 +0800 2026","text":"测试",
            "like_counts":0,
            "user":{"id":2991196451,"idstr":"2991196451","screen_name":"YangHaoRan_",
            "profile_image_url":"https://example.com/a.jpg"}}}
            """
        )

        let outcome = await service.reply(
            postMID: "999",
            text: "测试",
            credentials: credentials,
            now: createdAt
        )

        guard case .replied(let comment) = outcome else {
            return XCTFail("expected replied, got \(outcome)")
        }
        XCTAssertEqual(comment.id, "5368788372427081")
        XCTAssertEqual(comment.text, "测试")
        XCTAssertEqual(comment.screenName, "YangHaoRan_")
        XCTAssertEqual(comment.uid, "2991196451")

        let request = try XCTUnwrap(WeiboWriteURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://weibo.com/ajax/comments/create")
        let body = String(
            decoding: try XCTUnwrap(WeiboWriteURLProtocol.body(of: request)),
            as: UTF8.self
        )
        XCTAssertTrue(body.contains("id=999"))
        XCTAssertTrue(body.contains("comment=%E6%B5%8B%E8%AF%95"))
        XCTAssertTrue(body.contains("is_repost=0"))
        XCTAssertTrue(body.contains("is_comment=0"))
    }

    func testEmptyReplyIsRejectedWithoutRequest() async throws {
        let outcome = await service.reply(
            postMID: "999",
            text: "   ",
            credentials: credentials,
            now: createdAt
        )

        XCTAssertEqual(outcome, .failure(.invalidInput))
        XCTAssertTrue(WeiboWriteURLProtocol.requests.isEmpty)
    }

    func testReplyBudgetStopsAfterSix() async throws {
        respond(
            """
            {"ok":1,"data":{"id":1,"mid":"1","created_at":"Tue Nov 24 14:39:18 +0800 2026",
            "text":"x","like_counts":0,
            "user":{"id":1,"idstr":"1","screen_name":"a"}}}
            """
        )
        var now = createdAt

        for index in 0..<6 {
            let outcome = await service.reply(
                postMID: "999",
                text: "第\(index)条",
                credentials: credentials,
                now: now
            )
            guard case .replied = outcome else {
                return XCTFail("expected replied, got \(outcome)")
            }
            now = now.addingTimeInterval(3)
        }

        let blocked = await service.reply(
            postMID: "999",
            text: "第七条",
            credentials: credentials,
            now: now
        )

        guard case .failure(.localLimit) = blocked else {
            return XCTFail("expected localLimit, got \(blocked)")
        }
        XCTAssertEqual(WeiboWriteURLProtocol.requests.count, 6)
    }

    // MARK: - Helpers

    private func respond(_ json: String, status: Int = 200) {
        WeiboWriteURLProtocol.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, Data(json.utf8))
        }
    }
}
