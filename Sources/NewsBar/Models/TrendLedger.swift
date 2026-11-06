import Foundation

enum TrendTopicKey {
    /// Conservative exact-topic key: lowercase alphanumerics only. It merges
    /// punctuation and width variants but never performs semantic guessing.
    static func canonical(_ title: String) -> String {
        title.lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}

struct TrendObservation: Equatable, Sendable {
    let topicKey: String
    let title: String
    let source: NewsSource
    /// Fixed 30-minute bucket, so a burst of refreshes counts once.
    let bucket: Date
    let rank: Int?
    let hotLabel: String?
    let lastSeen: Date
}

enum TrendLabel: String, Equatable, Sendable {
    case persistent
    case rising
    case emerging
    case insufficient

    func title(_ language: AppLanguage) -> String {
        switch self {
        case .persistent: return language == .en ? "Persistent" : "持续趋势"
        case .rising: return language == .en ? "Rising" : "正在上升"
        case .emerging: return language == .en ? "New signal" : "新兴观察"
        case .insufficient: return language == .en ? "Limited sample" : "样本不足"
        }
    }
}

struct TrendCandidate: Identifiable, Equatable, Sendable {
    var id: String { topicKey }
    let topicKey: String
    let title: String
    let sources: [NewsSource]
    let bucketCount: Int
    let activeDays: Int
    let bestRank: Int?
    let rankImprovement: Int
    let firstSeen: Date
    let lastSeen: Date
    let score: Double
    let label: TrendLabel
}

/// Local, explainable trend judgement. It only sees observations that already
/// happened; a missing day is not filled in and a cold start cannot fabricate
/// a trend.
enum TrendDetector {
    static let analysisDays = 7
    static let bucketInterval: TimeInterval = 30 * 60

    static func observations(
        from snapshots: [TrendSnapshot],
        now: Date = Date(),
        days: Int = analysisDays
    ) -> [TrendObservation] {
        let cutoff = now.addingTimeInterval(-TimeInterval(max(1, days)) * 24 * 60 * 60)
        var best: [String: TrendObservation] = [:]

        for snapshot in snapshots where snapshot.timestamp >= cutoff {
            let bucket = bucketStart(for: snapshot.timestamp)
            for item in snapshot.weiboItems + snapshot.bilibiliItems {
                let key = TrendTopicKey.canonical(item.title)
                guard !key.isEmpty else { continue }
                let compound = "\(key)|\(bucket.timeIntervalSince1970)"
                let candidate = TrendObservation(
                    topicKey: key,
                    title: item.title,
                    source: item.source,
                    bucket: bucket,
                    rank: item.rank,
                    hotLabel: item.hotLabel,
                    lastSeen: snapshot.timestamp
                )
                if let existing = best[compound] {
                    let candidateRank = candidate.rank ?? Int.max
                    let existingRank = existing.rank ?? Int.max
                    if candidateRank < existingRank
                        || (candidateRank == existingRank && candidate.lastSeen > existing.lastSeen) {
                        best[compound] = candidate
                    }
                } else {
                    best[compound] = candidate
                }
            }
        }

        return best.values.sorted {
            if $0.bucket == $1.bucket { return $0.topicKey < $1.topicKey }
            return $0.bucket < $1.bucket
        }
    }

    static func candidates(
        from observations: [TrendObservation],
        now: Date = Date()
    ) -> [TrendCandidate] {
        guard !observations.isEmpty else { return [] }
        let calendar = Calendar.current
        var grouped: [String: [TrendObservation]] = [:]
        for observation in observations {
            grouped[observation.topicKey, default: []].append(observation)
        }

        var candidates: [TrendCandidate] = []
        for (key, rows) in grouped {
            let ordered = rows.sorted { $0.bucket < $1.bucket }
            guard let latest = ordered.last else { continue }
            let buckets = Set(ordered.map(\.bucket))
            let days = Set(ordered.map { calendar.startOfDay(for: $0.bucket) })
            let sources = Array(Set(ordered.map(\.source))).sorted { $0.id < $1.id }
            let first = ordered.first
            let bestRank = ordered.compactMap(\.rank).min()
            let laterBest = ordered.dropFirst().compactMap(\.rank).min()
            let firstRank = first?.rank
            let improvement: Int
            if let firstRank, let laterBest {
                improvement = max(0, firstRank - laterBest)
            } else {
                improvement = 0
            }

            let persistence = min(1, Double(days.count) / Double(analysisDays))
            let growth = min(1, Double(improvement) / 10)
            let breadth = min(1, Double(sources.count) / 3)
            let hours = max(0, now.timeIntervalSince(latest.lastSeen) / 3_600)
            let recency = exp(-hours / 24)
            let score = 0.30 * persistence + 0.30 * growth + 0.25 * breadth + 0.15 * recency

            let label: TrendLabel
            if days.count >= 3, buckets.count >= 6 {
                label = .persistent
            } else if improvement >= 3 {
                label = .rising
            } else if buckets.count >= 2 {
                label = .emerging
            } else {
                label = .insufficient
            }

            candidates.append(TrendCandidate(
                topicKey: key,
                title: latest.title,
                sources: sources,
                bucketCount: buckets.count,
                activeDays: days.count,
                bestRank: bestRank,
                rankImprovement: improvement,
                firstSeen: first?.lastSeen ?? latest.lastSeen,
                lastSeen: latest.lastSeen,
                score: score,
                label: label
            ))
        }

        return candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if ($0.bestRank ?? Int.max) != ($1.bestRank ?? Int.max) {
                return ($0.bestRank ?? Int.max) < ($1.bestRank ?? Int.max)
            }
            return $0.lastSeen > $1.lastSeen
        }
    }

    private static func bucketStart(for date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / bucketInterval) * bucketInterval)
    }
}
