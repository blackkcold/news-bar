import XCTest
@testable import NewsBar

final class AISearchArchiveViewTests: XCTestCase {
    func testArchiveFilterMatchesQuestionPageAndAnswerSummary() {
        let entries = [
            makeEntry(query: "Question needle", pageTitle: "Other page", summary: "Other answer"),
            makeEntry(query: "Other question", pageTitle: "Page needle", summary: "Other answer"),
            makeEntry(query: "Other question", pageTitle: "Other page", summary: "Answer needle"),
            makeEntry(query: "Unrelated", pageTitle: "Unrelated", summary: "Unrelated"),
        ]

        let filtered = AISearchArchiveView.filteredEntries(entries, query: "nEeDlE")

        XCTAssertEqual(Set(filtered.map(\.id)), Set(entries.prefix(3).map(\.id)))
    }

    func testArchiveReplayPreservesCitations() {
        let entry = makeEntry(
            query: "Why did it happen?",
            pageTitle: "Current page",
            summary: "A short answer",
            sources: [
                AISearchSource(
                    index: 1,
                    url: "https://source-one.example/article",
                    title: "Source one",
                    text: "Private fetched body one"
                ),
                AISearchSource(
                    index: 2,
                    url: "https://source-two.example/article",
                    title: "Source two",
                    text: "Private fetched body two"
                ),
                AISearchSource(
                    index: 3,
                    url: "https://source.example/article?ref=reader#top",
                    title: "Source article",
                    text: "Private fetched body"
                )
            ],
            citationText: "Explanation [3]"
        )

        let replay = AISearchArchiveView.restoredAnswer(for: entry)

        XCTAssertEqual(replay.question, "Why did it happen?")
        XCTAssertEqual(replay.citationIndices, [3])
        XCTAssertEqual(replay.sources.map(\.index), [1, 2, 3])
        XCTAssertEqual(replay.sources.map(\.title), ["Source one", "Source two", "Source article"])
        XCTAssertEqual(replay.sources.last?.url, "https://source.example/article?ref=reader")
        XCTAssertEqual(replay.sources.map(\.text), ["", "", ""])
    }

    private func makeEntry(
        query: String,
        pageTitle: String?,
        summary: String,
        sources: [AISearchSource] = [],
        citationText: String = ""
    ) -> AISearchArchiveEntry {
        let answer = AnswerDocument(
            kind: .event,
            oneLine: summary,
            blocks: [AnswerBlock(id: 0, heading: "Details", body: citationText)],
            sources: sources,
            mode: .web,
            model: "test-model",
            thinking: .off,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            question: query
        )
        return AISearchArchiveEntry(
            query: query,
            scope: .web,
            origin: .readerSearch,
            pageTitle: pageTitle,
            pageURL: "https://reader.example/page",
            providerName: "Test provider",
            answer: answer
        )
    }
}
