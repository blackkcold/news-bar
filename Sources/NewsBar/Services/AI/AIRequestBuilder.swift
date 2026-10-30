import Foundation

enum AIRequestBuilderError: Error, Equatable, LocalizedError {
    case invalidURL
    case emptyMessages

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid AI endpoint URL"
        case .emptyMessages: return "An AI request needs at least one message"
        }
    }
}

struct AIBuiltRequest: Sendable {
    let request: URLRequest
    let effectiveMaxTokens: Int
    let thinkingStyle: AIThinkingStyle
    /// Non-empty when the provider's thinking capability is not verified or the
    /// budget forced a larger max_tokens. Diagnostics only.
    let thinkingNote: String?
}

/// Single request constructor shared by summaries, chat, research and search.
///
/// The two services keep their own parsing, retry and transport policy; only
/// the wire body and headers live here, so a new provider field cannot drift
/// between them.
enum AIRequestBuilder {
    static func build(
        connection: ResolvedAIConnection,
        apiKey: String,
        model: String,
        messages: [AIChatMessage],
        maxTokens: Int,
        temperature: Double,
        thinking: AIThinkingLevel,
        timeout: TimeInterval,
        userAgent: String? = nil,
        stream: Bool = false
    ) throws -> AIBuiltRequest {
        guard !messages.isEmpty else { throw AIRequestBuilderError.emptyMessages }
        guard let url = URL(string: connection.baseURL) else { throw AIRequestBuilderError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "\(connection.authHeaderPrefix)\(apiKey)",
            forHTTPHeaderField: connection.authHeaderName
        )
        if connection.responseFormat == .anthropic, let version = connection.apiVersion {
            request.setValue(version, forHTTPHeaderField: "anthropic-version")
        }
        if let userAgent, !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        request.timeoutInterval = timeout

        let requested = max(1, maxTokens)
        var body: [String: Any]
        switch connection.responseFormat {
        case .openAI:
            body = [
                "model": model,
                "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
                "max_tokens": requested,
                "temperature": temperature,
            ]
            if stream {
                body["stream"] = true
                // Without this OpenAI-compatible servers omit token usage from
                // the final chunk, and the call could not be priced.
                body["stream_options"] = ["include_usage": true]
            }
        case .anthropic:
            let system = messages
                .filter { $0.role == .system }
                .map(\.content)
                .joined(separator: "\n\n")
            let turns = messages
                .filter { $0.role != .system }
                .map { ["role": $0.role.rawValue, "content": $0.content] }
            body = [
                "model": model,
                "messages": turns,
                "max_tokens": requested,
                "temperature": temperature,
            ]
            if !system.isEmpty { body["system"] = system }
            if stream { body["stream"] = true }
        }

        let applied = AIThinkingApplication.apply(
            style: connection.thinkingStyle,
            level: thinking,
            body: &body,
            maxTokens: requested
        )
        if applied.maxTokens != requested {
            body["max_tokens"] = applied.maxTokens
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var note = applied.note
        if !connection.thinkingStyle.isVerified, thinking != .providerDefault, note == nil {
            note = connection.thinkingStyle.capabilityNote(L10n.currentLanguage)
        }
        return AIBuiltRequest(
            request: request,
            effectiveMaxTokens: applied.maxTokens,
            thinkingStyle: connection.thinkingStyle,
            thinkingNote: note
        )
    }

    /// The legacy DeepSeek preference is honoured only when the connection
    /// actually declares a DeepSeek-style switch. A model id is never inspected.
    static func thinkingLevel(
        connection: ResolvedAIConnection,
        disableDeepSeekThinking: Bool
    ) -> AIThinkingLevel {
        connection.thinkingStyle == .deepseekToggle && disableDeepSeekThinking ? .off : .providerDefault
    }
}
