import Foundation

/// View-facing projection of a report. Kept free of SwiftUI so the coverage
/// rules can be unit tested without rendering.
struct ReportPresentation: Sendable {
    enum NodeState: Sendable, Equatable {
        case verified
        case citedUnverified
        case unsourced
    }

    /// What the report can honestly claim. Derived from the report itself, not
    /// from the run status: a "partial" run can still carry a complete report,
    /// and a "ready" record can carry zero evidence.
    enum Outcome: Sendable, Equatable {
        case legacy
        /// At least one quote was found verbatim in a fetched page.
        case complete
        /// Evidence exists, but no quote passed the verbatim check.
        case partialEvidence
        /// Sources were read, yet no quote could be extracted.
        case insufficientEvidence
        /// No search provider produced a usable response.
        case searchUnavailable
    }

    struct Node: Sendable, Identifiable {
        let node: TimelineNode
        let state: NodeState
        let evidence: [EvidenceItem]

        var id: String { node.id }
    }

    let nodes: [Node]
    let verifiedNodeCount: Int
    let citedNodeCount: Int
    let unsourcedNodeCount: Int
    let citedUnverifiedNodeCount: Int
    let evidenceCount: Int
    let verifiedEvidenceCount: Int
    let claimCount: Int
    let conflictCount: Int
    let missingCount: Int
    let verdict: VerificationReport.Verdict?
    let strength: Int
    let hasVerification: Bool
    let hasEvidence: Bool
    let isLegacy: Bool
    let outcome: Outcome

    init(report: BurstResearch, isLegacy: Bool = false) {
        let evidenceByID = Dictionary(
            report.evidence.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let mappedNodes = report.timeline.map { node -> Node in
            let resolved = node.evidenceIDs.compactMap { evidenceByID[$0] }
            let state: NodeState
            if resolved.isEmpty {
                state = .unsourced
            } else if resolved.contains(where: \.quoteVerified) {
                state = .verified
            } else {
                state = .citedUnverified
            }
            return Node(node: node, state: state, evidence: resolved)
        }
        self.nodes = mappedNodes
        self.verifiedNodeCount = mappedNodes.filter { $0.state == .verified }.count
        self.citedNodeCount = mappedNodes.filter { $0.state != .unsourced }.count
        self.unsourcedNodeCount = mappedNodes.filter { $0.state == .unsourced }.count
        self.citedUnverifiedNodeCount = mappedNodes.filter { $0.state == .citedUnverified }.count
        self.evidenceCount = report.evidence.count
        self.verifiedEvidenceCount = report.evidence.filter(\.quoteVerified).count
        self.claimCount = report.verification?.claims.count ?? 0
        self.conflictCount = report.verification?.conflicts.count ?? 0
        self.missingCount = report.verification?.missing.count ?? 0
        self.verdict = report.verification?.verdict
        self.strength = report.verification?.strength ?? 0
        self.hasVerification = report.verification != nil
        self.hasEvidence = !report.evidence.isEmpty
        self.isLegacy = isLegacy
        self.outcome = Self.outcome(for: report, isLegacy: isLegacy)
    }

    private static func outcome(for report: BurstResearch, isLegacy: Bool) -> Outcome {
        if isLegacy { return .legacy }
        if report.evidence.isEmpty {
            // A saved report with no evidence means pages or snippets were
            // available but no quote could be extracted. A run with no material
            // at all now fails before synthesis, so it never reaches this view.
            return report.searchStatus == .failed ? .searchUnavailable : .insufficientEvidence
        }
        return report.evidence.contains(where: \.quoteVerified) ? .complete : .partialEvidence
    }

    /// A report that has content but nothing traceable must be visibly
    /// distinguished from a verified one.
    var hasUnverifiedTimeline: Bool {
        !nodes.isEmpty && verifiedNodeCount < nodes.count
    }

    var isUnverified: Bool {
        verdict == .unverified
    }

    /// Evidence is the only thing that makes the claims/coverage panel honest.
    var showsVerificationSection: Bool { hasEvidence }

    /// Zero-evidence runs get an actionable gap card instead of an empty
    /// verification disclosure ("0 claims · 0 evidence").
    var showsEvidenceGap: Bool { !isLegacy && !hasEvidence }

    var claimsAreMeaningful: Bool { claimCount > 0 && hasEvidence }

    var legacyHasVerificationData: Bool { isLegacy && (claimCount > 0 || evidenceCount > 0) }

    /// Expand the verification disclosure by default only when hiding it could
    /// conceal counter-evidence. Unverified reports stay collapsed but keep a
    /// visible badge in the header.
    var expandsVerificationByDefault: Bool {
        conflictCount > 0 || verdict == .mixed || verdict == .refuted
    }
}
