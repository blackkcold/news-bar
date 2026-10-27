import Foundation

/// Entry point that created a research record. Fixed at creation time; the
/// record's origin never changes, even after a manual re-run.
enum ResearchOrigin: String, Codable, Sendable, CaseIterable {
    case burst, keyword, manual

    var isAutomatic: Bool { self != .manual }
}

enum ResearchStatus: String, Codable, Sendable, CaseIterable {
    case queued, running, ready, partial, failed, cancelled, interrupted, corrupt

    /// Statuses whose research task still owns a live slot in the coordinator.
    var isActive: Bool { self == .queued || self == .running }

    /// Statuses that may still carry a usable previous report.
    var keepsPreviousReport: Bool {
        self == .failed || self == .cancelled || self == .interrupted || self == .corrupt
    }
}

enum ResearchDepth: String, Codable, Sendable, CaseIterable {
    case quick, standard, deep
}

/// Why a record cannot be edited. A future-version file is readable in
/// projection only and must never be written back by an older build.
enum ResearchEntryIssue: String, Codable, Sendable, Equatable {
    case corrupt
    case ioUnavailable
    case unsupportedVersion
}

struct ResearchSeed: Codable, Hashable, Sendable {
    /// News item identity when the seed came from a live feed.
    var itemID: String?
    var title: String
    var url: String?
    var source: NewsSource
    var publishedAt: Date?
    var initialSummary: String
}

extension ResearchSeed {
    enum CodingKeys: String, CodingKey {
        case itemID, title, url, source, publishedAt, initialSummary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try container.decodeIfPresent(String.self, forKey: .itemID)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url)
        // Without a source the record cannot be attributed; do not invent one.
        source = try container.decode(NewsSource.self, forKey: .source)
        publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
        initialSummary = try container.decodeIfPresent(String.self, forKey: .initialSummary) ?? ""
    }
}

struct ResearchRun: Codable, Hashable, Sendable {
    enum Phase: String, Codable, Sendable, CaseIterable {
        case idle, planning, searching, reading, extracting, synthesizing, validating, done
    }

    var phase: Phase = .idle
    var depth: ResearchDepth = .standard
    var origin: ResearchOrigin = .manual
    var queriesPlanned = 0
    var queriesCompleted = 0
    var pagesRead = 0
    var aiCalls = 0
    var searchCalls = 0
    var startedAt: Date?
    var finishedAt: Date?
    var lastError: String?
}

extension ResearchRun {
    enum CodingKeys: String, CodingKey {
        case phase, depth, origin, queriesPlanned, queriesCompleted, pagesRead
        case aiCalls, searchCalls, startedAt, finishedAt, lastError
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        phase = try container.decodeIfPresent(Phase.self, forKey: .phase) ?? .idle
        depth = try container.decodeIfPresent(ResearchDepth.self, forKey: .depth) ?? .standard
        origin = try container.decodeIfPresent(ResearchOrigin.self, forKey: .origin) ?? .manual
        queriesPlanned = try container.decodeIfPresent(Int.self, forKey: .queriesPlanned) ?? 0
        queriesCompleted = try container.decodeIfPresent(Int.self, forKey: .queriesCompleted) ?? 0
        pagesRead = try container.decodeIfPresent(Int.self, forKey: .pagesRead) ?? 0
        aiCalls = try container.decodeIfPresent(Int.self, forKey: .aiCalls) ?? 0
        searchCalls = try container.decodeIfPresent(Int.self, forKey: .searchCalls) ?? 0
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }
}

struct ResearchRecord: Codable, Identifiable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    /// UUID string, never reused.
    let id: String
    /// SHA256 of the normalized topic title.
    var topicKey: String
    var origin: ResearchOrigin
    /// Latest observed title.
    var topic: String
    /// Other titles merged into this record. Capped at `aliasLimit`.
    var aliases: [String]
    var seed: ResearchSeed
    var createdAt: Date
    /// Most recent time this topic was observed in a feed.
    var lastSeenAt: Date
    /// Most recent successful report generation.
    var updatedAt: Date
    /// Most recent time the record was opened; write-throttled in the UI.
    var lastAccessedAt: Date
    var isPinned: Bool
    var isRead: Bool
    var status: ResearchStatus
    /// Last *successful* report. A failed run must never overwrite it.
    var report: BurstResearch?
    var run: ResearchRun
    /// 0 = legacy single-pass report; 2 = the evidence-backed pipeline.
    var reportVersion: Int
    /// Written on every new record. Missing means v1 (files written before the
    /// field existed). A higher value is read-only: the file is preserved.
    var schemaVersion: Int = ResearchRecord.currentSchemaVersion
    /// In-memory only. Set by the store when the file is corrupt, unreadable or
    /// from a newer build; never encoded and never written back.
    var loadIssue: ResearchEntryIssue? = nil

    static let aliasLimit = 8

    mutating func addAlias(_ alias: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != topic, !aliases.contains(trimmed) else { return }
        aliases.append(trimmed)
        if aliases.count > Self.aliasLimit {
            aliases.removeFirst(aliases.count - Self.aliasLimit)
        }
    }

    var strength: Int { report?.verification?.strength ?? 0 }

    var hasReport: Bool { report != nil }

    /// In-memory placeholder for an undecodable record file. The file is left
    /// untouched so the user can still inspect or delete it deliberately.
    static func corruptPlaceholder(id: String, date: Date) -> ResearchRecord {
        var run = ResearchRun()
        run.phase = .done
        run.origin = .manual
        run.startedAt = date
        run.finishedAt = date
        run.lastError = "Record file is corrupt"
        return ResearchRecord(
            id: id,
            topicKey: "",
            origin: .manual,
            topic: "",
            aliases: [],
            seed: ResearchSeed(
                itemID: nil,
                title: "",
                url: nil,
                source: .weibo,
                publishedAt: nil,
                initialSummary: ""
            ),
            createdAt: date,
            lastSeenAt: date,
            updatedAt: date,
            lastAccessedAt: date,
            isPinned: false,
            isRead: true,
            status: .corrupt,
            report: nil,
            run: run,
            reportVersion: 0
        )
    }
}

extension ResearchRecord {
    enum CodingKeys: String, CodingKey {
        case id, topicKey, origin, topic, aliases, seed, createdAt, lastSeenAt
        case updatedAt, lastAccessedAt, isPinned, isRead, status, report, run
        case reportVersion, schemaVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Identity and provenance are authoritative: a record missing them is
        // isolated by the store instead of being invented here.
        id = try container.decode(String.self, forKey: .id)
        topicKey = try container.decode(String.self, forKey: .topicKey)
        origin = try container.decode(ResearchOrigin.self, forKey: .origin)
        topic = try container.decode(String.self, forKey: .topic)
        seed = try container.decode(ResearchSeed.self, forKey: .seed)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        status = try container.decode(ResearchStatus.self, forKey: .status)

        // Display and ordering fields may be absent: fall back to durable
        // values, never to `Date()` (which would fake a fresh timestamp).
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        lastSeenAt = try container.decodeIfPresent(Date.self, forKey: .lastSeenAt) ?? createdAt
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        lastAccessedAt = try container.decodeIfPresent(Date.self, forKey: .lastAccessedAt)
            ?? updatedAt
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
        report = try container.decodeIfPresent(BurstResearch.self, forKey: .report)
        reportVersion = try container.decodeIfPresent(Int.self, forKey: .reportVersion) ?? 0
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? ResearchRecord.currentSchemaVersion

        var decodedRun = try container.decodeIfPresent(ResearchRun.self, forKey: .run)
            ?? ResearchRun()
        if decodedRun.origin == .manual, origin != .manual {
            // Older files omitted run.origin; the record's origin is the truth.
            decodedRun.origin = origin
        }
        run = decodedRun
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(topicKey, forKey: .topicKey)
        try container.encode(origin, forKey: .origin)
        try container.encode(topic, forKey: .topic)
        try container.encode(aliases, forKey: .aliases)
        try container.encode(seed, forKey: .seed)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastSeenAt, forKey: .lastSeenAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(lastAccessedAt, forKey: .lastAccessedAt)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(isRead, forKey: .isRead)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(report, forKey: .report)
        try container.encode(run, forKey: .run)
        try container.encode(reportVersion, forKey: .reportVersion)
        // All new and natural writes state the version explicitly.
        try container.encode(schemaVersion, forKey: .schemaVersion)
    }
}

// MARK: - Read-time degradation

extension ResearchRecord {
    /// Applies conservative downgrades that must not depend on the writer.
    ///
    /// Missing trust fields never upgrade a verdict; broken evidence references
    /// invalidate the core verification and turn a `ready` record into
    /// `partial`, while the readable report text is preserved.
    func normalizedForRead() -> ResearchRecord {
        var record = self
        record.schemaVersion = max(schemaVersion, ResearchRecord.currentSchemaVersion)
        guard var report = record.report else { return record }

        let evidenceIDs = Set(report.evidence.map(\.id))
        let hasBrokenTimelineReferences = report.timeline.contains { node in
            node.evidenceIDs.contains { !evidenceIDs.contains($0) }
        }
        guard var verification = report.verification else {
            if hasBrokenTimelineReferences {
                record.status = record.status == .ready ? .partial : record.status
                report.limitations = report.limitations
                    + (report.limitations.isEmpty ? "" : "\n")
                    + L10n.string("research.limitation.brokenEvidence")
                record.report = report
            }
            return record
        }

        var brokenReferences = false

        for claim in verification.claims {
            if claim.evidenceIDs.contains(where: { !evidenceIDs.contains($0) }) {
                brokenReferences = true
            }
        }
        for node in report.timeline {
            if node.evidenceIDs.contains(where: { !evidenceIDs.contains($0) }) {
                brokenReferences = true
            }
        }
        if report.evidence.isEmpty,
           verification.verdict != .unverified
            || verification.strength > 0
            || verification.independentSources > 0 {
            brokenReferences = true
            verification.independentSources = 0
        }

        if brokenReferences {
            verification.verdict = .unverified
            verification.strength = 0
            verification.claims = verification.claims.map { claim in
                var copy = claim
                copy.evidenceIDs = claim.evidenceIDs.filter { evidenceIDs.contains($0) }
                copy.status = nil
                return copy
            }
            report.verification = verification
            record.report = report
            if record.status == .ready {
                record.status = .partial
            }
            if !report.limitations.contains(L10n.string("research.limitation.brokenEvidence")) {
                report.limitations = report.limitations
                    + (report.limitations.isEmpty ? "" : "\n")
                    + L10n.string("research.limitation.brokenEvidence")
                record.report = report
            }
        }
        return record
    }
}

/// Counts used by the popover chip and the research center sidebar.
struct ResearchSummary: Sendable, Equatable {
    var burstCount = 0
    var unreadBurstCount = 0

    static let zero = ResearchSummary()
}
