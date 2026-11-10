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
    /// True when the request body actually contains a thinking field. The
    /// transports use this to retry once without an experimental field after a
    /// provider rejects it, instead of retrying every malformed request.
    let sentThinkingField: Bool
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
        stream: Bool = false,
        suppressThinking: Bool = false
    ) throws -> AIBuiltRequest {
        guard !messages.isEmpty else { throw AIRequestBuilderError.emptyMessages }
        guard let url = URL(string: connection.baseURL) else { throw AIRequestBuilderError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Provider-declared headers first; the fixed headers below always win
        // so a catalog or caller cannot replace authorization or content type.
        for (name, value) in connection.additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            apiKey.isEmpty ? nil : "\(connection.authHeaderPrefix)\(apiKey)",
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

        let effectiveStyle = AIThinkingResolver.effectiveStyle(
            connection: connection,
            model: model
        )
        let applied: AIThinkingApplication.Result
        if suppressThinking {
            applied = AIThinkingApplication.Result(maxTokens: requested, note: nil)
        } else {
            applied = AIThinkingApplication.apply(
                style: effectiveStyle,
                level: thinking,
                body: &body,
                maxTokens: requested
            )
        }
        if applied.maxTokens != requested {
            body["max_tokens"] = applied.maxTokens
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var note = applied.note
        if !suppressThinking, !effectiveStyle.isVerified, thinking != .providerDefault, note == nil {
            note = effectiveStyle.capabilityNote(L10n.currentLanguage)
        }
        return AIBuiltRequest(
            request: request,
            effectiveMaxTokens: applied.maxTokens,
            thinkingStyle: effectiveStyle,
            thinkingNote: note,
            sentThinkingField: applied.sentField
        )
    }

    /// The legacy DeepSeek preference is honoured only when the connection
    /// declares a DeepSeek-style switch. A DeepSeek-model capability still gates
    /// the field by model inside `build`; a non-DeepSeek model sends nothing.
    static func thinkingLevel(
        connection: ResolvedAIConnection,
        disableDeepSeekThinking: Bool
    ) -> AIThinkingLevel {
        let isDeepSeekCapability = connection.thinkingStyle == .deepseekToggle
            || connection.thinkingStyle == .deepseekModelToggle
        return isDeepSeekCapability && disableDeepSeekThinking ? .off : .providerDefault
    }
}
