import Foundation

/// How much reasoning a request asks for. Providers differ: DeepSeek only has a
/// binary switch, Anthropic-format providers take a token budget, and
/// OpenAI-compatible endpoints take an effort label. `providerDefault` sends
/// nothing and leaves the choice to the provider.
enum AIThinkingLevel: String, Codable, Sendable, CaseIterable, Identifiable {
    case off
    case low
    case medium
    case high
    case providerDefault

    var id: String { rawValue }

    func title(_ language: AppLanguage) -> String {
        let english = language == .en
        switch self {
        case .off: return english ? "Off" : "关闭"
        case .low: return english ? "Low" : "低"
        case .medium: return english ? "Medium" : "中"
        case .high: return english ? "High" : "高"
        case .providerDefault: return english ? "Provider default" : "提供商默认"
        }
    }

    func detail(_ language: AppLanguage) -> String {
        let english = language == .en
        switch self {
        case .off:
            return english
                ? "Ask the provider not to reason when it exposes an off switch; otherwise nothing is sent."
                : "提供商支持关闭时明确关闭；否则不发送任何思考参数。"
        case .low, .medium, .high:
            return english
                ? "Mapped to this provider's own parameter: budget tokens, reasoning effort, or a binary switch."
                : "映射到该提供商自己的参数：预算 token、推理强度或二元开关。"
        case .providerDefault:
            return english
                ? "No thinking field is sent; the provider decides."
                : "不发送思考字段，由提供商决定。"
        }
    }

    /// Anthropic-format budget. Anthropic's minimum is 1 024 tokens.
    var anthropicBudgetTokens: Int? {
        switch self {
        case .low: return 1_024
        case .medium: return 2_048
        case .high: return 4_096
        case .off, .providerDefault: return nil
        }
    }

    /// OpenAI-compatible effort label. `off` and `providerDefault` send nothing.
    var reasoningEffort: String? {
        switch self {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .off, .providerDefault: return nil
        }
    }
}

/// The wire shape a provider actually understands for reasoning control. This
/// is declared per connection, never guessed from a model name: a custom
/// endpoint can point at any model, and a model id is not a protocol.
enum AIThinkingStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case deepseekToggle
    case anthropicBudget
    case openAIReasoningEffort
    case ollamaThink
    case none

    var id: String { rawValue }

    func title(_ language: AppLanguage) -> String {
        let english = language == .en
        switch self {
        case .deepseekToggle: return english ? "DeepSeek thinking switch" : "DeepSeek 思考开关"
        case .anthropicBudget: return english ? "Anthropic thinking budget" : "Anthropic 思考预算"
        case .openAIReasoningEffort: return english ? "OpenAI reasoning effort" : "OpenAI 推理强度"
        case .ollamaThink: return english ? "Ollama think (unverified)" : "Ollama think（未验证）"
        case .none: return english ? "No thinking parameter" : "不发送思考参数"
        }
    }

    /// No live provider request was sent while building this version. Only
    /// `none` is trivially "verified" because it sends nothing at all; every
    /// other shape is implemented from provider documentation and labelled as
    /// not live-tested instead of claiming compatibility.
    var isVerified: Bool { self == .none }

    func capabilityNote(_ language: AppLanguage) -> String? {
        let english = language == .en
        switch self {
        case .deepseekToggle:
            return english
                ? "Implemented from the shipped DeepSeek behaviour: Off sends thinking.type=disabled; other levels send nothing. No live request was sent in this build."
                : "按现有 DeepSeek 线上行为实现：关闭时发送 thinking.type=disabled，其他档位不发送。本次构建未发送真实请求。"
        case .anthropicBudget:
            return english
                ? "Implemented from Anthropic's thinking format: type=enabled with budget_tokens, and max_tokens is raised above it. No live request was sent in this build."
                : "按 Anthropic thinking 格式实现：type=enabled 与 budget_tokens，并自动把 max_tokens 抬到预算之上。本次构建未发送真实请求。"
        case .openAIReasoningEffort:
            return english
                ? "Implemented from the OpenAI reasoning_effort field. Whether a Gemini shim or a self-hosted endpoint accepts it is unverified."
                : "按 OpenAI reasoning_effort 字段实现；Gemini shim 或自建端点是否接受该字段未验证。"
        case .ollamaThink:
            return english
                ? "Unverified: Ollama's native think field is not sent on the /v1 compatibility endpoint."
                : "未验证：当前走 /v1 兼容层，不发送 Ollama 原生 think 字段。"
        case .none:
            return nil
        }
    }
}

/// Applies one thinking level to an already-built JSON body. Returns the
/// possibly raised `max_tokens` and a capability note for diagnostics.
enum AIThinkingApplication {
    struct Result: Equatable {
        var maxTokens: Int
        var note: String?
    }

    static func apply(
        style: AIThinkingStyle,
        level: AIThinkingLevel,
        body: inout [String: Any],
        maxTokens: Int
    ) -> Result {
        switch style {
        case .deepseekToggle:
            // DeepSeek exposes a binary switch. Off is explicit; low/medium/high
            // are not representable and must not be faked with a guessed field.
            if level == .off {
                body["thinking"] = ["type": "disabled"]
            }
            return Result(maxTokens: maxTokens, note: nil)
        case .anthropicBudget:
            guard let budget = level.anthropicBudgetTokens else {
                return Result(maxTokens: maxTokens, note: nil)
            }
            body["thinking"] = ["type": "enabled", "budget_tokens": budget]
            // Anthropic rejects a request whose max_tokens does not exceed the
            // thinking budget. Raise it instead of failing at the provider.
            let raised = max(maxTokens, budget + 1_024)
            return Result(
                maxTokens: raised,
                note: raised > maxTokens ? "max_tokens raised to \(raised) for budget_tokens \(budget)" : nil
            )
        case .openAIReasoningEffort:
            if let effort = level.reasoningEffort {
                body["reasoning_effort"] = effort
            }
            return Result(maxTokens: maxTokens, note: nil)
        case .ollamaThink:
            // Do not send `think` on /v1. The capability stays marked unverified
            // in settings and in the builder's note.
            return Result(
                maxTokens: maxTokens,
                note: level == .off ? "Ollama /v1: think=false not sent (unverified)" : nil
            )
        case .none:
            return Result(maxTokens: maxTokens, note: nil)
        }
    }
}
