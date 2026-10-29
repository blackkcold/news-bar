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

    func resolvedConnection() -> ResolvedAIConnection {
        ResolvedAIConnection(
            baseURL: baseURL,
            responseFormat: responseFormat,
            authHeaderName: authHeaderName,
            authHeaderPrefix: authHeaderPrefix,
            apiVersion: apiVersion,
            providerID: rawValue
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
                ("计费方式", "按实际模型计费，详见 platform.deepseek.com 定价页"),
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
                ("计费方式", "免费层及按量额度依实际模型和账户而定，详见 aistudio.google.com"),
                ("用量参考",          "每次总结约消耗 200-800 tokens"),
            ]
        case .ollamaCloud:
            return [
                ("计费方式", "按量计费，详见 ollama.com/settings/billing"),
                ("用量参考", "每次总结约消耗 200-800 tokens"),
            ]
        }
    }
}
