import Foundation

/// Orchestrates one reader AI search: optional web search → page reading →
/// one model answer → citation validation.
///
/// All I/O is injected so the state machine, reading order, page limit and
/// citation rule can be tested without a network or an AI provider.
/// Retrieval cost knobs. Page count stays on the service (it is already part of
/// its contract); everything else is a profile so the two entries can differ
/// without branching.
struct SearchProfile: Sendable, Equatable {
    var readConcurrency: Int = 1
    var stopAfterSuccesses: Int = .max
    var maxSourceCharacters: Int = 6_000
    var maxTotalCharacters: Int = 24_000

    /// ⌘K keeps the original behaviour.
    static let readerSearch = SearchProfile()
    /// Selected-text look-up: fewer tokens, two pages in flight, stop early.
    static let selectionLookUp = SearchProfile(
        readConcurrency: 2,
        stopAfterSuccesses: 2,
        maxSourceCharacters: 4_000,
        maxTotalCharacters: 12_000
    )
}

struct AISearchService: Sendable {
    typealias SearchHandler = @Sendable (_ query: String, _ limit: Int) async throws -> [SearchHit]
    typealias ReadHandler = @Sendable (SearchHit) async throws -> ResearchDocument?
    typealias AnswerHandler = @Sendable (_ system: String, _ user: String, _ maxTokens: Int) async throws -> AIChatResponse
    typealias StreamAnswerHandler = @Sendable (_ system: String, _ user: String, _ maxTokens: Int) -> AsyncThrowingStream<AIChatStreamEvent, Error>

    static let answerTokens = 1_600

    let search: SearchHandler
    let read: ReadHandler
    let answer: AnswerHandler
    let reserve: @Sendable () async -> Bool
    let settle: @Sendable (AIChatResponse) async -> Void
    /// Quota check that does not consume a call. It runs before the first
    /// network hop so a reader who is out of budget does not spend search
    /// requests and page fetches on an answer that will be refused.
    var preflight: @Sendable () async -> Bool = { true }
    /// Production path: the answer arrives in pieces. `answer` remains the
    /// single-shot path used by tests and by any caller without a stream.
    var streamAnswer: StreamAnswerHandler? = nil
    /// Called with a parsed snapshot while text is still arriving. Never called
    /// for a snapshot that would be degraded on the final check.
    var onPartial: @Sendable (AnswerDocument) -> Void = { _ in }
    let now: @Sendable () -> Date
    let pageCount: Int
    let thinking: AIThinkingLevel
    let model: String
    let language: AppLanguage
    var profile: SearchProfile = .readerSearch

    func run(
        question: String,
        scope: AISearchScope,
        page: AISearchPageContext?,
        onStage: @Sendable (AISearchStage) async -> Void = { _ in }
    ) async throws -> AnswerDocument {
        let cleanedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedQuestion.isEmpty else { throw AISearchError.emptyQuestion }
        guard await preflight() else { throw AISearchError.quotaUnavailable }

        var sources: [AISearchSource] = []

        switch scope {
        case .currentPage:
            // Current-page scope never touches the network.
            guard let page,
                  !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AISearchError.noPageText
            }
            sources = [AISearchSource(index: 1, url: page.url, title: page.title, text: page.text)]

        case .web:
            await onStage(.searching)
            let hits: [SearchHit]
            do {
                hits = try await search(cleanedQuestion, pageCount)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AISearchError.searchFailed(error.localizedDescription)
            }

            var seen: Set<String> = []
            let selected = hits
                .filter { seen.insert($0.canonicalURL).inserted }
                .prefix(max(1, pageCount))
            guard !selected.isEmpty else { throw AISearchError.noSourcesReadable }

            var collected: [(offset: Int, url: String, title: String, text: String)] = []
            var started = 0
            let slots = Array(selected.enumerated())
            while started < slots.count {
                try Task.checkCancellation()
                let batch = Array(slots[started..<min(started + max(1, profile.readConcurrency), slots.count)])
                await onStage(.reading(index: started + 1, total: slots.count))
                let reads = await withTaskGroup(of: (Int, ResearchDocument?).self) { group in
                    for (offset, hit) in batch {
                        group.addTask { [read] in
                            let document = try? await read(hit)
                            return (offset, document)
                        }
                    }
                    var results: [(Int, ResearchDocument?)] = []
                    for await item in group { results.append(item) }
                    return results
                }
                for (offset, document) in reads.sorted(by: { $0.0 < $1.0 }) {
                    guard let document else { continue }
                    let text = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard text.count >= 200 else { continue }
                    collected.append((
                        offset,
                        document.url,
                        document.title.isEmpty ? selected[offset].title : document.title,
                        text
                    ))
                    if collected.count >= profile.stopAfterSuccesses { break }
                }
                started += batch.count
                if collected.count >= profile.stopAfterSuccesses { break }
            }
            try Task.checkCancellation()
            sources = collected
                .sorted { $0.offset < $1.offset }
                .enumerated()
                .map { index, item in
                    AISearchSource(index: index + 1, url: item.url, title: item.title, text: item.text)
                }
            guard !sources.isEmpty else { throw AISearchError.noSourcesReadable }
        }

        try Task.checkCancellation()
        await onStage(.answering)
        // The global daily ledger is the single quota authority; an AI search
        // call is reserved exactly like a summary call.
        guard await reserve() else { throw AISearchError.quotaUnavailable }

        let system = AnswerPrompt.search(language)
        let user = AISearchPrompts.user(
            question: cleanedQuestion,
            scope: scope,
            sources: sources,
            language: language
        )
        let mode: AnswerMode = scope == .currentPage ? .currentPage : .web

        var text = ""
        var usage: AIUsage?
        var truncated = false
        var lastEmitted = 0

        do {
            if let streamAnswer {
                for try await event in streamAnswer(system, user, Self.answerTokens) {
                    switch event {
                    case .text(let delta):
                        guard !delta.isEmpty else { continue }
                        text += delta
                        guard text.count - lastEmitted >= 24 else { continue }
                        let snapshot = AnswerParser.parse(text, fallbackKind: .term)
                        guard !snapshot.blocks.isEmpty else { continue }
                        lastEmitted = text.count
                        onPartial(
                            document(
                                from: snapshot,
                                sources: sources,
                                mode: mode,
                                question: cleanedQuestion,
                                truncated: false
                            )
                        )
                    case .usage(let value):
                        usage = Self.merged(usage, value)
                    case .finished(let value):
                        truncated = truncated || value
                    }
                }
            } else {
                let response = try await answer(system, user, Self.answerTokens)
                text = response.text
                usage = response.usage
                truncated = response.truncated
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AISearchError.modelFailed(error.localizedDescription)
        }

        await settle(AIChatResponse(text: text, truncated: truncated, usage: usage))

        let parsed = AnswerParser.parse(text, fallbackKind: .term)
        // An answer built from fetched pages that points at none of them is
        // unsupported prose. Replace it instead of showing it next to a source
        // list the model never used.
        let cited = AnswerDocument.citedIndices(in: parsed.blocks, sourceCount: sources.count)
        let unsupported = parsed.blocks.isEmpty || (!sources.isEmpty && cited.isEmpty)
        guard !unsupported else {
            return AnswerDocument(
                kind: parsed.kind,
                oneLine: L10n.string("reader.search.noCitations", language: language),
                blocks: [],
                sources: sources,
                mode: mode,
                model: model,
                thinking: thinking,
                generatedAt: now(),
                question: cleanedQuestion
            )
        }
        return document(
            from: parsed,
            sources: sources,
            mode: mode,
            question: cleanedQuestion,
            truncated: truncated
        )
    }

    private func document(
        from parsed: AnswerParser.Output,
        sources: [AISearchSource],
        mode: AnswerMode,
        question: String,
        truncated: Bool
    ) -> AnswerDocument {
        AnswerDocument(
            kind: parsed.kind,
            oneLine: parsed.oneLine,
            blocks: parsed.blocks,
            sources: sources,
            mode: mode,
            model: model,
            thinking: thinking,
            generatedAt: now(),
            question: question,
            truncated: truncated
        )
    }

    /// Usage can arrive in pieces (Anthropic sends input at start and output at
    /// end), so fields are merged by maximum instead of summed.
    private static func merged(_ current: AIUsage?, _ next: AIUsage) -> AIUsage {
        guard let current else { return next }
        return AIUsage(
            inputTokens: max(current.inputTokens, next.inputTokens),
            outputTokens: max(current.outputTokens, next.outputTokens),
            cacheReadTokens: max(current.cacheReadTokens, next.cacheReadTokens),
            cacheWriteTokens: max(current.cacheWriteTokens, next.cacheWriteTokens)
        )
    }
}
