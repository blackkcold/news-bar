import Foundation

/// How a provider-reported amount should be read. Keeping the basis next to
/// the number prevents a plan allowance from being shown as a balance charge.
enum AICostBasis: String, Sendable, Equatable {
    /// Money deducted from the account balance.
    case charged
    /// Go plan allowance consumed. This is an equivalent cost, not a charge.
    case allowance
    /// The model's list price, used when no amount was charged now.
    case listPrice
    /// A BYOK provider's own estimate.
    case estimated
    /// A free model or a zero-priced call.
    case free
}

/// One provider-reported amount in USD, with the reason it applies.
struct AIReportedCost: Sendable, Equatable {
    var usd: Double
    var basis: AICostBasis
    var billingSource: String?

    /// The ledger stores CNY micros. The rate is the same fixed estimate the
    /// local price catalog uses, and is labelled as an estimate in the UI.
    var cnyMicros: Int64 {
        Int64((max(0, usd) * AIPriceCatalog.usdToCny * 1_000_000).rounded())
    }
}

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
    /// Present when the provider reported a cost. OpenCode reports both the
    /// charged amount and, for Go, the plan allowance consumed.
    var reportedCost: AIReportedCost? = nil
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
        // OpenCode prices are generated from the live Console catalog and are
        // kept in their own file so a catalog refresh cannot disturb the
        // hand-checked vendor prices below.
        if let openCode = OpenCodePriceCatalog.price(for: providerID, model: model) {
            return openCode
        }
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
        entries.contains { $0.provider == providerID } || OpenCodePriceCatalog.hasPrices(for: providerID)
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

/// OpenCode Console billing metadata attached to a `usage` block. Present on
/// OpenAI- and Anthropic-shaped responses; free models and BYOK calls use the
/// same envelope.
struct OpenCodeUsagePayload: Decodable, Sendable {
    struct Tokens: Decodable, Sendable {
        let input: Int?
        let output: Int?
        let reasoning: Int?
        let cacheRead: Int?
        let cacheWrite5m: Int?
        let cacheWrite1h: Int?

        enum CodingKeys: String, CodingKey {
            case input, output, reasoning
            case cacheRead = "cache_read"
            case cacheWrite5m = "cache_write_5m"
            case cacheWrite1h = "cache_write_1h"
        }
    }

    let billingSource: String?
    let listCost: Double?
    let allowance: Double?
    let estimated: Bool?
    let tokens: Tokens?

    enum CodingKeys: String, CodingKey {
        case billingSource = "billing_source"
        case listCost = "list_cost"
        case allowance, estimated, tokens
    }
}

/// OpenAI-compatible `usage` block. Some gateways use `input_tokens` /
/// `output_tokens`; both shapes are accepted. OpenCode adds `cost` and
/// `opencode` beside the token counters.
struct OpenAIUsagePayload: Decodable, Sendable {
    let promptTokens: Int?
    let completionTokens: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let promptTokensDetails: Details?
    let cost: Double?
    let opencode: OpenCodeUsagePayload?

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
        case cost, opencode
    }
}

/// Anthropic `usage` block. Cache reads and cache writes are billed separately.
struct AnthropicUsagePayload: Decodable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cost: Double?
    let opencode: OpenCodeUsagePayload?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cost, opencode
    }
}

extension AIReportedCost {
    /// States the precedence once, for both wire formats:
    /// 1. Go usage is the plan allowance, not a balance charge.
    /// 2. Extra Usage and balance calls are the charged `cost`.
    /// 3. A BYOK `cost` is the provider's estimate.
    /// 4. Otherwise fall back to the list-price equivalent, then zero.
    static func resolve(cost: Double?, opencode: OpenCodeUsagePayload?) -> AIReportedCost? {
        let source = opencode?.billingSource?.lowercased()
        if source == "free" {
            return AIReportedCost(usd: 0, basis: .free, billingSource: source)
        }
        if source == "go" || source == "go-plus" {
            if let allowance = opencode?.allowance, allowance > 0 {
                return AIReportedCost(usd: allowance, basis: .allowance, billingSource: source)
            }
            if let cost, cost > 0 {
                return AIReportedCost(usd: cost, basis: .charged, billingSource: source)
            }
            if let list = opencode?.listCost, list > 0 {
                return AIReportedCost(usd: list, basis: .listPrice, billingSource: source)
            }
            if opencode?.allowance != nil || cost != nil || opencode?.listCost != nil {
                return AIReportedCost(usd: 0, basis: .free, billingSource: source)
            }
            return nil
        }
        if let cost, cost > 0 {
            let estimated = source == "byok" || opencode?.estimated == true
            return AIReportedCost(usd: cost, basis: estimated ? .estimated : .charged, billingSource: source)
        }
        if source == "balance" {
            if cost != nil {
                return AIReportedCost(usd: 0, basis: .free, billingSource: source)
            }
            if let list = opencode?.listCost {
                return AIReportedCost(usd: list, basis: .listPrice, billingSource: source)
            }
            return nil
        }
        if let list = opencode?.listCost {
            return AIReportedCost(usd: list, basis: .listPrice, billingSource: source)
        }
        if cost != nil {
            return AIReportedCost(usd: 0, basis: .free, billingSource: source)
        }
        return nil
    }
}

extension AIUsage {
    static func from(openAI payload: OpenAIUsagePayload?) -> AIUsage? {
        guard let payload else { return nil }
        let reported = AIReportedCost.resolve(cost: payload.cost, opencode: payload.opencode)
        // OpenCode's token block is the billed shape: input excludes cache,
        // output includes reasoning. Prefer it when present.
        if let tokens = payload.opencode?.tokens, tokens.input != nil || tokens.output != nil {
            let input = max(0, tokens.input ?? 0)
            let output = max(0, tokens.output ?? 0)
            guard input > 0 || output > 0 || reported != nil else { return nil }
            return AIUsage(
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: max(0, tokens.cacheRead ?? 0),
                cacheWriteTokens: max(0, (tokens.cacheWrite5m ?? 0) + (tokens.cacheWrite1h ?? 0)),
                reportedCost: reported
            )
        }
        let prompt = payload.promptTokens ?? payload.inputTokens ?? 0
        let output = payload.completionTokens ?? payload.outputTokens ?? 0
        let cached = payload.promptTokensDetails?.cachedTokens ?? 0
        guard prompt > 0 || output > 0 || reported != nil else { return nil }
        return AIUsage(
            inputTokens: max(0, prompt - cached),
            outputTokens: max(0, output),
            cacheReadTokens: max(0, cached),
            reportedCost: reported
        )
    }

    static func from(anthropic payload: AnthropicUsagePayload?) -> AIUsage? {
        guard let payload else { return nil }
        let reported = AIReportedCost.resolve(cost: payload.cost, opencode: payload.opencode)
        if let tokens = payload.opencode?.tokens, tokens.input != nil || tokens.output != nil {
            let input = max(0, tokens.input ?? 0)
            let output = max(0, tokens.output ?? 0)
            guard input > 0 || output > 0 || reported != nil else { return nil }
            return AIUsage(
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: max(0, tokens.cacheRead ?? 0),
                cacheWriteTokens: max(0, (tokens.cacheWrite5m ?? 0) + (tokens.cacheWrite1h ?? 0)),
                reportedCost: reported
            )
        }
        let input = payload.inputTokens ?? 0
        let output = payload.outputTokens ?? 0
        guard input > 0 || output > 0 || reported != nil else { return nil }
        return AIUsage(
            inputTokens: max(0, input),
            outputTokens: max(0, output),
            cacheReadTokens: max(0, payload.cacheReadInputTokens ?? 0),
            cacheWriteTokens: max(0, payload.cacheCreationInputTokens ?? 0),
            reportedCost: reported
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
