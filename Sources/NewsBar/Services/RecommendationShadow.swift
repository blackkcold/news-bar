import Foundation

enum RecommendationExperimentGate {
    // Reserved for a separately approved experiment. No call site may use it
    // to select displayed rankings until the experiment has been designed.
    static let dashboardTimeBlocksEnabled = false
}

struct RecommendationShadowSample: Codable, Sendable {
    struct Lane: Codable, Sendable {
        let top10Sources: Int
        let largestSourceCount: Int
        let ruleViolations: Int
        let milliseconds: Double
    }

    let occurredAt: Date
    let candidateCount: Int
    let top10Overlap: Int
    let rankChanged: Int
    let absoluteRankMovement: Int
    let enteredTop10: Int
    let exitedTop10: Int
    let a: Lane
    let b: Lane
}

struct RecommendationShadowInput: Sendable {
    struct Result: Sendable {
        let snapshot: RecommendationSnapshot
        let milliseconds: Double
    }
    let items: [NewsItem]
    let state: LocalInterestState
    let feedback: [InterestFeedback]
    let now: Date
    let seed: UInt64

    func rank(_ variant: RecommendationDiagnosticEvent.Variant) -> Result {
        let began = DispatchTime.now().uptimeNanoseconds
        let snapshot = RecommendationEngine.rank(items: items, state: state, now: now, seed: seed,
                                                 sessionFeedback: feedback, variant: variant)
        let elapsed = DispatchTime.now().uptimeNanoseconds - began
        return Result(snapshot: snapshot, milliseconds: Double(elapsed) / 1_000_000)
    }

    func compare(_ a: Result, _ b: Result) -> RecommendationShadowSample {
        let left = a.snapshot.items, right = b.snapshot.items
        let aTop = Set(left.prefix(10).map(\.contentID)), bTop = Set(right.prefix(10).map(\.contentID))
        var bRanks: [String: Int] = [:]
        for (i, row) in right.enumerated() { bRanks[row.contentID] = i }
        let moves = left.enumerated().compactMap { i, row in bRanks[row.contentID].map { abs(i - $0) } }
        return RecommendationShadowSample(
            occurredAt: now, candidateCount: items.count, top10Overlap: aTop.intersection(bTop).count,
            rankChanged: moves.filter { $0 > 0 }.count, absoluteRankMovement: moves.reduce(0, +),
            enteredTop10: bTop.subtracting(aTop).count, exitedTop10: aTop.subtracting(bTop).count,
            a: lane(a), b: lane(b)
        )
    }

    private func lane(_ result: Result) -> RecommendationShadowSample.Lane {
        let ranked = result.snapshot.items
        let sources = Dictionary(grouping: ranked.prefix(10), by: { $0.item.source.id })
        let blocks = BlockedContentIndex(state: state)
        var ids: Set<String> = [], clusters: Set<String> = []
        var violations = 0
        for (index, row) in ranked.enumerated() {
            if !ids.insert(row.contentID).inserted { violations += 1 }
            if !clusters.insert(row.clusterID).inserted { violations += 1 }
            if blocks.isBlocked(sourceID: row.item.source.id, contentID: row.contentID, clusterID: row.clusterID) {
                violations += 1
            }
            guard let trace = row.trace else { violations += 1; continue }
            let permitted: Set<String>
            switch index % 10 {
            case 7, 8: permitted = ["publicFresh", "publicHeat"]
            case 9: permitted = ["sourceRotation"]
            default: permitted = ["score"]
            }
            if !permitted.contains(trace.selectionPolicy) || trace.finalRank != index + 1 { violations += 1 }
        }
        return .init(top10Sources: sources.count, largestSourceCount: sources.values.map(\.count).max() ?? 0,
                     ruleViolations: violations, milliseconds: result.milliseconds)
    }
}
