import Foundation

// MARK: - Enumerations

enum WorkspaceNotificationKind: String, Codable, Sendable {
    case researchCompleted
    case eventProgress
}

/// Exact report version identity shared by event notices and research
/// completion notices. A record ID alone is not enough: the record may be
/// overwritten by a newer report before the notification is delivered.
enum WorkspaceResearchCausalToken {
    static func make(record: ResearchRecord) -> String? {
        guard let report = record.report else { return nil }
        let generated = report.generatedAt.map { String($0.timeIntervalSince1970) } ?? "no-date"
        return "research:\(record.id):\(generated):\(WorkspaceReportDigest.make(report))"
    }
}

enum WorkspaceSubjectKind: String, Codable, Sendable {
    case topic
    case event
    case mixed
}

enum WorkspaceUpdateState: String, Codable, Sendable {
    case current
    case hasUpdates
    case needsReview
}

enum WorkspaceCheckOutcome: Codable, Hashable, Sendable {
    case notConfigured
    case checked(added: Int, at: Date)
    case throttled(until: Date)
    case failed(message: String, at: Date)

    var checkedAt: Date? {
        switch self {
        case .notConfigured: return nil
        case let .checked(_, at), let .failed(_, at): return at
        case let .throttled(until): return until
        }
    }
}

enum WorkspaceEvidenceOrigin: String, Codable, Sendable {
    case research
    case event
}

enum WorkspaceEvidenceVerification: String, Codable, Sendable {
    case verifiedQuote
    case unverifiedQuote
    case snippetOnly
}

enum WorkspaceUpdateOrigin: String, Codable, Sendable {
    case rss
    case event
    /// A lead discovered by an explicit web search. Always unverified.
    case research
}

enum WorkspaceStoreIssue: String, Codable, Sendable, Equatable {
    case corruptFile
    case unsupportedVersion
    case ioUnavailable
}

// MARK: - Subject

struct WorkspaceSubject: Codable, Identifiable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    /// UUID, stable forever.
    let id: String
    var title: String
    var aliases: [String]
    var kind: WorkspaceSubjectKind
    var createdAt: Date
    var updatedAt: Date
    var lastActivityAt: Date
    var isFollowed: Bool
    var isArchived: Bool
    var archivedAt: Date?
    var updateState: WorkspaceUpdateState
    var lastCheckedAt: Date?
    var lastCheckOutcome: WorkspaceCheckOutcome
    var pendingUpdateIDs: [String]
    var researchRecordIDs: [String]
    var eventIDs: [String]
    /// "research:<id>", "event:<id>", "topic:<key>".
    var lookupKeys: [String]
    /// User-supplied page that seeds the first research run. Optional and
    /// additive: it never changes the encoded shape of a Record or Event.
    var seedURL: String? = nil
    var lastNotifiedAt: Date?
    var lastNotificationKind: WorkspaceNotificationKind?
    /// Which report version or event produced the last notification. Optional
    /// and additive: old index files decode it as nil. It lets the coordinator
    /// suppress a duplicate notice without a blanket time-based rule.
    var lastNotifiedReference: String? = nil
    var schemaVersion: Int
    /// Bumped by the store whenever a user-controlled field changes. A bulk
    /// reconcile keeps the stored revision instead of overwriting it.
    var userRevision: Int = 0

    init(
        id: String = UUID().uuidString,
        title: String,
        aliases: [String] = [],
        kind: WorkspaceSubjectKind = .topic,
        createdAt: Date,
        updatedAt: Date,
        lastActivityAt: Date,
        isFollowed: Bool = false,
        isArchived: Bool = false,
        archivedAt: Date? = nil,
        updateState: WorkspaceUpdateState = .current,
        lastCheckedAt: Date? = nil,
        lastCheckOutcome: WorkspaceCheckOutcome = .notConfigured,
        pendingUpdateIDs: [String] = [],
        researchRecordIDs: [String] = [],
        eventIDs: [String] = [],
        lookupKeys: [String] = [],
        seedURL: String? = nil,
        lastNotifiedAt: Date? = nil,
        lastNotificationKind: WorkspaceNotificationKind? = nil,
        lastNotifiedReference: String? = nil,
        schemaVersion: Int = WorkspaceSubject.currentSchemaVersion,
        userRevision: Int = 0
    ) {
        self.id = id
        self.title = title
        self.aliases = aliases
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastActivityAt = lastActivityAt
        self.isFollowed = isFollowed
        self.isArchived = isArchived
        self.archivedAt = archivedAt
        self.updateState = updateState
        self.lastCheckedAt = lastCheckedAt
        self.lastCheckOutcome = lastCheckOutcome
        self.pendingUpdateIDs = pendingUpdateIDs
        self.researchRecordIDs = researchRecordIDs
        self.eventIDs = eventIDs
        self.lookupKeys = lookupKeys
        self.seedURL = seedURL
        self.lastNotifiedAt = lastNotifiedAt
        self.lastNotificationKind = lastNotificationKind
        self.lastNotifiedReference = lastNotifiedReference
        self.schemaVersion = schemaVersion
        self.userRevision = userRevision
    }
}

extension WorkspaceSubject {
    /// Normalized, unique aliases. The title itself is not repeated.
    var normalizedAliases: [String] {
        let titleKey = TopicFingerprint.normalized(title)
        var seen: Set<String> = []
        return aliases.compactMap { alias in
            let key = TopicFingerprint.normalized(alias)
            guard !key.isEmpty, key != titleKey, seen.insert(key).inserted else { return nil }
            return alias.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func contains(recordID: String) -> Bool {
        researchRecordIDs.contains(recordID)
            || lookupKeys.contains("research:\(recordID)")
    }

    func contains(eventID: String) -> Bool {
        eventIDs.contains(eventID) || lookupKeys.contains("event:\(eventID)")
    }

    var recomputedKind: WorkspaceSubjectKind {
        switch (!researchRecordIDs.isEmpty, !eventIDs.isEmpty) {
        case (true, true): return .mixed
        case (false, true): return .event
        default: return .topic
        }
    }

    mutating func link(researchID: String, title: String, aliases incoming: [String]) {
        if !researchRecordIDs.contains(researchID) {
            researchRecordIDs.append(researchID)
        }
        insertLookupKey("research:\(researchID)")
        insertLookupKey("topic:\(TopicFingerprint.key(for: title))")
        mergeAliases(incoming)
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           TopicFingerprint.normalized(title) != TopicFingerprint.normalized(self.title) {
            mergeAliases([title])
        }
        kind = recomputedKind
    }

    mutating func link(eventID: String, title: String, aliases incoming: [String]) {
        if !eventIDs.contains(eventID) {
            eventIDs.append(eventID)
        }
        insertLookupKey("event:\(eventID)")
        mergeAliases(incoming)
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           TopicFingerprint.normalized(title) != TopicFingerprint.normalized(self.title) {
            mergeAliases([title])
        }
        kind = recomputedKind
    }

    mutating func markActivity(at date: Date) {
        if date > lastActivityAt { lastActivityAt = date }
        if date > updatedAt { updatedAt = date }
    }

    mutating func markArchived(_ archived: Bool, at date: Date) {
        isArchived = archived
        archivedAt = archived ? date : nil
        if date > updatedAt { updatedAt = date }
    }

    mutating func markUserStateChanged(at date: Date) {
        userRevision += 1
        if date > updatedAt { updatedAt = date }
    }

    private mutating func insertLookupKey(_ key: String) {
        guard !key.isEmpty, !lookupKeys.contains(key) else { return }
        lookupKeys.append(key)
    }

    private mutating func mergeAliases(_ incoming: [String]) {
        let titleKey = TopicFingerprint.normalized(title)
        for alias in incoming {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = TopicFingerprint.normalized(trimmed)
            guard !trimmed.isEmpty, !key.isEmpty, key != titleKey else { continue }
            if aliases.contains(where: { TopicFingerprint.normalized($0) == key }) { continue }
            aliases.append(trimmed)
        }
        if aliases.count > 12 {
            aliases.removeFirst(aliases.count - 12)
        }
    }

    /// Fields only the user (or the notification/check pipeline) may change.
    /// `saveAll` always copies these from the stored subject during a reconcile.
    static let userControlledKeys: Set<String> = [
        "isFollowed", "isArchived", "archivedAt", "lastCheckedAt",
        "lastCheckOutcome", "pendingUpdateIDs", "lastNotifiedAt",
        "lastNotificationKind", "lastNotifiedReference", "userRevision",
    ]

    mutating func adoptUserState(from stored: WorkspaceSubject) {
        isFollowed = stored.isFollowed
        isArchived = stored.isArchived
        archivedAt = stored.archivedAt
        lastCheckedAt = stored.lastCheckedAt
        lastCheckOutcome = stored.lastCheckOutcome
        pendingUpdateIDs = stored.pendingUpdateIDs
        seedURL = stored.seedURL
        lastNotifiedAt = stored.lastNotifiedAt
        lastNotificationKind = stored.lastNotificationKind
        lastNotifiedReference = stored.lastNotifiedReference
        userRevision = stored.userRevision
    }
}

// MARK: - Report versions

struct WorkspaceReportVersion: Codable, Identifiable, Hashable, Sendable {
    /// "\(recordID)#\(sequence)".
    let id: String
    let recordID: String
    let subjectID: String
    let sequence: Int
    let createdAt: Date
    let trigger: ResearchOrigin
    let report: BurstResearch
    let digest: String
    /// Fingerprint the analysis actually consumed. Optional for files written
    /// before the field existed; never recomputed at read time.
    var evidenceFingerprint: String? = nil
    var analysisSignature: ResearchReuseSignature? = nil
}

/// Digest that keeps the original verification flags, timestamps and sources.
enum WorkspaceReportDigest {
    static func make(_ report: BurstResearch) -> String {
        var parts: [String] = [
            report.summary,
            report.overview,
            report.generatedAt.map { String($0.timeIntervalSince1970) } ?? "no-date",
            String(report.promptVersion),
            report.depth.rawValue,
        ]
        for item in report.evidence.sorted(by: { $0.canonicalURL < $1.canonicalURL }) {
            parts.append(
                [
                    item.canonicalURL,
                    item.title,
                    item.quote,
                    item.quoteVerified ? "verified" : "unverified",
                    String(item.tier.rawValue),
                    item.stance.rawValue,
                    item.publishedAt.map { String($0.timeIntervalSince1970) } ?? "no-date",
                    item.fetchedAt == .distantPast ? "no-fetch" : String(item.fetchedAt.timeIntervalSince1970),
                    item.syndicationGroup ?? "",
                ].joined(separator: "\u{1F}")
            )
        }
        for node in report.timeline {
            parts.append("T\u{1F}" + node.date + "\u{1F}" + node.title + "\u{1F}" + node.detail)
        }
        return ContentIdentity.digest(parts.joined(separator: "\u{1E}"))
    }
}

// MARK: - Updates, evidence, timeline, metrics, detail

struct WorkspaceUpdateCandidate: Codable, Identifiable, Hashable, Sendable {
    /// Stable identity: `subjectID + canonicalURL`. Web search, RSS checks and
    /// automatic lead collection all use this one format.
    let id: String
    let subjectID: String
    let title: String
    let url: String
    let sourceName: String
    let publishedAt: Date?
    let discoveredAt: Date
    let origin: WorkspaceUpdateOrigin

    static func identity(subjectID: String, url: String) -> String {
        ContentIdentity.digest(
            "workspace-update\n\(subjectID)\n\(ContentIdentity.canonicalURL(url))"
        )
    }

    func canonicalized() -> WorkspaceUpdateCandidate {
        let canonicalID = Self.identity(subjectID: subjectID, url: url)
        guard canonicalID != id else { return self }
        return WorkspaceUpdateCandidate(
            id: canonicalID,
            subjectID: subjectID,
            title: title,
            url: url,
            sourceName: sourceName,
            publishedAt: publishedAt,
            discoveredAt: discoveredAt,
            origin: origin
        )
    }
}

struct WorkspaceEvidence: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let url: String
    let canonicalURL: String
    let quote: String
    let publishedAt: Date?
    let sourceName: String
    let origin: WorkspaceEvidenceOrigin
    let verification: WorkspaceEvidenceVerification
    let tier: SourceTier?
    let independence: NewsEventIndependence?
    let sharedWithEvent: Bool
}

struct WorkspaceTimelineEntry: Identifiable, Hashable, Sendable {
    let id: String
    let occurredAt: Date?
    let text: String
    let origin: WorkspaceEvidenceOrigin
    let evidenceIDs: [String]
    let confidence: Confidence?
}

struct WorkspaceSourceMetrics: Equatable, Sendable {
    var researchIndependentSourceCount: Int
    var researchUniqueDomainCount: Int
    var notificationPublisherCount: Int
    var notificationEligible: Bool
    var basis: String

    static let zero = WorkspaceSourceMetrics(
        researchIndependentSourceCount: 0,
        researchUniqueDomainCount: 0,
        notificationPublisherCount: 0,
        notificationEligible: false,
        basis: ""
    )
}

struct WorkspaceDetail: Sendable {
    var subject: WorkspaceSubject
    var event: NewsEvent?
    var research: ResearchRecord?
    var versions: [WorkspaceReportVersion]
    var evidence: [WorkspaceEvidence]
    var timeline: [WorkspaceTimelineEntry]
    var metrics: WorkspaceSourceMetrics
    var updates: [WorkspaceUpdateCandidate]
}

// MARK: - Store bootstrap and reconciler

struct WorkspaceBootstrap: Sendable, Equatable {
    var subjects: [WorkspaceSubject] = []
    var rebuilt: Bool = false
    var corruptFile: Bool = false
    var readOnly: Bool = false
    var issue: WorkspaceStoreIssue? = nil
}

struct WorkspaceReconcileResult: Sendable, Equatable {
    var subjects: [WorkspaceSubject]
    var changedIDs: Set<String>
    var createdIDs: Set<String>
}

struct WorkspaceUpdateCheckResult: Sendable, Equatable {
    var subject: WorkspaceSubject
    var added: [WorkspaceUpdateCandidate]
    var outcome: WorkspaceCheckOutcome
    var coverage: WorkspaceCheckCoverage = WorkspaceCheckCoverage()
}

/// What one RSS check actually did. Transient UI data only; the durable
/// subject keeps `lastCheckedAt` / `lastCheckOutcome`, not these counters.
struct WorkspaceCheckCoverage: Sendable, Equatable {
    var checkedSourceIDs: [String] = []
    var checkedSourceNames: [String] = []
    var eligibleSourceCount: Int = 0
    var deferredSourceCount: Int = 0
    var reusedSharedCheck: Bool = false
    var addedCount: Int = 0
    var budgetUsed: Int? = nil
    var budgetLimit: Int? = nil
    var budgetResetsAt: Date? = nil
    var nextEligibleAt: Date? = nil
    var retryAt: Date? = nil
    var failureSourceName: String? = nil
}

@MainActor
protocol WorkspaceUpdateChecking: AnyObject {
    func check(subjectID: String, sources: [NewsSource], now: Date) async
        -> WorkspaceUpdateCheckResult
}

// MARK: - Report analysis state

/// Persisted per record. The stored fingerprint is the one the analysis used,
/// never the current one, so a new event/update cannot fake a cache hit.
struct WorkspaceReportState: Codable, Sendable, Equatable, Hashable {
    enum Status: String, Codable, Sendable {
        case pending
        case analyzed
    }

    let recordID: String
    let subjectID: String
    var status: Status
    var signature: ResearchReuseSignature?
    var analyzedFingerprint: String?
    var versionID: String?
    var recordedAt: Date?
}

// MARK: - Research launcher types

typealias WorkspaceResearchExecutor = @MainActor (
    ResearchRecord,
    @escaping @Sendable (ResearchRun) async -> Void
) async -> ResearchExecution

struct WorkspaceResearchRequest: Sendable {
    var subjectID: String
    var depth: ResearchDepth
    var trigger: ResearchOrigin
    var forceRefresh: Bool
    var seed: ResearchSeed?
    /// Manual runs keep their original notification intent; automatic runs
    /// follow the user's research-completion notification switch instead of
    /// inheriting a hard-coded `true`.
    var notify: Bool
    /// Target an existing record instead of resolving the newest one. Used by
    /// the legacy automatic/keyword orchestrator after it provisioned a record.
    var recordID: String?
    /// Automatic runs always execute; the workspace reuse gate is for manual
    /// open/update actions.
    var allowReuse: Bool
    /// Automatic runs keep the pre-stage-4 full-run behavior. Manual runs keep
    /// the incremental context.
    var allowsIncremental: Bool

    init(
        subjectID: String,
        depth: ResearchDepth = .standard,
        trigger: ResearchOrigin = .manual,
        forceRefresh: Bool = false,
        seed: ResearchSeed? = nil,
        notify: Bool = true,
        recordID: String? = nil,
        allowReuse: Bool = true,
        allowsIncremental: Bool = true
    ) {
        self.subjectID = subjectID
        self.depth = depth
        self.trigger = trigger
        self.forceRefresh = forceRefresh
        self.seed = seed
        self.notify = notify
        self.recordID = recordID
        self.allowReuse = allowReuse
        self.allowsIncremental = allowsIncremental
    }
}

enum WorkspaceReuseReason: String, Sendable {
    case freshReport
    case unchangedEvidence
    case cacheWarm
}

/// Read-only prediction used by the detail footer. It mirrors the launcher's
/// reuse gate; the start call still decides for real.
struct WorkspaceReusePreview: Sendable, Equatable {
    var recordID: String
    var generatedAt: Date
    var age: TimeInterval
    var reason: WorkspaceReuseReason
}

enum WorkspaceResearchFailure: String, Sendable {
    case subjectMissing
    case noAIKey
    case alreadyActive
    case unavailable
    case persistenceFailed
}

enum WorkspaceResearchAction: Equatable, Sendable {
    case started(recordID: String)
    case focusedRunning(recordID: String)
    case reused(recordID: String, reason: WorkspaceReuseReason)
    case failed(WorkspaceResearchFailure)
}

// MARK: - Local search

struct WorkspaceSearchScope: OptionSet, Sendable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    static let subjects = WorkspaceSearchScope(rawValue: 1 << 0)
    static let reports = WorkspaceSearchScope(rawValue: 1 << 1)
    static let evidence = WorkspaceSearchScope(rawValue: 1 << 2)
    static let answers = WorkspaceSearchScope(rawValue: 1 << 3)
    static let all: WorkspaceSearchScope = [.subjects, .reports, .evidence, .answers]
}

enum WorkspaceSearchResult: Identifiable, Sendable {
    case subject(id: String, title: String, snippet: String, isFollowed: Bool)
    case report(recordID: String, subjectID: String, title: String,
                snippet: String, generatedAt: Date?)
    case evidence(id: String, subjectID: String, title: String,
                  snippet: String, url: String)
    case answer(id: String, query: String, snippet: String, createdAt: Date)

    var id: String {
        switch self {
        case let .subject(id, _, _, _): return "subject:\(id)"
        case let .report(recordID, _, _, _, _): return "report:\(recordID)"
        case let .evidence(id, _, _, _, _): return "evidence:\(id)"
        case let .answer(id, _, _, _): return "answer:\(id)"
        }
    }

    var associatedSubjectID: String? {
        switch self {
        case .subject(let id, _, _, _): return id
        case .report(_, let subjectID, _, _, _), .evidence(_, let subjectID, _, _, _):
            return subjectID.isEmpty ? nil : subjectID
        case .answer:
            return nil
        }
    }

    var isResearchMatch: Bool {
        switch self {
        case .report, .evidence: return true
        case .subject, .answer: return false
        }
    }
}

/// A read-only projection of an already active run. It is returned only with
/// local search results and is displayed only after the reader expands its row.
struct WorkspaceSearchRunSnapshot: Sendable, Identifiable {
    let recordID: String
    let subjectID: String
    let topic: String
    let status: ResearchStatus
    let phase: ResearchRun.Phase
    let queriesCompleted: Int
    let queriesPlanned: Int
    let pagesRead: Int
    let progressFacts: [ResearchRunFact]?

    var id: String { recordID }
}

struct WorkspaceSearchResponse: Sendable {
    var results: [WorkspaceSearchResult]
    var isLocalOnly: Bool
    var truncated: Bool
    var subjectTitles: [String: String] = [:]
    var activeResearchRuns: [WorkspaceSearchRunSnapshot] = []
}

enum WorkspaceSearchDocumentKind: String, Codable, Sendable {
    case subject
    case report
    case evidence
    case answer
}

struct WorkspaceSearchDocument: Codable, Identifiable, Sendable {
    let id: String
    let subjectID: String?
    let kind: WorkspaceSearchDocumentKind
    let title: String
    /// Short snippet only (<= 400 chars). Never raw private page text.
    let body: String
    let url: String?
    let updatedAt: Date
}

// MARK: - Evidence fingerprint

enum WorkspaceEvidenceFingerprint {
    static func make(
        event: NewsEvent?,
        research: ResearchRecord?,
        updates: [WorkspaceUpdateCandidate],
        asOf: Date? = nil
    ) -> String {
        var parts: [String] = []
        let reportEvidenceURLs: Set<String>
        if let report = research?.report {
            reportEvidenceURLs = Set(report.evidence.map(\.canonicalURL))
            parts.append("R\u{1F}" + (report.generatedAt.map { String($0.timeIntervalSince1970) } ?? "no-date"))
            for item in report.evidence.sorted(by: { $0.canonicalURL < $1.canonicalURL }) {
                parts.append(
                    [
                        "RE",
                        item.canonicalURL,
                        QuoteVerifier.normalize(item.quote),
                        item.quoteVerified ? "1" : "0",
                        item.publishedAt.map { String($0.timeIntervalSince1970) } ?? "no-date",
                        item.fetchedAt == .distantPast ? "no-fetch" : String(item.fetchedAt.timeIntervalSince1970),
                        item.syndicationGroup ?? "",
                    ].joined(separator: "\u{1F}")
                )
            }
        } else {
            reportEvidenceURLs = []
        }

        if let event {
            // Event evidence produced from a research report is self-derived.
            // Counting it makes every finished run look like a new external
            // lead and prevents a stable reuse hit.
            let external = event.evidence
                .filter { $0.inputKind != .research }
                .filter { !reportEvidenceURLs.contains(ContentIdentity.canonicalURL($0.url)) }
                .filter { item in asOf.map { item.fetchedAt <= $0 } ?? true }
                .sorted(by: { $0.id < $1.id })
            if !external.isEmpty {
                let header = external
                    .map { max($0.fetchedAt, $0.publishedAt ?? .distantPast) }
                    .max() ?? .distantPast
                parts.append("E\u{1F}" + String(header.timeIntervalSince1970))
                for item in external {
                    parts.append(
                        [
                            "EE",
                            item.id,
                            ContentIdentity.canonicalURL(item.url),
                            QuoteVerifier.normalize(item.excerpt),
                            item.publishedAt.map { String($0.timeIntervalSince1970) } ?? "no-date",
                            item.independence.rawValue,
                        ].joined(separator: "\u{1F}")
                    )
                }
            }
        }

        for update in updates.sorted(by: { $0.id < $1.id }) {
            if let asOf, update.discoveredAt > asOf { continue }
            let canonical = ContentIdentity.canonicalURL(update.url)
            // A lead generated from this report's own evidence is not external.
            if reportEvidenceURLs.contains(canonical) { continue }
            parts.append(
                [
                    "U",
                    update.id,
                    canonical,
                    update.publishedAt.map { String($0.timeIntervalSince1970) } ?? "no-date",
                    update.discoveredAt != .distantPast ? String(update.discoveredAt.timeIntervalSince1970) : "no-date",
                    update.origin.rawValue,
                ].joined(separator: "\u{1F}")
            )
        }

        return ContentIdentity.digest(parts.joined(separator: "\u{1E}"))
    }
}
