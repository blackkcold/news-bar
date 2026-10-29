import Foundation

/// Token counts for one provider call.
///
/// `inputTokens` excludes cached tokens: OpenAI reports `prompt_tokens`
/// inclusive of cache hits, so the parsers subtract `cached_tokens` and carry
/// it in `cacheReadTokens`. Anthropic already reports them separately.
struct AIUsage: Sendable, Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheWriteTokens: Int = 0
}

/// One model's prices, normalized to CNY per million tokens.
struct ModelPrice: Sendable, Equatable {
    var provider: String
    var modelPrefix: String
    var inputPerMTok: Double
    var outputPerMTok: Double
    var cacheReadPerMTok: Double?
    var cacheWritePerMTok: Double?
    var currency: String
    var updatedAt: String
}

/// Built-in reference prices. A missing entry is not an error: the UI asks the
/// user for unit prices instead of inventing a number.
///
/// Sources checked on 2026-10-29:
/// - Ollama Cloud model pricing (USD per 1M tokens).
/// - DeepSeek models & pricing (CNY per 1M tokens).
/// - Gemini Developer API pricing (USD per 1M tokens).
/// Peak/standard prices are used so a daily budget is not under-estimated.
enum AIPriceCatalog {
    static let updatedAt = "2026-10-29"
    /// Reference rate used only to display one currency. Users bill in USD and
    /// CNY; the estimate is always labelled as an estimate.
    static let usdToCny = 7.2

    private struct Entry {
        let provider: String
        let prefix: String
        let input: Double
        let output: Double
        let cacheRead: Double?
        let currency: String
    }

    private static let entries: [Entry] = [
        // DeepSeek — peak prices, CNY per 1M tokens.
        Entry(provider: "deepseek", prefix: "deepseek-flash", input: 2, output: 8, cacheRead: 0.04, currency: "CNY"),
        Entry(provider: "deepseek", prefix: "deepseek-v4-flash", input: 2, output: 8, cacheRead: 0.04, currency: "CNY"),
        Entry(provider: "deepseek", prefix: "deepseek-v4-pro", input: 9, output: 27, cacheRead: 0.30, currency: "CNY"),

        // Ollama Cloud — standard (non-off-peak) prices, USD per 1M tokens.
        Entry(provider: "ollamaCloud", prefix: "deepseek-v4.1-flash", input: 0.30, output: 1.20, cacheRead: 0.006, currency: "USD"),
        Entry(provider: "ollamaCloud", prefix: "deepseek-v4-pro", input: 1.32, output: 3.96, cacheRead: 0.044, currency: "USD"),
        Entry(provider: "ollamaCloud", prefix: "gpt-oss:120b", input: 0.15, output: 0.60, cacheRead: 0.014, currency: "USD"),
        Entry(provider: "ollamaCloud", prefix: "gpt-oss:20b", input: 0.07, output: 0.30, cacheRead: 0.035, currency: "USD"),
        Entry(provider: "ollamaCloud", prefix: "gemma4", input: 0.14, output: 0.40, cacheRead: 0.05, currency: "USD"),
        Entry(provider: "ollamaCloud", prefix: "glm-5.3-flash", input: 0.15, output: 0.50, cacheRead: 0.03, currency: "USD"),
        Entry(provider: "ollamaCloud", prefix: "glm-5.3", input: 1.40, output: 4.40, cacheRead: 0.26, currency: "USD"),
        Entry(provider: "ollamaCloud", prefix: "kimi-k3", input: 3.00, output: 15.00, cacheRead: 0.30, currency: "USD"),
        Entry(provider: "ollamaCloud", prefix: "minimax-m3.1-flash", input: 0.15, output: 0.60, cacheRead: 0.015, currency: "USD"),
        Entry(provider: "ollamaCloud", prefix: "minimax-m3", input: 0.60, output: 2.40, cacheRead: 0.12, currency: "USD"),
        Entry(provider: "ollamaCloud", prefix: "mistral-large-4", input: 0.68, output: 2.09, cacheRead: 0.07, currency: "USD"),

        // Gemini Developer API — standard paid tier, USD per 1M tokens.
        Entry(provider: "googleAIStudio", prefix: "gemini-4-argon", input: 2.00, output: 10.00, cacheRead: 0.10, currency: "USD"),
        Entry(provider: "googleAIStudio", prefix: "gemini-3.8-flash", input: 0.75, output: 3.75, cacheRead: 0.075, currency: "USD"),
        Entry(provider: "googleAIStudio", prefix: "gemini-3.5-flash-lite", input: 0.30, output: 2.50, cacheRead: 0.03, currency: "USD"),
        Entry(provider: "googleAIStudio", prefix: "gemini-3.1-flash-lite", input: 0.25, output: 1.50, cacheRead: 0.025, currency: "USD"),
    ]

    /// Most specific prefix wins: `glm-5.3-flash` must not fall back to
    /// `glm-5.3`. Unknown providers and models return nil.
    static func price(for providerID: String, model: String) -> ModelPrice? {
        let key = model.lowercased()
        let candidates = entries
            .filter { $0.provider == providerID && key.hasPrefix($0.prefix.lowercased()) }
            .sorted { $0.prefix.count > $1.prefix.count }
        guard let entry = candidates.first else { return nil }
        let rate = entry.currency == "USD" ? usdToCny : 1
        return ModelPrice(
            provider: entry.provider,
            modelPrefix: entry.prefix,
            inputPerMTok: entry.input * rate,
            outputPerMTok: entry.output * rate,
            cacheReadPerMTok: entry.cacheRead.map { $0 * rate },
            cacheWritePerMTok: nil,
            currency: "CNY",
            updatedAt: updatedAt
        )
    }

    /// True when at least one model is priced for this provider.
    static func hasPrices(for providerID: String) -> Bool {
        entries.contains { $0.provider == providerID }
    }
}

enum AICostEstimator {
    /// Cost of one settled call in micros of CNY (1e-6). Prices are CNY per
    /// million tokens, so `tokens × price` already lands in micros.
    static func costMicros(usage: AIUsage, price: ModelPrice) -> Int64 {
        let input = Double(max(0, usage.inputTokens)) * price.inputPerMTok
        let output = Double(max(0, usage.outputTokens)) * price.outputPerMTok
        let cacheRead = Double(max(0, usage.cacheReadTokens))
            * (price.cacheReadPerMTok ?? price.inputPerMTok)
        let cacheWrite = Double(max(0, usage.cacheWriteTokens))
            * (price.cacheWritePerMTok ?? price.inputPerMTok)
        return Int64((input + output + cacheRead + cacheWrite).rounded())
    }

    /// Conservative input estimate. CJK is roughly one token per three UTF-8
    /// bytes; English is roughly one per four. Dividing by three overestimates
    /// English, which is the safe direction for a budget.
    static func estimateInputTokens(system: String, user: String) -> Int {
        max(1, (system.utf8.count + user.utf8.count) / 3)
    }

    /// Reserve the worst case before dispatch. The measured usage replaces it
    /// on settle, so the reservation is a ceiling rather than a charge.
    static func reserveMicros(
        inputTokens: Int,
        maxOutputTokens: Int,
        price: ModelPrice
    ) -> Int64 {
        let input = Double(max(0, inputTokens)) * price.inputPerMTok
        let output = Double(max(0, maxOutputTokens)) * price.outputPerMTok
        return Int64((input + output).rounded())
    }
}

/// OpenAI-compatible `usage` block. Some gateways use `input_tokens` /
/// `output_tokens`; both shapes are accepted.
struct OpenAIUsagePayload: Decodable, Sendable {
    let promptTokens: Int?
    let completionTokens: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let promptTokensDetails: Details?

    struct Details: Decodable, Sendable {
        let cachedTokens: Int?
        enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case promptTokensDetails = "prompt_tokens_details"
    }
}

/// Anthropic `usage` block. Cache reads and cache writes are billed separately.
struct AnthropicUsagePayload: Decodable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
    }
}

extension AIUsage {
    static func from(openAI payload: OpenAIUsagePayload?) -> AIUsage? {
        guard let payload else { return nil }
        let prompt = payload.promptTokens ?? payload.inputTokens ?? 0
        let output = payload.completionTokens ?? payload.outputTokens ?? 0
        let cached = payload.promptTokensDetails?.cachedTokens ?? 0
        guard prompt > 0 || output > 0 else { return nil }
        return AIUsage(
            inputTokens: max(0, prompt - cached),
            outputTokens: max(0, output),
            cacheReadTokens: max(0, cached)
        )
    }

    static func from(anthropic payload: AnthropicUsagePayload?) -> AIUsage? {
        guard let payload else { return nil }
        let input = payload.inputTokens ?? 0
        let output = payload.outputTokens ?? 0
        guard input > 0 || output > 0 else { return nil }
        return AIUsage(
            inputTokens: max(0, input),
            outputTokens: max(0, output),
            cacheReadTokens: max(0, payload.cacheReadInputTokens ?? 0),
            cacheWriteTokens: max(0, payload.cacheCreationInputTokens ?? 0)
        )
    }
}

enum AICostFormat {
    /// Small per-call amounts keep four decimals; daily totals use two.
    static func yuan(_ micros: Int64) -> String {
        let value = Double(max(0, micros)) / 1_000_000
        if value == 0 { return "¥0.00" }
        if value < 0.01 { return String(format: "¥%.4f", value) }
        return String(format: "¥%.2f", value)
    }
}
