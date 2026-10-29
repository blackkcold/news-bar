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
    // Canonical tag for each known alias, so an explicit follow of "人工智能"
    // also transfers to titles that only say "AI" / "大模型".
    private static let aliasIndex: [String: String] = {
        var index: [String: String] = [:]
        for (tag, aliases) in lexicon.sorted(by: { $0.key < $1.key }) {
            for alias in aliases {
                let key = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if index[key] == nil { index[key] = tag }
            }
        }
        return index
    }()
    // Precompile Latin boundaries once, rather than compiling per candidate.
    private static let rules: [(String, [(String, NSRegularExpression?)])] = lexicon.map { tag, aliases in
        (tag, aliases.map { alias in
            let latin = alias.unicodeScalars.allSatisfy { $0.isASCII }
            return (alias.lowercased(), latin ? try? NSRegularExpression(pattern: "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: alias) + "(?![A-Za-z0-9])", options: .caseInsensitive) : nil)
        })
    }

    static func canonicalTag(for keyword: String) -> String? {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        return aliasIndex[value]
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
    /// tag → sourceID → decayed weight, collected in the same pass as `topics`.
    ///
    /// This is display-only evidence for the interest network graph. It is
    /// never read by scoring, normalization or ranking, so adding it cannot
    /// change a recommendation.
    var topicSources: [String: [String: Double]] = [:]
    var confidence: Double = 0
    // Negative evidence uses the same decay clock as the positive side. Each
    // value is the raw decayed sum; the scorer clamps and caps it.
    var negativeTopics: [String: Double] = [:]
    var negativeSources: [String: Double] = [:]
    var negativeClusters: [String: Double] = [:]

    static func build(state: LocalInterestState, now: Date = Date(), sessionFeedback: [InterestFeedback] = []) -> InterestProfile {
        guard state.learningEnabled else { return InterestProfile() }
        var profile = InterestProfile()
        var independent: Set<String> = []
        func add(_ item: NewsItem, strength: Double, age: Double) {
            let long = strength * pow(0.5, max(0, age) / (30 * 86400))
            let short = strength * pow(0.5, max(0, age) / (2 * 86400))
            let tags = TitleFeatures.tags(item.title)
            for topic in tags {
                profile.topics[topic, default: 0] += long
                profile.shortTermTopics[topic, default: 0] += short
                // Same pass, same decay as the topic weight. Display-only:
                // `topicSources` never feeds the scorer.
                profile.topicSources[topic, default: [:]][item.source.id, default: 0] += long
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
            // Feedback saved without profile consent (learning off/paused/private)
            // is historical user intent, not evidence to apply now or later.
            // Hard blocks are indexed separately and still apply.
            guard feedback.participatesInProfile else { continue }
            let age = now.timeIntervalSince(feedback.occurredAt)
            switch feedback.kind {
            case .bookmark:
                // A preserved bookmark after clearing is not itself consent to rebuild a profile.
                add(feedback.item, strength: 3, age: age)
                explicitCount += 1
            case .moreLikeThis:
                if age < 2 * 3600 {
                    for tag in TitleFeatures.tags(feedback.item.title) { profile.shortTermTopics[tag, default: 0] += 2 }
                }
            case .followTopic:
                if let topic = feedback.topic { profile.topics[topic, default: 0] += 4; explicitCount += 1 }
            case .reduceTopic:
                // Soft, decaying downweight. The old flat -4 profile
                // subtraction buried a topic far beyond the documented cap.
                if let topic = feedback.topic {
                    profile.negativeTopics[topic, default: 0] += 0.8 * pow(0.5, max(0, age) / (30 * 86400))
                }
            case .lessLikeContent:
                profile.negativeClusters[ContentIdentity.cluster(for: feedback.item), default: 0] += pow(0.5, max(0, age) / (14 * 86400))
            case .lessLikeSource:
                // A fresh single source rule reaches its 0.15 cap; repeats
                // saturate rather than stacking without bound.
                profile.negativeSources[feedback.item.source.id, default: 0] += pow(0.5, max(0, age) / (30 * 86400))
            default: break
            }
        }
        // Known-alias follows collapse onto their canonical topic and count once
        // even if the user followed several aliases of the same topic. Arbitrary
        // literal keywords keep their own spelling and count each.
        var canonicalFollowedTags: Set<String> = []
        var literalKeywords: [String] = []
        for keyword in state.followedTopics {
            if let tag = TitleFeatures.canonicalTag(for: keyword) {
                canonicalFollowedTags.insert(tag)
            } else {
                literalKeywords.append(keyword)
            }
        }
        for tag in canonicalFollowedTags { profile.topics[tag, default: 0] += 4 }
        for keyword in literalKeywords { profile.topics["followed:" + keyword, default: 0] += 4 }
        profile.confidence = min(1, Double(independent.count +
            (explicitCount + canonicalFollowedTags.count + literalKeywords.count) * 3) / 12)
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
    /// Produced by the actual ranking pass. `nil` only for callers that build a
    /// row manually or for snapshots from before traces existed.
    var trace: RecommendationTrace? = nil
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

/// One feature term from the single scoring table shared by `weighted`,
/// the denominator and `contributions`.
private struct FeatureTerm {
    let key: String
    let coefficient: Double
    let value: Double
}

/// A candidate plus the score parts needed to explain its selection without
/// recomputing them.
private struct TracedCandidate {
    var row: ScoredRecommendation
    let terms: [FeatureTerm]
    let baselineTerms: [FeatureTerm]
    let denominator: Double
    let personalScore: Double
    let baselineScore: Double
    let confidence: Double
    let readPenalty: Double
    let negativePenalty: Double
    let negativeContentPenalty: Double
    let negativeTopicPenalty: Double
    let negativeSourcePenalty: Double

    /// Single source of truth: the score the selector actually compares.
    var rawScore: Double { row.score }
}

enum RecommendationEngine {
    // 2: known-dictionary follows transfer to their canonical topic tag.
    // 3: canonical alias follows count once; non-consenting soft feedback no
    //    longer shapes the profile or the reduce-topic penalty.
    // 4: one signed model: soft negatives (content/topic/source) share the
    //    decay clock, cap at 0.40, and replace the flat reduce-topic -4.
    static let policyVersion = 4

    private static func contributions(terms: [FeatureTerm], baselineTerms: [FeatureTerm],
                                      denominator: Double, confidence: Double) -> [String: Double] {
        var result: [String: Double] = [:]
        for term in terms {
            result["personal." + term.key] = confidence * term.coefficient * term.value / denominator
        }
        for term in baselineTerms {
            result["baseline." + term.key] = (1 - confidence) * term.coefficient * term.value
        }
        return result
    }

    static func rank(items: [NewsItem], state: LocalInterestState, now: Date = Date(), limit: Int = 60, seed: UInt64 = 0,
                     sourceFiltered: Bool = false, sessionFeedback: [InterestFeedback] = []) -> RecommendationSnapshot {
        let profile = InterestProfile.build(state: state, now: now, sessionFeedback: sessionFeedback)
        var ids: Set<String> = []
        var candidates: [TracedCandidate] = []
        let peakTopic = max(1, profile.topics.values.max() ?? 1)
        let peakShort = max(1, profile.shortTermTopics.values.max() ?? 1)
        let peakSource = max(1, profile.sources.values.max() ?? 1)
        let readIDs = state.learningEnabled ? Set(state.profileSignals.values.filter { $0.strength >= 1 }.map { ContentIdentity.id(for: $0.item.url) }) : []
        // Known-dictionary follows are handled by canonical tags above; only
        // arbitrary keywords keep the literal match rule.
        let literalFollows = state.learningEnabled ? state.followedTopics.filter { TitleFeatures.canonicalTag(for: $0) == nil } : []
        let blocked = BlockedContentIndex(state: state)
        for item in items {
            let id = ContentIdentity.id(for: item.url)
            let clusterID = ContentIdentity.cluster(for: item)
            guard !blocked.isBlocked(sourceID: item.source.id, contentID: id, clusterID: clusterID) else { continue }
            guard ids.insert(id).inserted else { continue }
            var tags = TitleFeatures.tags(item.title)
            for keyword in literalFollows where TitleFeatures.matches(keyword, in: item.title) {
                tags.insert("followed:" + keyword)
            }
            let topic = tags.sorted().max { a, b in (profile.topics[a] ?? 0) < (profile.topics[b] ?? 0) }
            let affinity = tags.map { max(0, min(1, 0.65 * (profile.topics[$0] ?? 0) / peakTopic + 0.35 * (profile.shortTermTopics[$0] ?? 0) / peakShort)) }.max()
            let source = min(1, (profile.sources[item.source.id] ?? 0) / peakSource)
            let firstSeen = state.contents[id]?.firstSeen ?? now
            let age = max(0, now.timeIntervalSince(item.publishedAt ?? firstSeen))
            let recency = pow(0.5, age / (24 * 3600))
            let novelty = readIDs.contains(id) ? 0.0 : 1.0
            var components = ["source": source, "recency": recency, "novelty": novelty]
            // This is the only scoring table: weighted, denominator and trace
            // contributions all derive from these terms.
            var terms = [
                FeatureTerm(key: "source", coefficient: 0.10, value: source),
                FeatureTerm(key: "recency", coefficient: 0.15, value: recency),
                FeatureTerm(key: "novelty", coefficient: 0.10, value: novelty)
            ]
            var denominator = 0.35
            if let affinity {
                components["interest"] = affinity
                terms.append(FeatureTerm(key: "interest", coefficient: 0.35, value: affinity))
                denominator += 0.35
            }
            var heat: Double?
            if item.source.isBuiltIn, let rank = item.rank, rank > 0 {
                heat = max(0, min(1, 1 / sqrt(Double(rank)) + (item.hotLabel == "爆" ? 0.3 : 0)))
            }
            if let heat {
                components["publicHeat"] = heat
                terms.append(FeatureTerm(key: "publicHeat", coefficient: 0.15, value: heat))
                denominator += 0.15
            }
            let personal = terms.reduce(0) { $0 + $1.coefficient * $1.value } / denominator
            // Missing heat is unknown: the baseline has no publicHeat term at
            // all, rather than a zero heat term.
            let baselineTerms: [FeatureTerm]
            if let heat {
                baselineTerms = [
                    FeatureTerm(key: "publicHeat", coefficient: 0.5, value: heat),
                    FeatureTerm(key: "recency", coefficient: 0.35, value: recency),
                    FeatureTerm(key: "novelty", coefficient: 0.15, value: novelty)
                ]
            } else {
                baselineTerms = [
                    FeatureTerm(key: "recency", coefficient: 0.7, value: recency),
                    FeatureTerm(key: "novelty", coefficient: 0.3, value: novelty)
                ]
            }
            let baseline = baselineTerms.reduce(0) { $0 + $1.coefficient * $1.value }
            // One signed model: soft negatives are capped per scope and in
            // total, so "less like this" can never become a de-facto block.
            let negativeContent = min(1, profile.negativeClusters[clusterID] ?? 0)
            let negativeTopic = min(1, tags.map { profile.negativeTopics[$0] ?? 0 }.max() ?? 0)
            let negativeSource = min(1, profile.negativeSources[item.source.id] ?? 0)
            let negativeContentPenalty = min(0.25, 0.25 * negativeContent)
            let negativeTopicPenalty = min(0.20, 0.20 * negativeTopic)
            let negativeSourcePenalty = min(0.15, 0.15 * negativeSource)
            let negativePenalty = min(0.40, negativeContentPenalty + negativeTopicPenalty + negativeSourcePenalty)
            let readPenalty = readIDs.contains(id) ? 0.15 : 0
            let score = profile.confidence * personal + (1 - profile.confidence) * baseline - readPenalty - negativePenalty
            let reason = profile.confidence > 0 && (affinity ?? 0) > 0.1 ? "interest" : heat != nil ? "publicHeat" : "fresh"
            candidates.append(TracedCandidate(
                row: ScoredRecommendation(item: item, contentID: id, clusterID: clusterID, score: score,
                                          components: components, reason: reason, topic: topic),
                terms: terms,
                baselineTerms: baselineTerms,
                denominator: denominator,
                personalScore: personal,
                baselineScore: baseline,
                confidence: profile.confidence,
                readPenalty: readPenalty,
                negativePenalty: negativePenalty,
                negativeContentPenalty: negativeContentPenalty,
                negativeTopicPenalty: negativeTopicPenalty,
                negativeSourcePenalty: negativeSourcePenalty
            ))
        }
        candidates.sort { $0.row.score == $1.row.score ? $0.row.contentID < $1.row.contentID : $0.row.score > $1.row.score }
        let rankBeforeDiversity = Dictionary(uniqueKeysWithValues: candidates.enumerated().map {
            ($0.element.row.contentID, $0.offset + 1)
        })
        var selected: [ScoredRecommendation] = []
        var clusters: Set<String> = []
        var sourceCounts: [String: Int] = [:]
        var topicCounts: [String: Int] = [:]
        let cap = max(2, Int(ceil(Double(min(limit, candidates.count)) * 0.4)))
        while !candidates.isEmpty, selected.count < max(0, limit) {
            // Greedy diversity re-ranking across the entire eligible pool, not only interest Top-N.
            let explorationSlot = selected.count % 10 == 9
            let publicSlot = selected.count % 10 == 7 || selected.count % 10 == 8
            func penalties(for candidate: TracedCandidate) -> (source: Double, topic: Double, diversity: Double) {
                let sourcePenalty = sourceFiltered ? 0 : Double(sourceCounts[candidate.row.item.source.id, default: 0]) * 0.12
                let topicPenalty = Double(topicCounts[candidate.row.topic ?? "unknown", default: 0]) * 0.04
                let hardDiversity = !sourceFiltered && sourceCounts[candidate.row.item.source.id, default: 0] >= cap ? 1.0 : 0
                return (sourcePenalty, topicPenalty, hardDiversity)
            }
            let index: Int
            var applied = (source: 0.0, topic: 0.0, diversity: 0.0)
            var selectionBase = 0.0
            var policy = "score"
            var rotation: (sourceUseCount: Int, offset: Int, index: Int, count: Int)?
            if explorationSlot {
                // Honest source rotation: least-used source first, seed-rotated
                // tiebreak. This is lexicographic, not an additive score.
                let candidateCount = candidates.count
                let offset = Int(seed % UInt64(max(1, candidateCount)))
                index = candidates.indices.min { a, b in
                    let ca = sourceCounts[candidates[a].row.item.source.id, default: 0]
                    let cb = sourceCounts[candidates[b].row.item.source.id, default: 0]
                    if ca != cb { return ca < cb }
                    return (a + offset) % candidateCount < (b + offset) % candidateCount
                } ?? 0
                rotation = (sourceCounts[candidates[index].row.item.source.id, default: 0],
                            offset, index, candidateCount)
                // Not the decision key; kept as the audit scalar explained by the
                // rotation* fields rather than misrepresented as additive.
                selectionBase = candidates[index].row.score
                policy = "sourceRotation"
            } else {
                index = candidates.indices.max { a, b in
                    func adjusted(_ i: Int) -> Double {
                        let candidate = candidates[i]
                        let p = penalties(for: candidate)
                        let base = publicSlot
                            ? candidate.row.components["publicHeat"] ?? candidate.row.components["recency"] ?? 0
                            : candidate.row.score
                        return base - p.source - p.topic - p.diversity
                    }
                    let aa = adjusted(a), bb = adjusted(b)
                    return aa == bb ? a > b : aa < bb
                } ?? 0
                applied = penalties(for: candidates[index])
                if publicSlot {
                    if let heat = candidates[index].row.components["publicHeat"] {
                        selectionBase = heat
                        policy = "publicHeat"
                    } else {
                        selectionBase = candidates[index].row.components["recency"] ?? 0
                        policy = "publicFresh"
                    }
                } else {
                    selectionBase = candidates[index].row.score
                    policy = "score"
                }
            }
            var candidate = candidates.remove(at: index)
            guard clusters.insert(candidate.row.clusterID).inserted else { continue }
            if explorationSlot { candidate.row.reason = "exploration" }
            else if publicSlot { candidate.row.reason = candidate.row.components["publicHeat"] == nil ? "fresh" : "publicHeat" }
            let selectionScore = selectionBase - applied.source - applied.topic - applied.diversity
            candidate.row.trace = RecommendationTrace(
                contributions: contributions(terms: candidate.terms, baselineTerms: candidate.baselineTerms,
                                             denominator: candidate.denominator, confidence: candidate.confidence),
                personalScore: candidate.personalScore,
                baselineScore: candidate.baselineScore,
                confidence: candidate.confidence,
                readPenalty: candidate.readPenalty,
                negativePenalty: candidate.negativePenalty,
                negativeContentPenalty: candidate.negativeContentPenalty,
                negativeTopicPenalty: candidate.negativeTopicPenalty,
                negativeSourcePenalty: candidate.negativeSourcePenalty,
                rawScore: candidate.rawScore,
                selectionScore: selectionScore,
                sourcePenalty: applied.source,
                topicPenalty: applied.topic,
                diversityPenalty: applied.diversity,
                rankBeforeDiversity: rankBeforeDiversity[candidate.row.contentID] ?? 0,
                finalRank: selected.count + 1,
                selectionPolicy: policy,
                rotationSourceUseCount: rotation?.sourceUseCount,
                rotationOffset: rotation?.offset,
                rotationCandidateIndex: rotation?.index,
                rotationCandidateCount: rotation?.count
            )
            selected.append(candidate.row)
            sourceCounts[candidate.row.item.source.id, default: 0] += 1
            topicCounts[candidate.row.topic ?? "unknown", default: 0] += 1
        }
        return RecommendationSnapshot(asOf: now, profileVersion: state.profileVersion, policyVersion: policyVersion,
                                      profileConfidence: profile.confidence, semanticDegraded: true, items: selected)
    }
}
