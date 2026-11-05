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
    case quotaUnavailable

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
        case .quotaUnavailable: return "AI budget is unavailable"
        }
    }
}

enum AIQuotaSettlement: Sendable {
    case completed(usage: AIUsage?, price: ModelPrice?)
    case unknown
    case notDispatched
}

/// Accounting hook owned by the caller. Every actual HTTP dispatch reserves
/// once; a fallback therefore reserves twice.
struct AIChatQuota: Sendable {
    var reserve: @Sendable (AIChatRequest, Int) -> AIQuotaStore.Reservation?
    var settle: @Sendable (AIQuotaStore.Reservation, AIQuotaSettlement) -> Void

    /// Production wiring: one reservation per HTTP dispatch, settled with the
    /// provider's measured usage when available.
    static func tracked(
        origin: AIQuotaOrigin,
        policy: AIQuotaPolicy,
        price: ModelPrice?,
        store: AIQuotaStore = .shared
    ) -> AIChatQuota {
        AIChatQuota(
            reserve: { request, outputTokens in
                guard store.snapshot().availability.isUsable else { return nil }
                let system = request.messages.filter { $0.role == .system }
                    .map(\.content).joined(separator: "\n")
                let user = request.messages.filter { $0.role != .system }
                    .map(\.content).joined(separator: "\n")
                let reserved = price.map {
                    AICostEstimator.reserveMicros(
                        inputTokens: AICostEstimator.estimateInputTokens(system: system, user: user),
                        maxOutputTokens: outputTokens,
                        price: $0
                    )
                } ?? 0
                return store.reserveTracked(
                    origin, policy: policy, reservedCostMicros: reserved
                )
            },
            settle: { reservation, outcome in
                switch outcome {
                case let .completed(usage, actualPrice):
                    store.settle(reservation, usage: usage, price: actualPrice)
                case .unknown:
                    store.settle(reservation, usage: nil, price: nil)
                case .notDispatched:
                    store.settle(
                        reservation, actualCostMicros: 0,
                        inputTokens: 0, outputTokens: 0, priced: true
                    )
                }
            }
        )
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
    /// Accounting hook. When present, every actual HTTP dispatch reserves and
    /// settles on its own, so a stream fallback charges both dispatches.
    let quota: AIChatQuota?

    init(
        connection: ResolvedAIConnection,
        apiKey: String,
        model: String,
        disableDeepSeekThinking: Bool = false,
        thinking: AIThinkingLevel? = nil,
        timeout: TimeInterval = 60,
        quota: AIChatQuota? = nil,
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
        self.quota = quota
        self.transport = transport
        self.streamTransport = streamTransport
    }

    var price: ModelPrice? {
        connection.customPrice ?? AIPriceCatalog.price(for: connection.providerID, model: model)
    }

    func complete(_ request: AIChatRequest) async throws -> AIChatResponse {
        try await perform(request, stream: false)
    }

    /// One HTTP dispatch, one reservation. `build` runs before the reservation
    /// so an invalid request never consumes budget.
    private func perform(_ request: AIChatRequest, stream: Bool) async throws -> AIChatResponse {
        let built = try build(request, stream: stream)
        let reservation = try reserveDispatch(request, outputTokens: built.effectiveMaxTokens)
        if Task.isCancelled {
            settleDispatch(reservation, .notDispatched)
            throw CancellationError()
        }
        do {
            let (data, response) = try await send(built.request)
            try Self.validate(response)
            let parsed: AIChatResponse
            switch connection.responseFormat {
            case .openAI: parsed = try Self.parseOpenAI(data)
            case .anthropic: parsed = try Self.parseAnthropic(data)
            }
            settleDispatch(reservation, .completed(usage: parsed.usage, price: price))
            return parsed
        } catch {
            // The request left the device: the provider may bill it even when
            // it answered with an error, so the ceiling stays and is flagged.
            settleDispatch(reservation, .unknown)
            throw error
        }
    }

    private func reserveDispatch(
        _ request: AIChatRequest, outputTokens: Int
    ) throws -> AIQuotaStore.Reservation? {
        guard let quota else { return nil }
        guard let reservation = quota.reserve(request, outputTokens) else {
            throw AIChatError.quotaUnavailable
        }
        return reservation
    }

    private func settleDispatch(
        _ reservation: AIQuotaStore.Reservation?, _ outcome: AIQuotaSettlement
    ) {
        guard let reservation, let quota else { return }
        quota.settle(reservation, outcome)
    }

    // MARK: - Streaming

    func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let built: AIBuiltRequest
                let reservation: AIQuotaStore.Reservation?
                do {
                    built = try build(request, stream: true)
                        reservation = try reserveDispatch(request, outputTokens: built.effectiveMaxTokens)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                if Task.isCancelled {
                    settleDispatch(reservation, .notDispatched)
                    continuation.finish(throwing: CancellationError())
                    return
                }
                do {
                    let (chunks, response) = try await streamTransport(built.request)
                    do {
                        try Self.validate(response)
                    } catch let error as AIChatError {
                        // The first request already left the device, so its
                        // cost is unknown. A fallback is a second, separately
                        // reserved dispatch.
                        settleDispatch(reservation, .unknown)
                        guard Self.allowsNonStreamingFallback(error) else { throw error }
                        let whole = try await perform(request, stream: false)
                        if let usage = whole.usage { continuation.yield(.usage(usage)) }
                        continuation.yield(.text(whole.text))
                        continuation.yield(.finished(truncated: whole.truncated))
                        continuation.finish()
                        return
                    }

                    var buffer = ""
                    var usage: AIUsage?
                    var truncated = false
                    for try await data in chunks {
                        guard let text = String(data: data, encoding: .utf8) else { continue }
                        buffer += text
                        for frame in SSEDecoder.drain(&buffer) {
                            for event in AIStreamParser.events(from: frame, format: connection.responseFormat) {
                                if case .usage(let value) = event { usage = Self.mergedUsage(usage, value) }
                                if case .finished(let value) = event { truncated = truncated || value }
                                continuation.yield(event)
                            }
                        }
                    }
                    if let frame = SSEDecoder.frame(from: buffer) {
                        for event in AIStreamParser.events(from: frame, format: connection.responseFormat) {
                            if case .usage(let value) = event { usage = Self.mergedUsage(usage, value) }
                            if case .finished(let value) = event { truncated = truncated || value }
                            continuation.yield(event)
                        }
                    }
                    settleDispatch(reservation, .completed(usage: usage, price: price))
                    continuation.finish()
                } catch is CancellationError {
                    settleDispatch(reservation, .unknown)
                    continuation.finish(throwing: CancellationError())
                } catch {
                    settleDispatch(reservation, .unknown)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func mergedUsage(_ current: AIUsage?, _ next: AIUsage) -> AIUsage {
        guard let current else { return next }
        return AIUsage(
            inputTokens: max(current.inputTokens, next.inputTokens),
            outputTokens: max(current.outputTokens, next.outputTokens),
            cacheReadTokens: max(current.cacheReadTokens, next.cacheReadTokens),
            cacheWriteTokens: max(current.cacheWriteTokens, next.cacheWriteTokens),
            reportedCost: next.reportedCost ?? current.reportedCost
        )
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
