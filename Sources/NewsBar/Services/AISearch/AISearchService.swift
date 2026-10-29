import Foundation

/// Orchestrates one reader AI search: optional web search → page reading →
/// one model answer → citation validation.
///
/// All I/O is injected so the state machine, reading order, page limit and
/// citation rule can be tested without a network or an AI provider.
struct AISearchService: Sendable {
    typealias SearchHandler = @Sendable (_ query: String, _ limit: Int) async throws -> [SearchHit]
    typealias ReadHandler = @Sendable (SearchHit) async throws -> ResearchDocument?
    typealias AnswerHandler = @Sendable (_ system: String, _ user: String, _ maxTokens: Int) async throws -> AIChatResponse

    static let answerTokens = 1_200

    let search: SearchHandler
    let read: ReadHandler
    let answer: AnswerHandler
    let reserve: @Sendable () async -> Bool
    let settle: @Sendable (AIChatResponse) async -> Void
    let now: @Sendable () -> Date
    let pageCount: Int
    let thinking: AIThinkingLevel
    let model: String
    let language: AppLanguage

    func run(
        question: String,
        scope: AISearchScope,
        page: AISearchPageContext?,
        onStage: @Sendable (AISearchStage) async -> Void = { _ in }
    ) async throws -> AISearchAnswer {
        let cleanedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedQuestion.isEmpty else { throw AISearchError.emptyQuestion }

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

            for (offset, hit) in selected.enumerated() {
                try Task.checkCancellation()
                await onStage(.reading(index: offset + 1, total: selected.count))
                do {
                    guard let document = try await read(hit) else { continue }
                    let text = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard text.count >= 200 else { continue }
                    sources.append(AISearchSource(
                        index: sources.count + 1,
                        url: document.url,
                        title: document.title.isEmpty ? hit.title : document.title,
                        text: text
                    ))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // One unreadable result must not abort the whole answer.
                    continue
                }
            }
            guard !sources.isEmpty else { throw AISearchError.noSourcesReadable }
        }

        try Task.checkCancellation()
        await onStage(.answering)
        // The global daily ledger is the single quota authority; an AI search
        // call is reserved exactly like a summary call.
        guard await reserve() else { throw AISearchError.quotaUnavailable }

        let response: AIChatResponse
        do {
            response = try await answer(
                AISearchPrompts.system(language),
                AISearchPrompts.user(question: cleanedQuestion, scope: scope, sources: sources, language: language),
                Self.answerTokens
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AISearchError.modelFailed(error.localizedDescription)
        }
        await settle(response)

        let parsed = AISearchPrompts.parse(response.text, sources: sources, language: language)
        return AISearchAnswer(
            question: cleanedQuestion,
            answer: parsed.answer,
            citations: parsed.citations,
            fetchedSources: sources,
            thinkingLevel: thinking,
            model: model,
            scope: scope,
            searchedAt: now(),
            citationsUnavailable: parsed.unavailable
        )
    }
}
