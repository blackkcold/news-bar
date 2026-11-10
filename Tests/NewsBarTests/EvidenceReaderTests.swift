import XCTest
@testable import NewsBar

final class EvidenceReaderTests: XCTestCase {
    private func candidate(
        _ number: Int,
        url: String? = nil,
        title: String? = nil,
        publishedAt: Date? = nil
    ) -> EvidencePageCandidate {
        let hit = SearchHit(
            url: url ?? "https://source\(number).example/story",
            title: title ?? "Source \(number)",
            snippet: "",
            publishedAt: publishedAt,
            provider: .tavily,
            providerRank: number
        )
        return EvidencePageCandidate(hit: hit, discoveredBy: .original)
    }

    private func document(
        for hit: SearchHit,
        text: String = String(repeating: "正文内容", count: 120),
        publishedAt: Date? = nil
    ) -> ResearchDocument {
        ResearchDocument(
            url: hit.url,
            title: hit.title,
            text: text,
            publishedAt: publishedAt,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            source: .direct
        )
    }

    func testShortPageIsRecordedButNotUsed() async throws {
        let c = candidate(1)
        let result = try await EvidenceReader.read(
            candidates: [c],
            read: { _ in .tooShort(3) },
            readLimit: 3
        )
        XCTAssertTrue(result.sources.isEmpty)
        XCTAssertEqual(result.statuses, [.tooShort(characters: 3)])
        XCTAssertEqual(result.readCount, 0)
    }

    func testFailedPageIsRecordedButNotFatal() async throws {
        let c = candidate(1)
        let result = try await EvidenceReader.read(
            candidates: [c],
            read: { _ in .failed(.blocked) },
            readLimit: 3
        )
        XCTAssertTrue(result.sources.isEmpty)
        XCTAssertEqual(result.statuses, [.failed(.blocked)])
    }

    func testMetadataFallsBackToTheHit() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let c = candidate(1, publishedAt: date)
        let hit = c.hit
        let result = try await EvidenceReader.read(
            candidates: [c],
            read: { _ in .document(self.document(for: hit, publishedAt: nil)) },
            readLimit: 1
        )
        XCTAssertEqual(result.sources.first?.publishedAt, date)
        XCTAssertEqual(result.sources.first?.origin, .web)
        XCTAssertEqual(result.sources.first?.provider, .tavily)
        XCTAssertNotNil(result.sources.first?.fetchedAt)
    }

    func testSameHostAndTitleIsMarkedDuplicate() async throws {
        let first = candidate(1, url: "https://example.com/a", title: "同一篇报道")
        let second = candidate(2, url: "https://example.com/b", title: "同一篇报道")
        let result = try await EvidenceReader.read(
            candidates: [first, second],
            read: { candidate in
                .document(self.document(
                    for: candidate,
                    text: String(repeating: "第一段正文内容甲。", count: 40)
                ))
            },
            readLimit: 2
        )
        XCTAssertEqual(result.sources.count, 2)
        XCTAssertNil(result.sources[0].duplicateOf)
        XCTAssertEqual(result.sources[1].duplicateOf, result.sources[0].id)
    }

    func testCrossDomainSameBodyIsMarkedDuplicate() async throws {
        let first = candidate(1, url: "https://one.example/a")
        let second = candidate(2, url: "https://two.example/b")
        let body = String(repeating: "这是一段被多家网站转载的正文。", count: 30)
        let result = try await EvidenceReader.read(
            candidates: [first, second],
            read: { candidate in
                .document(self.document(for: candidate, text: body))
            },
            readLimit: 2
        )
        XCTAssertEqual(result.sources.count, 2)
        XCTAssertEqual(result.sources[1].duplicateOf, result.sources[0].id)
    }

    func testReadLimitCountsSuccessesNotAttempts() async throws {
        let candidates = [candidate(1), candidate(2), candidate(3)]
        let result = try await EvidenceReader.read(
            candidates: candidates,
            read: { candidate in
                if candidate.url.contains("source1") {
                    return .failed(.transport)
                }
                return .document(self.document(for: candidate))
            },
            readLimit: 2
        )
        XCTAssertEqual(result.readCount, 2)
        XCTAssertEqual(result.sources.count, 2)
        XCTAssertEqual(result.statuses[0], .failed(.transport))
        XCTAssertEqual(result.statuses.filter { if case .read = $0 { return true }; return false }.count, 2)
    }

    func testProgressReportsEveryAttempt() async throws {
        let candidates = [candidate(1), candidate(2)]
        let box = ProgressBox()
        _ = try await EvidenceReader.read(
            candidates: candidates,
            read: { candidate in .document(self.document(for: candidate)) },
            readLimit: 2,
            onRead: { index, total in box.values.append((index, total)) }
        )
        XCTAssertEqual(box.values.map(\.0), [1, 2])
        XCTAssertEqual(box.values.map(\.1), [2, 2])
    }

    private final class ProgressBox: @unchecked Sendable {
        var values: [(Int, Int)] = []
    }
}
