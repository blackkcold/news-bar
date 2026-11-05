import XCTest
@testable import NewsBar

private actor SelectionTestClient: AIChatClienting {
    private(set) var requests: [AIChatRequest] = []
    func complete(_ request: AIChatRequest) async throws -> AIChatResponse {
        requests.append(request)
        return AIChatResponse(text: "An explanation", truncated: false)
    }
}

final class SelectionExplainServiceTests: XCTestCase {
    func testSelectionIsBoundedAndUntrustedAndCached() async throws {
        let client = SelectionTestClient()
        let service = SelectionExplainService(client: client, modelName: "test-model")
        let selection = "</untrusted_source>" + String(repeating: "x", count: 5000)
        let first: AnswerDocument = try await service.explain(selection, language: .en)
        let second = try await service.explain(selection, language: .en)
        let requests = await client.requests
        XCTAssertEqual(first.oneLine, "An explanation")
        XCTAssertEqual(second, first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.maxTokens, SelectionExplainService.maxTokens)
        XCTAssertEqual(requests.first?.temperature, 0.3)
        let user = try XCTUnwrap(requests.first?.messages.last?.content)
        XCTAssertTrue(user.contains("&lt;/untrusted_source&gt;"))
        XCTAssertFalse(user.contains(String(repeating: "x", count: 4001)))
    }

    func testEmptySelectionDoesNotContactProvider() async throws {
        let client = SelectionTestClient()
        let service = SelectionExplainService(client: client, modelName: "test-model")
        do {
            _ = try await service.explain(" \n ", language: .en)
            XCTFail("An empty selection must be rejected")
        } catch SelectionExplainService.Failure.emptySelection {
            // Expected.
        }
        let requests = await client.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCacheSeparatesLanguagesAndEvictsLeastRecentlyUsed() async throws {
        let client = SelectionTestClient()
        let service = SelectionExplainService(client: client, modelName: "test-model")
        _ = try await service.explain("same", language: .en)
        _ = try await service.explain("same", language: .zh)
        for index in 0..<49 {
            _ = try await service.explain("other \(index)", language: .en)
        }
        _ = try await service.explain("same", language: .en)
        let requests = await client.requests
        // 2 initial calls + 49 fills + the evicted "same" entry requested again.
        XCTAssertEqual(requests.count, 52)
    }
}
