import XCTest
@testable import NewsBar

final class AICostTests: XCTestCase {

    // MARK: - Usage parsing

    func testOpenAIUsageSubtractsCachedTokens() throws {
        let data = Data("""
        {"prompt_tokens": 1000, "completion_tokens": 300,
         "prompt_tokens_details": {"cached_tokens": 200}}
        """.utf8)
        let payload = try JSONDecoder().decode(OpenAIUsagePayload.self, from: data)
        let usage = try XCTUnwrap(AIUsage.from(openAI: payload))
        XCTAssertEqual(usage.inputTokens, 800)
        XCTAssertEqual(usage.outputTokens, 300)
        XCTAssertEqual(usage.cacheReadTokens, 200)
        XCTAssertEqual(usage.cacheWriteTokens, 0)
    }

    func testOpenAIUsageAcceptsInputOutputShape() throws {
        let data = Data(#"{"input_tokens": 120, "output_tokens": 40}"#.utf8)
        let payload = try JSONDecoder().decode(OpenAIUsagePayload.self, from: data)
        let usage = try XCTUnwrap(AIUsage.from(openAI: payload))
        XCTAssertEqual(usage.inputTokens, 120)
        XCTAssertEqual(usage.outputTokens, 40)
    }

    func testAnthropicUsageReadsCacheFields() throws {
        let data = Data("""
        {"input_tokens": 100, "output_tokens": 50,
         "cache_read_input_tokens": 20, "cache_creation_input_tokens": 10}
        """.utf8)
        let payload = try JSONDecoder().decode(AnthropicUsagePayload.self, from: data)
        let usage = try XCTUnwrap(AIUsage.from(anthropic: payload))
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 50)
        XCTAssertEqual(usage.cacheReadTokens, 20)
        XCTAssertEqual(usage.cacheWriteTokens, 10)
    }

    func testMissingUsageIsNilNotZero() {
        XCTAssertNil(AIUsage.from(openAI: nil))
        XCTAssertNil(AIUsage.from(anthropic: nil))
    }

    func testEmptyUsagePayloadIsNil() throws {
        let payload = try JSONDecoder().decode(
            OpenAIUsagePayload.self,
            from: Data(#"{"prompt_tokens": 0, "completion_tokens": 0}"#.utf8)
        )
        XCTAssertNil(AIUsage.from(openAI: payload))
    }

    // MARK: - Pricing

    func testOllamaCloudPriceMatchesVersionedModel() throws {
        let price = try XCTUnwrap(
            AIPriceCatalog.price(for: "ollamaCloud", model: "deepseek-v4.1-flash:1017")
        )
        XCTAssertEqual(price.currency, "CNY")
        XCTAssertEqual(price.inputPerMTok, 0.30 * AIPriceCatalog.usdToCny, accuracy: 0.0001)
        XCTAssertEqual(price.outputPerMTok, 1.20 * AIPriceCatalog.usdToCny, accuracy: 0.0001)
    }

    func testSpecificPrefixWins() throws {
        let flash = try XCTUnwrap(
            AIPriceCatalog.price(for: "ollamaCloud", model: "glm-5.3-flash")
        )
        let full = try XCTUnwrap(
            AIPriceCatalog.price(for: "ollamaCloud", model: "glm-5.3")
        )
        XCTAssertLessThan(flash.inputPerMTok, full.inputPerMTok)
    }

    func testUnknownProviderHasNoPrice() {
        XCTAssertNil(AIPriceCatalog.price(for: "opencodeGo", model: "anything"))
        XCTAssertNil(AIPriceCatalog.price(for: "custom:abc", model: "anything"))
        XCTAssertFalse(AIPriceCatalog.hasPrices(for: "opencodeGo"))
    }

    // MARK: - Estimation

    func testCostMicrosUsesPerMillionPrices() throws {
        let price = ModelPrice(
            provider: "test",
            modelPrefix: "m",
            inputPerMTok: 2,
            outputPerMTok: 8,
            cacheReadPerMTok: 0.5,
            cacheWritePerMTok: nil,
            currency: "CNY",
            updatedAt: ""
        )
        let usage = AIUsage(inputTokens: 1000, outputTokens: 500, cacheReadTokens: 200)
        // 1000×2 + 500×8 + 200×0.5 = 2000 + 4000 + 100 = 6100 micros = ¥0.0061
        XCTAssertEqual(AICostEstimator.costMicros(usage: usage, price: price), 6_100)
    }

    func testReserveCoversInputAndMaxOutput() throws {
        let price = ModelPrice(
            provider: "test",
            modelPrefix: "m",
            inputPerMTok: 2,
            outputPerMTok: 8,
            cacheReadPerMTok: nil,
            cacheWritePerMTok: nil,
            currency: "CNY",
            updatedAt: ""
        )
        let reserved = AICostEstimator.reserveMicros(
            inputTokens: 1000,
            maxOutputTokens: 2000,
            price: price
        )
        XCTAssertEqual(reserved, 2_000 + 16_000)
    }

    func testInputEstimateIsConservative() {
        let english = AICostEstimator.estimateInputTokens(
            system: String(repeating: "a", count: 400),
            user: ""
        )
        XCTAssertGreaterThanOrEqual(english, 100)

        let chinese = AICostEstimator.estimateInputTokens(
            system: String(repeating: "新", count: 300),
            user: ""
        )
        XCTAssertGreaterThanOrEqual(chinese, 300)
    }

    func testYuanFormatting() {
        XCTAssertEqual(AICostFormat.yuan(0), "¥0.00")
        XCTAssertEqual(AICostFormat.yuan(6_100), "¥0.0061")
        XCTAssertEqual(AICostFormat.yuan(420_000), "¥0.42")
        XCTAssertEqual(AICostFormat.yuan(5_000_000), "¥5.00")
    }

    // MARK: - Settlement

    func testSettleWithPriceReplacesReservation() throws {
        let directory = try researchTestDirectory()
        let store = AIQuotaStore(fileURL: directory.appendingPathComponent("quota.json"))
        let price = ModelPrice(
            provider: "test",
            modelPrefix: "m",
            inputPerMTok: 2,
            outputPerMTok: 8,
            cacheReadPerMTok: nil,
            cacheWritePerMTok: nil,
            currency: "CNY",
            updatedAt: ""
        )
        let policy = AIQuotaPolicy(mode: .cost, costCapMicros: 100_000)
        XCTAssertTrue(store.reserve(.summary, policy: policy, reservedCostMicros: 20_000))
        store.settle(
            reservedCostMicros: 20_000,
            usage: AIUsage(inputTokens: 1000, outputTokens: 500),
            price: price
        )

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.costMicros, 6_000)
        XCTAssertEqual(snapshot.unpricedCalls, 0)
        XCTAssertEqual(snapshot.inputTokens, 1000)
        XCTAssertEqual(snapshot.outputTokens, 500)
    }

    func testSettleWithoutPriceKeepsReservationAndMarksUnpriced() throws {
        let directory = try researchTestDirectory()
        let store = AIQuotaStore(fileURL: directory.appendingPathComponent("quota.json"))
        let policy = AIQuotaPolicy(mode: .cost, costCapMicros: 100_000)
        XCTAssertTrue(store.reserve(.summary, policy: policy, reservedCostMicros: 7_000))
        store.settle(
            reservedCostMicros: 7_000,
            usage: AIUsage(inputTokens: 10, outputTokens: 5),
            price: nil
        )

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.costMicros, 7_000, "An unpriced call keeps its estimate")
        XCTAssertEqual(snapshot.unpricedCalls, 1)
    }
}
