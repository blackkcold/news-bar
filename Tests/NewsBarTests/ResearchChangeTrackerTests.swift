import XCTest
@testable import NewsBar

final class ResearchChangeTrackerTests: XCTestCase {
    private func node(_ value: String) -> TimelineNode {
        TimelineNode(date: value, title: value, detail: value)
    }

    func testOnlySameTopicReportsAreComparedNewestFirst() {
        let current = researchTestRecord(
            title: "Fictional topic",
            updatedAt: Date(timeIntervalSince1970: 3_000),
            report: BurstResearch(
                summary: "current",
                overview: "current overview",
                timeline: [node("b"), node("c")]
            )
        )
        let older = researchTestRecord(
            title: "Fictional topic",
            updatedAt: Date(timeIntervalSince1970: 1_000),
            report: BurstResearch(
                summary: "older",
                overview: "older overview",
                timeline: [node("a")]
            )
        )
        let newer = researchTestRecord(
            title: "Fictional topic",
            updatedAt: Date(timeIntervalSince1970: 2_000),
            report: BurstResearch(
                summary: "newer",
                overview: "",
                timeline: [node("a"), node("b"), node("d")]
            )
        )
        let unrelated = researchTestRecord(
            title: "Other topic",
            updatedAt: Date(timeIntervalSince1970: 4_000),
            report: BurstResearch(summary: "other")
        )
        let failed = researchTestRecord(
            title: "Fictional topic",
            updatedAt: Date(timeIntervalSince1970: 5_000),
            report: nil
        )

        let changes = ResearchChangeTracker.changes(
            current: current,
            previous: [older, unrelated, newer, current, failed]
        )

        XCTAssertEqual(changes.map(\.id), [newer.id, older.id])
        XCTAssertEqual(changes[0].timelineDelta, 1)
        XCTAssertTrue(changes[0].summaryChanged)
        XCTAssertEqual(changes[1].timelineDelta, -1)
        XCTAssertEqual(changes[1].evidenceCount, 0)
        XCTAssertEqual(changes[1].sourceCount, 0)
    }

    func testLimitKeepsNewestChanges() {
        let current = researchTestRecord(
            title: "Topic",
            report: BurstResearch(summary: "current")
        )
        let previous = (0..<8).map { index in
            researchTestRecord(
                title: "Topic",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                report: BurstResearch(summary: "v\(index)")
            )
        }

        let changes = ResearchChangeTracker.changes(
            current: current,
            previous: previous,
            limit: 3
        )

        XCTAssertEqual(changes.count, 3)
        XCTAssertEqual(changes.map(\.summary), ["v7", "v6", "v5"])
    }
}
