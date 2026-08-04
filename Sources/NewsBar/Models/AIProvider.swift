import Foundation

enum AIProvider: String, CaseIterable, Codable {
    case deepseek
    case minimaxTokenPlan
    case minimaxAPI
    case opencodeGo
    case opencodeZen
    case googleAIStudio
    case ollamaCloud

    // MARK: - Display

    var displayName: String {
        switch self {
        case .deepseek:          return "DeepSeek"
        case .minimaxTokenPlan:  return "MiniMax Token Plan"
        case .minimaxAPI:        return "MiniMax API"
        case .opencodeGo:        return "Opencode Go"
        case .opencodeZen:       return "Opencode Zen"
        case .googleAIStudio:    return "Google AI Studio"
        case .ollamaCloud:       return "Ollama Cloud"
        }
    }

    // MARK: - API Endpoint

    var baseURL: String {
        switch self {
        case .deepseek:
            return "https://api.deepseek.com/chat/completions"
        case .minimaxTokenPlan, .minimaxAPI:
            return "https://api.minimaxi.com/anthropic/v1/messages"
        case .opencodeGo:
            return "https://open-code-go.aiizhi.com/anthropic/v1/messages"
        case .opencodeZen:
            return "https://open-code-zen.aiizhi.com/anthropic/v1/messages"
        case .googleAIStudio:
            return "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        case .ollamaCloud:
            return "https://ollama.com/v1/chat/completions"
        }
    }

    // MARK: - Response Format

    enum ResponseFormat: String, Codable { case openAI, anthropic }

    var responseFormat: ResponseFormat {
        switch self {
        case .deepseek, .googleAIStudio, .ollamaCloud: return .openAI
        default:                                       return .anthropic
        }
    }

    // MARK: - Authentication

    var authHeaderName: String {
        switch self {
        case .deepseek, .googleAIStudio, .ollamaCloud: return "Authorization"
        default:                                       return "x-api-key"
        }
    }

    var authHeaderPrefix: String {
        switch self {
        case .deepseek, .googleAIStudio, .ollamaCloud: return "Bearer "
        default:                                       return ""
        }
    }

    /// Anthropic format requires an API version header; OpenAI format does not.
    var apiVersion: String? {
        responseFormat == .anthropic ? "2023-06-01" : nil
    }

    // MARK: - Models

    /// Complete official model list for the provider (used when the developer
    /// toggle "显示全部模型" is enabled). Sources verified against official docs.
    var allModels: [String] {
        switch self {
        case .deepseek:
            return ["deepseek-v4-flash", "deepseek-v4-pro"]
        case .minimaxTokenPlan, .minimaxAPI:
            return [
                "MiniMax-M3", "MiniMax-M2.7", "MiniMax-M2.7-highspeed",
                "MiniMax-M2.5", "MiniMax-M2.5-highspeed",
                "MiniMax-M2.1", "MiniMax-M2.1-highspeed", "MiniMax-M2",
            ]
        case .opencodeGo, .opencodeZen:
            // These proxy endpoints serve DeepSeek models.
            return ["deepseek-v4-flash", "deepseek-v4-pro"]
        case .googleAIStudio:
            return [
                "gemini-3.6-flash", "gemini-3.5-flash", "gemini-3.5-flash-lite",
                "gemini-3.1-flash-lite", "gemini-3.1-pro-preview", "gemini-3-flash-preview",
                "gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite",
            ]
        case .ollamaCloud:
            return [
                "deepseek-v4-flash:cloud", "deepseek-v4-pro:cloud",
                "gpt-oss:20b-cloud", "gpt-oss:120b-cloud",
                "kimi-k3:cloud", "kimi-k2.7-code:cloud", "kimi-k2.6:cloud",
                "minimax-m3:cloud", "minimax-m2.7:cloud",
                "glm-5.2:cloud", "glm-5.1:cloud",
                "qwen3.5:397b-cloud",
                "nemotron-3-super:cloud", "nemotron-3-ultra:cloud", "nemotron-3-nano:cloud",
                "mistral-large-3:cloud",
            ]
        }
    }

    /// Default collapsed model list: when the provider offers DeepSeek models,
    /// only those are shown by default; otherwise the full list is shown.
    var models: [String] {
        let deepseekModels = allModels.filter { $0.contains("deepseek") }
        return deepseekModels.isEmpty ? allModels : deepseekModels
    }

    /// Resolve the model list honouring the developer "显示全部模型" toggle.
    func models(showAll: Bool) -> [String] {
        showAll ? allModels : models
    }

    var defaultModel: String { models.first ?? "" }

    func resolvedConnection() -> ResolvedAIConnection {
        ResolvedAIConnection(
            baseURL: baseURL,
            responseFormat: responseFormat,
            authHeaderName: authHeaderName,
            authHeaderPrefix: authHeaderPrefix,
            apiVersion: apiVersion
        )
    }

    // MARK: - Keychain Account

    func apiKeyAccount() -> String { "ai-key-\(rawValue)" }
    func keyExistsFlag() -> String { "hasAIKey-\(rawValue)" }

    // MARK: - UI Hints

    var apiKeyPlaceholder: String {
        switch self {
        case .deepseek:       return "输入 DeepSeek API Key (sk-...)"
        case .minimaxTokenPlan, .minimaxAPI:
                              return "输入 MiniMax API Key"
        case .opencodeGo:     return "输入 Opencode Go API Key"
        case .opencodeZen:    return "输入 Opencode Zen API Key"
        case .googleAIStudio: return "输入 Google AI Studio API Key"
        case .ollamaCloud:    return "输入 Ollama Cloud API Key"
        }
    }

    var keyRetrievalURL: String {
        switch self {
        case .deepseek:       return "platform.deepseek.com → API Keys"
        case .minimaxTokenPlan, .minimaxAPI:
                              return "platform.minimaxi.com → 接口密钥"
        case .opencodeGo:     return "open-code-go.aiizhi.com"
        case .opencodeZen:    return "open-code-zen.aiizhi.com"
        case .googleAIStudio: return "aistudio.google.com → Get API Key"
        case .ollamaCloud:    return "ollama.com/settings/keys"
        }
    }

    var onePasswordHint: String {
        switch self {
        case .deepseek:       return "op://Private/DeepSeek/credential"
        case .minimaxTokenPlan, .minimaxAPI:
                              return "op://Private/MiniMax/credential"
        case .opencodeGo:     return "op://Private/OpencodeGo/credential"
        case .opencodeZen:    return "op://Private/OpencodeZen/credential"
        case .googleAIStudio: return "op://Private/Gemini/credential"
        case .ollamaCloud:    return "op://Private/OllamaCloud/credential"
        }
    }

    // MARK: - Pricing

    var pricingInfo: [(title: String, detail: String)] {
        switch self {
        case .deepseek:
            return [
                ("deepseek-v4-flash", "¥1/1M 输入 · ¥2/1M 输出 (缓存 ¥0.2)"),
                ("deepseek-v4-pro",  "¥12/1M 输入 · ¥24/1M 输出 (缓存 ¥1)"),
                ("用量参考",         "每次总结约消耗 200-800 tokens"),
            ]
        case .minimaxTokenPlan:
            return [
                ("计费方式", "订阅制 Token Plan，按余量扣减"),
                ("用量参考", "每次总结约消耗 200-800 tokens"),
            ]
        case .minimaxAPI:
            return [
                ("计费方式", "按量计费，详见 platform.minimaxi.com 定价页"),
                ("用量参考", "每次总结约消耗 200-800 tokens"),
            ]
        case .opencodeGo, .opencodeZen:
            return [
                ("计费方式", "通过 Opencode 代理调用，费用由 Opencode 账户决定"),
                ("用量参考", "每次总结约消耗 200-800 tokens"),
            ]
        case .googleAIStudio:
            return [
                ("gemini-2.5-flash", "免费层：每天 1500 次请求"),
                ("gemini-2.5-pro",   "免费层：每天 50 次请求"),
                ("用量参考",          "每次总结约消耗 200-800 tokens"),
            ]
        case .ollamaCloud:
            return [
                ("计费方式", "按量计费，详见 ollama.com/settings/billing"),
                ("用量参考", "每次总结约消耗 200-800 tokens"),
            ]
        }
    }

    func estimatedDailyCostText(model: String, requestCount: Int) -> String {
        guard requestCount > 0 else { return "¥0.0000" }

        switch self {
        case .deepseek:
            let inputTokensPerRequest = 400
            let outputTokensPerRequest = 100
            let inputRatePerMillion: Double
            let outputRatePerMillion: Double

            if model.contains("pro") {
                inputRatePerMillion = 12
                outputRatePerMillion = 24
            } else {
                inputRatePerMillion = 1
                outputRatePerMillion = 2
            }

            let inputCost = Double(requestCount * inputTokensPerRequest) * inputRatePerMillion / 1_000_000
            let outputCost = Double(requestCount * outputTokensPerRequest) * outputRatePerMillion / 1_000_000
            return String(format: "≈¥%.4f", inputCost + outputCost)
        case .googleAIStudio:
            return "≈¥0（免费层内）"
        case .minimaxTokenPlan:
            return "按 Token Plan 扣减"
        case .minimaxAPI:
            return "定价未内置"
        case .opencodeGo, .opencodeZen:
            return "由 Opencode 账户计费"
        case .ollamaCloud:
            return "按量计费，详见官网定价"
        }
    }
}
