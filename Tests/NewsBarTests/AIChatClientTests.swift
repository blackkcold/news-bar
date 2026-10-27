import XCTest
@testable import NewsBar

final class AIChatClientTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [URLRequest] = []

        func append(_ request: URLRequest) {
            lock.lock()
            values.append(request)
            lock.unlock()
        }

        var last: URLRequest? {
            lock.lock()
            defer { lock.unlock() }
            return values.last
        }
    }

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.example.com")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }

    private func openAIConnection() -> ResolvedAIConnection {
        ResolvedAIConnection(
            baseURL: "https://api.example.com/v1/chat/completions",
            responseFormat: .openAI,
            authHeaderName: "Authorization",
            authHeaderPrefix: "Bearer ",
            apiVersion: nil
        )
    }

    func testOpenAIRequestShapeAndResponse() async throws {
        let recorder = Recorder()
        let payload = """
        {"choices":[{"message":{"content":"hello"},"finish_reason":"stop"}]}
        """
        let client = HTTPAIChatClient(
            connection: openAIConnection(),
            apiKey: "sk-test",
            model: "test-model",
            transport: { request in
                recorder.append(request)
                return (Data(payload.utf8), HTTPURLResponse(
                    url: URL(string: "https://api.example.com")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!)
            }
        )

        let result = try await client.complete(
            AIChatRequest(
                messages: [
                    AIChatMessage(role: .system, content: "system"),
                    AIChatMessage(role: .user, content: "user"),
                ],
                maxTokens: 321,
                temperature: 0.2
            )
        )

        XCTAssertEqual(result.text, "hello")
        XCTAssertFalse(result.truncated)

        let request = try XCTUnwrap(recorder.last)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "test-model")
        XCTAssertEqual(object["max_tokens"] as? Int, 321)
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[1]["content"], "user")
    }

    func testAnthropicRequestHoistsSystemAndReportsTruncation() async throws {
        let recorder = Recorder()
        let payload = """
        {"content":[{"type":"text","text":"partial"}],"stop_reason":"max_tokens"}
        """
        let connection = ResolvedAIConnection(
            baseURL: "https://api.anthropic.com/v1/messages",
            responseFormat: .anthropic,
            authHeaderName: "x-api-key",
            authHeaderPrefix: "",
            apiVersion: "2023-06-01"
        )
        let client = HTTPAIChatClient(
            connection: connection,
            apiKey: "key",
            model: "claude",
            transport: { request in
                recorder.append(request)
                return (Data(payload.utf8), HTTPURLResponse(
                    url: URL(string: "https://api.anthropic.com")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!)
            }
        )

        let result = try await client.complete(
            AIChatRequest(messages: [
                AIChatMessage(role: .system, content: "sys"),
                AIChatMessage(role: .user, content: "ask"),
            ])
        )

        XCTAssertEqual(result.text, "partial")
        XCTAssertTrue(result.truncated)

        let request = try XCTUnwrap(recorder.last)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["system"] as? String, "sys")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"], "user")
    }

    func testMapsUnauthorizedAndRateLimited() async {
        for (status, expected) in [(401, AIChatError.unauthorized), (429, AIChatError.rateLimited)] {
            let client = HTTPAIChatClient(
                connection: openAIConnection(),
                apiKey: "k",
                model: "m",
                transport: { _ in (Data(), self.response(status)) }
            )
            do {
                _ = try await client.complete(AIChatRequest(messages: [AIChatMessage(role: .user, content: "x")]))
                XCTFail("expected \(expected)")
            } catch let error as AIChatError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testMapsTimeout() async {
        let client = HTTPAIChatClient(
            connection: openAIConnection(),
            apiKey: "k",
            model: "m",
            transport: { _ in throw URLError(.timedOut) }
        )
        do {
            _ = try await client.complete(AIChatRequest(messages: [AIChatMessage(role: .user, content: "x")]))
            XCTFail("expected timeout")
        } catch let error as AIChatError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
