import Foundation

/// Explains only explicitly selected text. The caller must provide a real,
/// fail-closed quota reservation; there is intentionally no unrestricted default.
///
/// The answer is always offline: no search, no page reads, no sources. The
/// document says so (`mode: .offline`) and the prompt forbids citation markers,
/// so the card can never look verified.
actor SelectionExplainService {
    enum Failure: Error, Equatable {
        case emptySelection
        case quotaUnavailable
        case emptyResponse
    }

    static let maxTokens = 900
    static let maxSelectionCharacters = 4_000

    private let client: any AIChatClienting
    private let modelName: String
    private let reserve: @Sendable () async -> Bool
    private let settle: @Sendable (AIChatResponse, ModelPrice?) async -> Void
    private var cache: [String: AnswerDocument] = [:]
    private var recency: [String] = []
    private let cacheLimit = 50

    init(
        client: any AIChatClienting,
        modelName: String,
        reserve: @escaping @Sendable () async -> Bool,
        settle: @escaping @Sendable (AIChatResponse, ModelPrice?) async -> Void
    ) {
        self.client = client
        self.modelName = modelName
        self.reserve = reserve
        self.settle = settle
    }

    func explain(
        _ selection: String,
        language: AppLanguage,
        onPartial: @escaping @Sendable (AnswerDocument) -> Void = { _ in }
    ) async throws -> AnswerDocument {
        let cleaned = String(
            selection.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(Self.maxSelectionCharacters)
        )
        guard !cleaned.isEmpty else { throw Failure.emptySelection }
        // The mode is part of the key: a future online explainer must not be
        // served an offline answer (or the reverse) from this cache.
        let key = [AnswerMode.offline.rawValue, language.rawValue, cleaned].joined(separator: "\n")
        if let cached = cache[key] {
            touch(key)
            return cached
        }
        try Task.checkCancellation()
        guard await reserve() else { throw Failure.quotaUnavailable }
        try Task.checkCancellation()

        let escaped = cleaned.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let request = AIChatRequest(messages: [
            AIChatMessage(role: .system, content: AnswerPrompt.selection(language)),
            AIChatMessage(role: .user, content: "<untrusted_source>\n\(escaped)\n</untrusted_source>"),
        ], maxTokens: Self.maxTokens, temperature: 0.3)
        var text = ""
        var usage: AIUsage?
        var truncated = false
        var lastEmitted = 0
        do {
            for try await event in client.stream(request) {
                switch event {
                case .text(let delta):
                    guard !delta.isEmpty else { continue }
                    text += delta
                    guard text.count - lastEmitted >= 24 else { continue }
                    let snapshot = AnswerParser.parse(text, fallbackKind: .term)
                    guard !snapshot.blocks.isEmpty else { continue }
                    lastEmitted = text.count
                    onPartial(makeDocument(from: snapshot, truncated: false))
                case .usage(let value):
                    usage = Self.merged(usage, value)
                case .finished(let value):
                    truncated = truncated || value
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        }
        await settle(AIChatResponse(text: text, truncated: truncated, usage: usage), client.price)
        try Task.checkCancellation()
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw Failure.emptyResponse }

        let parsed = AnswerParser.parse(answer, fallbackKind: .term)
        guard !parsed.blocks.isEmpty else { throw Failure.emptyResponse }
        let document = makeDocument(from: parsed, truncated: truncated)
        cache[key] = document
        touch(key)
        if recency.count > cacheLimit {
            let oldest = recency.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        return document
    }

    private func makeDocument(from parsed: AnswerParser.Output, truncated: Bool) -> AnswerDocument {
        AnswerDocument(
            kind: parsed.kind,
            oneLine: parsed.oneLine,
            blocks: parsed.blocks,
            sources: [],
            mode: .offline,
            model: modelName,
            thinking: .off,
            generatedAt: Date(),
            question: nil,
            truncated: truncated
        )
    }

    private static func merged(_ current: AIUsage?, _ next: AIUsage) -> AIUsage {
        guard let current else { return next }
        return AIUsage(
            inputTokens: max(current.inputTokens, next.inputTokens),
            outputTokens: max(current.outputTokens, next.outputTokens),
            cacheReadTokens: max(current.cacheReadTokens, next.cacheReadTokens),
            cacheWriteTokens: max(current.cacheWriteTokens, next.cacheWriteTokens),
            reportedCost: next.reportedCost ?? current.reportedCost
        )
    }

    private func touch(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}
