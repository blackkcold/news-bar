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
    /// Incremental answer. Providers that cannot stream still satisfy this:
    /// the default implementation runs `complete` and yields one text event,
    /// so every caller has a single code path.
    func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIChatStreamEvent, Error>
    /// Unit price used to reserve and settle the call. Test doubles and
    /// providers without a published price return nil.
    var price: ModelPrice? { get }
}

extension AIChatClienting {
    var price: ModelPrice? { nil }

    func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)
                    if let usage = response.usage { continuation.yield(.usage(usage)) }
                    continuation.yield(.text(response.text))
                    continuation.yield(.finished(truncated: response.truncated))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Minimal chat-completions client that speaks both OpenAI-compatible and
/// Anthropic wire formats. It deliberately does not use native tool calling or
/// provider-side web search: research output stays a plain JSON contract.
struct HTTPAIChatClient: AIChatClienting {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias StreamTransport = @Sendable (URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse)

    let connection: ResolvedAIConnection
    let apiKey: String
    let model: String
    let disableDeepSeekThinking: Bool
    /// Explicit level (AI search sets its own). `nil` keeps the legacy summary
    /// preference, applied only when the connection declares a DeepSeek switch.
    let thinking: AIThinkingLevel?
    let timeout: TimeInterval
    let transport: Transport
    let streamTransport: StreamTransport

    init(
        connection: ResolvedAIConnection,
        apiKey: String,
        model: String,
        disableDeepSeekThinking: Bool = false,
        thinking: AIThinkingLevel? = nil,
        timeout: TimeInterval = 60,
        transport: @escaping Transport = { request in
            try await PrivateHTTP.data(
                for: request,
                maxBytes: PrivateHTTP.defaultMaxBytes,
                timeout: request.timeoutInterval
            )
        },
        streamTransport: @escaping StreamTransport = { request in
            try await PrivateHTTP.stream(for: request, timeout: request.timeoutInterval)
        }
    ) {
        self.connection = connection
        self.apiKey = apiKey
        self.model = model
        self.disableDeepSeekThinking = disableDeepSeekThinking
        self.thinking = thinking
        self.timeout = timeout
        self.transport = transport
        self.streamTransport = streamTransport
    }

    var price: ModelPrice? {
        connection.customPrice ?? AIPriceCatalog.price(for: connection.providerID, model: model)
    }

    func complete(_ request: AIChatRequest) async throws -> AIChatResponse {
        let built = try build(request, stream: false)
        let (data, response) = try await send(built.request)
        try Self.validate(response)
        switch connection.responseFormat {
        case .openAI:
            return try Self.parseOpenAI(data)
        case .anthropic:
            return try Self.parseAnthropic(data)
        }
    }

    // MARK: - Streaming

    func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let built = try build(request, stream: true)
                    let (chunks, response) = try await streamTransport(built.request)
                    do {
                        try Self.validate(response)
                    } catch let error as AIChatError {
                        // A provider or proxy that refuses streaming must not
                        // cost the user the answer. Nothing was generated yet,
                        // so retrying without `stream` is free.
                        guard Self.allowsNonStreamingFallback(error) else { throw error }
                        let whole = try await complete(request)
                        if let usage = whole.usage { continuation.yield(.usage(usage)) }
                        continuation.yield(.text(whole.text))
                        continuation.yield(.finished(truncated: whole.truncated))
                        continuation.finish()
                        return
                    }

                    var buffer = ""
                    for try await data in chunks {
                        guard let text = String(data: data, encoding: .utf8) else { continue }
                        buffer += text
                        for frame in SSEDecoder.drain(&buffer) {
                            for event in AIStreamParser.events(from: frame, format: connection.responseFormat) {
                                continuation.yield(event)
                            }
                        }
                    }
                    if let frame = SSEDecoder.frame(from: buffer) {
                        for event in AIStreamParser.events(from: frame, format: connection.responseFormat) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func allowsNonStreamingFallback(_ error: AIChatError) -> Bool {
        switch error {
        case .server(let status): return [400, 404, 405, 415, 422, 501].contains(status)
        case .malformedResponse: return true
        default: return false
        }
    }

    private func build(_ request: AIChatRequest, stream: Bool) throws -> AIBuiltRequest {
        do {
            return try AIRequestBuilder.build(
                connection: connection,
                apiKey: apiKey,
                model: model,
                messages: request.messages,
                maxTokens: request.maxTokens,
                temperature: request.temperature,
                thinking: thinking ?? AIRequestBuilder.thinkingLevel(
                    connection: connection,
                    disableDeepSeekThinking: disableDeepSeekThinking
                ),
                timeout: timeout,
                userAgent: "NewsBar/1.0 (macOS; Chat)",
                stream: stream
            )
        } catch AIRequestBuilderError.invalidURL {
            throw AIChatError.invalidURL
        } catch {
            throw AIChatError.malformedResponse
        }
    }

    // MARK: - Response parsing

    private static func parseOpenAI(_ data: Data) throws -> AIChatResponse {
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

    private static func parseAnthropic(_ data: Data) throws -> AIChatResponse {
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
