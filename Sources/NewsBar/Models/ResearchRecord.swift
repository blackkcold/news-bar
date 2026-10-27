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

struct ResearchSeed: Codable, Hashable, Sendable {
    /// News item identity when the seed came from a live feed.
    var itemID: String?
    var title: String
    var url: String?
    var source: NewsSource
    var publishedAt: Date?
    var initialSummary: String
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

struct ResearchRecord: Codable, Identifiable, Hashable, Sendable {
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
    /// Optional so records written before this field existed still decode.
    var schemaVersion: Int? = nil

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

/// Counts used by the popover chip and the research center sidebar.
struct ResearchSummary: Sendable, Equatable {
    var burstCount = 0
    var unreadBurstCount = 0

    static let zero = ResearchSummary()
}
