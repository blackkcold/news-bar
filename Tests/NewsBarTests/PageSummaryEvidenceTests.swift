import XCTest
@testable import NewsBar

final class PageSummaryEvidenceTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        var searchedQueries: [SearchQuery] = []
        var readURLs: [String] = []
        var assessedIndexes: [Int] = []
    }

    private func hit(_ number: Int, url: String? = nil) -> SearchHit {
        SearchHit(
            url: url ?? "https://source\(number).example/story",
            title: "Source \(number)",
            snippet: "",
            provider: .tavily,
            providerRank: number
        )
    }

    private func document(
        for hit: SearchHit,
        text: String = String(repeating: "正文内容", count: 120)
    ) -> ResearchDocument {
        ResearchDocument(
            url: hit.url,
            title: hit.title,
            text: text,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            source: .direct
        )
    }

    private func source(
        _ index: Int,
        adoption: SourceAdoption,
        independence: SourceIndependence = .independent,
        type: SourceType = .primary
    ) -> AISearchSource {
        var source = AISearchSource(
            index: index,
            url: "https://source\(index).example/story",
            title: "Source \(index)",
            text: String(repeating: "正文内容", count: 120)
        )
        source.assessment = SourceAssessment(
            type: type,
            independence: independence,
            adoption: adoption,
            reason: adoption == .rejected ? .modelRejected : .assessed
        )
        return source
    }

    private func provider(
        search: @escaping PageSummaryEvidenceProvider.SearchHandler,
        read: @escaping PageSummaryEvidenceProvider.ReadHandler,
        assess: PageSummaryEvidenceProvider.AssessHandler? = nil
    ) -> PageSummaryEvidenceProvider {
        PageSummaryEvidenceProvider(search: search, read: read, assess: assess)
    }

    // MARK: - Policy

    func testPrivateReadingNeverSearches() {
        XCTAssertFalse(PageSummaryEvidencePolicy.shouldSearch(
            isPrivate: true,
            webSupplement: true,
            scope: .article
        ))
        XCTAssertFalse(PageSummaryEvidencePolicy.shouldSearch(
            isPrivate: false,
            webSupplement: false,
            scope: .article
        ))
        XCTAssertFalse(PageSummaryEvidencePolicy.shouldSearch(
            isPrivate: false,
            webSupplement: true,
            scope: .list
        ))
        XCTAssertTrue(PageSummaryEvidencePolicy.shouldSearch(
            isPrivate: false,
            webSupplement: true,
            scope: .article
        ))
    }

    func testCacheTTLPolicy() {
        XCTAssertEqual(
            PageSummaryEvidencePolicy.cacheTTL(webSupplement: false, adoptedExternalCount: 0),
            PageSummaryCacheStore.retention
        )
        XCTAssertEqual(
            PageSummaryEvidencePolicy.cacheTTL(webSupplement: true, adoptedExternalCount: 0),
            PageSummaryEvidencePolicy.failedExternalTTL
        )
        XCTAssertEqual(
            PageSummaryEvidencePolicy.cacheTTL(webSupplement: true, adoptedExternalCount: 2),
            PageSummaryEvidencePolicy.externalTTL
        )
    }

    // MARK: - Provider

    func testTwoQueriesShareFourAttemptsAndDegradeToSearchUnavailable() async {
        let ticketBox = Box()
        let result = await provider(
            search: { query, ticket in
                ticketBox.searchedQueries.append(query)
                _ = ticket.consume()
                _ = ticket.consume()
                throw SearchUnavailableError(failures: [])
            },
            read: { _ in .failed(.unknown) }
        ).collect(
            title: "Test article",
            excerpt: "First sentence. Second sentence.",
            currentPageURL: "https://current.example/story",
            language: .en
        )

        XCTAssertEqual(result.evidence.basis, .searchUnavailable)
        XCTAssertTrue(result.searchAttempted)
        XCTAssertTrue(result.evidence.retrieval?.notes.contains(.searchUnavailable) ?? false)
        XCTAssertEqual(ticketBox.searchedQueries.count, 2)
    }

    func testNoResultsReturnsPageOnly() async {
        let result = await provider(
            search: { _, _ in [] },
            read: { _ in .failed(.unknown) }
        ).collect(
            title: "Test article",
            excerpt: "First sentence.",
            currentPageURL: "https://current.example/story",
            language: .en
        )
        XCTAssertEqual(result.evidence.basis, .pageOnly)
        XCTAssertTrue(result.evidence.retrieval?.notes.contains(.noResults) ?? false)
        XCTAssertTrue(result.evidence.sources.isEmpty)
    }

    func testUnreadablePagesReturnPageOnly() async {
        let result = await provider(
            search: { _, _ in [self.hit(1)] },
            read: { _ in .failed(.transport) }
        ).collect(
            title: "Test article",
            excerpt: "First sentence.",
            currentPageURL: "https://current.example/story",
            language: .en
        )
        XCTAssertEqual(result.evidence.basis, .pageOnly)
        XCTAssertTrue(result.evidence.retrieval?.notes.contains(.noSourcesReadable) ?? false)
    }

    func testCurrentPageURLIsNotReadAsExternal() async {
        let box = Box()
        let current = hit(1, url: "https://current.example/story")
        let external = hit(2)
        let result = await provider(
            search: { _, _ in [current, external] },
            read: { hit in
                box.readURLs.append(hit.url)
                return .document(self.document(for: hit))
            },
            assess: { _, _, sources in
                EvidenceAssessor.heuristic(question: "q", sources: sources)
            }
        ).collect(
            title: "Test article",
            excerpt: "First sentence.",
            currentPageURL: current.url,
            language: .en
        )
        XCTAssertEqual(box.readURLs, [external.url])
        XCTAssertEqual(result.evidence.sources.map(\.url), [external.url])
        XCTAssertEqual(result.evidence.sources.first?.index, 2)
    }

    func testAssessmentRunsBeforeRemapAndConflictsAreShifted() async {
        let box = Box()
        let result = await provider(
            search: { _, _ in [self.hit(1)] },
            read: { hit in .document(self.document(for: hit)) },
            assess: { _, _, sources in
                box.assessedIndexes = sources.map(\.index)
                return AssessmentResult(
                    sources: [self.source(1, adoption: .primary)],
                    conflicts: [
                        EvidenceConflict(claim: "a", indices: [1], note: "b"),
                    ],
                    notes: []
                )
            }
        ).collect(
            title: "Test article",
            excerpt: "First sentence.",
            currentPageURL: "https://current.example/story",
            language: .en
        )

        XCTAssertEqual(box.assessedIndexes, [1])
        XCTAssertEqual(result.evidence.sources.first?.index, 2)
        XCTAssertEqual(result.evidence.sources.first?.assessment?.adoption, .primary)
        XCTAssertEqual(result.evidence.conflicts.first?.indices, [2])
        XCTAssertEqual(result.evidence.basis, .externalSupported)
        XCTAssertEqual(result.evidence.retrieval?.adoptedCount, 1)
    }

    func testAllRejectedSourcesStayVisibleButBasisIsPageOnly() async {
        let result = await provider(
            search: { _, _ in [self.hit(1)] },
            read: { hit in .document(self.document(for: hit)) },
            assess: { _, _, _ in
                AssessmentResult(
                    sources: [self.source(1, adoption: .rejected)],
                    conflicts: [],
                    notes: [.assessmentFailed]
                )
            }
        ).collect(
            title: "Test article",
            excerpt: "First sentence.",
            currentPageURL: "https://current.example/story",
            language: .en
        )
        XCTAssertEqual(result.evidence.basis, .pageOnly)
        XCTAssertEqual(result.evidence.retrieval?.adoptedCount, 0)
        XCTAssertEqual(result.evidence.sources.first?.index, 2)
        XCTAssertEqual(result.evidence.sources.first?.assessment?.adoption, .rejected)
        XCTAssertTrue(result.evidence.retrieval?.notes.contains(.assessmentFailed) ?? false)
    }
}
