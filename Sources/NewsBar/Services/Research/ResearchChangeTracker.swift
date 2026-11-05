import Foundation

/// One previous version of the same research topic. Only records with the same
/// `topicKey` are compared; unrelated topics are never presented as history.
struct ResearchChange: Identifiable, Sendable, Equatable {
    let id: String
    let updatedAt: Date
    let summary: String
    let overview: String
    let evidenceCount: Int
    let timelineCount: Int
    let sourceCount: Int
    let verdict: VerificationReport.Verdict?
    let evidenceDelta: Int
    let timelineDelta: Int
    let summaryChanged: Bool
}

enum ResearchChangeTracker {
    /// Newest first. The current record is excluded; only records with a stored
    /// report participate, so failed runs never appear as a "change".
    static func changes(
        current: ResearchRecord,
        previous: [ResearchRecord],
        limit: Int = 5
    ) -> [ResearchChange] {
        let currentReport = current.report
        return previous
            .filter {
                $0.id != current.id
                    && $0.topicKey == current.topicKey
                    && $0.report != nil
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(max(0, limit))
            .compactMap { record in
                guard let report = record.report else { return nil }
                return ResearchChange(
                    id: record.id,
                    updatedAt: record.updatedAt,
                    summary: report.summary,
                    overview: report.overview,
                    evidenceCount: report.evidence.count,
                    timelineCount: report.timeline.count,
                    sourceCount: report.sources.count,
                    verdict: report.verification?.verdict,
                    evidenceDelta: report.evidence.count - (currentReport?.evidence.count ?? 0),
                    timelineDelta: report.timeline.count - (currentReport?.timeline.count ?? 0),
                    summaryChanged: report.summary != (currentReport?.summary ?? "")
                )
            }
    }
}
