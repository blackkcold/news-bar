import Foundation

enum NewsEventInputKind: String, Codable, Sendable { case rss, trend, research }
enum NewsEventPublisherKind: String, Codable, Sendable { case newsPublisher, official, unknown }
enum NewsEventIndependence: String, Codable, Sendable { case independent, samePublisher, syndicated, unknown }
enum NewsEventCoreConsistency: String, Codable, Sendable { case consistent, contested, unknown }
enum NewsEventClaimRisk: String, Codable, Sendable { case ordinary, highRisk }
enum NewsEventClaimStatus: String, Codable, Sendable { case unverified, supported, contested, corrected }
enum NewsEventClaimScope: String, Codable, Sendable { case core, detail }
enum NewsEventLifecycle: String, Codable, Sendable { case queued, tracking, expired }
enum NewsEventChangeKind: String, Codable, Sendable { case initial, routine, majorProgress, correction }
enum NewsEventTrackingStatus: String, Codable, Sendable { case scheduled, checking, budgetDeferred, noFreshSource, failed }
enum NewsEventNotificationEligibility: String, Codable, Sendable {
    case eligible, insufficientPublishers, coreUnknown, coreContested, alreadyNotified, staleEvidence
}
enum NewsEventInterestDisposition: String, Codable, Sendable { case open, matched, unmatched, excluded, hardBlocked }

enum NewsEventControllerState: Equatable, Sendable {
    case idle, loading(hasCachedEvents: Bool)
    case loaded(updatedAt: Date, isStale: Bool)
    case failed(message: String, hasCachedEvents: Bool)
}

enum NewsEventTrackingState: String, Codable, Equatable, Sendable {
    case idle, tracking, budgetDeferred, noFreshSource, failed, capacityLimited
}

enum NewsEventBudgetAvailability: String, Codable, Sendable { case available, paused, unknown }

struct NewsEventBudgetSnapshot: Codable, Equatable, Sendable {
    var availability: NewsEventBudgetAvailability
    var reason: String?
    /// Event-capacity detail, independent from RSS-check budget availability.
    var capacityReason: String? = nil
    var checksUsed: Int?
    var checksLimit: Int?
    var resetsAt: Date?

    init(
        availability: NewsEventBudgetAvailability = .unknown,
        reason: String? = nil,
        capacityReason: String? = nil,
        checksUsed: Int? = nil,
        checksLimit: Int? = nil,
        resetsAt: Date? = nil
    ) {
        self.availability = availability
        self.reason = reason
        self.capacityReason = capacityReason
        self.checksUsed = checksUsed
        self.checksLimit = checksLimit
        self.resetsAt = resetsAt
    }
}

struct NewsEventClaim: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var text: String
    var risk: NewsEventClaimRisk
    var status: NewsEventClaimStatus
    var evidenceIDs: [String]
    /// Optional so snapshots written before conflict scoping remain decodable.
    var scope: NewsEventClaimScope? = nil
}

struct NewsEventTimelineNode: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var occurredAt: Date?
    var text: String
    var evidenceIDs: [String]
}

struct NewsEventEvidence: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let url: String
    let excerpt: String
    let inputKind: NewsEventInputKind
    let publisherKind: NewsEventPublisherKind
    let sourceID: String?
    let sourceName: String
    let author: String?
    let publisherKey: String?
    let independence: NewsEventIndependence
    let publishedAt: Date?
    let fetchedAt: Date
    var subjectAliases: [String]
    let action: String?
    let eventDescription: String
    let eventTime: Date?
    let location: String?
    var claims: [NewsEventClaim]
    /// Research report conflicts are copied verbatim here and accumulated on the event.
    var conflicts: [String]
    /// Optional for backwards compatibility with previously persisted evidence.
    var coreConflicts: [String]? = nil
    var detailConflicts: [String]? = nil
    var timeline: [NewsEventTimelineNode]
    /// A bounded public signal (for example a trend rank); never a truth score.
    var publicSignal: Int?

    var publicationTimeUnknown: Bool { publishedAt == nil }

    init(
        id: String,
        title: String,
        url: String,
        excerpt: String,
        inputKind: NewsEventInputKind,
        publisherKind: NewsEventPublisherKind,
        sourceID: String? = nil,
        sourceName: String,
        author: String? = nil,
        publisherKey: String? = nil,
        independence: NewsEventIndependence = .unknown,
        publishedAt: Date? = nil,
        fetchedAt: Date,
        subjectAliases: [String] = [],
        action: String? = nil,
        eventDescription: String,
        eventTime: Date? = nil,
        location: String? = nil,
        claims: [NewsEventClaim] = [],
        conflicts: [String] = [],
        coreConflicts: [String]? = nil,
        detailConflicts: [String]? = nil,
        timeline: [NewsEventTimelineNode] = [],
        publicSignal: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.excerpt = excerpt
        self.inputKind = inputKind
        self.publisherKind = publisherKind
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.author = author
        self.publisherKey = publisherKey
        self.independence = independence
        self.publishedAt = publishedAt
        self.fetchedAt = fetchedAt
        self.subjectAliases = subjectAliases
        self.action = action
        self.eventDescription = eventDescription
        self.eventTime = eventTime
        self.location = location
        self.claims = claims
        self.conflicts = conflicts
        self.coreConflicts = coreConflicts
        self.detailConflicts = detailConflicts
        self.timeline = timeline
        self.publicSignal = publicSignal
    }
}

struct NewsEvent: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var title: String
    var action: String?
    var eventDescription: String
    var subjectAliases: [String]
    var eventTime: Date?
    var location: String?
    var lifecycle: NewsEventLifecycle
    /// Optional marker for a short-lived, unnotified candidate expiry.
    var provisionalCandidateExpiredAt: Date? = nil
    /// Optional timestamp that preserves a longer tracking window after major progress.
    var lastMajorProgressAt: Date? = nil
    var coreConsistency: NewsEventCoreConsistency
    let firstSeenAt: Date
    var lastEvidenceAt: Date
    var nextCheckAt: Date?
    var expiresAt: Date?
    var trackingStatus: NewsEventTrackingStatus
    var trackingMessage: String?
    var followupIndex: Int
    var lastCheckedAt: Date?
    var evidence: [NewsEventEvidence]
    var claims: [NewsEventClaim]
    var timeline: [NewsEventTimelineNode]
    var conflicts: [String]
    /// New snapshots distinguish core contradictions from detail-only conflicts.
    /// `nil` means this event came from an older snapshot and is treated conservatively.
    var coreConflicts: [String]? = nil
    var detailConflicts: [String]? = nil
    var mergeReasons: [String]
    var sourceGroups: [NewsEventSourceGroup]
    var countablePublisherCount: Int
    var notificationEligibility: NewsEventNotificationEligibility
    var publicImportanceScore: Int
    var publicImportanceReason: String?
    var personalInterestScore: Int
    var interestDisposition: NewsEventInterestDisposition
    var interestReasons: [String]
    var notificationKeys: Set<String>
    var lastNotifiedAt: Date?
    /// The semantic state last accepted for notification; optional for old snapshots.
    var lastNotifiedFingerprint: String? = nil
    var notificationMessage: String?

    var hasConflict: Bool { coreConsistency == .contested || !conflicts.isEmpty }
    var coreConflictDetails: [String] {
        if let coreConflicts { return coreConflicts }
        let details = Set(detailConflicts ?? [])
        return conflicts.filter { !details.contains($0) }
    }
    var detailConflictDetails: [String] { detailConflicts ?? [] }
    var wasNotified: Bool { lastNotifiedAt != nil }
    var publicationTimeUnknown: Bool { evidence.allSatisfy { $0.publishedAt == nil } }

    init(
        id: String = UUID().uuidString,
        title: String,
        action: String? = nil,
        eventDescription: String,
        subjectAliases: [String],
        eventTime: Date? = nil,
        location: String? = nil,
        lifecycle: NewsEventLifecycle = .queued,
        provisionalCandidateExpiredAt: Date? = nil,
        lastMajorProgressAt: Date? = nil,
        coreConsistency: NewsEventCoreConsistency = .unknown,
        firstSeenAt: Date,
        lastEvidenceAt: Date,
        nextCheckAt: Date? = nil,
        expiresAt: Date? = nil,
        trackingStatus: NewsEventTrackingStatus = .scheduled,
        trackingMessage: String? = nil,
        followupIndex: Int = 0,
        lastCheckedAt: Date? = nil,
        evidence: [NewsEventEvidence] = [],
        claims: [NewsEventClaim] = [],
        timeline: [NewsEventTimelineNode] = [],
        conflicts: [String] = [],
        coreConflicts: [String]? = nil,
        detailConflicts: [String]? = nil,
        mergeReasons: [String] = [],
        sourceGroups: [NewsEventSourceGroup] = [],
        countablePublisherCount: Int = 0,
        notificationEligibility: NewsEventNotificationEligibility = .coreUnknown,
        publicImportanceScore: Int = 0,
        publicImportanceReason: String? = nil,
        personalInterestScore: Int = 0,
        interestDisposition: NewsEventInterestDisposition = .open,
        interestReasons: [String] = [],
        notificationKeys: Set<String> = [],
        lastNotifiedAt: Date? = nil,
        lastNotifiedFingerprint: String? = nil,
        notificationMessage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.action = action
        self.eventDescription = eventDescription
        self.subjectAliases = subjectAliases
        self.eventTime = eventTime
        self.location = location
        self.lifecycle = lifecycle
        self.provisionalCandidateExpiredAt = provisionalCandidateExpiredAt
        self.lastMajorProgressAt = lastMajorProgressAt
        self.coreConsistency = coreConsistency
        self.firstSeenAt = firstSeenAt
        self.lastEvidenceAt = lastEvidenceAt
        self.nextCheckAt = nextCheckAt
        self.expiresAt = expiresAt
        self.trackingStatus = trackingStatus
        self.trackingMessage = trackingMessage
        self.followupIndex = followupIndex
        self.lastCheckedAt = lastCheckedAt
        self.evidence = evidence
        self.claims = claims
        self.timeline = timeline
        self.conflicts = conflicts
        self.coreConflicts = coreConflicts
        self.detailConflicts = detailConflicts
        self.mergeReasons = mergeReasons
        self.sourceGroups = sourceGroups
        self.countablePublisherCount = countablePublisherCount
        self.notificationEligibility = notificationEligibility
        self.publicImportanceScore = publicImportanceScore
        self.publicImportanceReason = publicImportanceReason
        self.personalInterestScore = personalInterestScore
        self.interestDisposition = interestDisposition
        self.interestReasons = interestReasons
        self.notificationKeys = notificationKeys
        self.lastNotifiedAt = lastNotifiedAt
        self.lastNotifiedFingerprint = lastNotifiedFingerprint
        self.notificationMessage = notificationMessage
    }
}

enum NewsEventMatchDecision: Equatable, Sendable {
    case sameEvent(reasons: [String]), separate(reasons: [String]), insufficient(reasons: [String])
}

protocol NewsEventMatching: Sendable {
    func decide(_ evidence: NewsEventEvidence, against event: NewsEvent) -> NewsEventMatchDecision
}

struct NewsEventSourceGroup: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let publisherKey: String?
    let publisherKind: NewsEventPublisherKind
    let independence: NewsEventIndependence
    let evidenceIDs: [String]
}

protocol NewsEventSourceResolving: Sendable {
    func groups(for evidence: [NewsEventEvidence]) -> [NewsEventSourceGroup]
    func countablePublisherCount(in evidence: [NewsEventEvidence]) -> Int
}

struct NewsEventFeedCursor: Codable, Equatable, Sendable {
    let sourceID: String
    var eTag: String?
    var lastModified: String?
    var checkedAt: Date?
    var attemptedAt: Date?
    var retryAfter: Date?
    var failureCount: Int
    var lastError: String?

    init(
        sourceID: String,
        eTag: String? = nil,
        lastModified: String? = nil,
        checkedAt: Date? = nil,
        attemptedAt: Date? = nil,
        retryAfter: Date? = nil,
        failureCount: Int = 0,
        lastError: String? = nil
    ) {
        self.sourceID = sourceID
        self.eTag = eTag
        self.lastModified = lastModified
        self.checkedAt = checkedAt
        self.attemptedAt = attemptedAt
        self.retryAfter = retryAfter
        self.failureCount = max(0, failureCount)
        self.lastError = lastError
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID, eTag, lastModified, checkedAt, attemptedAt, retryAfter, failureCount, lastError
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try container.decode(String.self, forKey: .sourceID)
        eTag = try container.decodeIfPresent(String.self, forKey: .eTag)
        lastModified = try container.decodeIfPresent(String.self, forKey: .lastModified)
        checkedAt = try container.decodeIfPresent(Date.self, forKey: .checkedAt)
        attemptedAt = try container.decodeIfPresent(Date.self, forKey: .attemptedAt)
        retryAfter = try container.decodeIfPresent(Date.self, forKey: .retryAfter)
        failureCount = max(0, try container.decodeIfPresent(Int.self, forKey: .failureCount) ?? 0)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encodeIfPresent(eTag, forKey: .eTag)
        try container.encodeIfPresent(lastModified, forKey: .lastModified)
        try container.encodeIfPresent(checkedAt, forKey: .checkedAt)
        try container.encodeIfPresent(attemptedAt, forKey: .attemptedAt)
        try container.encodeIfPresent(retryAfter, forKey: .retryAfter)
        try container.encode(failureCount, forKey: .failureCount)
        try container.encodeIfPresent(lastError, forKey: .lastError)
    }
}

struct NewsEventTrackingResult: Sendable {
    let state: NewsEventTrackingState
    let evidence: [NewsEventEvidence]
    let budgetSnapshot: NewsEventBudgetSnapshot
    let checkedEventIDs: [String]
    let pendingEventIDs: [String]
    let message: String?
    /// An HTTP 200 cursor held until the controller durably ingests its evidence.
    var cursorToCommitAfterIngest: NewsEventFeedCursor? = nil
}

enum NewsEventInterestScope: String, Codable, CaseIterable, Sendable {
    case topic, entity, region, source
}

struct NewsEventInterestRule: Codable, Equatable, Sendable {
    var scope: NewsEventInterestScope
    var value: String

    init(scope: NewsEventInterestScope, value: String) {
        self.scope = scope
        self.value = value
    }
}

struct NewsEventInterestSettings: Codable, Equatable, Sendable {
    var keywords: [String]
    var aliases: [String: [String]]
    var includes: [String]
    var excludes: [String]
    var hardBlocks: [String]
    var learningEnabled: Bool
    /// Category-aware rules are additive so pre-scope snapshots remain readable.
    var scopedIncludes: [NewsEventInterestRule]
    var scopedExcludes: [NewsEventInterestRule]

    init(
        keywords: [String] = [],
        aliases: [String: [String]] = [:],
        includes: [String] = [],
        excludes: [String] = [],
        hardBlocks: [String] = [],
        learningEnabled: Bool = false,
        scopedIncludes: [NewsEventInterestRule] = [],
        scopedExcludes: [NewsEventInterestRule] = []
    ) {
        self.keywords = keywords
        self.aliases = aliases
        self.includes = includes
        self.excludes = excludes
        self.hardBlocks = hardBlocks
        self.learningEnabled = learningEnabled
        self.scopedIncludes = scopedIncludes
        self.scopedExcludes = scopedExcludes
    }

    enum CodingKeys: String, CodingKey {
        case keywords, aliases, includes, excludes, hardBlocks, learningEnabled, scopedIncludes, scopedExcludes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        aliases = try container.decodeIfPresent([String: [String]].self, forKey: .aliases) ?? [:]
        includes = try container.decodeIfPresent([String].self, forKey: .includes) ?? []
        excludes = try container.decodeIfPresent([String].self, forKey: .excludes) ?? []
        hardBlocks = try container.decodeIfPresent([String].self, forKey: .hardBlocks) ?? []
        learningEnabled = try container.decodeIfPresent(Bool.self, forKey: .learningEnabled) ?? false
        scopedIncludes = try container.decodeIfPresent([NewsEventInterestRule].self, forKey: .scopedIncludes) ?? []
        scopedExcludes = try container.decodeIfPresent([NewsEventInterestRule].self, forKey: .scopedExcludes) ?? []
    }
}

struct NewsEventAlert: Codable, Equatable, Sendable {
    let eventID: String
    let notificationID: String
    let title: String
    let body: String
    let change: NewsEventChangeKind
    var semanticFingerprint: String? = nil
}

enum NewsEventNotificationDecision: Equatable, Sendable {
    case notify(NewsEventAlert), suppress(reason: String)
}

protocol NewsEventNotificationPolicing: Sendable {
    func eligibility(for event: NewsEvent) -> NewsEventNotificationEligibility
    func decide(event: NewsEvent, change: NewsEventChangeKind) -> NewsEventNotificationDecision
    func explanation(for event: NewsEvent, now: Date) -> String?
}

protocol NewsEventSummaryBuilding: Sendable {
    func make(event: NewsEvent) -> String
}

protocol NewsEventInputAdapting: Sendable {
    func from(items: [NewsItem], kind: NewsEventInputKind, now: Date) -> [NewsEventEvidence]
    func fromResearchRecord(_ record: ResearchRecord, now: Date) -> [NewsEventEvidence]
}

struct NewsEventPruneResult: Codable, Equatable, Sendable {
    var deletedEventIDs: [String]
    var capacityLimited: Bool
    var capacityPressureDeletedCount: Int = 0
    var deletedCandidateCount: Int = 0
    var protectedEventCount: Int = 0
}

protocol NewsEventPersisting: Sendable {
    func events() async throws -> [NewsEvent]
    func event(id: String) async throws -> NewsEvent?
    func upsert(_ event: NewsEvent) async throws
    func claimNotification(eventID: String, key: String, at: Date) async throws -> Bool
    func feedCursor(for sourceID: String) async throws -> NewsEventFeedCursor?
    func saveFeedCursor(_ cursor: NewsEventFeedCursor) async throws
    func trackingAttempts(since: Date) async throws -> [Date]
    func recordTrackingAttempt(at: Date) async throws
    func trackingState() async throws -> NewsEventTrackingState
    func saveTrackingState(_ state: NewsEventTrackingState) async throws
    func budgetSnapshot() async throws -> NewsEventBudgetSnapshot
    func saveBudgetSnapshot(_ snapshot: NewsEventBudgetSnapshot) async throws
    func prune(now: Date, maximumEvents: Int, terminalRetention: TimeInterval) async throws -> NewsEventPruneResult
}

@MainActor
protocol NewsEventControlling: AnyObject {
    var events: [NewsEvent] { get }
    var state: NewsEventControllerState { get }
    var trackingState: NewsEventTrackingState { get }
    var budgetSnapshot: NewsEventBudgetSnapshot { get }
    func reload(now: Date) async
    @discardableResult func ingest(_ evidence: [NewsEventEvidence], now: Date) async -> Bool
    func event(id: String) -> NewsEvent?
    func recoverAndTick(now: Date, sources: [NewsSource]) async
}
