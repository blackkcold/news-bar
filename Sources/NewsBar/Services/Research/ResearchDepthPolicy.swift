import Foundation

/// Where a research pass's depth is decided.
///
/// Depth drives how many search requests a pass may dispatch, and the gap round
/// made that number materially larger: a deep pass now plans six event queries
/// plus up to four follow-ups. Automatic research runs unattended against a
/// daily request cap (default 20), so a single deep automatic run would consume
/// almost the whole day's allowance before the user asked for anything.
///
/// The rule therefore caps the *automatic* path at standard and leaves the
/// manual path exactly as requested. It is a ceiling, not a floor: a user who
/// configures quick for automatic research still gets quick.
enum ResearchDepthPolicy {
    static func effectiveDepth(requested: ResearchDepth, isAutomatic: Bool) -> ResearchDepth {
        guard isAutomatic else { return requested }
        return requested == .deep ? .standard : requested
    }
}
