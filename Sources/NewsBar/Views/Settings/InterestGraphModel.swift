import Foundation

/// One node of the read-only interest network.
///
/// The graph is built from the persisted interest profile and is never read by
/// the ranker. `weight` is a display normalization inside this graph, not a
/// probability, an accuracy or a semantic distance.
struct InterestGraphNode: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case hub
        case topic
        case source
    }

    let kind: Kind
    let id: String
    let label: String
    /// 0…1, normalized against the heaviest node of the same ring.
    let weight: Double
    /// Negative signals only mark a node. They are never drawn as an edge.
    let isSuppressed: Bool
    /// Local evidence titles that produced this tag (topics only).
    let evidenceCount: Int
    /// Topic → its per-source evidence counts, heaviest first.
    let sourceShares: [InterestGraphSourceShare]
}

struct InterestGraphSourceShare: Identifiable, Equatable, Sendable {
    let sourceID: String
    let label: String
    let count: Int

    var id: String { sourceID }
}

struct InterestGraphEdge: Identifiable, Equatable, Sendable {
    let from: String
    let to: String
    /// 0…1, normalized against the heaviest drawn edge.
    let weight: Double

    var id: String { from + "→" + to }
}

/// A deterministic three-ring graph: hub → topics → sources.
///
/// No force simulation, no 3D, no particle system, no chart dependency: node
/// positions are a pure function of weight order, so the same profile always
/// produces the same picture.
struct InterestGraphModel: Equatable, Sendable {
    static let topicLimit = 8
    static let sourceLimit = 6
    static let edgeLimit = 28

    let hub: InterestGraphNode
    let topics: [InterestGraphNode]
    let sources: [InterestGraphNode]
    let edges: [InterestGraphEdge]
    let truncatedTopics: Int
    let truncatedSources: Int
    let truncatedEdges: Int
    let language: AppLanguage

    var isEmpty: Bool { topics.isEmpty }
    var nodeCount: Int { 1 + topics.count + sources.count }

    static func empty(language: AppLanguage) -> InterestGraphModel {
        InterestGraphModel(
            hub: InterestGraphNode(
                kind: .hub,
                id: "hub",
                label: language == .en ? "My interests" : "我的兴趣",
                weight: 1,
                isSuppressed: false,
                evidenceCount: 0,
                sourceShares: []
            ),
            topics: [],
            sources: [],
            edges: [],
            truncatedTopics: 0,
            truncatedSources: 0,
            truncatedEdges: 0,
            language: language
        )
    }

    /// Consumes the `topicSources` field already produced by
    /// `InterestProfile.build`. This function never builds a second profile and
    /// never touches ranking weights.
    static func make(
        profile: InterestProfile,
        dimensions: [RecommendationExplanationDimension],
        state: LocalInterestState,
        language: AppLanguage
    ) -> InterestGraphModel {
        let evidence = EvidenceIndex(state: state)
        let english = language == .en

        // Ranking of the ring: real profile weight, ties by key for determinism.
        // Literal manual follows have no source link, so they stay out of the
        // network and keep their existing dedicated section.
        let topicKeys = profile.topics
            .filter { !$0.key.hasPrefix("followed:") && abs($0.value) > 0.0001 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map(\.key)
        let selectedTopicKeys = Array(topicKeys.prefix(topicLimit))

        // Aggregate source weight only across the topics that are actually
        // drawn, so the source ring describes this picture.
        var sourceWeight: [String: Double] = [:]
        for topic in selectedTopicKeys {
            for (sourceID, weight) in profile.topicSources[topic] ?? [:] where weight > 0 {
                sourceWeight[sourceID, default: 0] += weight
            }
        }
        let sourceKeys = sourceWeight
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map(\.key)
        let selectedSourceKeys = Array(sourceKeys.prefix(sourceLimit))
        let selectedSources = Set(selectedSourceKeys)

        var pairs: [(topic: String, source: String, weight: Double)] = []
        for topic in selectedTopicKeys {
            for (sourceID, weight) in (profile.topicSources[topic] ?? [:]).sorted(by: { $0.key < $1.key })
            where weight > 0 && selectedSources.contains(sourceID) {
                pairs.append((topic, sourceID, weight))
            }
        }
        pairs.sort {
            if $0.weight != $1.weight { return $0.weight > $1.weight }
            if $0.topic != $1.topic { return $0.topic < $1.topic }
            return $0.source < $1.source
        }
        let keptPairs = Array(pairs.prefix(edgeLimit))

        let peakTopic = selectedTopicKeys.compactMap { profile.topics[$0] }.map(abs).max() ?? 0
        let peakSource = selectedSourceKeys.compactMap { sourceWeight[$0] }.max() ?? 0
        let peakEdge = keptPairs.map(\.weight).max() ?? 0

        let dimensionEvidence = Dictionary(
            uniqueKeysWithValues: dimensions.map { ($0.key, $0.evidenceCount) }
        )

        let topics = selectedTopicKeys.map { key -> InterestGraphNode in
            let raw = profile.topics[key] ?? 0
            let weight = peakTopic > 0 ? max(0, raw) / peakTopic : 0
            let shares = evidence
                .shares(for: key, sourceLimit: sourceLimit)
            return InterestGraphNode(
                kind: .topic,
                id: "topic:" + key,
                label: dimensionLabel(key: key, dimensions: dimensions, language: language),
                weight: min(1, weight),
                isSuppressed: (profile.negativeTopics[key] ?? 0) > 0.0001,
                evidenceCount: max(dimensionEvidence[key] ?? 0, evidence.total(for: key)),
                sourceShares: shares
            )
        }
        let sources = selectedSourceKeys.map { key -> InterestGraphNode in
            let weight = peakSource > 0 ? max(0, sourceWeight[key] ?? 0) / peakSource : 0
            return InterestGraphNode(
                kind: .source,
                id: "source:" + key,
                label: evidence.label(for: key, language: language),
                weight: min(1, weight),
                isSuppressed: (profile.negativeSources[key] ?? 0) > 0.0001,
                evidenceCount: evidence.total(forSource: key),
                sourceShares: []
            )
        }
        let edges = keptPairs.map { pair in
            InterestGraphEdge(
                from: "topic:" + pair.topic,
                to: "source:" + pair.source,
                weight: peakEdge > 0 ? pair.weight / peakEdge : 0
            )
        }

        return InterestGraphModel(
            hub: InterestGraphNode(
                kind: .hub,
                id: "hub",
                label: english ? "My interests" : "我的兴趣",
                weight: 1,
                isSuppressed: false,
                evidenceCount: selectedTopicKeys.compactMap { dimensionEvidence[$0] }.reduce(0, +),
                sourceShares: []
            ),
            topics: topics,
            sources: sources,
            edges: edges,
            truncatedTopics: max(0, topicKeys.count - selectedTopicKeys.count),
            truncatedSources: max(0, sourceKeys.count - selectedSourceKeys.count),
            truncatedEdges: max(0, pairs.count - keptPairs.count),
            language: language
        )
    }

    /// A single-topic cut of the same graph. Weights are kept as normalized for
    /// the full picture so a topic does not appear to grow when isolated.
    func subgraph(topicID: String) -> InterestGraphModel {
        guard let topic = topics.first(where: { $0.id == topicID }) else { return self }
        let linked = edges.filter { $0.from == topic.id }
        let sourceIDs = Set(linked.map(\.to))
        return InterestGraphModel(
            hub: hub,
            topics: [topic],
            sources: sources.filter { sourceIDs.contains($0.id) },
            edges: linked,
            truncatedTopics: 0,
            truncatedSources: 0,
            truncatedEdges: max(0, truncatedEdges),
            language: language
        )
    }

    /// Complete text equivalent. Every drawn topic is listed with its weight,
    /// evidence count and per-source split; suppressed nodes are named as such.
    func textAlternative() -> String {
        let english = language == .en
        guard !topics.isEmpty else {
            return english
                ? "No interest network yet. Qualified reads, bookmarks, follows or “more like this” create topic tags."
                : "尚无兴趣网络。合格阅读、收藏、关注或「更多同类」后才会形成主题标签。"
        }
        var lines: [String] = []
        lines.append(english
            ? "Interest network: one hub, \(topics.count) topics and \(sources.count) sources. Edges mean a title tag and a source occurred together, not causality or semantic similarity."
            : "兴趣网络：中心「我的兴趣」，\(topics.count) 个主题、\(sources.count) 个来源。连线只表示标题标签与来源同时出现，不代表因果或语义相似度。")
        for topic in topics {
            let weight = String(format: "%.2f", topic.weight)
            let suppressed = topic.isSuppressed ? (english ? ", marked reduced by an explicit rule" : "，被减少主题规则标记") : ""
            let shares = topic.sourceShares.isEmpty
                ? (english ? "no source links" : "暂无来源关联")
                : topic.sourceShares.map { "\($0.label) \($0.count)" }.joined(separator: english ? ", " : "、")
            lines.append(english
                ? "Topic “\(topic.label)” weight \(weight), \(topic.evidenceCount) evidence items → \(shares)\(suppressed)."
                : "主题「\(topic.label)」权重 \(weight)，证据 \(topic.evidenceCount) 条 → \(shares)\(suppressed)。")
        }
        let suppressedSources = sources.filter(\.isSuppressed)
        if !suppressedSources.isEmpty {
            lines.append(english
                ? "Reduced sources (node marker only, no edge): \(suppressedSources.map(\.label).joined(separator: ", "))."
                : "已减少的来源（仅节点标记，不画连线）：\(suppressedSources.map(\.label).joined(separator: "、"))。")
        }
        if truncatedTopics > 0 || truncatedSources > 0 || truncatedEdges > 0 {
            lines.append(english
                ? "Truncated by weight: \(truncatedTopics) more topics, \(truncatedSources) more sources, \(truncatedEdges) more links."
                : "已按权重截断：另有 \(truncatedTopics) 个主题、\(truncatedSources) 个来源、\(truncatedEdges) 条连线。")
        }
        return lines.joined(separator: "\n")
    }

    private static func dimensionLabel(
        key: String,
        dimensions: [RecommendationExplanationDimension],
        language: AppLanguage
    ) -> String {
        if let dimension = dimensions.first(where: { $0.key == key }) { return dimension.label }
        return key
    }
}

/// One scan over local profile signals for per-source evidence counts and
/// human-readable source labels. It does not build a profile and does not call
/// the ranker; `TitleFeatures.tags` is already cached per title.
private struct EvidenceIndex {
    private var totalByTopic: [String: Int] = [:]
    private var countByTopicSource: [String: [String: Int]] = [:]
    private var totalBySource: [String: Int] = [:]
    private var labels: [String: String] = [:]

    init(state: LocalInterestState) {
        for signal in state.profileSignals.values {
            let item = signal.item
            let sourceID = item.source.id
            if labels[sourceID] == nil {
                labels[sourceID] = sourceLabel(item.source)
            }
            totalBySource[sourceID, default: 0] += 1
            for tag in TitleFeatures.tags(item.title) {
                totalByTopic[tag, default: 0] += 1
                countByTopicSource[tag, default: [:]][sourceID, default: 0] += 1
            }
        }
        // A saved bookmark is local evidence too, and the explanation page
        // already counts it. Include it without touching the profile.
        for feedback in state.feedbacks where feedback.participatesInProfile && feedback.kind == .bookmark {
            let item = feedback.item
            let sourceID = item.source.id
            if labels[sourceID] == nil {
                labels[sourceID] = sourceLabel(item.source)
            }
            totalBySource[sourceID, default: 0] += 1
            for tag in TitleFeatures.tags(item.title) {
                totalByTopic[tag, default: 0] += 1
                countByTopicSource[tag, default: [:]][sourceID, default: 0] += 1
            }
        }
    }

    func total(for topic: String) -> Int { totalByTopic[topic] ?? 0 }
    func total(forSource source: String) -> Int { totalBySource[source] ?? 0 }
    func label(for source: String, language: AppLanguage) -> String {
        if source == "weibo" { return L10n.string("source.weibo", language: language) }
        if source == "bilibili" { return L10n.string("source.bilibili", language: language) }
        if let label = labels[source], !label.isEmpty { return label }
        if let host = URL(string: source)?.host, !host.isEmpty { return host }
        return source
    }

    func shares(for topic: String, sourceLimit: Int) -> [InterestGraphSourceShare] {
        let entries = (countByTopicSource[topic] ?? [:])
            .filter { $0.value > 0 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(sourceLimit)
        return entries.map { sourceID, count in
            InterestGraphSourceShare(
                sourceID: sourceID,
                label: labels[sourceID] ?? sourceID,
                count: count
            )
        }
    }

    private func sourceLabel(_ source: NewsSource) -> String {
        switch source {
        case .weibo: return "weibo"
        case .bilibili: return "bilibili"
        case let .rss(name, _): return name
        }
    }
}
