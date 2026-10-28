import Foundation

struct TimelineNode: Codable, Hashable, Sendable, Identifiable {
    var id: String { ContentIdentity.digest("\(date)\n\(title)\n\(detail)") }
    /// AI-produced date label, e.g. "2026-08-05", "8月3日", or a relative label.
    let date: String
    let title: String
    let detail: String

    // Added in the evidence-backed pipeline. Defaults keep legacy JSON readable.
    var sortDate: Date? = nil
    var precision: DatePrecision = .unknown
    var evidenceIDs: [String] = []
    var confidence: Confidence = .medium

    init(
        date: String,
        title: String,
        detail: String,
        sortDate: Date? = nil,
        precision: DatePrecision = .unknown,
        evidenceIDs: [String] = [],
        confidence: Confidence = .medium
    ) {
        self.date = date
        self.title = title
        self.detail = detail
        self.sortDate = sortDate
        self.precision = precision
        self.evidenceIDs = evidenceIDs
        self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey {
        case date, title, detail, sortDate, precision, evidenceIDs, confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decode(String.self, forKey: .detail)
        sortDate = try container.decodeIfPresent(Date.self, forKey: .sortDate)
        precision = try container.decodeIfPresent(DatePrecision.self, forKey: .precision) ?? .unknown
        evidenceIDs = try container.decodeIfPresent([String].self, forKey: .evidenceIDs) ?? []
        confidence = try container.decodeIfPresent(Confidence.self, forKey: .confidence) ?? .medium
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(title, forKey: .title)
        try container.encode(detail, forKey: .detail)
        try container.encodeIfPresent(sortDate, forKey: .sortDate)
        try container.encode(precision, forKey: .precision)
        try container.encode(evidenceIDs, forKey: .evidenceIDs)
        try container.encode(confidence, forKey: .confidence)
    }
}

/// Whether web search ran (and how it ended) for a burst research pass.
enum BurstSearchStatus: String, Codable, Sendable {
    case none
    case searching
    case succeeded
    case failed
}

struct BurstResearch: Codable, Hashable, Sendable {
    var summary: String = ""
    var overview: String = ""
    /// Empty when the AI lacked grounded info (e.g., pure-AI fallback) — UI hides it.
    var timeline: [TimelineNode] = []
    /// Source URLs the research is grounded on (search mode only).
    var sources: [String] = []
    /// Self-healing contract: true when AI wants page content scraped for accuracy.
    var needsRefetch: Bool = false
    /// URLs the AI wants scraped when `needsRefetch` is true.
    var refetchURLs: [String] = []
    /// How web search ended in this pass (for UI diagnostics & logging).
    var searchStatus: BurstSearchStatus = .none

    // Added in the evidence-backed pipeline. Defaults keep legacy artifacts readable.
    var evidence: [EvidenceItem] = []
    var verification: VerificationReport? = nil
    var limitations: String = ""
    var generatedAt: Date? = nil
    var promptVersion: Int = 0
    var depth: ResearchDepth = .standard
    var method: ResearchMethod? = nil

    init(
        summary: String = "",
        overview: String = "",
        timeline: [TimelineNode] = [],
        sources: [String] = [],
        needsRefetch: Bool = false,
        refetchURLs: [String] = [],
        searchStatus: BurstSearchStatus = .none,
        evidence: [EvidenceItem] = [],
        verification: VerificationReport? = nil,
        limitations: String = "",
        generatedAt: Date? = nil,
        promptVersion: Int = 0,
        depth: ResearchDepth = .standard,
        method: ResearchMethod? = nil
    ) {
        self.summary = summary
        self.overview = overview
        self.timeline = timeline
        self.sources = sources
        self.needsRefetch = needsRefetch
        self.refetchURLs = refetchURLs
        self.searchStatus = searchStatus
        self.evidence = evidence
        self.verification = verification
        self.limitations = limitations
        self.generatedAt = generatedAt
        self.promptVersion = promptVersion
        self.depth = depth
        self.method = method
    }

    enum CodingKeys: String, CodingKey {
        case summary, overview, timeline, sources, needsRefetch, refetchURLs, searchStatus
        case evidence, verification, limitations, generatedAt, promptVersion, depth, method
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        overview = try container.decodeIfPresent(String.self, forKey: .overview) ?? ""
        timeline = try container.decodeIfPresent([TimelineNode].self, forKey: .timeline) ?? []
        sources = try container.decodeIfPresent([String].self, forKey: .sources) ?? []
        needsRefetch = try container.decodeIfPresent(Bool.self, forKey: .needsRefetch) ?? false
        refetchURLs = try container.decodeIfPresent([String].self, forKey: .refetchURLs) ?? []
        searchStatus = try container.decodeIfPresent(BurstSearchStatus.self, forKey: .searchStatus) ?? .none
        evidence = try container.decodeIfPresent([EvidenceItem].self, forKey: .evidence) ?? []
        verification = try container.decodeIfPresent(VerificationReport.self, forKey: .verification)
        limitations = try container.decodeIfPresent(String.self, forKey: .limitations) ?? ""
        generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt)
        promptVersion = try container.decodeIfPresent(Int.self, forKey: .promptVersion) ?? 0
        depth = try container.decodeIfPresent(ResearchDepth.self, forKey: .depth) ?? .standard
        method = try container.decodeIfPresent(ResearchMethod.self, forKey: .method)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(summary, forKey: .summary)
        try container.encode(overview, forKey: .overview)
        try container.encode(timeline, forKey: .timeline)
        try container.encode(sources, forKey: .sources)
        try container.encode(needsRefetch, forKey: .needsRefetch)
        try container.encode(refetchURLs, forKey: .refetchURLs)
        try container.encode(searchStatus, forKey: .searchStatus)
        try container.encode(evidence, forKey: .evidence)
        try container.encodeIfPresent(verification, forKey: .verification)
        try container.encode(limitations, forKey: .limitations)
        try container.encodeIfPresent(generatedAt, forKey: .generatedAt)
        try container.encode(promptVersion, forKey: .promptVersion)
        try container.encode(depth, forKey: .depth)
        try container.encodeIfPresent(method, forKey: .method)
    }
}

extension BurstResearch {
    /// Nodes that cite at least one evidence ID. This is the denominator for
    /// "has the model grounded its timeline?"; quote-level verification is a
    /// stricter check performed by the presentation layer.
    var citedTimelineCount: Int {
        timeline.filter { !$0.evidenceIDs.isEmpty }.count
    }

    /// A report with only unsourced timeline prose must not be presented as a
    /// completed, ready research result.
    var hasGroundedContent: Bool {
        !summary.isEmpty || !overview.isEmpty || citedTimelineCount > 0
    }
}

struct WebSearchResult: Codable, Hashable, Sendable {
    let url: String
    let title: String
    let description: String
    /// Search-provider snippet; the only content available when scraping is off.
    var snippet: String = ""

    init(url: String, title: String, description: String, snippet: String = "") {
        self.url = url
        self.title = title
        self.description = description
        self.snippet = snippet
    }
}

/// Extensible for future Bing/DDG providers; only Firecrawl (keyless) is shipped.
enum WebSearchProvider: String, CaseIterable, Codable, Sendable {
    case firecrawl
}
