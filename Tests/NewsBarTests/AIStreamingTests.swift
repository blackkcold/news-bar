import XCTest
@testable import NewsBar

/// Streaming is the last unshipped piece of P1. The contract under test:
/// frames survive arbitrary chunk boundaries, both wire formats map to the same
/// events, and a provider that refuses `stream: true` falls back instead of
/// failing the answer.
final class AIStreamingTests: XCTestCase {
    // MARK: - SSE framing

    func testDrainReturnsCompleteFramesAndKeepsThePartialTail() {
        var buffer = "event: message\ndata: one\n\ndata: two\n\ndata: par"
        let frames = SSEDecoder.drain(&buffer)
        XCTAssertEqual(frames, [
            SSEFrame(event: "message", data: "one"),
            SSEFrame(event: nil, data: "two")
        ])
        XCTAssertEqual(buffer, "data: par")
    }

    func testDrainJoinsMultiLineDataAndIgnoresComments() {
        var buffer = ": keep-alive\ndata: a\ndata: b\n\n"
        let frames = SSEDecoder.drain(&buffer)
        XCTAssertEqual(frames, [SSEFrame(event: nil, data: "a\nb")])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDrainHandlesCRLFBoundaries() {
        var buffer = "data: one\r\n\r\ndata: two\r\n\r\n"
        let frames = SSEDecoder.drain(&buffer)
        XCTAssertEqual(frames.map(\.data), ["one", "two"])
    }

    // MARK: - OpenAI format

    func testOpenAIDeltaBecomesText() {
        let frame = SSEFrame(event: nil, data: #"{"choices":[{"delta":{"content":"你好"},"finish_reason":null}]}"#)
        XCTAssertEqual(
            AIStreamParser.events(from: frame, format: .openAI),
            [.text("你好")]
        )
    }

    func testOpenAIFinishAndUsageAreReported() {
        let frame = SSEFrame(
            event: nil,
            data: #"{"choices":[{"delta":{},"finish_reason":"length"}],"usage":{"prompt_tokens":10,"completion_tokens":20}}"#
        )
        XCTAssertEqual(
            AIStreamParser.events(from: frame, format: .openAI),
            [.usage(AIUsage(inputTokens: 10, outputTokens: 20)), .finished(truncated: true)]
        )
    }

    func testOpenAIDoneEndsTheStreamOnce() {
        let frame = SSEFrame(event: nil, data: "[DONE]")
        XCTAssertEqual(AIStreamParser.events(from: frame, format: .openAI), [.finished(truncated: false)])
    }

    // MARK: - Anthropic format

    func testAnthropicTextDeltaBecomesText() {
        let frame = SSEFrame(
            event: "content_block_delta",
            data: #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"一段"}}"#
        )
        XCTAssertEqual(AIStreamParser.events(from: frame, format: .anthropic), [.text("一段")])
    }

    func testAnthropicMessageDeltaReportsUsageAndStopReason() {
        let frame = SSEFrame(
            event: "message_delta",
            data: #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":42}}"#
        )
        XCTAssertEqual(
            AIStreamParser.events(from: frame, format: .anthropic),
            [.usage(AIUsage(inputTokens: 0, outputTokens: 42)), .finished(truncated: true)]
        )
    }

    func testAnthropicMessageStopEndsTheStream() {
        let frame = SSEFrame(event: "message_stop", data: #"{"type":"message_stop"}"#)
        XCTAssertEqual(AIStreamParser.events(from: frame, format: .anthropic), [.finished(truncated: false)])
    }

    func testUnknownEventIsIgnored() {
        let frame = SSEFrame(event: "ping", data: #"{"type":"ping"}"#)
        XCTAssertTrue(AIStreamParser.events(from: frame, format: .anthropic).isEmpty)
        XCTAssertTrue(AIStreamParser.events(from: frame, format: .openAI).isEmpty)
    }

    // MARK: - Request building

    func testStreamingRequestAsksForTheStreamAndUsage() throws {
        let built = try AIRequestBuilder.build(
            connection: AIProvider.deepseek.resolvedConnection(),
            apiKey: "k",
            model: "m",
            messages: [AIChatMessage(role: .user, content: "hi")],
            maxTokens: 100,
            temperature: 0.2,
            thinking: .providerDefault,
            timeout: 30,
            stream: true
        )
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(built.request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
    }

    func testNonStreamingRequestStaysUnchanged() throws {
        let built = try AIRequestBuilder.build(
            connection: AIProvider.minimaxAPI.resolvedConnection(),
            apiKey: "k",
            model: "m",
            messages: [AIChatMessage(role: .user, content: "hi")],
            maxTokens: 100,
            temperature: 0.2,
            thinking: .providerDefault,
            timeout: 30
        )
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(built.request.httpBody)) as? [String: Any]
        )
        XCTAssertNil(body["stream"])
        XCTAssertNil(body["stream_options"])
    }

    // MARK: - Reveal budget

    func testRevealedDocumentStopsInsideTheBudget() {
        let document = Self.document(blocks: [
            AnswerBlock(id: 0, heading: "定义", body: "一二三四五"),
            AnswerBlock(id: 1, heading: "要点", body: "六七八九十")
        ])
        XCTAssertEqual(document.revealed(upTo: 3).blocks.map(\.body), ["一二三"])
        XCTAssertEqual(document.revealed(upTo: 5).blocks.map(\.body), ["一二三四五"])
        let two = document.revealed(upTo: 7)
        XCTAssertEqual(two.blocks.map(\.body), ["一二三四五", "六七"])
        XCTAssertEqual(document.revealed(upTo: 0).blocks.count, 0)
        XCTAssertEqual(document.revealed(upTo: 99).blocks.count, 2)
    }

    // MARK: - Service wiring

    func testServiceEmitsPartialsAndSettlesOnce() async throws {
        let partials = Counter()
        let settlements = Counter()
        var service = self.service(settle: { _ in settlements.increment() })
        service.streamAnswer = { _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.text("@@ {\"kind\":\"event\",\"oneLine\":\"一句\"}\n## 概览\n"))
                continuation.yield(.text("第一段[1]。\n## 后续\n第二段[1]。"))
                continuation.yield(.usage(AIUsage(inputTokens: 5, outputTokens: 6)))
                continuation.yield(.finished(truncated: false))
                continuation.finish()
            }
        }
        service.onPartial = { document in partials.record(document.blocks.count) }

        let answer = try await service.run(question: "q", scope: .web, page: nil)
        XCTAssertEqual(answer.blocks.count, 2)
        XCTAssertEqual(answer.oneLine, "一句")
        XCTAssertEqual(settlements.count, 1)
        XCTAssertGreaterThanOrEqual(partials.count, 1)
    }

    // MARK: - Helpers

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func increment() { lock.lock(); values.append(1); lock.unlock() }
        func record(_ value: Int) { lock.lock(); values.append(value); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    }

    private func service(settle: @escaping @Sendable (AIChatResponse) async -> Void) -> AISearchService {
        AISearchService(
            search: { _, _ in
                [SearchHit(
                    url: "https://a.example/1",
                    title: "A",
                    snippet: "s",
                    provider: .tavily,
                    providerRank: 1
                )]
            },
            read: { hit in
                ResearchDocument(
                    url: hit.url,
                    title: hit.title,
                    text: String(repeating: "正文", count: 400),
                    source: .direct
                )
            },
            answer: { _, _, _ in
                AIChatResponse(text: "@@ {\"kind\":\"event\",\"oneLine\":\"ok\"}\n## 概览\nok[1]", truncated: false)
            },
            reserve: { true },
            settle: settle,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            pageCount: 1,
            thinking: .medium,
            model: "m",
            language: .zh
        )
    }

    private static func document(blocks: [AnswerBlock]) -> AnswerDocument {
        AnswerDocument(
            kind: .term,
            oneLine: "一句",
            blocks: blocks,
            sources: [],
            mode: .offline,
            model: "m",
            thinking: .off,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            question: nil
        )
    }
}
