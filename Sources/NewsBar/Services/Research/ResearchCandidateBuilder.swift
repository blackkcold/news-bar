import Foundation

/// One item the automatic selector is willing to research. `kind` is a tag for
/// ordering and explanation; `priority` is the existing recommendation score,
/// not a second scoring formula.
struct ResearchCandidateItem: Sendable, Equatable {
    enum Kind: Int, Sendable, Comparable {
        case publicImpact = 0
        case keyword = 1
        case burst = 2
        case publicHot = 3
        case personal = 4

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let item: NewsItem
    let kind: Kind
    let publicHeat: Double?
    let personalRelevance: Double
    let priority: Double
    let eventID: String?
    let isUrgent: Bool

    init(
        item: NewsItem,
        kind: Kind,
        publicHeat: Double?,
        personalRelevance: Double,
        priority: Double,
        eventID: String? = nil,
        isUrgent: Bool = false
    ) {
        self.item = item
        self.kind = kind
        self.publicHeat = publicHeat
        self.personalRelevance = personalRelevance
        self.priority = priority
        self.eventID = eventID
        self.isUrgent = isUrgent
    }

    var topicKey: String { TopicFingerprint.key(for: item.title) }
}

/// Builds the automatic-research candidate pool. High-impact public events
/// enter without heat or personal-interest signals and precede personalization.
enum ResearchCandidateBuilder {
    static let personalThreshold = 0.35
    static let publicHeatThreshold = 0.5
    static let publicImportanceThreshold = 20

    static func build(
        items: [NewsItem],
        state: LocalInterestState,
        now: Date = Date(),
        limit: Int = 6,
        excludingTopicKeys: Set<String> = [],
        lastResearchedAtByTopicKey: [String: Date] = [:],
        publicImportanceItemIDs: Set<String> = [],
        eventIDByItemID: [String: String] = [:],
        urgentEventIDs: Set<String> = [],
        includePersonal: Bool = true,
        isKeywordMatch: (NewsItem) -> Bool = { _ in false }
    ) -> [ResearchCandidateItem] {
        guard limit > 0 else { return [] }
        var seenURLs: Set<String> = []
        var seenHeadlines: Set<String> = []
        let eligible = items.filter { item in
            guard !state.isBlocked(item) else { return false }
            if case .rss = item.source, let published = item.publishedAt,
               now.timeIntervalSince(published) > 24 * 3600 {
                return false
            }
            let topicKey = TopicFingerprint.key(for: item.title)
            if excludingTopicKeys.contains(topicKey) {
                guard let publishedAt = item.publishedAt,
                      let lastResearchedAt = lastResearchedAtByTopicKey[topicKey],
                      publishedAt > lastResearchedAt else { return false }
            }
            let url = ContentIdentity.canonicalURL(item.url)
            let headline = TopicFingerprint.normalized(item.title)
            guard !headline.isEmpty,
                  seenHeadlines.insert(headline).inserted else { return false }
            return url.isEmpty || seenURLs.insert(url).inserted
        }
        guard !eligible.isEmpty else { return [] }

        let snapshot = RecommendationEngine.rank(
            items: eligible,
            state: state,
            now: now,
            limit: eligible.count
        )
        var seenContent: Set<String> = []
        var seenEventIDs: Set<String> = []
        var result: [ResearchCandidateItem] = []
        for row in snapshot.items {
            guard seenContent.insert(row.contentID).inserted else { continue }
            let eventID = eventIDByItemID[row.item.id]
            if let eventID,
               !seenEventIDs.insert(eventID).inserted { continue }
            let isUrgent = eventID.map(urgentEventIDs.contains) ?? false
            let personal = row.components["interest"] ?? 0
            let heat = row.components["publicHeat"]
            let kind: ResearchCandidateItem.Kind
            if publicImportanceItemIDs.contains(row.item.id) || isUrgent {
                kind = .publicImpact
            } else if isKeywordMatch(row.item) {
                kind = .keyword
            } else if row.item.hotLabel == "爆", heat != nil {
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
                priority: row.score,
                eventID: eventID,
                isUrgent: isUrgent
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
            if candidate.kind == .publicImpact { return true }
            if candidate.kind == .keyword { return true }
            if candidate.kind == .burst { return true }
            if personalizationEnabled, candidate.kind == .personal { return true }
            return (candidate.publicHeat ?? 0) >= publicHeatThreshold
        }
    }
}
