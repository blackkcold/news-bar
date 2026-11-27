import XCTest
@testable import NewsBar

/// Automatic research runs on its own, so it must not be able to spend a day's
/// search allowance in one go. Deep now dispatches up to 18 requests per pass
/// (event round plus gap round), while the default automatic daily cap is 20 —
/// one deep automatic run would starve the rest of the day. The clamp lives in
/// a pure function so the rule is testable without running a pipeline.
final class ResearchDepthPolicyTests: XCTestCase {
    func testManualRunKeepsTheRequestedDepth() {
        XCTAssertEqual(
            ResearchDepthPolicy.effectiveDepth(requested: .deep, isAutomatic: false),
            .deep
        )
        XCTAssertEqual(
            ResearchDepthPolicy.effectiveDepth(requested: .quick, isAutomatic: false),
            .quick
        )
    }

    /// The default settings depth is what an automatic run would otherwise
    /// inherit, and it is configurable. Deep must not reach that path.
    func testAutomaticRunIsCappedAtStandard() {
        XCTAssertEqual(
            ResearchDepthPolicy.effectiveDepth(requested: .deep, isAutomatic: true),
            .standard
        )
    }

    /// The cap is a ceiling, not a floor: a user who configures quick for
    /// automatic research still gets quick.
    func testAutomaticRunKeepsAQuickerChoice() {
        XCTAssertEqual(
            ResearchDepthPolicy.effectiveDepth(requested: .quick, isAutomatic: true),
            .quick
        )
        XCTAssertEqual(
            ResearchDepthPolicy.effectiveDepth(requested: .standard, isAutomatic: true),
            .standard
        )
    }

    /// The profile's per-pass ceiling must stay above what deep actually plans,
    /// or the second round can never run. This is the constant the clamp exists
    /// to protect.
    func testDeepProfileFitsItsOwnRequestCeiling() {
        let deep = DepthProfile.profile(for: .deep)
        XCTAssertLessThanOrEqual(
            deep.queryCount + deep.gapQueryCount,
            DepthProfile.maxSearchHTTPCallsPerTask
        )
    }
}
