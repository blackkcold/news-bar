import Foundation

struct AIChatMessage: Sendable, Equatable {
    enum Role: String, Sendable {
        case system
        case user
        case assistant
    }

    let role: Role
    let content: String
}

struct AIChatRequest: Sendable, Equatable {
    var messages: [AIChatMessage]
    var maxTokens: Int = 8192
    var temperature: Double = 0.3
}

struct AIChatResponse: Sendable, Equatable {
    let text: String
    /// True when the provider stopped because it hit the token ceiling. The
    /// pipeline retries once with a larger budget instead of persisting a
    /// half-written JSON document as if it were complete.
    let truncated: Bool
    /// Measured token usage, when the provider reported it. `nil` means the
    /// call is real but cannot be priced.
    var usage: AIUsage? = nil
}

enum AIChatError: Error, Equatable, LocalizedError {
    case invalidURL
    case unauthorized
    case rateLimited
    case server(Int)
    case timeout
    case transport(String)
    case malformedResponse
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid AI endpoint URL"
        case .unauthorized: return "AI API key is invalid"
        case .rateLimited: return "AI provider rate limited the request"
        case .server(let status): return "AI provider returned HTTP \(status)"
        case .timeout: return "AI request timed out"
        case .transport(let detail): return "AI transport failed: \(detail)"
        case .malformedResponse: return "AI response could not be decoded"
        case .emptyResponse: return "AI returned an empty response"
        }
    }
}

protocol AIChatClienting: Sendable {
    func complete(_ request: AIChatRequest) async throws -> AIChatResponse
    /// Unit price used to reserve and settle the call. Test doubles and
    /// providers without a published price return nil.
    var price: ModelPrice? { get }
}

extension AIChatClienting {
    var price: ModelPrice? { nil }
}

/// Minimal chat-completions client that speaks both OpenAI-compatible and
/// Anthropic wire formats. It deliberately does not use native tool calling or
/// provider-side web search: research output stays a plain JSON contract.
struct HTTPAIChatClient: AIChatClienting {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let connection: ResolvedAIConnection
    let apiKey: String
    let model: String
    let disableDeepSeekThinking: Bool
    let timeout: TimeInterval
    let transport: Transport

    init(
        connection: ResolvedAIConnection,
        apiKey: String,
        model: String,
        disableDeepSeekThinking: Bool = false,
        timeout: TimeInterval = 60,
        transport: @escaping Transport = { request in
            try await PrivateHTTP.data(
                for: request,
                maxBytes: PrivateHTTP.defaultMaxBytes,
                timeout: request.timeoutInterval
            )
        }
    ) {
        self.connection = connection
        self.apiKey = apiKey
        self.model = model
        self.disableDeepSeekThinking = disableDeepSeekThinking
        self.timeout = timeout
        self.transport = transport
    }

    func complete(_ request: AIChatRequest) async throws -> AIChatResponse {
        switch connection.responseFormat {
        case .openAI:
            return try await openAIComplete(request)
        case .anthropic:
            return try await anthropicComplete(request)
        }
    }

    // MARK: - OpenAI-compatible

    private func openAIComplete(_ request: AIChatRequest) async throws -> AIChatResponse {
        guard let url = URL(string: connection.baseURL) else { throw AIChatError.invalidURL }
        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.setValue(
            "\(connection.authHeaderPrefix)\(apiKey)",
            forHTTPHeaderField: connection.authHeaderName
        )
        httpRequest.timeoutInterval = timeout

        var body: [String: Any] = [
            "model": model,
            "messages": request.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "max_tokens": request.maxTokens,
            "temperature": request.temperature,
        ]
        if disableDeepSeekThinking, ProviderModelSelection.isDeepSeek(model) {
            body["thinking"] = ["type": "disabled"]
        }
        httpRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(httpRequest)
        try Self.validate(response)

        struct OpenAIResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
                let finishReason: String?

                enum CodingKeys: String, CodingKey {
                    case message
                    case finishReason = "finish_reason"
                }
            }
            let choices: [Choice]
            let usage: OpenAIUsagePayload?
        }

        guard let decoded = try? JSONDecoder().decode(OpenAIResponse.self, from: data),
              let choice = decoded.choices.first else {
            throw AIChatError.malformedResponse
        }
        guard let text = choice.message.content, !text.isEmpty else {
            throw AIChatError.emptyResponse
        }
        return AIChatResponse(
            text: text,
            truncated: choice.finishReason == "length",
            usage: AIUsage.from(openAI: decoded.usage)
        )
    }

    // MARK: - Anthropic

    private func anthropicComplete(_ request: AIChatRequest) async throws -> AIChatResponse {
        guard let url = URL(string: connection.baseURL) else { throw AIChatError.invalidURL }
        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.setValue(
            "\(connection.authHeaderPrefix)\(apiKey)",
            forHTTPHeaderField: connection.authHeaderName
        )
        httpRequest.setValue(connection.apiVersion ?? "2023-06-01", forHTTPHeaderField: "anthropic-version")
        httpRequest.timeoutInterval = timeout

        let system = request.messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        let messages = request.messages
            .filter { $0.role != .system }
            .map { ["role": $0.role.rawValue, "content": $0.content] }

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": request.maxTokens,
            "temperature": request.temperature,
        ]
        if !system.isEmpty {
            body["system"] = system
        }
        httpRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(httpRequest)
        try Self.validate(response)

        struct AnthropicResponse: Decodable {
            struct Block: Decodable {
                let type: String
                let text: String?
            }
            let content: [Block]
            let stopReason: String?
            let usage: AnthropicUsagePayload?

            enum CodingKeys: String, CodingKey {
                case content
                case stopReason = "stop_reason"
                case usage
            }
        }

        guard let decoded = try? JSONDecoder().decode(AnthropicResponse.self, from: data) else {
            throw AIChatError.malformedResponse
        }
        guard let text = decoded.content.first(where: { $0.type == "text" })?.text, !text.isEmpty else {
            throw AIChatError.emptyResponse
        }
        return AIChatResponse(
            text: text,
            truncated: decoded.stopReason == "max_tokens",
            usage: AIUsage.from(anthropic: decoded.usage)
        )
    }

    // MARK: - Shared

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await transport(request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw AIChatError.timeout
            case .cancelled: throw CancellationError()
            default: throw AIChatError.transport(error.localizedDescription)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AIChatError.transport(error.localizedDescription)
        }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AIChatError.malformedResponse
        }
        switch http.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw AIChatError.unauthorized
        case 402, 429:
            throw AIChatError.rateLimited
        default:
            throw AIChatError.server(http.statusCode)
        }
    }
}
