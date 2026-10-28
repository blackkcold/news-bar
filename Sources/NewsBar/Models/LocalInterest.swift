import CryptoKit
import Foundation

enum ContentIdentity {
    static let version = 1

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalURL(_ raw: String) -> String {
        guard var c = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return raw }
        c.fragment = nil
        c.host = c.host?.lowercased()
        c.scheme = c.scheme?.lowercased()
        // Preserve percent encoding and business-parameter order exactly.
        let tracking: Set<String> = ["fbclid", "gclid", "dclid", "mc_cid", "mc_eid"]
        if let query = c.percentEncodedQuery {
            let parts = query.split(separator: "&", omittingEmptySubsequences: false).filter { part in
                let name = String(part.split(separator: "=", maxSplits: 1).first ?? "").removingPercentEncoding?.lowercased() ?? ""
                return !name.hasPrefix("utm_") && !tracking.contains(name)
            }
            c.percentEncodedQuery = parts.isEmpty ? nil : parts.joined(separator: "&")
        }
        return c.string ?? raw
    }

    static func id(for url: String) -> String { digest("url-v1\n" + canonicalURL(url)) }

    static func cluster(for item: NewsItem) -> String {
        // Exact title relationships only; no fuzzy semantic merging of different events.
        digest("cluster-v1\n" + item.title.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct ContentRecord: Codable, Sendable {
    var item: NewsItem
    let firstSeen: Date
    var lastSeen: Date
    var aliases: Set<String>
    var clusterID: String
}

enum InterestEventKind: String, Codable, Sendable {
    case impression, opened, browsed, qualifiedRead, deepRead, externalHandoff, failed, blocked
    var strength: Double {
        switch self {
        case .opened: return 0.15
        case .browsed: return 0.25
        case .qualifiedRead: return 1
        case .deepRead: return 1.5
        default: return 0
        }
    }
}

struct InterestEvent: Codable, Identifiable, Sendable {
    var id = UUID()
    let occurredAt: Date
    let epoch: UUID
    let item: NewsItem
    let contentID: String
    let kind: InterestEventKind
    let sessionID: UUID
    /// Event document schema, not a ranking-policy version.
    var schemaVersion = 1
    // Optional attribution added after schema v1. V1 payloads decode with nil
    // values; no device identifier, telemetry upload or exact-pixel claim.
    var surface: String?
    var contextID: String?
    /// 0-based position in the original recommendation batch.
    var position: Int?
    var readerSessionID: UUID?
    /// Actual ranking policy that produced the batch, e.g. "ranking-v2".
    var policyVersion: String?
    var profileVersion: Int?
}

struct ProfileSignal: Codable, Sendable {
    let item: NewsItem
    let occurredAt: Date
    let strength: Double
}

enum ReadingTerminalState: String, Codable, Sendable {
    case engaged, handoff, error, blocked, unknown
}

struct ReadingSessionRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let epoch: UUID
    let newsItemID: String
    let contentID: String
    let surface: String
    let contextID: String?
    let endedAt: Date
    let activeSeconds: Double
    let scrollCoverage: Double
    let articleAdapted: Bool
    let terminalState: ReadingTerminalState
}

enum InterestFeedbackKind: String, Codable, Sendable {
    case bookmark, moreLikeThis, notInterested, muteSource, reduceTopic, followTopic, hideEvent
}

struct InterestFeedback: Codable, Identifiable, Sendable {
    var id = UUID()
    let item: NewsItem
    let kind: InterestFeedbackKind
    let occurredAt: Date
    var topic: String?
    var participatesInProfile = true

    /// Real rule scope: one mute per source, one block per article/event, one
    /// reduction per topic. Repeating the same explicit action replaces the
    /// previous rule instead of stacking duplicate ranking penalties.
    var scopeKey: String {
        switch kind {
        case .muteSource:
            return "source:" + item.source.id
        case .notInterested, .bookmark:
            return "content:" + ContentIdentity.id(for: item.url)
        case .hideEvent:
            return "cluster:" + ContentIdentity.cluster(for: item)
        case .reduceTopic, .followTopic:
            return "topic:" + (topic ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        case .moreLikeThis:
            return "session-content:" + ContentIdentity.id(for: item.url)
        }
    }
}

struct PersistedResearchState: Codable, Sendable {
    var artifacts: [String: BurstResearch] = [:]
    var notifiedBursts: Set<String> = []
    var notifiedKeywords: Set<String> = []
    var lastResearchAt: Date?
    /// Start of the most recent feed-triggered research run. Persisted so a
    /// relaunch cannot bypass the one-per-hour automatic budget.
    var lastAutomaticStartedAt: Date?
    var updatedAt: Date = Date()
}

struct LocalInterestState: Codable, Sendable {
    var schemaVersion = 1
    var revision: Int = 0
    var consentEpoch = UUID()
    var learningEnabled = false
    var learningPaused = false
    /// Public metadata cache (titles/URLs observed from feeds), not behavioral
    /// evidence. It is cleared on a personal reset and can be recreated by a
    /// normal public refresh, which is not a new consent.
    var contents: [String: ContentRecord] = [:]
    var events: [InterestEvent] = []
    var profileSignals: [String: ProfileSignal] = [:]
    var readingSessions: [ReadingSessionRecord] = []
    var feedbacks: [InterestFeedback] = []
    var followedTopics: [String] = []
    var research = PersistedResearchState()
    var profileVersion: Int = 0
    var archiveStartedAt: Date?
    var archiveUpdatedAt: Date?

    mutating func ingest(_ items: [NewsItem], now: Date = Date(), usingFetchTimestamps: Bool = false) {
        for item in items {
            let observedAt = usingFetchTimestamps ? min(now, item.timestamp) : now
            archiveStartedAt = min(archiveStartedAt ?? observedAt, observedAt)
            archiveUpdatedAt = max(archiveUpdatedAt ?? observedAt, observedAt)
            let key = ContentIdentity.id(for: item.url)
            if var record = contents[key] {
                if observedAt >= record.lastSeen {
                    var updated = item
                    updated.publishedAt = item.publishedAt ?? record.item.publishedAt
                    record.item = updated
                }
                record.lastSeen = max(record.lastSeen, observedAt)
                if record.aliases.count < 32 { record.aliases.insert(item.id) }
                contents[key] = record
            } else {
                contents[key] = ContentRecord(item: item, firstSeen: observedAt, lastSeen: observedAt, aliases: [item.id], clusterID: ContentIdentity.cluster(for: item))
            }
        }
        prune(now: now)
    }

    @discardableResult
    mutating func record(
        item: NewsItem,
        kind: InterestEventKind,
        epoch: UUID,
        sessionID: UUID = UUID(),
        now: Date = Date(),
        pruneNow: Bool = true,
        surface: String? = nil,
        contextID: String? = nil,
        position: Int? = nil,
        readerSessionID: UUID? = nil,
        policyVersion: String? = nil,
        profileVersionAtEvent: Int? = nil
    ) -> Bool {
        guard learningEnabled, !learningPaused, epoch == consentEpoch else { return false }
        let key = ContentIdentity.id(for: item.url)
        // Impressions are the only high-frequency event; dedupe exactly one per
        // content and list/batch session. Every other funnel event is retained,
        // so upgrading opened → read never deletes the earlier legitimate event.
        if kind == .impression,
           events.contains(where: {
               $0.contentID == key && $0.sessionID == sessionID && $0.epoch == epoch && $0.kind == .impression
           }) { return false }
        events.append(InterestEvent(
            occurredAt: now,
            epoch: epoch,
            item: item,
            contentID: key,
            kind: kind,
            sessionID: sessionID,
            surface: surface,
            contextID: contextID,
            position: position,
            readerSessionID: readerSessionID,
            policyVersion: policyVersion,
            profileVersion: profileVersionAtEvent ?? self.profileVersion
        ))
        if kind.strength > 0 {
            // The profile keeps only the strongest same-day signal per content,
            // independently of the raw event stream above.
            let day = Calendar.current.startOfDay(for: now).timeIntervalSince1970
            let signalKey = "\(key):\(day)"
            if kind.strength > (profileSignals[signalKey]?.strength ?? 0) {
                profileSignals[signalKey] = ProfileSignal(item: item, occurredAt: now, strength: kind.strength)
                profileVersion += 1
            }
        }
        if pruneNow { prune(now: now) }
        return true
    }

    func evidence(for contentID: String) -> Double {
        events.filter { $0.contentID == contentID }.map(\.kind.strength).max() ?? 0
    }

    @discardableResult
    mutating func recordSession(_ session: ReadingSessionRecord) -> Bool {
        guard learningEnabled, !learningPaused, session.epoch == consentEpoch,
              session.activeSeconds.isFinite, session.activeSeconds >= 0,
              session.scrollCoverage.isFinite, (0...1).contains(session.scrollCoverage),
              !readingSessions.contains(where: { $0.id == session.id }) else { return false }
        readingSessions.append(session)
        prune(now: session.endedAt)
        return true
    }

    @discardableResult
    mutating func feedback(
        item: NewsItem,
        kind: InterestFeedbackKind,
        topic: String? = nil,
        now: Date = Date(),
        participatesInProfile: Bool? = nil
    ) -> UUID {
        // Keep the literal spelling: arbitrary keywords form tags such as
        // `followed:PC2545`. Deduplication below is case-insensitive instead of
        // rewriting the stored label, which would no longer match that tag.
        let trimmedTopic = topic.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        // Explicit rules are user intent, not behavioral learning. They are
        // stored even while automatic learning is off or paused, but only
        // participate in the profile when consent was active at that moment.
        let feedback = InterestFeedback(
            item: item,
            kind: kind,
            occurredAt: now,
            topic: trimmedTopic,
            participatesInProfile: participatesInProfile ?? (learningEnabled && !learningPaused)
        )
        if let existing = feedbacks.firstIndex(where: { $0.kind == kind && $0.scopeKey == feedback.scopeKey }) {
            var updated = feedback
            // Repeat actions replace the rule, but a scoped topic must keep its
            // original spelling when only case differs.
            if kind == .reduceTopic || kind == .followTopic {
                updated.topic = feedbacks[existing].topic ?? trimmedTopic
            }
            feedbacks[existing] = updated
        } else {
            feedbacks.append(feedback)
        }
        profileVersion += 1
        prune(now: now)
        return feedback.id
    }

    mutating func undoFeedback(_ id: UUID) {
        feedbacks.removeAll { $0.id == id }
        profileVersion += 1
    }

    func isBlocked(_ item: NewsItem) -> Bool {
        let contentID = ContentIdentity.id(for: item.url)
        let clusterID = ContentIdentity.cluster(for: item)
        return feedbacks.contains { feedback in
            switch feedback.kind {
            case .muteSource: return feedback.item.source.id == item.source.id
            case .notInterested: return ContentIdentity.id(for: feedback.item.url) == contentID
            case .hideEvent: return ContentIdentity.cluster(for: feedback.item) == clusterID
            default: return false
            }
        }
    }

    mutating func clearPersonalData(keepBookmarks: Bool) {
        // A personal reset is a privacy boundary: stop learning by default,
        // drop behavioral evidence and the public metadata cache, and retain
        // only explicitly requested bookmarks without granting consent to
        // rebuild a profile from them.
        consentEpoch = UUID()
        learningEnabled = false
        learningPaused = false
        events = []
        profileSignals = [:]
        readingSessions = []
        followedTopics = []
        contents = [:]
        archiveStartedAt = nil
        archiveUpdatedAt = nil
        feedbacks = keepBookmarks ? feedbacks.filter { $0.kind == .bookmark }.map {
            var retained = $0
            retained.participatesInProfile = false
            return retained
        } : []
        profileVersion += 1
        research = PersistedResearchState()
    }

    mutating func prune(now: Date = Date()) {
        events = Array(events.filter { now.timeIntervalSince($0.occurredAt) <= 30 * 86400 }.suffix(10_000))
        readingSessions = Array(readingSessions.filter { now.timeIntervalSince($0.endedAt) <= 30 * 86400 }.suffix(10_000))
        profileSignals = profileSignals.filter { now.timeIntervalSince($0.value.occurredAt) <= 180 * 86400 }
        if profileSignals.count > 20_000 {
            profileSignals = Dictionary(uniqueKeysWithValues: profileSignals.sorted { $0.value.occurredAt > $1.value.occurredAt }.prefix(20_000).map { ($0.key, $0.value) })
        }
        // Only session-scoped "more like this" expires. Long-term rules and
        // bookmarks are deduped by scope and must not be silently truncated.
        feedbacks = feedbacks.filter { $0.kind != .moreLikeThis || now.timeIntervalSince($0.occurredAt) < 2 * 3600 }
        let bookmarked = Set(feedbacks.filter { $0.kind == .bookmark }.map { ContentIdentity.id(for: $0.item.url) })
        contents = contents.filter { bookmarked.contains($0.key) || now.timeIntervalSince($0.value.lastSeen) <= 7 * 86400 }
        if contents.count > 5_000 {
            let keep = Set(contents.sorted { $0.value.lastSeen > $1.value.lastSeen }.prefix(5_000).map(\.key)).union(bookmarked)
            contents = contents.filter { keep.contains($0.key) }
        }
        // Research history now belongs to ResearchStore. Never age-prune the
        // legacy BLOB copy here: migrated records would lose their source data
        // before the research center takes over in P1.
    }
}
