import XCTest
@testable import NewsBar

/// The reveal clock, tested as a counting rule instead of as a timer.
///
/// How many frames a burst needs is what decides how often the whole answer is
/// rebuilt, and that rate is the reason the canvas used to paint the previous
/// frame's text under the new one. A 600-character burst used to take a dozen
/// frames at 30 fps; it must now land in a handful at 15 fps.
@MainActor
final class AnswerRevealTests: XCTestCase {
    func testABurstIsOnScreenInWellUnderASecond() {
        var remaining = 600
        var frames = 0
        while remaining > 0, frames < 40 {
            remaining -= min(remaining, AnswerReveal.step(remaining: remaining))
            frames += 1
        }
        XCTAssertEqual(remaining, 0)
        // 8 frames at 66 ms is half a second.
        XCTAssertLessThanOrEqual(frames, 8)
    }

    func testEveryFrameAdvancesEvenOnAShortTail() {
        for remaining in 1...400 {
            XCTAssertGreaterThanOrEqual(AnswerReveal.step(remaining: remaining), 1, "remaining \(remaining)")
        }
    }

    func testTheFrameStepNeverOvershootsTheTextItIsRevealing() {
        // The clock clamps with `min`, but the rule itself must stay proportional
        // for large remainders or a long answer would jump in one frame.
        XCTAssertLessThan(AnswerReveal.step(remaining: 3_000), 3_000)
        XCTAssertGreaterThan(AnswerReveal.step(remaining: 3_000), AnswerReveal.step(remaining: 300))
    }
}
