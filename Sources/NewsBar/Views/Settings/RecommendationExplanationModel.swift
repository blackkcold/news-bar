import Foundation

/// Shared readable names for the engine's component keys.
func explanationComponentName(_ key: String, _ language: AppLanguage) -> String {
    let english = language == .en
    switch key {
    case "interest": return english ? "Interest match" : "兴趣匹配"
    case "source": return english ? "Source familiarity" : "来源熟悉度"
    case "recency": return english ? "Recency" : "新鲜度"
    case "novelty": return english ? "Novelty" : "新颖度"
    case "publicHeat": return english ? "Public heat" : "公共热度"
    default: return key
    }
}

// MARK: - Segments

enum RecommendationExplanationSegment: String, CaseIterable, Identifiable, Sendable {
    case overview
    case interests
    case ranking
    case dataPrivacy

    var id: String { rawValue }

    func title(_ language: AppLanguage) -> String {
        let english = language == .en
        switch self {
        case .overview: return english ? "Overview" : "概览"
        case .interests: return english ? "Interests" : "兴趣关联"
        case .ranking: return english ? "Ranking" : "推荐链路"
        case .dataPrivacy: return english ? "Data & privacy" : "数据与隐私"
        }
    }

    func subtitle(_ language: AppLanguage) -> String {
        let english = language == .en
        switch self {
        case .overview: return english ? "What the current snapshot uses" : "当前快照用了什么"
        case .interests: return english ? "Tags, evidence and manual follows" : "标签、证据与手动关注"
        case .ranking: return english ? "Components, penalties and ranks" : "组成、惩罚与名次"
        case .dataPrivacy: return english ? "Local storage, outbound scope, clear" : "本机存储、发送范围、清空"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "rectangle.grid.2x2"
        case .interests: return "tag"
        case .ranking: return "list.number"
        case .dataPrivacy: return "lock.shield"
        }
    }
}

// MARK: - Status

enum RecommendationExplanationStatus: Equatable, Sendable {
    case resetting
    case notLoaded
    case unavailable
    case off
    case paused
    case privateReading
    case active

    func headline(_ language: AppLanguage) -> String {
        let english = language == .en
        switch self {
        case .resetting: return english ? "Clearing local data" : "正在清空本地数据"
        case .notLoaded: return english ? "Local data not loaded yet" : "本地数据尚未载入"
        case .unavailable: return english ? "Local interest data unavailable" : "本地兴趣数据不可用"
        case .off: return english ? "Public ranking" : "公共排序"
        case .paused: return english ? "Learning paused" : "学习已暂停"
        case .privateReading: return english ? "Private reading" : "隐私阅读中"
        case .active: return english ? "Local learning" : "本地学习"
        }
    }

    /// `retainedProfile` is true when learning is off but historical evidence
    /// still exists. Off must not be described as "no profile yet": the store
    /// keeps it, the ranker just stops using it.
    func detail(_ language: AppLanguage, retainedProfile: Bool = false) -> String {
        let english = language == .en
        switch self {
        case .resetting:
            return english
                ? "A privacy reset is in progress. The old profile and snapshot are hidden until it finishes; a failed clear is reported, never shown as success."
                : "正在执行隐私清空。完成前不显示旧画像与旧快照；清空失败会报告，不会显示成功。"
        case .notLoaded:
            return english
                ? "Waiting for the local store to load. This page does not read or re-rank on its own."
                : "正在等待本地存储载入。本页不会主动读取或重排。"
        case .unavailable:
            return english
                ? "Learning has stopped. You can still clear the local store in the settings section to recover; a failed clear is never shown as success."
                : "学习已停止。仍可在设置页的「本地兴趣与隐私」中清空以恢复；清空失败不会显示成功。"
        case .off:
            if retainedProfile {
                return english
                    ? "Local learning is off, so ranking uses only public heat and freshness. The profile you built earlier is kept but is not used for the current ranking; turning learning back on resumes with the retained profile. \(Self.softFeedbackAvailability(english))"
                    : "本地学习未开启，排序只使用公共热度与新鲜度。此前形成的画像仍保留，但不参与当前排序；重新开启后会继续使用保留的画像。\(Self.softFeedbackAvailability(english))"
            }
            return english
                ? "Local learning is off, so ranking uses only public heat and freshness. Turning it on starts collecting evidence for a profile. \(Self.softFeedbackAvailability(english))"
                : "本地学习未开启，排序只使用公共热度与新鲜度。开启后会开始积累画像证据。\(Self.softFeedbackAvailability(english))"
        case .paused:
            return english
                ? "No new evidence is added while paused. The existing profile is kept; this page will not resume learning. \(Self.softFeedbackAvailability(english))"
                : "暂停期间不新增证据，已有画像保留；本页不会恢复学习。\(Self.softFeedbackAvailability(english))"
        case .privateReading:
            return english
                ? "Current browsing is not recorded. The existing profile is kept and this page stays read-only. \(Self.softFeedbackAvailability(english))"
                : "当前浏览不会被记录；已有画像保留，本页保持只读。\(Self.softFeedbackAvailability(english))"
        case .active:
            return english
                ? "Ranking mixes the local profile with a public baseline. Viewing this page records nothing."
                : "排序会把本地画像与公共基线混合；查看本页不记录任何行为。"
        }
    }

    /// Soft profile feedback needs active learning; explicit rules do not.
    static func softFeedbackAvailability(_ english: Bool) -> String {
        english
            ? "Bookmarks, mutes and hides still work; reducing a topic, more like this and follows need learning on."
            : "收藏、屏蔽与隐藏仍可用；减少主题、更多同类与关注需要开启学习。"
    }
}

// MARK: - Input

struct RecommendationExplanationInput: Sendable {
    var isReady: Bool = true
    var isResetting: Bool = false
    var storageError: String?
    var privateReading: Bool = false
    var state: LocalInterestState
    var snapshot: RecommendationSnapshot?
    var sessionFeedback: [InterestFeedback] = []
    var now: Date = Date()
    var language: AppLanguage = .zh
}

// MARK: - Trace

struct RecommendationExplanationTraceRow: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let value: String
    var emphasis = false
}

struct RecommendationExplanationTrace: Equatable, Sendable {
    let contributions: [String: Double]
    let personalScore: Double
    let baselineScore: Double
    let confidence: Double
    let readPenalty: Double
    let negativePenalty: Double
    let negativeContentPenalty: Double
    let negativeTopicPenalty: Double
    let negativeSourcePenalty: Double
    let rawScore: Double
    let selectionScore: Double
    let sourcePenalty: Double
    let topicPenalty: Double
    let diversityPenalty: Double
    let rankBeforeDiversity: Int
    let finalRank: Int
    let selectionPolicy: String
    var rotationSourceUseCount: Int? = nil
    var rotationOffset: Int? = nil
    var rotationCandidateIndex: Int? = nil
    var rotationCandidateCount: Int? = nil

    var contributionsTotal: Double { contributions.values.reduce(0, +) }

    /// Sum of contributions minus read/negative penalties should equal rawScore.
    var contributionMismatch: Double {
        abs(contributionsTotal - readPenalty - negativePenalty - rawScore)
    }

    /// `selectionScore` is the decision key for additive slots only. Source
    /// rotation is lexicographic, so showing it as the reason would be a lie.
    var selectionScoreIsDecisionKey: Bool { selectionPolicy != "sourceRotation" }

    func consistencyNote(_ language: AppLanguage) -> String? {
        guard contributionMismatch > 0.001 else { return nil }
        let delta = String(format: "%.3f", contributionMismatch)
        return language == .en
            ? "Recorded components differ from the recorded raw score by \(delta). Values are shown as recorded, not recalculated."
            : "记录的组件合计与原始分相差 \(delta)。这里只显示记录值，不重新计算。"
    }

    func rows(_ language: AppLanguage) -> [RecommendationExplanationTraceRow] {
        let english = language == .en
        var rows: [RecommendationExplanationTraceRow] = contributions
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { key, value in
                RecommendationExplanationTraceRow(
                    id: "contribution.\(key)",
                    label: contributionLabel(key, language),
                    value: String(format: "%.3f", value)
                )
            }
        func row(_ id: String, _ label: String, _ value: Double, emphasis: Bool = false) {
            rows.append(RecommendationExplanationTraceRow(id: id, label: label, value: String(format: "%.3f", value), emphasis: emphasis))
        }
        row("personalScore", english ? "Personal score (before blend weight)" : "个人分（未乘混合权重）", personalScore, emphasis: true)
        row("baselineScore", english ? "Public baseline" : "公共基线", baselineScore)
        rows.append(RecommendationExplanationTraceRow(
            id: "confidence",
            label: english ? "Blend weight" : "混合权重",
            value: "\(Int((confidence * 100).rounded()))%"
        ))
        row("readPenalty", english ? "Read penalty" : "已读惩罚", readPenalty)
        row("negativePenalty", english ? "Soft negative total" : "软降权合计", negativePenalty, emphasis: true)
        row("negativeContent", english ? "Less like this event" : "少推荐这条", negativeContentPenalty)
        row("negativeTopic", english ? "Less like this topic" : "少推荐这个主题", negativeTopicPenalty)
        row("negativeSource", english ? "Less like this source" : "少推荐这个来源", negativeSourcePenalty)
        row("rawScore", english ? "Raw score" : "原始分", rawScore, emphasis: true)
        rows.append(RecommendationExplanationTraceRow(
            id: "selectionScore",
            label: selectionScoreLabel(language),
            value: String(format: "%.3f", selectionScore)
        ))
        row("sourcePenalty", english ? "Source penalty" : "来源惩罚", sourcePenalty)
        row("topicPenalty", english ? "Topic penalty" : "主题惩罚", topicPenalty)
        row("diversityPenalty", english ? "Diversity hold" : "多样性限制", diversityPenalty)
        rows.append(RecommendationExplanationTraceRow(
            id: "rankBeforeDiversity",
            label: english ? "Candidate-pool rank (before cluster dedupe)" : "候选池名次（聚类去重前）",
            value: "\(rankBeforeDiversity)"
        ))
        rows.append(RecommendationExplanationTraceRow(
            id: "finalRank",
            label: english ? "Final rank" : "最终名次",
            value: "\(finalRank)",
            emphasis: true
        ))
        rows.append(RecommendationExplanationTraceRow(
            id: "selectionPolicy",
            label: english ? "Selection policy" : "选择策略",
            value: policyLabel(selectionPolicy, language),
            emphasis: true
        ))
        if let rotationSourceUseCount {
            rows.append(intRow("rotation.sourceUseCount", english ? "Source uses at selection" : "选择时该来源已用次数", rotationSourceUseCount))
        }
        if let rotationOffset {
            rows.append(intRow("rotation.offset", english ? "Seed offset" : "seed 偏移", rotationOffset))
        }
        if let rotationCandidateIndex {
            rows.append(intRow("rotation.candidateIndex", english ? "Remaining candidate index (0-based)" : "剩余候选序号（0 基）", rotationCandidateIndex))
        }
        if let rotationCandidateCount {
            rows.append(intRow("rotation.candidateCount", english ? "Remaining candidates" : "剩余候选总数", rotationCandidateCount))
        }
        return rows
    }

    /// Caption for the rank fields; a cluster duplicate can occupy a pool rank
    /// while never appearing in the snapshot, so gaps and larger values exist.
    func rankContractNote(_ language: AppLanguage) -> String {
        language == .en
            ? "Candidate-pool rank is measured after URL de-duplication and hard blocks, before exact-title cluster de-duplication. Dropped duplicates still occupy a rank, so it can be larger than the returned item count and gaps are expected."
            : "候选池名次在 URL 去重与硬屏蔽之后、精确标题聚类去重之前计算。被聚类去重丢弃的候选仍占名次，因此可能大于返回条数并出现空档。"
    }

    func selectionScoreLabel(_ language: AppLanguage) -> String {
        let english = language == .en
        switch selectionPolicy {
        case "score":
            return english ? "Actual selection score (raw − slot penalties)" : "实际选择分（原始分 − 当次惩罚）"
        case "publicHeat":
            return english ? "Actual order key (public heat − slot penalties)" : "实际排序键（公共热度 − 当次惩罚）"
        case "publicFresh":
            return english ? "Actual order key (recency − slot penalties)" : "实际排序键（时效 − 当次惩罚）"
        case "sourceRotation":
            return english ? "Audit value only (not used for selection)" : "审计值（不用于选择）"
        default:
            return english ? "Selection score" : "选择分"
        }
    }

    private func intRow(_ id: String, _ label: String, _ value: Int) -> RecommendationExplanationTraceRow {
        RecommendationExplanationTraceRow(id: id, label: label, value: "\(value)")
    }

    private func contributionLabel(_ key: String, _ language: AppLanguage) -> String {
        let english = language == .en
        if key.hasPrefix("personal.") {
            return (english ? "Personal · " : "个人·") + explanationComponentName(String(key.dropFirst("personal.".count)), language)
        }
        if key.hasPrefix("baseline.") {
            return (english ? "Baseline · " : "基线·") + explanationComponentName(String(key.dropFirst("baseline.".count)), language)
        }
        return key
    }

    private func policyLabel(_ raw: String, _ language: AppLanguage) -> String {
        let english = language == .en
        switch raw {
        case "score": return english ? "Blended score" : "混合分排序"
        case "publicHeat": return english ? "Public heat slot" : "公共热度位"
        case "publicFresh": return english ? "Public-fresh slot" : "公共新鲜位"
        case "sourceRotation": return english ? "Source rotation (lexicographic, not additive)" : "来源补位（轮换，字典序非可加分）"
        default: return raw
        }
    }
}

// MARK: - Dimensions

struct RecommendationExplanationDimension: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Equatable, Sendable {
        case topic
        case entity
        case followed

        func title(_ language: AppLanguage) -> String {
            let english = language == .en
            switch self {
            case .topic: return english ? "Topics" : "主题"
            case .entity: return english ? "Entities" : "实体"
            case .followed: return english ? "Manual follows" : "手动关注"
            }
        }

        /// When a retained profile is being displayed, "no … yet" is wrong for
        /// an empty group: records may exist in the store but simply have no
        /// member of this kind, and learning is not ranking it.
        func emptyText(_ language: AppLanguage, retainedProfile: Bool = false) -> String {
            let english = language == .en
            if retainedProfile {
                switch self {
                case .topic:
                    return english
                        ? "The retained profile has no topic tags. Learning is off, so they do not affect ranking."
                        : "保留画像中没有主题标签；学习已关闭，这些记录不参与排序。"
                case .entity:
                    return english
                        ? "The retained profile has no entity tags. Learning is off, so they do not affect ranking."
                        : "保留画像中没有实体标签；学习已关闭，这些记录不参与排序。"
                case .followed:
                    return english
                        ? "The retained profile has no literal manual follows. Lexicon follows appear on their topic rows."
                        : "保留画像中没有词典外的手动关注；词典内关注显示在对应主题行。"
                }
            }
            switch self {
            case .topic: return english ? "No topic evidence yet." : "尚无主题证据。"
            case .entity: return english ? "No entity evidence yet." : "尚无实体证据。"
            case .followed:
                return english
                    ? "No literal manual follows. Lexicon follows appear on their topic rows."
                    : "没有词典外的手动关注；词典内关注显示在对应主题行。"
            }
        }
    }

    let kind: Kind
    let key: String
    let label: String
    let longTerm: Double
    let shortTerm: Double
    let evidenceCount: Int
    let relativeWeight: Double
    /// Canonical follow aliases that were merged into this topic/entity row.
    let manualFollowKeywords: [String]
    /// An explicit reduce-topic rule offsets this row's weight.
    let isReduced: Bool

    var id: String { "\(kind.rawValue):\(key)" }
    var entityDisplayName: String { label }
    var isManual: Bool { kind == .followed }
    /// A tag that exists only in the short-term (session) profile, e.g. from
    /// "more like this". Its bar uses the long-term value and can be 0.
    var isSessionOnly: Bool {
        abs(longTerm) <= 0.0001 && abs(shortTerm) > 0.0001
    }
}

struct RecommendationExplanationGroup: Identifiable, Equatable, Sendable {
    let kind: RecommendationExplanationDimension.Kind
    let title: String
    let emptyText: String
    let dimensions: [RecommendationExplanationDimension]

    var id: String { kind.rawValue }
}

// MARK: - Connections

struct RecommendationExplanationEvidence: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let sourceName: String
    let detail: String
}

struct RecommendationExplanationCandidateLink: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let sourceName: String
    let matchedTags: [String]
}

struct RecommendationExplanationConnections: Equatable, Sendable {
    static let evidenceLimit = 5
    /// The model keeps at most this many recent evidence titles per key.
    static let evidenceCap = 8
    static let candidateLimit = 5

    let dimensionID: String
    let label: String
    let isManualFollow: Bool
    let manualFollowKeywords: [String]
    let evidence: [RecommendationExplanationEvidence]
    let candidates: [RecommendationExplanationCandidateLink]
    let listedEvidenceCount: Int

    var nodeCount: Int { 1 + evidence.count + candidates.count }

    func textAlternative(_ language: AppLanguage) -> String {
        let english = language == .en
        let merged = manualFollowKeywords.isEmpty
            ? ""
            : (english
                ? " The topic weight also includes manual follows: \(manualFollowKeywords.joined(separator: ", ")) (one weight per topic)."
                : "该主题权重还包含手动关注：\(manualFollowKeywords.joined(separator: "、"))（同一主题只计一次）。")
        if isManualFollow {
            return english
                ? "Literal manual follow “\(label)” lists \(listedEvidenceCount) most recent matching local titles (max \(Self.evidenceCap); \(evidence.count) drawn) and \(candidates.count) snapshot candidates. Edges only mean literal keyword matches; they are not model inference or causality, and node positions follow list order, not vector distance or semantic similarity."
                : "字面手动关注「\(label)」列出最近 \(listedEvidenceCount) 条本地命中标题（最多 \(Self.evidenceCap) 条，图中画 \(evidence.count) 条）与 \(candidates.count) 篇快照候选。连线只表示字面关键词命中，不代表模型推断或因果；节点位置按列表顺序排列，不代表向量距离或语义相似度。"
        }
        return english
            ? "Tag “\(label)” lists \(listedEvidenceCount) most recent local evidence titles (max \(Self.evidenceCap); \(evidence.count) drawn) and \(candidates.count) snapshot candidates. Edges only mean title-tag hits, not causality; evidence is newest first and node positions do not encode vector distance or semantic similarity.\(merged)"
            : "标签「\(label)」列出最近 \(listedEvidenceCount) 条本地证据标题（最多 \(Self.evidenceCap) 条，图中画 \(evidence.count) 条）与 \(candidates.count) 篇快照候选。连线只表示标题标签命中，不代表因果；证据按时间从新到旧排列，节点位置不代表向量距离或语义相似度。\(merged)"
    }
}

// MARK: - Ranked items

struct RecommendationExplanationComponent: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let rawValue: Double
    let contribution: Double?
}

struct RecommendationExplanationRankedItem: Identifiable, Equatable, Sendable {
    let id: String
    let rank: Int
    let title: String
    let sourceName: String
    let score: Double
    let reason: String
    let components: [RecommendationExplanationComponent]
    let trace: RecommendationExplanationTrace?
    let matchedTags: [String]
    /// For public slots, the real key read from `ScoredRecommendation.components`.
    let slotKeyNote: String?
    let traceAvailableNote: String
    let traceUnavailableNote: String
}

struct RecommendationExplanationFact: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let body: String
}

struct ExplanationGuideSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let body: String
}

// MARK: - Model

struct RecommendationExplanationModel {
    let status: RecommendationExplanationStatus
    let statusHeadline: String
    let statusDetail: String
    let language: AppLanguage
    /// Version of the live in-memory state (all personalization changes).
    let currentStateVersion: Int
    /// Version recorded by the frozen ranking snapshot.
    let snapshotProfileVersion: Int?
    let snapshotProfileConfidence: Double?
    let snapshotConfidencePercent: Int?
    /// Blend weight of the live profile, shown only with an explicit live label.
    let currentProfileConfidence: Double
    let currentProfilePercent: Int
    let policyVersion: Int?
    let dimensions: [RecommendationExplanationDimension]
    let groups: [RecommendationExplanationGroup]
    let snapshotAsOf: Date?
    let candidateCount: Int
    let itemLimit: Int
    let itemsNote: String
    let items: [RecommendationExplanationRankedItem]
    let semanticNote: String
    let selectionNote: String
    let weightNote: String
    let readOnlyNote: String
    let emptyReason: String?
    /// True when learning is off but the model is showing a display-only copy
    /// of the retained profile. That copy never feeds the real ranker.
    let retainedProfileShown: Bool
    /// Explains that retained tags/weights are read-only and not ranking.
    let retainedProfileNote: String?
    /// Labels the raw score column in the ranking list.
    let scoreColumnNote: String
    let storageErrorNote: String?
    /// Shown when an unavailable store still has last-known in-memory data.
    let lastKnownNote: String?
    /// Live profile value, clearly separated from the frozen snapshot.
    let currentProfileNote: String?
    /// Shown when no snapshot exists, so no weight/rank is presented as ranking data.
    let noSnapshotNote: String?
    let clearNote: String
    let browserScopeNote: String
    let outboundNote: String
    let privacyFacts: [RecommendationExplanationFact]
    let guide: [ExplanationGuideSection]
    let guideUnavailable: Bool
    let guideUnavailableNote: String

    private let snapshot: RecommendationSnapshot?
    private let evidenceSeeds: [String: [RecommendationExplanationEvidence]]
    private let followedSeeds: [String: [RecommendationExplanationEvidence]]

    var hasDimensions: Bool { !dimensions.isEmpty }

    /// Explains canonical follows without promising more than the engine does.
    var followMergeNote: String? {
        guard dimensions.contains(where: { !$0.manualFollowKeywords.isEmpty }) else { return nil }
        return language == .en
            ? "A follow that matches the built-in lexicon raises its topic tag (for example Swift → Technology). Several aliases of the same topic count once in the current profile. Only literal keywords outside the lexicon appear under Manual follows."
            : "命中内置词典的关注会加到对应主题标签（例如 Swift → 科技）。同一主题的多个别名在当前画像中只计一次；只有词典外的关键词会出现在「手动关注」分组。"
    }

    func connections(for dimensionID: String) -> RecommendationExplanationConnections? {
        guard let dimension = dimensions.first(where: { $0.id == dimensionID }) else { return nil }
        let seeds = dimension.kind == .followed ? followedSeeds[dimension.key] : evidenceSeeds[dimension.key]
        let evidence = Array((seeds ?? []).prefix(RecommendationExplanationConnections.evidenceLimit))
        let matcher = dimension.kind == .followed ? LiteralTitleMatcher(dimension.key) : nil
        var candidates: [RecommendationExplanationCandidateLink] = []
        for item in snapshot?.items ?? [] {
            guard candidates.count < RecommendationExplanationConnections.candidateLimit else { break }
            let title = item.item.title
            let matches = matcher?.matches(title) ?? TitleFeatures.tags(title).contains(dimension.key)
            guard matches else { continue }
            candidates.append(RecommendationExplanationCandidateLink(
                id: item.contentID,
                title: item.item.displayTitle,
                sourceName: item.item.source.displayName,
                matchedTags: Array(TitleFeatures.tags(title).sorted().prefix(6))
            ))
        }
        return RecommendationExplanationConnections(
            dimensionID: dimension.id,
            label: dimension.label,
            isManualFollow: dimension.kind == .followed,
            manualFollowKeywords: dimension.manualFollowKeywords,
            evidence: evidence,
            candidates: candidates,
            listedEvidenceCount: dimension.evidenceCount
        )
    }

    func item(id: String) -> RecommendationExplanationRankedItem? {
        items.first { $0.id == id }
    }

    static func make(
        input: RecommendationExplanationInput,
        guide: [ExplanationGuideSection] = [],
        traceFor: (ScoredRecommendation) -> RecommendationExplanationTrace? = { _ in nil }
    ) -> RecommendationExplanationModel {
        let language = input.language
        let english = language == .en
        let status = resolveStatus(input)
        // Off must not erase history from the explanation. When evidence was
        // retained, build the profile from a display-only copy with learning
        // enabled and label every row as "retained · not ranked". The real
        // controller state and the ranker are untouched.
        let retainedProfileShown = status == .off && hasRetainedProfileEvidence(input.state)
        var displayInput = input
        if retainedProfileShown { displayInput.state.learningEnabled = true }
        let profile = InterestProfile.build(state: displayInput.state, now: input.now, sessionFeedback: displayInput.sessionFeedback)
        let seeds = status == .resetting ? [:] : buildEvidenceSeeds(input: displayInput)
        let followedSeeds = status == .resetting ? [:] : buildFollowedSeeds(input: displayInput)
        let dimensions = status == .resetting
            ? []
            : buildDimensions(input: displayInput, profile: profile, seeds: seeds, followedSeeds: followedSeeds, language: language)
        let groups = RecommendationExplanationDimension.Kind.allCases.map { kind in
            RecommendationExplanationGroup(
                kind: kind,
                title: kind.title(language),
                emptyText: kind.emptyText(language, retainedProfile: retainedProfileShown),
                dimensions: dimensions.filter { $0.kind == kind }
            )
        }
        let items = status == .resetting ? [] : buildItems(input: input, traceFor: traceFor, language: language)
        let snapshot = input.snapshot
        // Live-profile fields must describe the real state, never the retained
        // display copy (which exists only to render tags/weights). While off,
        // the real profile is intentionally empty.
        let realProfile = retainedProfileShown
            ? InterestProfile.build(state: input.state, now: input.now)
            : profile
        let currentPercent = Int((realProfile.confidence * 100).rounded())
        let snapshotPercent = snapshot.map { Int(($0.profileConfidence * 100).rounded()) }
        let itemCount = items.count
        let candidateCount = snapshot?.items.count ?? 0
        let liveProfileText = english
            ? "Current live profile: state v\(input.state.profileVersion) · blend weight \(currentPercent)%."
            : "当前实时画像：状态 v\(input.state.profileVersion) · 混合权重 \(currentPercent)%。"

        return RecommendationExplanationModel(
            status: status,
            statusHeadline: status.headline(language),
            statusDetail: status.detail(language, retainedProfile: retainedProfileShown),
            language: language,
            currentStateVersion: input.state.profileVersion,
            snapshotProfileVersion: snapshot?.profileVersion,
            snapshotProfileConfidence: snapshot?.profileConfidence,
            snapshotConfidencePercent: snapshotPercent,
            currentProfileConfidence: realProfile.confidence,
            currentProfilePercent: currentPercent,
            policyVersion: snapshot?.policyVersion,
            dimensions: dimensions,
            groups: groups,
            snapshotAsOf: snapshot?.asOf,
            candidateCount: candidateCount,
            itemLimit: 10,
            itemsNote: itemsNote(shown: itemCount, total: candidateCount, language: language),
            items: items,
            semanticNote: semanticNote(snapshot: snapshot, language: language),
            selectionNote: english
                ? "Slots follow the policy: each tenth position includes two public heat/freshness slots and one source rotation (backfill) slot. Rotation is a lexicographic least-used-source choice, not an additive score. Penalties and rank movement are shown in the drill-down."
                : "槽位由策略决定：每十个位置含 2 个公共热度/时效位与 1 个来源补位（轮换）位；轮换按最少使用来源的字典序选择，不是可加分数。惩罚与名次变化见下钻。",
            weightNote: english
                ? "Weights are relative local profile scores, not a probability or an accuracy. Bars use the long-term value; a tag seen only in this session is marked session/recent and its bar can be 0."
                : "权重是本地画像中的相对评分，不是概率，也不是准确率。条形按长期值绘制；仅在本次会话出现的标签会标「会话/近期」，条形可能为 0。",
            readOnlyNote: english
                ? "Read-only snapshot: opening this page writes no learning events, makes no network or AI request, and triggers no re-ranking."
                : "只读快照：查看本页不会写入学习事件、不会调用 AI 或联网、不会触发重新排序。",
            emptyReason: dimensions.isEmpty
                ? emptyReason(status: status, language: language, retainedProfile: retainedProfileShown)
                : nil,
            retainedProfileShown: retainedProfileShown,
            retainedProfileNote: retainedProfileShown
                ? (english
                    ? "Retained profile · not used for the current ranking. Learning is off; the tags and weights below are a read-only copy of the kept profile. Turning learning back on resumes using them."
                    : "保留画像·未参与当前排序。本地学习未开启；下方标签与权重来自保留画像的只读副本，重新开启后会恢复使用。")
                : nil,
            scoreColumnNote: english
                ? "The right-hand number is the blended score before slot penalties, not the actual selection key."
                : "列表右侧为混合分（惩罚前），不是实际选择键。",
            storageErrorNote: input.storageError == nil ? nil : (english
                ? "Local interest data is unavailable, so learning has stopped. You can still clear it in the settings section to recover. This page stays read-only."
                : "本地兴趣数据不可用，学习已停止。仍可在设置页的「本地兴趣与隐私」中清空以恢复；本页只读。"),
            lastKnownNote: lastKnownNote(status: status, hasData: !dimensions.isEmpty || !items.isEmpty, language: language),
            currentProfileNote: currentProfileNote(
                status: status,
                snapshotVersion: snapshot?.profileVersion,
                snapshotPercent: snapshotPercent,
                currentVersion: input.state.profileVersion,
                currentPercent: currentPercent,
                learningEnabled: input.state.learningEnabled,
                language: language
            ),
            noSnapshotNote: snapshot == nil
                ? noSnapshotNote(status: status, learningEnabled: input.state.learningEnabled, liveProfileText: liveProfileText, language: language)
                : nil,
            clearNote: english
                ? "Clearing personal data removes behavior, profile, feedback, followed keywords, personalized caches, research state, the public content cache and the current web session, and stops learning. Local personalization must be turned on again to continue. Retained bookmarks never rebuild the profile. A failed clear is not reported as success."
                : "清空个人数据会删除行为、画像、反馈、关注词、个性化缓存、调研状态、公开内容缓存与当前网页会话，同时停止学习；如需继续本地个性化，需要重新开启。保留的收藏不会自动重建画像。清空失败不会显示成功。",
            browserScopeNote: english
                ? "Clearing in settings only affects this app's local interest library. System or other-browser history, cookies and backups are untouched. The reader keeps only first-party cookies for sites you visit, managed in the Browser tab."
                : "设置页的清空只影响本应用兴趣库，不影响系统或其他浏览器的历史、Cookie 与备份；阅读器只保存你访问站点自身的第一方 Cookie，可在「浏览器」页签管理。",
            outboundNote: english
                ? "Selected news titles and the minimum context still go to your configured AI provider for summaries; search and translation follow their own settings, and a deep research run you start also sends its titles, topics and search results to that provider. The local profile is never uploaded."
                : "AI 摘要仍会把你选中的新闻标题及必要上下文发送给配置的提供商；搜索与翻译按各自设置发送；你主动发起的深度调研还会把标题、主题与搜索结果发送给该提供商。本地画像不会上传。",
            privacyFacts: privacyFacts(language: language),
            guide: guide,
            guideUnavailable: guide.isEmpty,
            guideUnavailableNote: guide.isEmpty ? (english
                ? "The offline guide resource is unavailable; no invented guide text is shown."
                : "离线说明资源不可用；这里不会显示编造的说明文字。") : "",
            snapshot: snapshot,
            evidenceSeeds: seeds,
            followedSeeds: followedSeeds
        )
    }

    // MARK: Build helpers

    private static func resolveStatus(_ input: RecommendationExplanationInput) -> RecommendationExplanationStatus {
        if input.isResetting { return .resetting }
        if input.storageError != nil { return .unavailable }
        guard input.isReady else { return .notLoaded }
        // Off wins over a stale private-reading flag: learning is not running.
        if !input.state.learningEnabled { return .off }
        if input.privateReading { return .privateReading }
        if input.state.learningPaused { return .paused }
        return .active
    }

    /// Historical evidence still in the store. Only feedback that actually fed
    /// the profile counts; a bookmark kept across a clear is not profile
    /// evidence and must not be presented as a retained profile.
    static func hasRetainedProfileEvidence(_ state: LocalInterestState) -> Bool {
        if !state.profileSignals.isEmpty || !state.followedTopics.isEmpty { return true }
        return state.feedbacks.contains { $0.participatesInProfile }
    }

    private static func emptyReason(
        status: RecommendationExplanationStatus,
        language: AppLanguage,
        retainedProfile: Bool = false
    ) -> String {
        let english = language == .en
        switch status {
        case .resetting:
            return english
                ? "A privacy reset is in progress; old interest evidence is hidden."
                : "正在清空本地数据，旧兴趣证据暂不显示。"
        case .notLoaded:
            return english
                ? "Waiting for local data to load; no interest evidence is shown yet."
                : "正在等待本地数据载入，尚不显示兴趣证据。"
        case .off:
            if retainedProfile {
                return english
                    ? "Local learning is off. The profile is retained but does not take part in the current ranking; turning learning back on restores it. The retained profile has no displayable tags or follows."
                    : "本地学习未开启。画像仍保留，但不参与当前排序；重新开启后会恢复。保留画像中没有可展示的标签或关注。"
            }
            return english
                ? "Local learning is off, so no local interest evidence exists yet. Turning it on starts collecting evidence."
                : "本地学习未开启，尚无本地兴趣证据；开启后会开始积累证据。"
        case .paused:
            return english
                ? "Learning is paused and there is no local interest evidence yet. More like this needs learning on and unpaused."
                : "学习已暂停，尚无本地兴趣证据；「更多同类」需要学习开启且未暂停。"
        case .unavailable:
            return english
                ? "No local interest evidence can be shown while the store is unavailable."
                : "本地存储不可用，尚无本地兴趣证据。"
        case .privateReading, .active:
            return english
                ? "No local interest evidence yet. Qualified reads, bookmarks, follows or “more like this” (session preference) create tags."
                : "尚无本地兴趣证据。合格阅读、收藏、关注或「更多同类」（会话偏好）后才会形成标签。"
        }
    }

    private static func itemsNote(shown: Int, total: Int, language: AppLanguage) -> String {
        let english = language == .en
        if total > shown {
            return english ? "Showing first \(shown) of \(total) snapshot items." : "显示前 \(shown) 条（快照共 \(total) 条）。"
        }
        return english ? "\(total) snapshot items." : "快照共 \(total) 条。"
    }

    private static func currentProfileNote(
        status: RecommendationExplanationStatus,
        snapshotVersion: Int?,
        snapshotPercent: Int?,
        currentVersion: Int,
        currentPercent: Int,
        learningEnabled: Bool,
        language: AppLanguage
    ) -> String? {
        guard status == .active || status == .privateReading || status == .paused else { return nil }
        guard learningEnabled, let snapshotVersion, let snapshotPercent else { return nil }
        guard snapshotVersion != currentVersion || snapshotPercent != currentPercent else { return nil }
        return language == .en
            ? "Current live profile: state v\(currentVersion) · blend weight \(currentPercent)%. It may be newer than this frozen snapshot (v\(snapshotVersion) · \(snapshotPercent)%)."
            : "当前实时画像：状态 v\(currentVersion) · 混合权重 \(currentPercent)%，可能比冻结快照（v\(snapshotVersion) · \(snapshotPercent)%）更新。"
    }

    private static func noSnapshotNote(
        status: RecommendationExplanationStatus,
        learningEnabled: Bool,
        liveProfileText: String,
        language: AppLanguage
    ) -> String {
        let english = language == .en
        switch status {
        case .resetting:
            return english
                ? "A privacy reset is in progress; no ranking data is shown."
                : "正在清空本地数据，暂不显示排序数据。"
        case .off, .unavailable, .notLoaded:
            return english
                ? "No recommendation snapshot yet, so no ranking weight or rank is shown."
                : "尚无推荐快照，因此不显示排序权重与名次。"
        default:
            if learningEnabled {
                return english
                    ? "No recommendation snapshot yet, so no ranking weight or rank is shown. \(liveProfileText) This live value is not a snapshot."
                    : "尚无推荐快照，因此不显示排序权重与名次。\(liveProfileText)该实时值不是快照。"
            }
            return english
                ? "No recommendation snapshot yet, so no ranking weight or rank is shown."
                : "尚无推荐快照，因此不显示排序权重与名次。"
        }
    }

    private static func lastKnownNote(
        status: RecommendationExplanationStatus,
        hasData: Bool,
        language: AppLanguage
    ) -> String? {
        guard status == .unavailable, hasData else { return nil }
        return language == .en
            ? "Items and tags below are last-known in-memory data and may no longer match the current store."
            : "下方标签与条目为上次已知的内存数据，可能已不再对应当前存储。"
    }

    private static func semanticNote(snapshot: RecommendationSnapshot?, language: AppLanguage) -> String {
        let english = language == .en
        if snapshot?.semanticDegraded == false {
            // The shipped engine always reports degraded; this branch only
            // exists for evaluation snapshots and must not claim live ranking.
            return english
                ? "An evaluation-only embedding model produced this snapshot. It does not take part in live ranking; tag links still show title hits only."
                : "本次快照来自仅用于离线评测的向量模型，不参与线上排序；标签关联仍只表示标题命中。"
        }
        return english
            ? "Semantic embeddings are not used for this ranking; tag links only show title-tag hits. Node positions do not encode vector distance."
            : "语义向量当前未参与排序；标签关联只表示标题命中。节点位置不代表向量距离。"
    }

    private static func privacyFacts(language: AppLanguage) -> [RecommendationExplanationFact] {
        let english = language == .en
        return [
            RecommendationExplanationFact(
                id: "retention",
                title: english ? "Local retention" : "本机保留",
                body: english
                    ? "Raw events 30 days · aggregate profile 180 days · content metadata 7 days. Clearing can keep bookmarks."
                    : "原始事件 30 天 · 画像聚合 180 天 · 内容元数据 7 天；清空时可选保留收藏。"
            ),
            RecommendationExplanationFact(
                id: "publicCache",
                title: english ? "Public content cache" : "公开内容缓存",
                body: english
                    ? "Public news metadata is a cache, not personal profile data. A normal refresh can recreate it."
                    : "公开新闻元数据属于缓存，不是个人画像。正常刷新可能重新生成。"
            ),
            RecommendationExplanationFact(
                id: "preferences",
                title: english ? "Bookmarks and blocks" : "收藏与屏蔽",
                body: english
                    ? "Explicit bookmarks, mutes and hides stay separate from automatic learning. A retained bookmark does not rebuild the profile."
                    : "明确的收藏、屏蔽与隐藏和自动学习分开。保留的收藏不会重建画像。"
            )
        ]
    }

    private static func buildEvidenceSeeds(input: RecommendationExplanationInput) -> [String: [RecommendationExplanationEvidence]] {
        var entries: [(date: Date, item: NewsItem, detail: String, tags: Set<String>)] = []
        let readingDetail = input.language == .en ? "Reading evidence" : "阅读证据"
        let bookmarkDetail = input.language == .en ? "Bookmark" : "收藏"
        for signal in input.state.profileSignals.values {
            entries.append((signal.occurredAt, signal.item, readingDetail, TitleFeatures.tags(signal.item.title)))
        }
        for feedback in input.state.feedbacks + input.sessionFeedback
        where feedback.participatesInProfile && feedback.kind == .bookmark {
            entries.append((feedback.occurredAt, feedback.item, bookmarkDetail, TitleFeatures.tags(feedback.item.title)))
        }
        // Dictionary iteration order is undefined; establish real time order first.
        entries.sort { $0.date > $1.date }

        var collected: [String: [RecommendationExplanationEvidence]] = [:]
        var seen: [String: Set<String>] = [:]
        for entry in entries {
            let contentID = ContentIdentity.id(for: entry.item.url)
            for tag in entry.tags {
                guard seen[tag]?.contains(contentID) != true else { continue }
                guard (collected[tag]?.count ?? 0) < RecommendationExplanationConnections.evidenceCap else { continue }
                seen[tag, default: []].insert(contentID)
                collected[tag, default: []].append(RecommendationExplanationEvidence(
                    id: contentID,
                    title: entry.item.displayTitle,
                    sourceName: entry.item.source.displayName,
                    detail: entry.detail
                ))
            }
        }
        return collected
    }

    /// One pass over local contents with precompiled literal matchers. Canonical
    /// follows are not scanned here: their weight belongs to a topic row.
    private static func buildFollowedSeeds(input: RecommendationExplanationInput) -> [String: [RecommendationExplanationEvidence]] {
        let keywords = literalFollowKeywords(input.state.followedTopics)
        guard input.state.learningEnabled, !keywords.isEmpty else { return [:] }
        let matchers = keywords.map(LiteralTitleMatcher.init)
        let detail = input.language == .en ? "Local title match" : "本地标题命中"
        let sorted = input.state.contents.values.sorted { $0.lastSeen > $1.lastSeen }
        var result: [String: [RecommendationExplanationEvidence]] = [:]
        var saturated = 0
        for record in sorted {
            guard saturated < matchers.count else { break }
            for (index, matcher) in matchers.enumerated() {
                let keyword = keywords[index]
                guard (result[keyword]?.count ?? 0) < RecommendationExplanationConnections.evidenceCap else { continue }
                guard matcher.matches(record.item.title) else { continue }
                result[keyword, default: []].append(RecommendationExplanationEvidence(
                    id: ContentIdentity.id(for: record.item.url),
                    title: record.item.displayTitle,
                    sourceName: record.item.source.displayName,
                    detail: detail
                ))
                if (result[keyword]?.count ?? 0) == RecommendationExplanationConnections.evidenceCap {
                    saturated += 1
                }
            }
        }
        return result
    }

    private static func dedupedKeywords(_ followedTopics: [String]) -> [String] {
        var seen: Set<String> = []
        return followedTopics.filter { keyword in
            let folded = keyword.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            return seen.insert(folded).inserted
        }
    }

    private static func literalFollowKeywords(_ followedTopics: [String]) -> [String] {
        dedupedKeywords(followedTopics).filter { TitleFeatures.canonicalTag(for: $0) == nil }
    }

    private static func canonicalFollowKeywords(_ followedTopics: [String]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for keyword in dedupedKeywords(followedTopics) {
            guard let tag = TitleFeatures.canonicalTag(for: keyword) else { continue }
            result[tag, default: []].append(keyword)
        }
        return result
    }

    private static func buildDimensions(
        input: RecommendationExplanationInput,
        profile: InterestProfile,
        seeds: [String: [RecommendationExplanationEvidence]],
        followedSeeds: [String: [RecommendationExplanationEvidence]],
        language: AppLanguage
    ) -> [RecommendationExplanationDimension] {
        let state = input.state
        let canonicalKeywords = canonicalFollowKeywords(state.followedTopics)
        let canonicalTargets = Set(canonicalKeywords.keys)
        let reduceTopics = Set(state.feedbacks
            .filter { $0.kind == .reduceTopic && $0.participatesInProfile }
            .compactMap(\.topic))

        var topics: [(key: String, long: Double, short: Double, count: Int, manual: [String], reduced: Bool)] = []
        var entities: [(key: String, long: Double, short: Double, count: Int, manual: [String], reduced: Bool)] = []
        var followed: [(key: String, long: Double, short: Double, count: Int, manual: [String], reduced: Bool)] = []

        // The ranker consumes both long-term tags and short-term (session)
        // tags. Iterating only `topics` hid "more like this" evidence and made
        // the page claim there was none.
        let keys = Set(profile.topics.keys).union(profile.shortTermTopics.keys).sorted()
        for key in keys {
            let long = profile.topics[key] ?? 0
            let short = profile.shortTermTopics[key] ?? 0
            let include = abs(long) > 0.0001 || abs(short) > 0.0001 || canonicalTargets.contains(key) || reduceTopics.contains(key)
            guard include else { continue }
            if key.hasPrefix("entity:") {
                entities.append((key, long, short, seeds[key]?.count ?? 0, canonicalKeywords[key] ?? [], reduceTopics.contains(key)))
            } else if key.hasPrefix("followed:") {
                let keyword = String(key.dropFirst("followed:".count))
                followed.append((keyword, long, short, followedSeeds[keyword]?.count ?? 0, [], reduceTopics.contains(key)))
            } else {
                topics.append((key, long, short, seeds[key]?.count ?? 0, canonicalKeywords[key] ?? [], reduceTopics.contains(key)))
            }
        }

        topics.sort { $0.long == $1.long ? $0.key < $1.key : $0.long > $1.long }
        entities.sort { $0.long == $1.long ? $0.key < $1.key : $0.long > $1.long }
        followed.sort { $0.long == $1.long ? $0.key < $1.key : $0.long > $1.long }

        // Peak normalization deliberately uses long-term values only. A
        // session-only tag must not shrink every other bar or fake a weight.
        let peak = (topics.map { $0.long } + entities.map { $0.long } + followed.map { $0.long }).map(abs).max() ?? 0
        func dimension(
            _ kind: RecommendationExplanationDimension.Kind,
            _ raw: (key: String, long: Double, short: Double, count: Int, manual: [String], reduced: Bool)
        ) -> RecommendationExplanationDimension {
            let weight = peak > 0 ? max(0, raw.long) / peak : 0
            return RecommendationExplanationDimension(
                kind: kind,
                key: raw.key,
                label: label(kind: kind, key: raw.key, language: language),
                longTerm: raw.long,
                shortTerm: raw.short,
                evidenceCount: raw.count,
                relativeWeight: min(1, weight),
                manualFollowKeywords: raw.manual,
                isReduced: raw.reduced
            )
        }
        return topics.map { dimension(.topic, $0) }
            + entities.map { dimension(.entity, $0) }
            + followed.map { dimension(.followed, $0) }
    }

    private static func label(kind: RecommendationExplanationDimension.Kind, key: String, language: AppLanguage) -> String {
        switch kind {
        case .followed:
            return key
        case .entity:
            let name = key.hasPrefix("entity:") ? String(key.dropFirst("entity:".count)) : key
            return entityNames[name] ?? name
        case .topic:
            if let names = topicNames[key] { return language == .en ? names.en : names.zh }
            return key
        }
    }

    private static let topicNames: [String: (zh: String, en: String)] = [
        "ai": ("AI", "AI"),
        "technology": ("科技", "Technology"),
        "auto": ("汽车", "Automotive"),
        "finance": ("金融", "Finance"),
        "space": ("航天", "Space"),
        "health": ("健康", "Health"),
        "design": ("设计", "Design"),
        "sports": ("体育", "Sports"),
        "culture": ("文化", "Culture"),
        "gaming": ("游戏", "Gaming"),
        "world": ("国际", "World")
    ]

    private static let entityNames: [String: String] = [
        "apple": "Apple",
        "google": "Google",
        "microsoft": "Microsoft",
        "vivo": "vivo",
        "tesla": "Tesla"
    ]

    private static func buildItems(
        input: RecommendationExplanationInput,
        traceFor: (ScoredRecommendation) -> RecommendationExplanationTrace?,
        language: AppLanguage
    ) -> [RecommendationExplanationRankedItem] {
        let english = language == .en
        let limit = 10
        let ranked = Array((input.snapshot?.items ?? []).prefix(limit))
        return ranked.enumerated().map { index, candidate in
            let trace = traceFor(candidate)
            return RecommendationExplanationRankedItem(
                id: candidate.contentID,
                rank: index + 1,
                title: candidate.item.displayTitle,
                sourceName: candidate.item.source.displayName,
                score: candidate.score,
                reason: reasonLabel(candidate.reason, language: language),
                components: componentRows(candidate.components, trace: trace, language: language),
                trace: trace,
                matchedTags: Array(TitleFeatures.tags(candidate.item.title).sorted().prefix(6)),
                slotKeyNote: slotKeyNote(candidate.components, trace: trace, language: language),
                traceAvailableNote: english
                    ? "These values come from the trace actually recorded during this ranking pass."
                    : "以下数值来自本次排序实际记录的轨迹，未重新打分。",
                traceUnavailableNote: english
                    ? "No ranking trace is available for this article in this snapshot. Missing fields stay blank."
                    : "本次快照未提供该文章的排序轨迹（不可用）。缺失字段保持空白。"
            )
        }
    }

    private static func slotKeyNote(
        _ components: [String: Double],
        trace: RecommendationExplanationTrace?,
        language: AppLanguage
    ) -> String? {
        guard let trace else { return nil }
        let english = language == .en
        switch trace.selectionPolicy {
        case "publicHeat":
            guard let heat = components["publicHeat"] else {
                return english
                    ? "This public slot has no heat value; its base order key is recency."
                    : "该公共位没有热度值，排序基数为时效。"
            }
            return english
                ? String(format: "Slot base key (before penalties): public heat %.3f (row.components)", heat)
                : String(format: "本槽排序基数（惩罚前）：公共热度 %.3f（row.components）", heat)
        case "publicFresh":
            guard let recency = components["recency"] else { return nil }
            return english
                ? String(format: "Slot base key (before penalties): recency %.3f (row.components)", recency)
                : String(format: "本槽排序基数（惩罚前）：时效 %.3f（row.components）", recency)
        default:
            return nil
        }
    }

    private static func componentRows(
        _ components: [String: Double],
        trace: RecommendationExplanationTrace?,
        language: AppLanguage
    ) -> [RecommendationExplanationComponent] {
        let order = ["interest", "source", "recency", "novelty", "publicHeat"]
        return components.keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? order.count
            let ib = order.firstIndex(of: b) ?? order.count
            return ia == ib ? a < b : ia < ib
        }.map { key in
            RecommendationExplanationComponent(
                id: key,
                label: explanationComponentName(key, language),
                rawValue: components[key] ?? 0,
                contribution: trace?.contributions["personal." + key]
            )
        }
    }

    private static func reasonLabel(_ reason: String, language: AppLanguage) -> String {
        let english = language == .en
        switch reason {
        case "interest": return english ? "Interest match" : "兴趣匹配"
        case "publicHeat": return english ? "Public heat" : "公共热度"
        case "fresh": return english ? "Freshness" : "新鲜度"
        case "exploration": return english ? "Source rotation" : "来源补位"
        default: return reason
        }
    }
}

// MARK: - Literal keyword matcher

/// Precompiled literal keyword matcher so a follows scan does not compile one
/// regex per keyword × content pair on the main thread.
private struct LiteralTitleMatcher {
    let keyword: String
    private let foldedNeedle: String
    private let regex: NSRegularExpression?

    init(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keyword = trimmed
        let isASCII = trimmed.unicodeScalars.allSatisfy { $0.isASCII }
        let lower = trimmed.lowercased()
        self.foldedNeedle = lower.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        self.regex = isASCII && !trimmed.isEmpty
            ? try? NSRegularExpression(
                pattern: "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: lower) + "(?![A-Za-z0-9])",
                options: .caseInsensitive
            )
            : nil
    }

    func matches(_ title: String) -> Bool {
        guard !keyword.isEmpty else { return false }
        guard let regex else {
            return title.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let folded = title.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        // Cheap substring precheck avoids running the regex on most titles.
        guard folded.range(of: foldedNeedle, options: [.caseInsensitive]) != nil else { return false }
        return regex.firstMatch(in: folded, range: NSRange(folded.startIndex..., in: folded)) != nil
    }
}
