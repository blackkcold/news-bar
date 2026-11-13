import Foundation

enum NewsEventStoreError: LocalizedError, Equatable {
    case corruptSnapshot(String)
    case unsupportedVersion(Int)
    case capacityLimited
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .corruptSnapshot(let detail): return "事件存储文件损坏，原文件已保留：\(detail)"
        case .unsupportedVersion(let version): return "事件存储版本 \(version) 不受当前版本支持；原文件已保留。"
        case .capacityLimited: return "事件存储已达 500 项上限，未淘汰活跃、已通知或带去重键事件。"
        case .persistenceFailed(let detail): return "事件存储写入失败：\(detail)"
        }
    }
}

actor NewsEventStore: NewsEventPersisting {
    static let shared = NewsEventStore()
    static let currentVersion = 1
    static let maximumEvents = 500

    private struct Snapshot: Codable, Sendable {
        var version: Int
        var events: [String: NewsEvent]
        var feedCursors: [String: NewsEventFeedCursor]
        var trackingAttempts: [Date]
        var trackingState: NewsEventTrackingState
        var budgetSnapshot: NewsEventBudgetSnapshot
        var updatedAt: Date

        init(
            version: Int,
            events: [String: NewsEvent],
            feedCursors: [String: NewsEventFeedCursor],
            trackingAttempts: [Date],
            trackingState: NewsEventTrackingState,
            budgetSnapshot: NewsEventBudgetSnapshot,
            updatedAt: Date
        ) {
            self.version = version
            self.events = events
            self.feedCursors = feedCursors
            self.trackingAttempts = trackingAttempts
            self.trackingState = trackingState
            self.budgetSnapshot = budgetSnapshot
            self.updatedAt = updatedAt
        }

        static func empty(now: Date = .distantPast) -> Snapshot {
            Snapshot(
                version: NewsEventStore.currentVersion,
                events: [:],
                feedCursors: [:],
                trackingAttempts: [],
                trackingState: .idle,
                budgetSnapshot: NewsEventBudgetSnapshot(),
                updatedAt: now
            )
        }

        enum CodingKeys: String, CodingKey {
            case version, events, feedCursors, trackingAttempts, trackingState, budgetSnapshot, updatedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            events = try container.decodeIfPresent([String: NewsEvent].self, forKey: .events) ?? [:]
            feedCursors = try container.decodeIfPresent([String: NewsEventFeedCursor].self, forKey: .feedCursors) ?? [:]
            trackingAttempts = try container.decodeIfPresent([Date].self, forKey: .trackingAttempts) ?? []
            trackingState = try container.decodeIfPresent(NewsEventTrackingState.self, forKey: .trackingState) ?? .idle
            budgetSnapshot = try container.decodeIfPresent(NewsEventBudgetSnapshot.self, forKey: .budgetSnapshot) ?? NewsEventBudgetSnapshot()
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(events, forKey: .events)
            try container.encode(feedCursors, forKey: .feedCursors)
            try container.encode(trackingAttempts, forKey: .trackingAttempts)
            try container.encode(trackingState, forKey: .trackingState)
            try container.encode(budgetSnapshot, forKey: .budgetSnapshot)
            try container.encode(updatedAt, forKey: .updatedAt)
        }
    }

    private let fileURL: URL
    private var cachedSnapshot: Snapshot?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory: URL
            if TestIsolation.isActive {
                directory = TestIsolation.directory("NewsEvents")
            } else {
                directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("com.newsbar.app/NewsEvents", isDirectory: true)
            }
            self.fileURL = directory.appendingPathComponent("news-events-v1.json")
        }
    }

    func events() async throws -> [NewsEvent] {
        try loadSnapshot().events.values.sorted(by: Self.eventOrder)
    }

    func event(id: String) async throws -> NewsEvent? {
        try loadSnapshot().events[id]
    }

    func upsert(_ event: NewsEvent) async throws {
        var snapshot = try loadSnapshot()
        guard snapshot.events[event.id] != nil || snapshot.events.count < Self.maximumEvents else {
            throw NewsEventStoreError.capacityLimited
        }
        snapshot.events[event.id] = event
        try commit(snapshot)
    }

    /// The de-duplication key is committed before a notification is handed to UserNotifications.
    /// `lastNotifiedAt` is intentionally set only after the system accepts the request.
    func claimNotification(eventID: String, key: String, at: Date) async throws -> Bool {
        var snapshot = try loadSnapshot()
        guard var event = snapshot.events[eventID] else { return false }
        guard !event.notificationKeys.contains(key) else { return false }
        event.notificationKeys.insert(key)
        event.notificationMessage = "通知去重键已持久化，系统投递结果待确认。"
        snapshot.events[eventID] = event
        snapshot.updatedAt = at
        try commit(snapshot)
        return true
    }

    func feedCursor(for sourceID: String) async throws -> NewsEventFeedCursor? {
        try loadSnapshot().feedCursors[sourceID]
    }

    func saveFeedCursor(_ cursor: NewsEventFeedCursor) async throws {
        var snapshot = try loadSnapshot()
        if let existing = snapshot.feedCursors[cursor.sourceID] {
            let incomingCheck = cursor.checkedAt ?? .distantPast
            let existingCheck = existing.checkedAt ?? .distantPast
            let incomingAttempt = cursor.attemptedAt ?? .distantPast
            let existingAttempt = existing.attemptedAt ?? .distantPast
            let incomingCheckIsNewer = cursor.checkedAt != nil
                && (existing.checkedAt == nil || incomingCheck > existingCheck)
            let incomingAttemptIsNewer = cursor.attemptedAt != nil
                && (existing.attemptedAt == nil || incomingAttempt > existingAttempt)
            snapshot.feedCursors[cursor.sourceID] = NewsEventFeedCursor(
                sourceID: cursor.sourceID,
                eTag: incomingCheckIsNewer ? (cursor.eTag ?? existing.eTag) : existing.eTag,
                lastModified: incomingCheckIsNewer ? (cursor.lastModified ?? existing.lastModified) : existing.lastModified,
                checkedAt: Self.latest(cursor.checkedAt, existing.checkedAt),
                attemptedAt: Self.latest(cursor.attemptedAt, existing.attemptedAt),
                retryAfter: incomingAttemptIsNewer ? cursor.retryAfter : existing.retryAfter,
                failureCount: incomingAttemptIsNewer ? cursor.failureCount : existing.failureCount,
                lastError: incomingAttemptIsNewer ? cursor.lastError : existing.lastError
            )
        } else {
            snapshot.feedCursors[cursor.sourceID] = cursor
        }
        try commit(snapshot)
    }

    func trackingAttempts(since: Date) async throws -> [Date] {
        try loadSnapshot().trackingAttempts.filter { $0 >= since }.sorted()
    }

    func recordTrackingAttempt(at date: Date) async throws {
        var snapshot = try loadSnapshot()
        snapshot.trackingAttempts.append(date)
        snapshot.trackingAttempts.sort()
        if snapshot.trackingAttempts.count > 2_000 {
            snapshot.trackingAttempts.removeFirst(snapshot.trackingAttempts.count - 2_000)
        }
        snapshot.updatedAt = date
        try commit(snapshot)
    }

    func trackingState() async throws -> NewsEventTrackingState {
        try loadSnapshot().trackingState
    }

    func saveTrackingState(_ state: NewsEventTrackingState) async throws {
        var snapshot = try loadSnapshot()
        snapshot.trackingState = state
        try commit(snapshot)
    }

    func budgetSnapshot() async throws -> NewsEventBudgetSnapshot {
        try loadSnapshot().budgetSnapshot
    }

    func saveBudgetSnapshot(_ snapshotValue: NewsEventBudgetSnapshot) async throws {
        var snapshot = try loadSnapshot()
        snapshot.budgetSnapshot = snapshotValue
        try commit(snapshot)
    }

    func prune(
        now: Date,
        maximumEvents: Int,
        terminalRetention: TimeInterval
    ) async throws -> NewsEventPruneResult {
        var snapshot = try loadSnapshot()
        let limit = max(1, min(Self.maximumEvents, maximumEvents))
        let eligible = snapshot.events.values.filter { event in
            event.lifecycle == .expired
                && event.lastNotifiedAt == nil
                && event.notificationKeys.isEmpty
        }
        let retentionReady = eligible.filter { event in
            let terminalAt = event.expiresAt ?? event.lastEvidenceAt
            return now.timeIntervalSince(terminalAt) >= max(0, terminalRetention)
        }
        var removedIDs = Set(retentionReady.map(\.id))
        for id in removedIDs { snapshot.events.removeValue(forKey: id) }

        var pressureDeletedCount = 0
        var candidateDeletedCount = retentionReady.filter { $0.countablePublisherCount < 3 }.count
        if snapshot.events.count >= limit {
            let remainingExpired = eligible
                .filter { !removedIDs.contains($0.id) }
                .sorted {
                    let lhsCandidate = $0.provisionalCandidateExpiredAt != nil || $0.countablePublisherCount < 3
                    let rhsCandidate = $1.provisionalCandidateExpiredAt != nil || $1.countablePublisherCount < 3
                    if lhsCandidate != rhsCandidate { return lhsCandidate }
                    let lhsDate = $0.expiresAt ?? $0.lastEvidenceAt
                    let rhsDate = $1.expiresAt ?? $1.lastEvidenceAt
                    if lhsDate != rhsDate { return lhsDate < rhsDate }
                    return $0.id < $1.id
                }
            for event in remainingExpired {
                guard snapshot.events.count >= limit else { break }
                snapshot.events.removeValue(forKey: event.id)
                removedIDs.insert(event.id)
                pressureDeletedCount += 1
                if event.provisionalCandidateExpiredAt != nil || event.countablePublisherCount < 3 {
                    candidateDeletedCount += 1
                }
            }
        }

        let protectedCount = snapshot.events.values.filter { event in
            event.lifecycle != .expired || event.lastNotifiedAt != nil || !event.notificationKeys.isEmpty
        }.count
        let result = NewsEventPruneResult(
            deletedEventIDs: removedIDs.sorted(),
            capacityLimited: snapshot.events.count >= limit,
            capacityPressureDeletedCount: pressureDeletedCount,
            deletedCandidateCount: candidateDeletedCount,
            protectedEventCount: protectedCount
        )
        if !removedIDs.isEmpty { try commit(snapshot) }
        return result
    }

    private func loadSnapshot() throws -> Snapshot {
        if let cachedSnapshot { return cachedSnapshot }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = Snapshot.empty()
            cachedSnapshot = empty
            return empty
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            guard snapshot.version == Self.currentVersion else {
                throw NewsEventStoreError.unsupportedVersion(snapshot.version)
            }
            cachedSnapshot = snapshot
            return snapshot
        } catch let error as NewsEventStoreError {
            throw error
        } catch {
            throw NewsEventStoreError.corruptSnapshot(error.localizedDescription)
        }
    }

    private func commit(_ candidate: Snapshot) throws {
        var snapshot = candidate
        snapshot.version = Self.currentVersion
        snapshot.updatedAt = Date()
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            cachedSnapshot = snapshot
        } catch {
            throw NewsEventStoreError.persistenceFailed(error.localizedDescription)
        }
    }

    private static func eventOrder(_ lhs: NewsEvent, _ rhs: NewsEvent) -> Bool {
        if lhs.interestDisposition == .hardBlocked || lhs.interestDisposition == .excluded {
            if rhs.interestDisposition != .hardBlocked && rhs.interestDisposition != .excluded { return false }
        } else if rhs.interestDisposition == .hardBlocked || rhs.interestDisposition == .excluded {
            return true
        }
        if lhs.publicImportanceScore != rhs.publicImportanceScore {
            return lhs.publicImportanceScore > rhs.publicImportanceScore
        }
        if lhs.personalInterestScore != rhs.personalInterestScore {
            return lhs.personalInterestScore > rhs.personalInterestScore
        }
        if lhs.lastEvidenceAt != rhs.lastEvidenceAt { return lhs.lastEvidenceAt > rhs.lastEvidenceAt }
        return lhs.id < rhs.id
    }

    private static func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (left?, right?): return max(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }
}
