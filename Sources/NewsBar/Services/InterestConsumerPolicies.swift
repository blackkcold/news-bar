import Foundation

struct ResearchCandidate: Sendable {
    let item: NewsItem
    let publicHeat: Double?
    let personalRelevance: Double
    let researchPriority: Double
}

enum ResearchSelectionPolicy {
    static func select(items: [NewsItem], state: LocalInterestState, limit: Int) -> [ResearchCandidate] {
        guard limit > 0 else { return [] }
        let snapshot = RecommendationEngine.rank(items: items, state: state, limit: items.count)
        var candidates = snapshot.items.map { row in
            ResearchCandidate(item: row.item, publicHeat: row.item.hotLabel == "爆" ? row.components["publicHeat"] : nil,
                              personalRelevance: row.components["interest"] ?? 0, researchPriority: row.score)
        }
        var selected: [ResearchCandidate] = []
        if let publicIndex = candidates.indices.filter({ candidates[$0].publicHeat != nil }).max(by: {
            (candidates[$0].publicHeat ?? 0) < (candidates[$1].publicHeat ?? 0)
        }) {
            selected.append(candidates.remove(at: publicIndex))
        }
        candidates.sort {
            if $0.personalRelevance != $1.personalRelevance { return $0.personalRelevance > $1.personalRelevance }
            return $0.researchPriority > $1.researchPriority
        }
        selected.append(contentsOf: candidates.prefix(max(0, limit - selected.count)))
        return selected
    }
}

enum NotificationSelectionPolicy {
    static func select(items: [NewsItem], state: LocalInterestState, count: Int) -> [NewsItem] {
        guard count > 0 else { return [] }
        let eligible = items.filter {
            !state.isBlocked($0) && (!state.learningEnabled || state.evidence(for: ContentIdentity.id(for: $0.url)) < 1)
        }
        return RecommendationEngine.rank(items: eligible, state: state, limit: count).items.map(\.item)
    }
}
