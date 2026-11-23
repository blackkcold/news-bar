import Foundation

/// A domain that can be shown as a source group. Whitespace-only domains are
/// treated as missing so the metrics and the source index agree.
private func hasSourceDomain(_ domain: String) -> Bool {
    !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// Read-only counts shown in the report's conclusion header. Every value is
/// derived from the report itself; nothing is estimated or inferred.
struct ResearchReportMetrics: Equatable, Sendable {
    let evidenceCount: Int
    let verifiedQuoteCount: Int
    let domainCount: Int
    let claimCount: Int
    let claimsWithVerifiedEvidenceCount: Int
    let claimsNeedingEvidenceCount: Int
    let conflictCount: Int
    let missingCount: Int
    let timelineNodeCount: Int
    /// Nil when fewer than two timeline nodes carry a sortable date.
    let timelineSpanDays: Int?
    let independentSourceCount: Int

    init(report: BurstResearch) {
        let evidenceByID = Dictionary(
            report.evidence.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let claims = report.verification?.claims ?? []

        evidenceCount = report.evidence.count
        verifiedQuoteCount = report.evidence.filter(\.quoteVerified).count
        // A missing domain cannot be shown as a source group, so it is not a domain.
        domainCount = Set(report.evidence.map(\.domain).filter(hasSourceDomain)).count
        claimCount = claims.count
        claimsWithVerifiedEvidenceCount = claims.filter { claim in
            claim.evidenceIDs.contains { evidenceByID[$0]?.quoteVerified == true }
        }.count
        claimsNeedingEvidenceCount = max(0, claimCount - claimsWithVerifiedEvidenceCount)
        conflictCount = report.verification?.conflicts.count ?? 0
        missingCount = report.verification?.missing.count ?? 0
        timelineNodeCount = report.timeline.count
        independentSourceCount = report.verification?.independentSources ?? 0
        timelineSpanDays = Self.spanDays(for: report.timeline)
    }

    private static func spanDays(for timeline: [TimelineNode]) -> Int? {
        let dates = timeline.compactMap(\.sortDate)
        guard let earliest = dates.min(), let latest = dates.max(), dates.count >= 2 else {
            return nil
        }
        let days = Calendar(identifier: .gregorian)
            .dateComponents([.day], from: earliest, to: latest)
            .day ?? 0
        return max(0, days)
    }

    /// The span worth writing down. `timelineSpanDays == 0` is a real value —
    /// every dated node falls on one day — but "span 0 days" reads like a bug,
    /// so the display layer falls back to a plain node count instead.
    var displaySpanDays: Int? {
        guard let timelineSpanDays, timelineSpanDays > 0 else { return nil }
        return timelineSpanDays
    }
}

// MARK: - Source grouping

/// One domain's evidence, in natural ID order (E2 before E10).
struct ResearchSourceGroup: Identifiable, Equatable, Hashable, Sendable {
    let domain: String
    let items: [EvidenceItem]

    var id: String { domain }
}

enum ResearchSourceGrouping {
    /// Groups evidence by domain. Groups with more items come first; ties are
    /// broken by domain so the index is stable across runs. Evidence without a
    /// domain is skipped: it would otherwise render a blank group.
    static func groups(for evidence: [EvidenceItem]) -> [ResearchSourceGroup] {
        Dictionary(grouping: evidence.filter { hasSourceDomain($0.domain) }, by: \.domain)
            .map { domain, items in
                ResearchSourceGroup(domain: domain, items: items.sorted(by: itemOrder))
            }
            .sorted { lhs, rhs in
                if lhs.items.count != rhs.items.count {
                    return lhs.items.count > rhs.items.count
                }
                return lhs.domain < rhs.domain
            }
    }

    private static func itemOrder(_ lhs: EvidenceItem, _ rhs: EvidenceItem) -> Bool {
        let left = numericSuffix(of: lhs.id) ?? .max
        let right = numericSuffix(of: rhs.id) ?? .max
        if left != right { return left < right }
        return lhs.id < rhs.id
    }

    /// Trailing digits of an ID such as `E10`; nil when the ID has none.
    private static func numericSuffix(of id: String) -> Int? {
        let digits = String(id.reversed().prefix { $0.isNumber }.reversed())
        return digits.isEmpty ? nil : Int(digits)
    }
}

// MARK: - Historical display

enum ResearchReportDisplay {
    /// The report to render: an explicitly selected version wins over the
    /// record's latest report.
    static func report(
        selectedVersion: WorkspaceReportVersion?,
        record: ResearchRecord?
    ) -> BurstResearch? {
        selectedVersion?.report ?? record?.report
    }

    /// True only when a selected version differs from the record's latest
    /// report. Without both sides there is nothing to compare.
    static func isHistorical(
        selectedVersion: WorkspaceReportVersion?,
        record: ResearchRecord?
    ) -> Bool {
        guard let selectedVersion, let latest = record?.report else { return false }
        return WorkspaceReportDigest.make(selectedVersion.report)
            != WorkspaceReportDigest.make(latest)
    }
}
