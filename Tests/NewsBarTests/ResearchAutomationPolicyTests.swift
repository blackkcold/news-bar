import XCTest
@testable import NewsBar

final class ResearchAutomationPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstRunIsAllowed() {
        XCTAssertTrue(
            ResearchAutomationPolicy.allows(
                now: now,
                lastStartedAt: nil,
                activeAutomaticRuns: 0
            )
        )
    }

    func testSecondRunInsideTheHourIsBlocked() {
        XCTAssertFalse(
            ResearchAutomationPolicy.allows(
                now: now,
                lastStartedAt: now.addingTimeInterval(-59 * 60),
                activeAutomaticRuns: 0
            )
        )
    }

    func testRunAtExactlyOneHourIsAllowed() {
        XCTAssertTrue(
            ResearchAutomationPolicy.allows(
                now: now,
                lastStartedAt: now.addingTimeInterval(-ResearchAutomationPolicy.minimumInterval),
                activeAutomaticRuns: 0
            )
        )
    }

    func testActiveAutomaticJobBlocksEvenAfterTheWindow() {
        XCTAssertFalse(
            ResearchAutomationPolicy.allows(
                now: now,
                lastStartedAt: nil,
                activeAutomaticRuns: 1
            )
        )
    }

    func testCheapSkipsDoNotConsumeTheHourlyCheckWindow() {
        XCTAssertFalse(ResearchAutomationPolicy.skipConsumesCheckWindow(.skippedNoCandidates))
        XCTAssertFalse(ResearchAutomationPolicy.skipConsumesCheckWindow(.skippedKeywordPriority))
        XCTAssertTrue(ResearchAutomationPolicy.skipConsumesCheckWindow(.skippedNoWorthy))
        XCTAssertTrue(ResearchAutomationPolicy.skipConsumesCheckWindow(.skippedNotStarted))
        XCTAssertTrue(ResearchAutomationPolicy.skipConsumesCheckWindow(.triageFailed))
        XCTAssertTrue(ResearchAutomationPolicy.skipConsumesCheckWindow(.skippedBudget))
    }

    func testHandledKeywordMatchDoesNotBlockInferredInterest() {
        let item = NewsItem(
            title: "OpenAI 新模型发布",
            url: "https://example.com/keyword",
            source: .rss(name: "Example", url: "https://example.com/rss")
        )
        let pair = "OpenAI\n\(item.title)"

        XCTAssertFalse(ResearchKeywordPriority.hasUnprocessedMatch(
            items: [item],
            keywords: ["OpenAI"],
            handledPairs: [pair],
            handledTitles: [],
            isBlocked: { _ in false }
        ))
    }

    func testNewKeywordMatchStillBlocksInferredInterest() {
        let item = NewsItem(
            title: "OpenAI 新模型发布",
            url: "https://example.com/keyword",
            source: .rss(name: "Example", url: "https://example.com/rss")
        )

        XCTAssertTrue(ResearchKeywordPriority.hasUnprocessedMatch(
            items: [item],
            keywords: ["OpenAI"],
            handledPairs: [],
            handledTitles: [],
            isBlocked: { _ in false }
        ))
    }

    func testBlockedOrAlreadyHandledTitleDoesNotBlockInferredInterest() {
        let blocked = NewsItem(
            title: "OpenAI 已屏蔽",
            url: "https://example.com/blocked",
            source: .rss(name: "Example", url: "https://example.com/rss")
        )
        let handled = NewsItem(
            title: "OpenAI 已研究",
            url: "https://example.com/handled",
            source: .rss(name: "Example", url: "https://example.com/rss")
        )

        XCTAssertFalse(ResearchKeywordPriority.hasUnprocessedMatch(
            items: [blocked, handled],
            keywords: ["OpenAI"],
            handledPairs: [],
            handledTitles: [handled.title],
            isBlocked: { $0.id == blocked.id }
        ))
    }

    func testCheapCheckIntervalOnlyBoundsRepeatedCheapSkips() {
        XCTAssertTrue(ResearchAutomationPolicy.cheapCheckAllows(now: now, lastCheapCheckAt: nil))
        XCTAssertFalse(ResearchAutomationPolicy.cheapCheckAllows(
            now: now,
            lastCheapCheckAt: now.addingTimeInterval(-299)
        ))
        XCTAssertTrue(ResearchAutomationPolicy.cheapCheckAllows(
            now: now,
            lastCheapCheckAt: now.addingTimeInterval(-ResearchAutomationPolicy.cheapCheckInterval)
        ))
    }

    func testRemainingCooldownRoundsDownToZeroAtTheBoundary() {
        XCTAssertEqual(
            ResearchAutomationPolicy.remainingCooldown(
                now: now,
                lastStartedAt: now.addingTimeInterval(-3_600)
            ),
            0
        )
        XCTAssertEqual(
            ResearchAutomationPolicy.remainingCooldown(
                now: now,
                lastStartedAt: now.addingTimeInterval(-1_800)
            ),
            1_800
        )
        XCTAssertEqual(
            ResearchAutomationPolicy.remainingCooldown(now: now, lastStartedAt: nil),
            0
        )
    }
}
