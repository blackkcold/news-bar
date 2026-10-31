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
        XCTAssertNil(AIPriceCatalog.price(for: "custom:abc", model: "anything"))
        XCTAssertFalse(AIPriceCatalog.hasPrices(for: "custom:abc"))
    }

    func testOpenCodePriceCatalogCoversGoAndZen() throws {
        let go = try XCTUnwrap(AIPriceCatalog.price(for: "opencodeGo", model: "deepseek-v4.1-flash"))
        XCTAssertEqual(go.currency, "CNY")
        // Peak DeepSeek price on Go: the reservation must be a ceiling.
        XCTAssertEqual(go.inputPerMTok, 0.30 * AIPriceCatalog.usdToCny, accuracy: 0.0001)
        XCTAssertEqual(go.outputPerMTok, 1.20 * AIPriceCatalog.usdToCny, accuracy: 0.0001)
        XCTAssertEqual(go.cacheReadPerMTok ?? 0, 0.006 * AIPriceCatalog.usdToCny, accuracy: 0.0001)

        let zen = try XCTUnwrap(AIPriceCatalog.price(for: "opencodeZen", model: "deepseek-v4.1-flash"))
        XCTAssertEqual(zen.inputPerMTok, 0.30 * AIPriceCatalog.usdToCny, accuracy: 0.0001)
        XCTAssertEqual(zen.outputPerMTok, 1.20 * AIPriceCatalog.usdToCny, accuracy: 0.0001)

        XCTAssertTrue(AIPriceCatalog.hasPrices(for: "opencodeGo"))
        XCTAssertTrue(AIPriceCatalog.hasPrices(for: "opencodeZen"))
    }

    func testOpenCodePlanAllowanceIsModelSpecific() throws {
        let go = try XCTUnwrap(
            OpenCodePriceCatalog.entry(for: "opencodeGo", model: "deepseek-v4.1-flash")?.allowance
        )
        XCTAssertEqual(go.go, 100)
        XCTAssertEqual(go.goPlus, 200)
        XCTAssertEqual(go.goTeams, 105)

        let flash = try XCTUnwrap(
            OpenCodePriceCatalog.entry(for: "opencodeGo", model: "glm-5.3-flash")?.allowance
        )
        XCTAssertEqual(flash.go, 60)
        XCTAssertNil(OpenCodePriceCatalog.entry(for: "opencodeGo", model: "beam-free")?.allowance)
        XCTAssertTrue(try XCTUnwrap(
            OpenCodePriceCatalog.entry(for: "opencodeZen", model: "deepseek-v4.1-flash-free")
        ).isFree)
    }

    // MARK: - Reported cost

    func testOpenCodeGoUsageReadsAllowanceAndBilledTokens() throws {
        let data = Data("""
        {"prompt_tokens": 1500, "completion_tokens": 1000, "cost": 0,
         "opencode": {"billing_source": "go", "list_cost": 0.00165, "allowance": 0.00165,
           "tokens": {"input": 1500, "output": 1000, "reasoning": 0,
                      "cache_read": 200, "cache_write_5m": 0, "cache_write_1h": 0}}}
        """.utf8)
        let payload = try JSONDecoder().decode(OpenAIUsagePayload.self, from: data)
        let usage = try XCTUnwrap(AIUsage.from(openAI: payload))
        XCTAssertEqual(usage.inputTokens, 1500)
        XCTAssertEqual(usage.outputTokens, 1000)
        XCTAssertEqual(usage.cacheReadTokens, 200)
        let reported = try XCTUnwrap(usage.reportedCost)
        XCTAssertEqual(reported.usd, 0.00165, accuracy: 1e-9)
        XCTAssertEqual(reported.basis, .allowance)
        XCTAssertEqual(reported.billingSource, "go")
        XCTAssertEqual(reported.cnyMicros, 11_880)
    }

    func testOpenCodeBalanceUsageUsesChargedCost() throws {
        let data = Data("""
        {"prompt_tokens": 1200, "completion_tokens": 300, "cost": 0.00412,
         "opencode": {"billing_source": "balance", "list_cost": 0.00412}}
        """.utf8)
        let payload = try JSONDecoder().decode(OpenAIUsagePayload.self, from: data)
        let reported = try XCTUnwrap(AIUsage.from(openAI: payload)?.reportedCost)
        XCTAssertEqual(reported.basis, .charged)
        XCTAssertEqual(reported.usd, 0.00412, accuracy: 1e-9)
        XCTAssertEqual(reported.cnyMicros, 29_664)
    }

    func testOpenCodeFreeUsageIsZeroAndPriced() throws {
        let data = Data("""
        {"prompt_tokens": 10, "completion_tokens": 5, "cost": 0,
         "opencode": {"billing_source": "free", "list_cost": 0}}
        """.utf8)
        let payload = try JSONDecoder().decode(OpenAIUsagePayload.self, from: data)
        let reported = try XCTUnwrap(AIUsage.from(openAI: payload)?.reportedCost)
        XCTAssertEqual(reported.basis, .free)
        XCTAssertEqual(reported.usd, 0)
        XCTAssertEqual(reported.cnyMicros, 0)
    }

    func testOpenCodeAnthropicUsageAlsoCarriesReportedCost() throws {
        let data = Data("""
        {"input_tokens": 100, "output_tokens": 50, "cost": 0,
         "opencode": {"billing_source": "go", "allowance": 0.0005}}
        """.utf8)
        let payload = try JSONDecoder().decode(AnthropicUsagePayload.self, from: data)
        let reported = try XCTUnwrap(AIUsage.from(anthropic: payload)?.reportedCost)
        XCTAssertEqual(reported.basis, .allowance)
        XCTAssertEqual(reported.usd, 0.0005, accuracy: 1e-12)
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

    func testReportedGoAllowanceWinsOverTheLocalTable() throws {
        let directory = try researchTestDirectory()
        let store = AIQuotaStore(fileURL: directory.appendingPathComponent("quota.json"))
        let price = ModelPrice(
            provider: "opencodeGo",
            modelPrefix: "deepseek-v4.1-flash",
            inputPerMTok: 1_000,
            outputPerMTok: 1_000,
            cacheReadPerMTok: nil,
            cacheWritePerMTok: nil,
            currency: "CNY",
            updatedAt: ""
        )
        let policy = AIQuotaPolicy(mode: .cost, costCapMicros: 100_000)
        XCTAssertTrue(store.reserve(.summary, policy: policy, reservedCostMicros: 20_000))
        let usage = AIUsage(
            inputTokens: 1500,
            outputTokens: 1000,
            reportedCost: AIReportedCost(usd: 0.00165, basis: .allowance, billingSource: "go")
        )
        store.settle(reservedCostMicros: 20_000, usage: usage, price: price)

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.costMicros, 11_880, "The provider's allowance replaces both the reserve and the local table")
        XCTAssertEqual(snapshot.unpricedCalls, 0)
    }

    func testReportedFreeCallSettlesAtZeroWithoutBeingUnpriced() throws {
        let directory = try researchTestDirectory()
        let store = AIQuotaStore(fileURL: directory.appendingPathComponent("quota.json"))
        let policy = AIQuotaPolicy(mode: .cost, costCapMicros: 100_000)
        XCTAssertTrue(store.reserve(.summary, policy: policy, reservedCostMicros: 20_000))
        let usage = AIUsage(
            inputTokens: 10,
            outputTokens: 5,
            reportedCost: AIReportedCost(usd: 0, basis: .free, billingSource: "free")
        )
        store.settle(reservedCostMicros: 20_000, usage: usage, price: nil)

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.costMicros, 0)
        XCTAssertEqual(snapshot.unpricedCalls, 0)
    }
}
