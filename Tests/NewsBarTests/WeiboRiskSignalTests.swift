import XCTest
@testable import NewsBar

final class WeiboRiskSignalTests: XCTestCase {
    private func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    func testHTTPRateLimitStatuses() {
        for status in [418, 429, 403, 432] {
            XCTAssertEqual(
                WeiboRiskSignal.classify(
                    statusCode: status,
                    data: Data(),
                    contentType: "application/json",
                    error: nil
                ),
                .rateLimited
            )
        }
    }

    func testServerError() {
        XCTAssertEqual(
            WeiboRiskSignal.classify(
                statusCode: 503,
                data: Data(),
                contentType: "application/json",
                error: nil
            ),
            .server
        )
    }

    func testAuthRedirectWithMinusOneHundred() {
        let data = json(["ok": -100, "url": "https://weibo.com/login.php?url=x"])
        XCTAssertEqual(
            WeiboRiskSignal.classify(
                statusCode: 200,
                data: data,
                contentType: "application/json",
                error: nil
            ),
            .authExpired
        )
    }

    func testAuthRedirectWithZeroAndPassport() {
        let data = json(["ok": 0, "url": "https://passport.weibo.com/sso/signin"])
        XCTAssertEqual(
            WeiboRiskSignal.classify(
                statusCode: 200,
                data: data,
                contentType: "application/json",
                error: nil
            ),
            .authExpired
        )
    }

    func testHTMLChallengePage() {
        let data = "<!DOCTYPE html><html><body>verify</body></html>".data(using: .utf8) ?? Data()
        XCTAssertEqual(
            WeiboRiskSignal.classify(
                statusCode: 200,
                data: data,
                contentType: "text/html",
                error: nil
            ),
            .challenge
        )
    }

    func testRiskPhraseInErrorEnvelope() {
        let data = json(["ok": 0, "message": "访问过于频繁，请稍后再试"])
        XCTAssertEqual(
            WeiboRiskSignal.classify(
                statusCode: 200,
                data: data,
                contentType: "application/json",
                error: nil
            ),
            .rateLimited
        )
    }

    func testNormalFeedWithRiskPhraseInPostTextIsOK() {
        let data = json([
            "ok": 1,
            "data": [
                "list": [
                    ["idstr": "1", "text_raw": "请稍后再试，这只是帖子正文"]
                ]
            ],
        ])
        XCTAssertEqual(
            WeiboRiskSignal.classify(
                statusCode: 200,
                data: data,
                contentType: "application/json",
                error: nil
            ),
            .ok
        )
    }

    func testNetworkError() {
        XCTAssertEqual(
            WeiboRiskSignal.classify(
                statusCode: nil,
                data: nil,
                contentType: nil,
                error: URLError(.notConnectedToInternet)
            ),
            .network
        )
    }

    func testSuccessfulPayload() {
        XCTAssertEqual(
            WeiboRiskSignal.classify(
                statusCode: 200,
                data: json(["ok": 1, "data": ["list": []]]),
                contentType: "application/json",
                error: nil
            ),
            .ok
        )
    }

    func testNilBodyIsUnknown() {
        XCTAssertEqual(
            WeiboRiskSignal.classify(
                statusCode: 200,
                data: nil,
                contentType: nil,
                error: nil
            ),
            .unknown
        )
    }
}
