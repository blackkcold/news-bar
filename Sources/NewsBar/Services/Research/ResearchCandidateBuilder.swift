import Foundation

/// One item the automatic selector is willing to research. `kind` is a tag for
/// ordering and explanation; `priority` is the existing recommendation score,
/// not a second scoring formula.
struct ResearchCandidateItem: Sendable, Equatable {
    enum Kind: Int, Sendable, Comparable {
        case burst = 0
        case personal = 1
        case publicHot = 2

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let item: NewsItem
    let kind: Kind
    let publicHeat: Double?
    let personalRelevance: Double
    let priority: Double

    var topicKey: String { TopicFingerprint.key(for: item.title) }
}

/// Builds the automatic-research candidate pool: bursts, high-interest items
/// and public-chart items, ranked by the one recommendation table. Anything
/// else (plain recency, low heat, low interest) is not worth an AI call.
enum ResearchCandidateBuilder {
    static let personalThreshold = 0.35
    static let publicHeatThreshold = 0.5

    static func build(
        items: [NewsItem],
        state: LocalInterestState,
        now: Date = Date(),
        limit: Int = 6,
        excludingTopicKeys: Set<String> = [],
        includePersonal: Bool = true,
        isKeywordMatch: (NewsItem) -> Bool = { _ in false }
    ) -> [ResearchCandidateItem] {
        guard limit > 0 else { return [] }
        let eligible = items.filter { item in
            guard !state.isBlocked(item) else { return false }
            // Explicit keywords own their own path; do not spend triage on them.
            guard !isKeywordMatch(item) else { return false }
            if case .rss = item.source, let published = item.publishedAt,
               now.timeIntervalSince(published) > 24 * 3600 {
                return false
            }
            return !excludingTopicKeys.contains(TopicFingerprint.key(for: item.title))
        }
        guard !eligible.isEmpty else { return [] }

        let snapshot = RecommendationEngine.rank(
            items: eligible,
            state: state,
            now: now,
            limit: eligible.count
        )
        var seenContent: Set<String> = []
        var seenCluster: Set<String> = []
        var result: [ResearchCandidateItem] = []
        for row in snapshot.items {
            guard seenContent.insert(row.contentID).inserted,
                  seenCluster.insert(row.clusterID).inserted else { continue }
            let personal = row.components["interest"] ?? 0
            let heat = row.components["publicHeat"]
            let kind: ResearchCandidateItem.Kind
            if row.item.hotLabel == "爆", heat != nil {
                kind = .burst
            } else if personal >= personalThreshold, includePersonal {
                kind = .personal
            } else if row.item.source.isBuiltIn, (heat ?? 0) >= publicHeatThreshold {
                kind = .publicHot
            } else {
                continue
            }
            result.append(ResearchCandidateItem(
                item: row.item,
                kind: kind,
                publicHeat: heat,
                personalRelevance: personal,
                priority: row.score
            ))
        }
        result.sort { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.item.id < rhs.item.id
        }
        return Array(result.prefix(limit))
    }

    /// Cheap pre-AI plausibility check. A pool with only low-heat public items
    /// and no matching interest is not worth a paid call.
    static func hasPlausibleCandidate(
        _ candidates: [ResearchCandidateItem],
        personalizationEnabled: Bool
    ) -> Bool {
        candidates.contains { candidate in
            if candidate.kind == .burst { return true }
            if personalizationEnabled, candidate.kind == .personal { return true }
            return (candidate.publicHeat ?? 0) >= publicHeatThreshold
        }
    }
}
