import Foundation

/// Orchestrates one reader AI search: query plan → shared-budget retrieval →
/// page reads → optional assessment → one model answer → citation validation.
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
    typealias SearchHandler = @Sendable (
        _ query: SearchQuery,
        _ ticket: SearchAttemptTicket
    ) async throws -> [SearchHit]
    typealias ReadHandler = @Sendable (SearchHit) async throws -> PageReadOutcome
    typealias AnswerHandler = @Sendable (_ system: String, _ user: String, _ maxTokens: Int) async throws -> AIChatResponse
    typealias StreamAnswerHandler = @Sendable (_ system: String, _ user: String, _ maxTokens: Int) -> AsyncThrowingStream<AIChatStreamEvent, Error>
    typealias AssessHandler = @Sendable (
        _ question: String,
        _ pageTitle: String?,
        _ sources: [AISearchSource]
    ) async -> AssessmentResult

    static let answerTokens = 1_600
    /// One run, all query variants. Three variants × two attempts fills it.
    static let maxSearchAttempts = 6

    let search: SearchHandler
    let read: ReadHandler
    let answer: AnswerHandler
    /// Quota check that does not consume a call. It runs before the first
    /// network hop so a reader who is out of budget does not spend search
    /// requests and page fetches on an answer that will be refused.
    var preflight: @Sendable () async -> Bool = { true }
    /// Production path: the answer arrives in pieces. `answer` remains the
    /// single-shot path used by tests and by any caller without a stream.
    var streamAnswer: StreamAnswerHandler? = nil
    /// Optional evidence assessment. `nil` means the user turned it off; the
    /// run then uses the readability heuristic and never claims verification.
    var assess: AssessHandler? = nil
    /// Called with a parsed snapshot while text is still arriving. A snapshot
    /// with no valid citation is withheld when adopted external sources exist,
    /// so the canvas never shows prose the final check will mark unverified.
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
        var retrieval = RetrievalEvidence()
        var conflicts: [EvidenceConflict] = []
        let mode: AnswerMode = scope == .currentPage ? .currentPage : .web

        switch scope {
        case .currentPage:
            // Current-page scope never touches the network.
            guard let page,
                  !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AISearchError.noPageText
            }
            sources = [
                AISearchSource(
                    index: 1,
                    url: page.url,
                    title: page.title,
                    text: page.text,
                    origin: .currentPage
                )
            ]
            retrieval.readCount = 1

        case .web:
            await onStage(.searching)
            let plan = QueryPlanner.plan(
                question: cleanedQuestion,
                scope: scope,
                page: page,
                language: language
            )
            retrieval.queryCount = plan.queries.count
            let ticket = SearchAttemptTicket(limit: Self.maxSearchAttempts)
            let result = await EvidenceRetriever.retrieve(
                plan: plan,
                search: search,
                ticket: ticket,
                // Read slots and candidate slots are not the same number: a
                // failed read must not leave the answer one source short.
                candidateCap: max(1, pageCount) + 3,
                language: language
            )
            retrieval.foundCount = result.foundCount
            retrieval.httpAttempts = result.attemptsUsed

            if result.searchUnavailable {
                throw AISearchError.searchFailed(result.failureDetail ?? "")
            }
            guard !result.candidates.isEmpty else {
                retrieval.add(.noResults)
                return emptyAnswer(
                    question: cleanedQuestion,
                    note: .noResults,
                    retrieval: retrieval,
                    mode: mode
                )
            }

            let readResult = try await EvidenceReader.read(
                candidates: result.candidates,
                read: read,
                readLimit: max(1, pageCount)
            ) { index, total in
                await onStage(.reading(index: index, total: total))
            }
            retrieval.readCount = readResult.readCount
            guard !readResult.sources.isEmpty else {
                retrieval.add(.noSourcesReadable)
                return emptyAnswer(
                    question: cleanedQuestion,
                    note: .noSourcesReadable,
                    retrieval: retrieval,
                    mode: mode
                )
            }
            sources = readResult.sources

            let assessment: AssessmentResult
            if let assess {
                await onStage(.assessing)
                assessment = await assess(cleanedQuestion, page?.title, sources)
            } else {
                assessment = EvidenceAssessor.heuristic(
                    question: cleanedQuestion,
                    sources: sources
                )
            }
            sources = assessment.sources
            conflicts = assessment.conflicts
            for note in assessment.notes { retrieval.add(note) }
            retrieval.adoptedCount = sources.filter {
                $0.origin == .web && $0.assessment?.adoption != .rejected
            }.count
            retrieval.rejectedCount = sources.filter {
                $0.origin == .web && $0.assessment?.adoption == .rejected
            }.count
        }

        let system = AnswerPrompt.search(language)
        let user = AISearchPrompts.user(
            question: cleanedQuestion,
            scope: scope,
            sources: sources,
            language: language,
            maxSourceCharacters: profile.maxSourceCharacters,
            maxTotalCharacters: profile.maxTotalCharacters,
            conflicts: conflicts
        )
        let allowed = AnswerValidator.allowedIndices(sources)
        let hasAdoptedExternal = sources.contains {
            $0.origin == .web && $0.assessment?.adoption != .rejected
        }

        try Task.checkCancellation()
        await onStage(.answering)
        try Task.checkCancellation()

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
                        if hasAdoptedExternal {
                            let valid = AnswerDocument.citedIndices(
                                in: snapshot.blocks,
                                sourceCount: sources.count,
                                allowed: allowed
                            )
                            guard !valid.isEmpty else { continue }
                        }
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
        } catch let error as AIChatError {
            if error == .quotaUnavailable { throw AISearchError.quotaUnavailable }
            throw AISearchError.modelFailed("AI call failed")
        } catch {
            if error is CancellationError { throw CancellationError() }
            throw AISearchError.modelFailed(error.localizedDescription)
        }

        var parsed = AnswerParser.parse(text, fallbackKind: .term)
        var validation = AnswerValidator.validate(blocks: parsed.blocks, sources: sources)

        // One repair call. A zero-citation answer next to adopted sources is
        // worth one retry; after that the prose is preserved with an explicit
        // warning instead of being blanked.
        if !parsed.blocks.isEmpty,
           validation.validCitations.isEmpty,
           hasAdoptedExternal,
           await preflight() {
            let repairUser = user + "\n\n" + AnswerPrompt.searchRepair(language)
            do {
                let response = try await answer(system, repairUser, Self.answerTokens)
                let repaired = AnswerParser.parse(response.text, fallbackKind: parsed.kind)
                let repairedValidation = AnswerValidator.validate(
                    blocks: repaired.blocks,
                    sources: sources
                )
                if !repaired.blocks.isEmpty, !repairedValidation.validCitations.isEmpty {
                    parsed = repaired
                    validation = repairedValidation
                    truncated = truncated || response.truncated
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Keep the original answer; the basis will say it is unverified.
            }
        }

        retrieval.invalidCitationCount = validation.invalidCitations
        retrieval.uncitedFactualSentences = validation.uncitedFactualSentences
        if validation.invalidCitations > 0 { retrieval.add(.partialCitations) }
        let basis = AnswerValidator.basis(
            sources: sources,
            blocks: parsed.blocks,
            validation: validation
        )
        retrieval.basis = basis

        if parsed.blocks.isEmpty {
            return AnswerDocument(
                kind: parsed.kind,
                oneLine: L10n.string("reader.search.noCitations", language: language),
                blocks: [],
                sources: sources,
                mode: mode,
                model: model,
                thinking: thinking,
                generatedAt: now(),
                question: cleanedQuestion,
                truncated: truncated,
                retrieval: retrieval
            )
        }

        return AnswerDocument(
            kind: parsed.kind,
            oneLine: parsed.oneLine,
            blocks: parsed.blocks,
            sources: sources,
            mode: mode,
            model: model,
            thinking: thinking,
            generatedAt: now(),
            question: cleanedQuestion,
            truncated: truncated,
            retrieval: retrieval
        )
    }

    private func emptyAnswer(
        question: String,
        note: RetrievalNote,
        retrieval: RetrievalEvidence,
        mode: AnswerMode
    ) -> AnswerDocument {
        var evidence = retrieval
        evidence.basis = .insufficientMaterial
        evidence.add(note)
        return AnswerDocument(
            kind: .term,
            oneLine: note.message(language),
            blocks: [],
            sources: [],
            mode: mode,
            model: model,
            thinking: thinking,
            generatedAt: now(),
            question: question,
            retrieval: evidence
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
            cacheWriteTokens: max(current.cacheWriteTokens, next.cacheWriteTokens),
            reportedCost: next.reportedCost ?? current.reportedCost
        )
    }
}
