import XCTest
@testable import NewsBar

/// Locks the new capability layer: the connection declares the protocol, and a
/// DeepSeek-family model id only gates whether the declared switch applies.
final class AIThinkingCapabilityTests: XCTestCase {
    private func connection(
        style: AIThinkingStyle,
        format: AIProvider.ResponseFormat = .openAI
    ) -> ResolvedAIConnection {
        ResolvedAIConnection(
            baseURL: "https://api.example.com/v1/chat/completions",
            responseFormat: format,
            authHeaderName: format == .anthropic ? "x-api-key" : "Authorization",
            authHeaderPrefix: format == .anthropic ? "" : "Bearer ",
            apiVersion: format == .anthropic ? "2023-06-01" : nil,
            providerID: "test",
            thinkingStyle: style
        )
    }

    private func build(
        _ connection: ResolvedAIConnection,
        thinking: AIThinkingLevel,
        model: String,
        suppressThinking: Bool = false
    ) throws -> AIBuiltRequest {
        try AIRequestBuilder.build(
            connection: connection,
            apiKey: "key",
            model: model,
            messages: [
                AIChatMessage(role: .system, content: "sys"),
                AIChatMessage(role: .user, content: "user"),
            ],
            maxTokens: 1_000,
            temperature: 0.3,
            thinking: thinking,
            timeout: 30,
            suppressThinking: suppressThinking
        )
    }

    private func body(_ built: AIBuiltRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(built.request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Model-family gate

    func testDeepSeekModelToggleIsGatedByModelFamily() {
        let modelGated = connection(style: .deepseekModelToggle)
        XCTAssertEqual(
            AIThinkingResolver.effectiveStyle(connection: modelGated, model: "deepseek-v4.1-flash"),
            .deepseekToggle
        )
        XCTAssertEqual(
            AIThinkingResolver.effectiveStyle(connection: modelGated, model: "vendor/deepseek-r1"),
            .deepseekToggle
        )
        XCTAssertEqual(
            AIThinkingResolver.effectiveStyle(connection: modelGated, model: "gpt-5"),
            .none
        )

        // The official DeepSeek connection keeps its declared switch even for a
        // manually entered, non-DeepSeek id. This preserves the old contract.
        XCTAssertEqual(
            AIThinkingResolver.effectiveStyle(
                connection: connection(style: .deepseekToggle),
                model: "some-other-model"
            ),
            .deepseekToggle
        )

        // A no-parameter connection never starts sending because of a model id.
        XCTAssertEqual(
            AIThinkingResolver.effectiveStyle(
                connection: connection(style: .none),
                model: "deepseek-v4"
            ),
            .none
        )
    }

    func testDeepSeekModelIdsAreDetectedByTokenNotSubstring() {
        XCTAssertTrue(ProviderModelSelection.isDeepSeek("deepseek-v4.1-flash-free"))
        XCTAssertTrue(ProviderModelSelection.isDeepSeek("vendor/deepseek-r1"))
        XCTAssertTrue(ProviderModelSelection.isDeepSeek("DeepSeek-V3"))
        XCTAssertTrue(ProviderModelSelection.isDeepSeek("deepseek_v4"))
        XCTAssertFalse(ProviderModelSelection.isDeepSeek("deepseekv4"))
        XCTAssertFalse(ProviderModelSelection.isDeepSeek("notdeepseek"))
        XCTAssertFalse(ProviderModelSelection.isDeepSeek("gpt-5"))
    }

    // MARK: - Capability options

    func testCapabilityOffersOnlyRepresentableLevels() {
        let deepseek = AIThinkingResolver.capability(
            connection: connection(style: .deepseekToggle),
            model: "deepseek-v4",
            language: .en
        )
        XCTAssertEqual(deepseek.options, [.off, .providerDefault])
        XCTAssertTrue(deepseek.isExperimental)

        let anthropic = AIThinkingResolver.capability(
            connection: connection(style: .anthropicBudget, format: .anthropic),
            model: "claude",
            language: .en
        )
        XCTAssertEqual(anthropic.options, [.off, .low, .medium, .high])

        let openAI = AIThinkingResolver.capability(
            connection: connection(style: .openAIReasoningEffort),
            model: "gpt-5",
            language: .en
        )
        XCTAssertEqual(openAI.options, [.low, .medium, .high, .providerDefault])
        XCTAssertFalse(openAI.options.contains(.off))

        let none = AIThinkingResolver.capability(
            connection: connection(style: .none),
            model: "deepseek-v4",
            language: .en
        )
        XCTAssertTrue(none.options.isEmpty)

        let gatedOut = AIThinkingResolver.capability(
            connection: connection(style: .deepseekModelToggle),
            model: "gpt-5",
            language: .en
        )
        XCTAssertTrue(gatedOut.options.isEmpty)
        XCTAssertNotNil(gatedOut.note)
    }

    func testNormalizationKeepsUnsupportedConcreteLevelsAtProviderDefault() {
        let deepseek = AIThinkingResolver.capability(
            connection: connection(style: .deepseekToggle),
            model: "deepseek-v4",
            language: .en
        )
        XCTAssertEqual(deepseek.normalized(.medium), .providerDefault)
        XCTAssertEqual(deepseek.normalized(.off), .off)

        let anthropic = AIThinkingResolver.capability(
            connection: connection(style: .anthropicBudget, format: .anthropic),
            model: "claude",
            language: .en
        )
        XCTAssertEqual(anthropic.normalized(.providerDefault), .off)

        let openAI = AIThinkingResolver.capability(
            connection: connection(style: .openAIReasoningEffort),
            model: "gpt-5",
            language: .en
        )
        XCTAssertEqual(openAI.normalized(.off), .providerDefault)

        let none = AIThinkingResolver.capability(
            connection: connection(style: .none),
            model: "gpt-5",
            language: .en
        )
        XCTAssertEqual(none.normalized(.high), .providerDefault)
    }

    // MARK: - Request body

    func testDeepSeekModelToggleOnlySendsForDeepSeekModels() throws {
        let modelGated = connection(style: .deepseekModelToggle)

        let deepseek = try build(modelGated, thinking: .off, model: "deepseek-v4.1-flash")
        XCTAssertTrue(deepseek.sentThinkingField)
        let deepseekBody = try body(deepseek)
        XCTAssertEqual((deepseekBody["thinking"] as? [String: String])?["type"], "disabled")

        let other = try build(modelGated, thinking: .off, model: "gpt-5")
        XCTAssertFalse(other.sentThinkingField)
        XCTAssertNil(try body(other)["thinking"])
    }

    func testSuppressThinkingRemovesTheExperimentalField() throws {
        let built = try build(
            connection(style: .deepseekModelToggle),
            thinking: .off,
            model: "deepseek-v4",
            suppressThinking: true
        )
        XCTAssertFalse(built.sentThinkingField)
        XCTAssertNil(try body(built)["thinking"])
        XCTAssertEqual(built.thinkingStyle, .deepseekToggle)
    }

    func testDeepSeekApplicationReportsWhetherAFieldWasWritten() {
        var disabledBody: [String: Any] = [:]
        let disabled = AIThinkingApplication.apply(
            style: .deepseekToggle,
            level: .off,
            body: &disabledBody,
            maxTokens: 100
        )
        XCTAssertTrue(disabled.sentField)
        XCTAssertEqual((disabledBody["thinking"] as? [String: String])?["type"], "disabled")

        var defaultBody: [String: Any] = [:]
        let providerDefault = AIThinkingApplication.apply(
            style: .deepseekToggle,
            level: .medium,
            body: &defaultBody,
            maxTokens: 100
        )
        XCTAssertFalse(providerDefault.sentField)
        XCTAssertTrue(defaultBody.isEmpty)
    }

    func testLegacyPreferenceAlsoCoversTheModelGatedCapability() {
        XCTAssertEqual(
            AIRequestBuilder.thinkingLevel(
                connection: connection(style: .deepseekModelToggle),
                disableDeepSeekThinking: true
            ),
            .off
        )
        XCTAssertEqual(
            AIRequestBuilder.thinkingLevel(
                connection: connection(style: .deepseekModelToggle),
                disableDeepSeekThinking: false
            ),
            .providerDefault
        )
    }
}

// MARK: - Settings migration

final class AIThinkingSettingsTests: XCTestCase {
    private let keys = [
        "aiDisableDeepSeekThinking",
        "aiSearchThinking",
        "aiOverviewThinking",
        "aiSummaryThinking",
    ]
    private var snapshot: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        snapshot = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, TestIsolation.defaults.object(forKey: $0))
        })
        for key in keys {
            TestIsolation.defaults.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in keys {
            if let value = snapshot[key] ?? nil {
                TestIsolation.defaults.set(value, forKey: key)
            } else {
                TestIsolation.defaults.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    func testSummaryMigratesFromLegacyBoolean() {
        TestIsolation.defaults.set(true, forKey: "aiDisableDeepSeekThinking")
        XCTAssertEqual(AppSettings().aiSummaryThinking, .off)

        TestIsolation.defaults.set(false, forKey: "aiDisableDeepSeekThinking")
        XCTAssertEqual(AppSettings().aiSummaryThinking, .providerDefault)
    }

    func testOverviewInheritsSearchWhenTheNewKeyIsMissing() {
        TestIsolation.defaults.set(AIThinkingLevel.high.rawValue, forKey: "aiSearchThinking")
        XCTAssertEqual(AppSettings().aiOverviewThinking, .high)
    }

    func testExplicitValuesWinOverMigrationDefaults() {
        TestIsolation.defaults.set(AIThinkingLevel.low.rawValue, forKey: "aiOverviewThinking")
        TestIsolation.defaults.set(AIThinkingLevel.high.rawValue, forKey: "aiSummaryThinking")
        let settings = AppSettings()
        XCTAssertEqual(settings.aiOverviewThinking, .low)
        XCTAssertEqual(settings.aiSummaryThinking, .high)
    }

    func testInvalidStoredValuesFallBackSafely() {
        TestIsolation.defaults.set("not-a-level", forKey: "aiOverviewThinking")
        TestIsolation.defaults.set("not-a-level", forKey: "aiSummaryThinking")
        TestIsolation.defaults.set(false, forKey: "aiDisableDeepSeekThinking")
        let settings = AppSettings()
        XCTAssertEqual(settings.aiOverviewThinking, .medium)
        XCTAssertEqual(settings.aiSummaryThinking, .providerDefault)
    }
}

// MARK: - Experimental-field fallback

final class AIThinkingFallbackTests: XCTestCase {
    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []

        func append(_ request: URLRequest) -> Int {
            lock.lock()
            defer { lock.unlock() }
            requests.append(request)
            return requests.count - 1
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return requests.count
        }

        var all: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
    }

    private func connection() -> ResolvedAIConnection {
        ResolvedAIConnection(
            baseURL: "https://api.example.com/v1/chat/completions",
            responseFormat: .openAI,
            authHeaderName: "Authorization",
            authHeaderPrefix: "Bearer ",
            apiVersion: nil,
            providerID: "test",
            thinkingStyle: .deepseekToggle
        )
    }

    private func response(_ status: Int, url: URL, contentType: String? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: contentType.map { ["Content-Type": $0] }
        )!
    }

    func testChatRetriesOnceWithoutARejectedThinkingField() async throws {
        let recorder = RequestRecorder()
        let payload = #"{"choices":[{"message":{"content":"hello"},"finish_reason":"stop"}]}"#
        let client = HTTPAIChatClient(
            connection: connection(),
            apiKey: "key",
            model: "deepseek-v4",
            thinking: .off,
            transport: { request in
                let index = recorder.append(request)
                if index == 0 {
                    return (Data(), self.response(400, url: request.url!))
                }
                return (Data(payload.utf8), self.response(200, url: request.url!, contentType: "application/json"))
            }
        )

        let result = try await client.complete(
            AIChatRequest(messages: [AIChatMessage(role: .user, content: "hi")])
        )

        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(recorder.count, 2)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(recorder.all[0].httpBody)) as? [String: Any])
        XCTAssertNotNil(first["thinking"])
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(recorder.all[1].httpBody)) as? [String: Any])
        XCTAssertNil(second["thinking"])
    }

    func testSummaryRetriesOnceWithoutARejectedThinkingField() async throws {
        let directory = try researchTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = AIQuotaStore(fileURL: directory.appendingPathComponent("quota.json"))
        AISummaryService.initBudget(
            target: .popup,
            mode: .independent,
            policy: .unlimited,
            forceReset: true
        )
        let recorder = RequestRecorder()
        let payload = #"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#

        let result = try await AISummaryService.makeRequest(
            connection: connection(),
            apiKey: "key",
            model: "deepseek-v4",
            systemPrompt: "sys",
            userPrompt: "user",
            maxTokens: 100,
            thinking: .off,
            target: .popup,
            budgetMode: .independent,
            ledger: ledger,
            transport: { request in
                let index = recorder.append(request)
                if index == 0 {
                    return (Data(), self.response(400, url: request.url!))
                }
                return (Data(payload.utf8), self.response(200, url: request.url!, contentType: "application/json"))
            }
        )

        XCTAssertEqual(result.summary, "ok")
        XCTAssertEqual(recorder.count, 2)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(recorder.all[0].httpBody)) as? [String: Any])
        XCTAssertNotNil(first["thinking"])
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(recorder.all[1].httpBody)) as? [String: Any])
        XCTAssertNil(second["thinking"])
    }
}
