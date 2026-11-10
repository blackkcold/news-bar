import Foundation

/// One user-facing AI surface whose thinking level can be chosen independently.
enum AIThinkingSurface: String, CaseIterable, Identifiable, Sendable {
    case overview
    case search
    case summary

    var id: String { rawValue }

    func title(_ language: AppLanguage) -> String {
        let english = language == .en
        switch self {
        case .overview: return english ? "Overview" : "概览"
        case .search: return english ? "Search" : "搜索"
        case .summary: return english ? "Summary" : "总结"
        }
    }
}

/// What the current connection and model can actually do with thinking
/// controls. `options` is the list the UI may offer; an empty list means the
/// surface should hide the control instead of showing a dead picker.
struct AIThinkingCapability: Equatable, Sendable {
    let style: AIThinkingStyle
    let options: [AIThinkingLevel]
    let isExperimental: Bool
    let note: String?

    /// Maps a stored level onto one the current connection can express.
    /// A concrete budget/effort that the provider cannot represent falls back
    /// to provider default instead of being silently downgraded to "off".
    func normalized(_ level: AIThinkingLevel) -> AIThinkingLevel {
        AIThinkingLevel.normalized(level, options: options)
    }
}

extension AIThinkingLevel {
    /// Shared normalization used by both the settings pickers and the
    /// "did this answer use the current level?" hint in the search footer.
    static func normalized(
        _ level: AIThinkingLevel,
        options: [AIThinkingLevel]
    ) -> AIThinkingLevel {
        if options.contains(level) { return level }
        if options.isEmpty { return .providerDefault }
        if level == .off || level == .providerDefault {
            if options.contains(.off) { return .off }
            if options.contains(.providerDefault) { return .providerDefault }
        }
        if options.contains(.providerDefault) { return .providerDefault }
        if options.contains(.off) { return .off }
        return options.first ?? .providerDefault
    }
}

enum AIThinkingResolver {
    /// The wire style after the model-family gate. The connection still
    /// declares the protocol; the model id only decides whether the declared
    /// DeepSeek-model capability applies to this request.
    static func effectiveStyle(
        connection: ResolvedAIConnection,
        model: String
    ) -> AIThinkingStyle {
        switch connection.thinkingStyle {
        case .deepseekModelToggle:
            return ProviderModelSelection.isDeepSeek(model) ? .deepseekToggle : .none
        default:
            return connection.thinkingStyle
        }
    }

    static func capability(
        connection: ResolvedAIConnection,
        model: String,
        language: AppLanguage
    ) -> AIThinkingCapability {
        let english = language == .en
        let declared = connection.thinkingStyle
        let style = effectiveStyle(connection: connection, model: model)

        switch style {
        case .deepseekToggle:
            let note: String
            if declared == .deepseekModelToggle {
                note = english
                    ? "Experimental: this connection applies the DeepSeek switch only to DeepSeek-family models. If the provider rejects the field, the request retries once without it."
                    : "实验性：该连接仅对 DeepSeek 系列模型发送思考开关；若提供商拒绝该字段，会自动去掉字段重试一次。"
            } else {
                note = english
                    ? "DeepSeek exposes a binary switch: off is explicit, and the other levels are not representable."
                    : "DeepSeek 只提供二元开关：关闭是明确发送，其他档位无法表达。"
            }
            return AIThinkingCapability(
                style: .deepseekToggle,
                options: [.off, .providerDefault],
                isExperimental: true,
                note: note
            )
        case .anthropicBudget:
            return AIThinkingCapability(
                style: .anthropicBudget,
                options: [.off, .low, .medium, .high],
                isExperimental: false,
                note: english
                    ? "Anthropic format: off sends no thinking field; low/medium/high set a token budget and may raise max_tokens."
                    : "Anthropic 格式：关闭不发送思考字段；低/中/高会设置 token 预算，并可能抬高 max_tokens。"
            )
        case .openAIReasoningEffort:
            return AIThinkingCapability(
                style: .openAIReasoningEffort,
                options: [.low, .medium, .high, .providerDefault],
                isExperimental: true,
                note: english
                    ? "OpenAI-compatible effort: off is not representable here. Provider default may still reason."
                    : "OpenAI 兼容推理强度：该端点无法表达“关闭”，提供商默认仍可能思考。"
            )
        case .ollamaThink:
            return AIThinkingCapability(
                style: .ollamaThink,
                options: [],
                isExperimental: true,
                note: english
                    ? "Ollama's native think field is not sent on the /v1 compatibility endpoint."
                    : "Ollama 原生 think 字段不会在 /v1 兼容端点发送。"
            )
        case .none:
            let note: String?
            if declared == .deepseekModelToggle {
                note = english
                    ? "The selected model is not DeepSeek-family, so no thinking field is sent."
                    : "当前模型不是 DeepSeek 系列，不发送思考参数。"
            } else {
                note = nil
            }
            return AIThinkingCapability(
                style: .none,
                options: [],
                isExperimental: false,
                note: note
            )
        case .deepseekModelToggle:
            // `effectiveStyle` never returns this case; keeps the switch total.
            return AIThinkingCapability(style: .none, options: [], isExperimental: true, note: nil)
        }
    }
}
