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
