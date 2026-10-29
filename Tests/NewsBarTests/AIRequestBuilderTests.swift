import XCTest
@testable import NewsBar

/// The shared request constructor: one body shape for summaries and chat, with
/// thinking decided by the connection's declared capability — never by a model
/// name.
final class AIRequestBuilderTests: XCTestCase {
    private func connection(
        format: AIProvider.ResponseFormat = .openAI,
        style: AIThinkingStyle,
        baseURL: String = "https://api.example.com/v1/chat/completions",
        apiVersion: String? = nil
    ) -> ResolvedAIConnection {
        ResolvedAIConnection(
            baseURL: baseURL,
            responseFormat: format,
            authHeaderName: format == .anthropic ? "x-api-key" : "Authorization",
            authHeaderPrefix: format == .anthropic ? "" : "Bearer ",
            apiVersion: apiVersion,
            providerID: "test",
            thinkingStyle: style
        )
    }

    private func body(_ built: AIBuiltRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(built.request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func build(
        _ connection: ResolvedAIConnection,
        thinking: AIThinkingLevel,
        maxTokens: Int = 1_000,
        model: String = "model-x"
    ) throws -> AIBuiltRequest {
        try AIRequestBuilder.build(
            connection: connection,
            apiKey: "key",
            model: model,
            messages: [
                AIChatMessage(role: .system, content: "sys"),
                AIChatMessage(role: .user, content: "user"),
            ],
            maxTokens: maxTokens,
            temperature: 0.3,
            thinking: thinking,
            timeout: 30
        )
    }

    // MARK: - Capability, not model name

    func testDeepSeekSwitchIsChosenByCapabilityNotModelName() throws {
        // A DeepSeek-style connection disables thinking even for an unrelated id.
        let deepseek = try build(connection(style: .deepseekToggle), thinking: .off, model: "some-other-model")
        let thinking = try XCTUnwrap(try body(deepseek)["thinking"] as? [String: String])
        XCTAssertEqual(thinking["type"], "disabled")

        // A connection with no declared capability sends nothing, even when the
        // model id literally contains "deepseek". This is the old bug.
        let none = try build(connection(style: .none), thinking: .off, model: "deepseek-v4")
        XCTAssertNil(try body(none)["thinking"])
        XCTAssertNil(try body(none)["reasoning_effort"])
    }

    func testDeepSeekLowMediumHighAreNotFaked() throws {
        for level in [AIThinkingLevel.low, .medium, .high, .providerDefault] {
            let built = try build(connection(style: .deepseekToggle), thinking: level)
            XCTAssertNil(try body(built)["thinking"], "level \(level) must not invent a DeepSeek field")
        }
    }

    // MARK: - Anthropic budget

    func testAnthropicBudgetRaisesMaxTokensAboveTheBudget() throws {
        let built = try build(
            connection(
                format: .anthropic,
                style: .anthropicBudget,
                baseURL: "https://api.anthropic.com/v1/messages",
                apiVersion: "2023-06-01"
            ),
            thinking: .high,
            maxTokens: 2_000
        )
        let payload = try body(built)
        let thinking = try XCTUnwrap(payload["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "enabled")
        XCTAssertEqual(thinking["budget_tokens"] as? Int, 4_096)
        XCTAssertEqual(payload["max_tokens"] as? Int, 5_120)
        XCTAssertEqual(built.effectiveMaxTokens, 5_120)
        XCTAssertGreaterThan(built.effectiveMaxTokens, 4_096)
        XCTAssertNotNil(built.thinkingNote)
    }

    func testAnthropicOffAndProviderDefaultSendNoThinking() throws {
        for level in [AIThinkingLevel.off, .providerDefault] {
            let built = try build(
                connection(format: .anthropic, style: .anthropicBudget, apiVersion: "2023-06-01"),
                thinking: level
            )
            XCTAssertNil(try body(built)["thinking"])
        }
    }

    func testAnthropicHoistsSystemAndKeepsMaxTokensWhenAlreadyLarge() throws {
        let built = try build(
            connection(format: .anthropic, style: .anthropicBudget, apiVersion: "2023-06-01"),
            thinking: .low,
            maxTokens: 9_000
        )
        let payload = try body(built)
        XCTAssertEqual(payload["system"] as? String, "sys")
        let messages = try XCTUnwrap(payload["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"], "user")
        XCTAssertEqual(payload["max_tokens"] as? Int, 9_000)
        XCTAssertEqual(built.effectiveMaxTokens, 9_000)
    }

    // MARK: - OpenAI effort

    func testOpenAIReasoningEffortMapsLevels() throws {
        for (level, expected) in [
            (AIThinkingLevel.low, "low"),
            (.medium, "medium"),
            (.high, "high"),
        ] {
            let built = try build(connection(style: .openAIReasoningEffort), thinking: level)
            XCTAssertEqual(try body(built)["reasoning_effort"] as? String, expected)
            XCTAssertNil(try body(built)["thinking"])
        }
        for level in [AIThinkingLevel.off, .providerDefault] {
            let built = try build(connection(style: .openAIReasoningEffort), thinking: level)
            XCTAssertNil(try body(built)["reasoning_effort"])
        }
    }

    // MARK: - Ollama

    func testOllamaCompatibilityEndpointDoesNotSendThink() throws {
        let built = try build(connection(style: .ollamaThink), thinking: .off)
        XCTAssertNil(try body(built)["think"])
        XCTAssertNotNil(built.thinkingNote)
        XCTAssertFalse(built.thinkingStyle.isVerified)
    }

    // MARK: - Custom

    func testCustomNoneSendsNoThinkingFieldsForEveryLevel() throws {
        for level in AIThinkingLevel.allCases {
            let built = try build(connection(style: .none), thinking: level)
            let payload = try body(built)
            XCTAssertNil(payload["thinking"])
            XCTAssertNil(payload["reasoning_effort"])
            XCTAssertNil(payload["think"])
        }
    }

    // MARK: - Headers

    func testHeadersComeFromTheConnection() throws {
        let openai = try build(connection(style: .none), thinking: .providerDefault)
        XCTAssertEqual(openai.request.value(forHTTPHeaderField: "Authorization"), "Bearer key")
        XCTAssertEqual(openai.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(openai.request.value(forHTTPHeaderField: "anthropic-version"))

        let anthropic = try build(
            connection(format: .anthropic, style: .anthropicBudget, apiVersion: "2023-06-01"),
            thinking: .providerDefault
        )
        XCTAssertEqual(anthropic.request.value(forHTTPHeaderField: "x-api-key"), "key")
        XCTAssertEqual(anthropic.request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testProviderCapabilitiesAreDeclaredPerProvider() {
        XCTAssertEqual(AIProvider.deepseek.thinkingStyle, .deepseekToggle)
        XCTAssertEqual(AIProvider.minimaxAPI.thinkingStyle, .anthropicBudget)
        XCTAssertEqual(AIProvider.minimaxTokenPlan.thinkingStyle, .anthropicBudget)
        XCTAssertEqual(AIProvider.opencodeGo.thinkingStyle, .anthropicBudget)
        XCTAssertEqual(AIProvider.opencodeZen.thinkingStyle, .anthropicBudget)
        XCTAssertEqual(AIProvider.googleAIStudio.thinkingStyle, .openAIReasoningEffort)
        XCTAssertEqual(AIProvider.ollamaCloud.thinkingStyle, .ollamaThink)
    }

    func testCustomProviderDeclaresItsOwnThinkingStyleAndSurvivesDecoding() throws {
        let config = CustomAIProviderConfig(
            name: "Self-hosted",
            baseURL: "https://llm.example.com/v1/chat/completions",
            models: [],
            responseFormat: .openAI,
            thinkingStyle: .openAIReasoningEffort
        )
        XCTAssertEqual(config.resolvedConnection().thinkingStyle, .openAIReasoningEffort)

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CustomAIProviderConfig.self, from: encoded)
        XCTAssertEqual(decoded.thinkingStyle, .openAIReasoningEffort)

        // An old config without the field decodes to "send nothing".
        let legacy = """
        {"id":"legacy","name":"Old","baseURL":"https://old.example.com/v1","models":[],"responseFormat":"openAI","authHeaderName":"Authorization","authHeaderPrefix":"Bearer "}
        """.data(using: .utf8)!
        let old = try JSONDecoder().decode(CustomAIProviderConfig.self, from: legacy)
        XCTAssertEqual(old.thinkingStyle, .none)
    }

    // MARK: - Legacy preference

    func testLegacyDeepSeekPreferenceOnlyAppliesToADeepSeekCapability() {
        XCTAssertEqual(
            AIRequestBuilder.thinkingLevel(connection: connection(style: .deepseekToggle), disableDeepSeekThinking: true),
            .off
        )
        XCTAssertEqual(
            AIRequestBuilder.thinkingLevel(connection: connection(style: .deepseekToggle), disableDeepSeekThinking: false),
            .providerDefault
        )
        // The model name alone must not trigger the legacy switch.
        XCTAssertEqual(
            AIRequestBuilder.thinkingLevel(connection: connection(style: .none), disableDeepSeekThinking: true),
            .providerDefault
        )
    }

    // MARK: - Manual model escape hatch

    func testManualModelIdIsUsableWithoutACatalogButBlankIsNot() {
        let defaults = UserDefaults.standard
        let oldProvider = defaults.string(forKey: "aiProvider")
        let oldModel = defaults.string(forKey: "aiModel")
        let oldManual = defaults.object(forKey: "aiModelManuallyEntered")
        defer {
            restore(defaults, key: "aiProvider", value: oldProvider)
            restore(defaults, key: "aiModel", value: oldModel)
            if let oldManual { defaults.set(oldManual, forKey: "aiModelManuallyEntered") }
            else { defaults.removeObject(forKey: "aiModelManuallyEntered") }
        }

        defaults.set("deepseek", forKey: "aiProvider")
        defaults.set("vendor-model-2026", forKey: "aiModel")
        defaults.set(true, forKey: "aiModelManuallyEntered")
        let manual = AppSettings()
        XCTAssertTrue(manual.canUseCurrentAIModel)
        XCTAssertFalse(manual.isAIModelCatalogValidated)

        defaults.set(false, forKey: "aiModelManuallyEntered")
        let picksOnly = AppSettings()
        XCTAssertFalse(picksOnly.canUseCurrentAIModel)

        defaults.set("", forKey: "aiModel")
        defaults.set(true, forKey: "aiModelManuallyEntered")
        let blank = AppSettings()
        XCTAssertFalse(blank.canUseCurrentAIModel)
    }

    private func restore(_ defaults: UserDefaults, key: String, value: String?) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
