import Foundation
import os

protocol ContentFeatureProvider: Sendable {
    func features(for item: NewsItem) -> Set<String>
}

struct TitleFeatures: ContentFeatureProvider {
    static let version = 1
    private static let cache = OSAllocatedUnfairLock<[String: Set<String>]>(initialState: [:])
    private static let lexicon: [String: [String]] = [
        "ai": ["AI", "人工智能", "大模型", "机器学习", "生成式", "LLM", "ChatGPT", "DeepSeek"],
        "technology": ["科技", "芯片", "半导体", "开源", "编程", "软件", "Swift", "technology", "chip", "software"],
        "auto": ["汽车", "新能源", "电动车", "自动驾驶", "EV", "automotive"],
        "finance": ["金融", "股票", "经济", "利率", "投资", "finance", "economy", "stocks"],
        "space": ["航天", "火箭", "卫星", "太空", "NASA", "space", "rocket"],
        "health": ["健康", "医疗", "医学", "医院", "health", "medicine"],
        "design": ["设计", "摄影", "建筑", "design", "photography"],
        "sports": ["体育", "足球", "篮球", "网球", "奥运", "football", "sports", "tennis"],
        "culture": ["电影", "音乐", "电视剧", "演员", "艺术", "film", "music", "art"],
        "gaming": ["游戏", "电竞", "任天堂", "game", "gaming", "Nintendo"],
        "world": ["国际", "外交", "选举", "联合国", "election", "diplomacy"],
        "entity:apple": ["苹果", "Apple", "iPhone"],
        "entity:google": ["谷歌", "Google", "Gemini"],
        "entity:microsoft": ["微软", "Microsoft"],
        "entity:vivo": ["vivo"],
        "entity:tesla": ["特斯拉", "Tesla"]
    ]
    // Precompile Latin boundaries once, rather than compiling per candidate.
    private static let rules: [(String, [(String, NSRegularExpression?)])] = lexicon.map { tag, aliases in
        (tag, aliases.map { alias in
            let latin = alias.unicodeScalars.allSatisfy { $0.isASCII }
            return (alias.lowercased(), latin ? try? NSRegularExpression(pattern: "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: alias) + "(?![A-Za-z0-9])", options: .caseInsensitive) : nil)
        })
    }

    static func matches(_ keyword: String, in title: String) -> Bool {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        if value.unicodeScalars.allSatisfy({ $0.isASCII }) {
            let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: value) + "(?![A-Za-z0-9])"
            let foldedTitle = title.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            return foldedTitle.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return title.range(of: value, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    static func tags(_ title: String) -> Set<String> {
        if let cached = cache.withLock({ $0[title] }) { return cached }
        let lower = title.lowercased()
        let range = NSRange(title.startIndex..., in: title)
        let tags = Set(rules.compactMap { tag, aliases in
            aliases.contains { alias, regex in
                if let regex { return regex.firstMatch(in: title, range: range) != nil }
                return lower.contains(alias)
            } ? tag : nil
        })
        cache.withLock {
            if $0.count >= 4096 { $0.removeAll(keepingCapacity: true) }
            $0[title] = tags
        }
        return tags
    }

    func features(for item: NewsItem) -> Set<String> { Self.tags(item.title) }
}

struct InterestProfile: Sendable {
    var topics: [String: Double] = [:]
    var shortTermTopics: [String: Double] = [:]
    var sources: [String: Double] = [:]
    var confidence: Double = 0

    static func build(state: LocalInterestState, now: Date = Date(), sessionFeedback: [InterestFeedback] = []) -> InterestProfile {
        guard state.learningEnabled else { return InterestProfile() }
        var profile = InterestProfile()
        var independent: Set<String> = []
        func add(_ item: NewsItem, strength: Double, age: Double) {
            let long = strength * pow(0.5, max(0, age) / (30 * 86400))
            let short = strength * pow(0.5, max(0, age) / (2 * 86400))
            for topic in TitleFeatures.tags(item.title) {
                profile.topics[topic, default: 0] += long
                profile.shortTermTopics[topic, default: 0] += short
            }
            profile.sources[item.source.id, default: 0] += long
        }
        for signal in state.profileSignals.values {
            add(signal.item, strength: signal.strength, age: now.timeIntervalSince(signal.occurredAt))
            if signal.strength >= 1 { independent.insert(ContentIdentity.id(for: signal.item.url)) }
        }
        let feedbacks = state.feedbacks + sessionFeedback
        var explicitCount = 0
        for feedback in feedbacks {
            let age = now.timeIntervalSince(feedback.occurredAt)
            switch feedback.kind {
            case .bookmark:
                // A preserved bookmark after clearing is not itself consent to rebuild a profile.
                guard feedback.participatesInProfile else { continue }
                add(feedback.item, strength: 3, age: age)
                explicitCount += 1
            case .moreLikeThis:
                if age < 2 * 3600 {
                    for tag in TitleFeatures.tags(feedback.item.title) { profile.shortTermTopics[tag, default: 0] += 2 }
                }
            case .followTopic:
                if let topic = feedback.topic { profile.topics[topic, default: 0] += 4; explicitCount += 1 }
            case .reduceTopic:
                if let topic = feedback.topic { profile.topics[topic, default: 0] -= 4; profile.shortTermTopics[topic, default: 0] -= 4 }
            default: break
            }
        }
        for keyword in state.followedTopics { profile.topics["followed:" + keyword, default: 0] += 4 }
        profile.confidence = min(1, Double(independent.count + (explicitCount + state.followedTopics.count) * 3) / 12)
        return profile
    }
}

struct ScoredRecommendation: Identifiable, Sendable {
    var id: String { contentID }
    let item: NewsItem
    let contentID: String
    let clusterID: String
    let score: Double
    let components: [String: Double]
    var reason: String
    let topic: String?
}

struct RecommendationSnapshot: Identifiable, Sendable {
    let id = UUID()
    let asOf: Date
    let profileVersion: Int
    let policyVersion: Int
    let profileConfidence: Double
    let semanticDegraded: Bool
    var items: [ScoredRecommendation]
}

/// One pass over explicit feedback per ranking, instead of scanning the whole
/// feedback list (and re-hashing URLs) for every candidate.
private struct BlockedContentIndex {
    let sourceIDs: Set<String>
    let contentIDs: Set<String>
    let clusterIDs: Set<String>

    init(state: LocalInterestState) {
        var sourceIDs: Set<String> = []
        var contentIDs: Set<String> = []
        var clusterIDs: Set<String> = []
        for feedback in state.feedbacks {
            switch feedback.kind {
            case .muteSource:
                sourceIDs.insert(feedback.item.source.id)
            case .notInterested:
                contentIDs.insert(ContentIdentity.id(for: feedback.item.url))
            case .hideEvent:
                clusterIDs.insert(ContentIdentity.cluster(for: feedback.item))
            default:
                break
            }
        }
        self.sourceIDs = sourceIDs
        self.contentIDs = contentIDs
        self.clusterIDs = clusterIDs
    }

    func isBlocked(sourceID: String, contentID: String, clusterID: String) -> Bool {
        sourceIDs.contains(sourceID) || contentIDs.contains(contentID) || clusterIDs.contains(clusterID)
    }
}

protocol RecommendationPolicy: Sendable {
    func select(_ snapshot: RecommendationSnapshot, limit: Int) -> [NewsItem]
}

enum RecommendationEngine {
    static let policyVersion = 1

    static func rank(items: [NewsItem], state: LocalInterestState, now: Date = Date(), limit: Int = 60, seed: UInt64 = 0,
                     sourceFiltered: Bool = false, sessionFeedback: [InterestFeedback] = []) -> RecommendationSnapshot {
        let profile = InterestProfile.build(state: state, now: now, sessionFeedback: sessionFeedback)
        var ids: Set<String> = []
        var candidates: [ScoredRecommendation] = []
        let peakTopic = max(1, profile.topics.values.max() ?? 1)
        let peakShort = max(1, profile.shortTermTopics.values.max() ?? 1)
        let peakSource = max(1, profile.sources.values.max() ?? 1)
        let readIDs = state.learningEnabled ? Set(state.profileSignals.values.filter { $0.strength >= 1 }.map { ContentIdentity.id(for: $0.item.url) }) : []
        let blocked = BlockedContentIndex(state: state)
        for item in items {
            let id = ContentIdentity.id(for: item.url)
            let clusterID = ContentIdentity.cluster(for: item)
            guard !blocked.isBlocked(sourceID: item.source.id, contentID: id, clusterID: clusterID) else { continue }
            guard ids.insert(id).inserted else { continue }
            var tags = TitleFeatures.tags(item.title)
            if state.learningEnabled {
                for keyword in state.followedTopics where TitleFeatures.matches(keyword, in: item.title) { tags.insert("followed:" + keyword) }
            }
            let topic = tags.sorted().max { a, b in (profile.topics[a] ?? 0) < (profile.topics[b] ?? 0) }
            let affinity = tags.map { max(0, min(1, 0.65 * (profile.topics[$0] ?? 0) / peakTopic + 0.35 * (profile.shortTermTopics[$0] ?? 0) / peakShort)) }.max()
            let source = min(1, (profile.sources[item.source.id] ?? 0) / peakSource)
            let firstSeen = state.contents[id]?.firstSeen ?? now
            let age = max(0, now.timeIntervalSince(item.publishedAt ?? firstSeen))
            let recency = pow(0.5, age / (24 * 3600))
            let novelty = readIDs.contains(id) ? 0.0 : 1.0
            var components = ["source": source, "recency": recency, "novelty": novelty]
            var weighted = source * 0.10 + recency * 0.15 + novelty * 0.10
            var weight = 0.35
            if let affinity { components["interest"] = affinity; weighted += affinity * 0.35; weight += 0.35 }
            var heat: Double?
            if item.source.isBuiltIn, let rank = item.rank, rank > 0 {
                heat = max(0, min(1, 1 / sqrt(Double(rank)) + (item.hotLabel == "爆" ? 0.3 : 0)))
            }
            if let heat { components["publicHeat"] = heat; weighted += heat * 0.15; weight += 0.15 }
            let personal = weighted / weight
            // Missing heat is unknown, not a negative vote against RSS.
            let baseline = heat.map { 0.5 * $0 + 0.35 * recency + 0.15 * novelty } ?? (0.7 * recency + 0.3 * novelty)
            let reduced = state.learningEnabled && state.feedbacks.contains { $0.kind == .reduceTopic && $0.topic.map(tags.contains) == true }
            let score = profile.confidence * personal + (1 - profile.confidence) * baseline - (readIDs.contains(id) ? 0.15 : 0) - (reduced ? 0.2 : 0)
            let reason = profile.confidence > 0 && (affinity ?? 0) > 0.1 ? "interest" : heat != nil ? "publicHeat" : "fresh"
            candidates.append(ScoredRecommendation(item: item, contentID: id, clusterID: clusterID, score: score,
                                                    components: components, reason: reason, topic: topic))
        }
        candidates.sort { $0.score == $1.score ? $0.contentID < $1.contentID : $0.score > $1.score }
        var selected: [ScoredRecommendation] = []
        var clusters: Set<String> = []
        var sourceCounts: [String: Int] = [:]
        var topicCounts: [String: Int] = [:]
        let cap = max(2, Int(ceil(Double(min(limit, candidates.count)) * 0.4)))
        while !candidates.isEmpty, selected.count < max(0, limit) {
            // Greedy diversity re-ranking across the entire eligible pool, not only interest Top-N.
            let explorationSlot = selected.count % 10 == 9
            let publicSlot = selected.count % 10 == 7 || selected.count % 10 == 8
            let index: Int
            if explorationSlot {
                let offset = Int(seed % UInt64(max(1, candidates.count)))
                index = candidates.indices.min { a, b in
                    let ca = sourceCounts[candidates[a].item.source.id, default: 0]
                    let cb = sourceCounts[candidates[b].item.source.id, default: 0]
                    if ca != cb { return ca < cb }
                    return (a + offset) % candidates.count < (b + offset) % candidates.count
                } ?? 0
            } else {
                index = candidates.indices.max { a, b in
                    func adjusted(_ i: Int) -> Double {
                        let candidate = candidates[i]
                        let sourcePenalty = sourceFiltered ? 0 : Double(sourceCounts[candidate.item.source.id, default: 0]) * 0.12
                        let topicPenalty = Double(topicCounts[candidate.topic ?? "unknown", default: 0]) * 0.04
                        let hardDiversity = !sourceFiltered && sourceCounts[candidate.item.source.id, default: 0] >= cap ? 1.0 : 0
                        return (publicSlot ? candidate.components["publicHeat"] ?? candidate.components["recency"] ?? 0 : candidate.score) - sourcePenalty - topicPenalty - hardDiversity
                    }
                    let aa = adjusted(a), bb = adjusted(b)
                    return aa == bb ? a > b : aa < bb
                } ?? 0
            }
            var candidate = candidates.remove(at: index)
            guard clusters.insert(candidate.clusterID).inserted else { continue }
            if explorationSlot { candidate.reason = "exploration" }
            else if publicSlot { candidate.reason = candidate.components["publicHeat"] == nil ? "fresh" : "publicHeat" }
            selected.append(candidate)
            sourceCounts[candidate.item.source.id, default: 0] += 1
            topicCounts[candidate.topic ?? "unknown", default: 0] += 1
        }
        return RecommendationSnapshot(asOf: now, profileVersion: state.profileVersion, policyVersion: policyVersion,
                                      profileConfidence: profile.confidence, semanticDegraded: true, items: selected)
    }
}
