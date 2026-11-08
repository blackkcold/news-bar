import XCTest
@testable import NewsBar

private final class RelevanceURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var lastRequest: URLRequest?
    static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            Self.lastBody = data
        } else {
            Self.lastBody = request.httpBody
        }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
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

final class WeiboRelevanceDeciderTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        RelevanceURLProtocol.handler = nil
        RelevanceURLProtocol.lastRequest = nil
        RelevanceURLProtocol.lastBody = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelevanceURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        RelevanceURLProtocol.handler = nil
        session = nil
        super.tearDown()
    }

    private func client() -> WeiboSystemOneClient {
        WeiboSystemOneClient(
            kind: .openCodeFree,
            endpoint: URL(string: "https://example.test/v1/systemone")!,
            model: "jev-1.13-free",
            authorization: nil,
            timeout: 2,
            session: session
        )
    }

    private func respond(
        status: Int = 200,
        body: String
    ) {
        RelevanceURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }
    }

    func testParsesTheRealSystemOneResponse() throws {
        let result = try WeiboSystemOneClient.parse(
            Data(
                """
                {"model":"jev-1.13-free","answers":{
                  "is_ad":{"type":"noul","noul":0.05},
                  "is_off":{"type":"noul","noul":0.1},
                  "topic":{"type":"choice","choice":"phone","confidence":1,
                    "probabilities":{"phone":1,"pc":0,"ai":0,"software":0,"auto":0,"life":0,"ent":0,"policy":0,"other":0}},
                  "info":{"type":"score","score":0.74,"confidence":0.58}
                },"usage":{"input_tokens":561,"output_tokens":128,"cost":0}}
                """.utf8
            ),
            fallbackModel: "jev-1.13-free"
        )
        XCTAssertEqual(result.isAd, 0.05, accuracy: 0.001)
        XCTAssertEqual(result.isOffTopic, 0.10, accuracy: 0.001)
        XCTAssertEqual(result.topic, "phone")
        XCTAssertEqual(result.topicConfidence, 1)
        XCTAssertEqual(result.infoScore, 0.74)
        XCTAssertEqual(result.inputTokens, 561)
        XCTAssertEqual(result.costMicros, 0)
    }

    func testDecisionSendsFourAtomicQuestionsAndStructuredState() async throws {
        respond(
            body: """
            {"model":"jev-1.13-free","answers":{
              "is_ad":{"type":"noul","noul":0.1},
              "is_off":{"type":"noul","noul":0.9},
              "topic":{"type":"choice","choice":"life","probabilities":{"life":0.9}},
              "info":{"type":"score","score":0.2}
            }}
            """
        )
        let result = try await client().decide(
            text: "今天吃饺子",
            context: WeiboDecisionContext(
                screenName: "钟文泽",
                recentTopics: ["phone"],
                isLongText: false
            )
        )
        XCTAssertEqual(result.topic, "life")

        let body = try XCTUnwrap(RelevanceURLProtocol.lastBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["model"] as? String, "jev-1.13-free")
        let state = try XCTUnwrap(object["state"] as? [String: Any])
        XCTAssertEqual(state["account"] as? String, "钟文泽")
        XCTAssertEqual(state["text"] as? String, "今天吃饺子")
        let topics = try XCTUnwrap(state["account_recent_topics"] as? [String])
        XCTAssertEqual(topics, ["phone"])
        let questions = try XCTUnwrap(object["questions"] as? [String: Any])
        XCTAssertEqual(Set(questions.keys), Set(["is_ad", "is_off", "topic", "info"]))
    }

    func testHTTPFailureIsSurfacedAsAnError() async {
        respond(status: 503, body: "{}")
        do {
            _ = try await client().decide(
                text: "x",
                context: WeiboDecisionContext(
                    screenName: "a",
                    recentTopics: [],
                    isLongText: false
                )
            )
            XCTFail("expected an error")
        } catch let error as WeiboDecisionError {
            XCTAssertEqual(error, .httpStatus(503))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testMalformedResponseIsAnError() async {
        respond(body: "not json")
        do {
            _ = try await client().decide(
                text: "x",
                context: WeiboDecisionContext(
                    screenName: "a",
                    recentTopics: [],
                    isLongText: false
                )
            )
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is WeiboDecisionError)
        }
    }

    func testCircuitBreakerOpensAfterThreeFailuresAndCoolsDown() {
        var breaker = WeiboRelevanceCircuitBreaker()
        let now = Date()
        XCTAssertTrue(breaker.canRequest(now: now))
        breaker.noteFailure(now: now)
        breaker.noteFailure(now: now)
        XCTAssertTrue(breaker.canRequest(now: now))
        breaker.noteFailure(now: now)
        XCTAssertTrue(breaker.isOpen(now: now))
        XCTAssertFalse(breaker.canRequest(now: now))
        XCTAssertTrue(breaker.canRequest(now: now.addingTimeInterval(11 * 60)))
    }

    func testCircuitBreakerResetAfterSuccess() {
        var breaker = WeiboRelevanceCircuitBreaker()
        let now = Date()
        breaker.noteFailure(now: now)
        breaker.noteFailure(now: now)
        breaker.noteSuccess()
        breaker.noteFailure(now: now)
        XCTAssertFalse(breaker.isOpen(now: now))
    }
}
