import Foundation

struct SummaryCitation: Codable, Sendable {
    let index: Int
    let newsItemID: String
    let contentID: String
    let clusterID: String
    let title: String
    let url: String
    let sourceID: String
}

struct SummaryManifest: Codable, Identifiable, Sendable {
    let id: UUID
    let items: [NewsItem]
    let citations: [SummaryCitation]
    let trendIndices: Set<Int>
    let profileVersion: Int
    let rankingPolicyVersion: Int
    let promptVersion: Int
    let model: String
    let provider: String
    let language: AppLanguage
    let maxWords: Int
    let trendHistoryHash: String
    let asOf: Date
    let coverageStart: Date
    let cacheKey: String

    init(items: [NewsItem], profileVersion: Int, model: String, provider: String, language: AppLanguage, maxWords: Int,
         asOf: Date = Date(), coverageStart: Date? = nil, trendHistoryHash: String = "") {
        id = UUID()
        self.items = items
        self.profileVersion = profileVersion
        rankingPolicyVersion = RecommendationEngine.policyVersion
        promptVersion = 2
        self.model = model
        self.provider = provider
        self.language = language
        self.maxWords = maxWords
        self.trendHistoryHash = trendHistoryHash
        self.asOf = asOf
        self.coverageStart = coverageStart ?? asOf
        trendIndices = Set(items.enumerated().filter { $0.element.source.isBuiltIn }.map(\.offset))
        citations = items.enumerated().map { index, item in
            SummaryCitation(index: index, newsItemID: item.id, contentID: ContentIdentity.id(for: item.url),
                            clusterID: ContentIdentity.cluster(for: item), title: item.title, url: item.url, sourceID: item.source.id)
        }
        cacheKey = ContentIdentity.digest([Self.contentFingerprint(items), String(profileVersion), String(rankingPolicyVersion), String(promptVersion),
                                          model, provider, language.rawValue, String(maxWords), trendHistoryHash, String(self.coverageStart.timeIntervalSince1970), String(asOf.timeIntervalSince1970)].joined(separator: "\n"))
    }

    static func contentFingerprint(_ items: [NewsItem]) -> String {
        ContentIdentity.digest(items.map { "\($0.id):\($0.title):\($0.rank ?? 0):\($0.hotLabel ?? "unknown"):\($0.publishedAt?.timeIntervalSince1970 ?? -1)" }.joined(separator: "\n"))
    }

    static func generationIdentity(items: [NewsItem], model: String, provider: String, language: AppLanguage, maxWords: Int) -> String {
        ContentIdentity.digest([contentFingerprint(items), model, provider, language.rawValue, String(maxWords), "prompt-v2", "ranking-v\(RecommendationEngine.policyVersion)"].joined(separator: "\n"))
    }
}

enum SummarySelectionPolicy {
    /// Conservative byte-based token upper estimate: <=3,500 title bytes plus
    /// <=1,000 trend-context bytes and a fixed prompt; no behavior/profile is sent.
    static func select(items: [NewsItem], state: LocalInterestState, now: Date = Date()) -> [NewsItem] {
        let eligible = items.filter { !state.isBlocked($0) }
        let trends = eligible.filter { $0.source.isBuiltIn }.sorted {
            if ($0.hotLabel == "爆") != ($1.hotLabel == "爆") { return $0.hotLabel == "爆" }
            return ($0.rank ?? Int.max) < ($1.rank ?? Int.max)
        }
        let ranked = RecommendationEngine.rank(items: eligible, state: state, now: now, limit: 40).items.map(\.item)
        var result: [NewsItem] = []
        var clusters: Set<String> = []
        var bytes = 0
        // Public trend slots are retained before personalized daily selections.
        for item in Array(trends.prefix(6)) + ranked {
            guard result.count < 20 else { break }
            let cost = min(300, item.title.count) * 4 + 96
            guard bytes + cost <= 3500, clusters.insert(ContentIdentity.cluster(for: item)).inserted else { continue }
            result.append(item)
            bytes += cost
        }
        return result
    }
}
