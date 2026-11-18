import Foundation
import UserNotifications

enum NotificationDeliveryState: String, Codable, Sendable {
    case queued
    case submitting
    case accepted
    case failed
    case unknown
    case read
    case suppressed
}

enum NotificationDeliveryChannel: String, Codable, Sendable {
    case summaryQueue
    case hourlySummary
    case dailySummary
    case eventAlert
    case researchAlert
    case other
}

struct NotificationDeliveryRecord: Codable, Sendable {
    let semanticID: String
    var requestID: String
    var channel: NotificationDeliveryChannel
    var kind: NotificationDigestResearchKind
    var eventID: String?
    var recordID: String?
    var versionID: String?
    var state: NotificationDeliveryState
    var attempts: Int
    var updatedAt: Date
    var lastError: String?
}

struct NotificationDeliveryReceipt: Codable, Sendable {
    let id: UUID
    let requestID: String
    let channel: NotificationDeliveryChannel
    let semanticIDs: [String]
    let eventIDs: [String]
    let recordIDs: [String]
    let acceptedAt: Date
}

struct NotificationDeliveryMetrics: Equatable, Sendable {
    var distinctEventCount: Int
    var distinctReportCount: Int
    var systemAcceptedRequestCount: Int
    var userReadCount: Int
    var summaryRequestCount: Int
}

/// Durable local intent state for research/event notifications. It stores
/// identifiers and short, already-sanitized digest text only; the atomic file
/// is owner-only and stays outside the clearable research-record directory.
actor NotificationDeliveryLedger {
    static let shared = NotificationDeliveryLedger()
    static let maximumAttempts = 2
    private static let rollingHourLimit = 2
    private static let normalDayLimit = 6
    private static let busyDayLimit = 10

    private struct EnhancedQuotaReservation: Codable {
        let eventKey: String
        let reservedAt: Date
    }

    private struct Snapshot: Codable {
        var version = 1
        var deliveries: [String: NotificationDeliveryRecord] = [:]
        var summaryItems: [String: NotificationDigestResearchItem] = [:]
        var receipts: [NotificationDeliveryReceipt] = []
        var enhancedQuotaReservations: [String: EnhancedQuotaReservation] = [:]

        enum CodingKeys: String, CodingKey {
            case version, deliveries, summaryItems, receipts, enhancedQuotaReservations
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            deliveries = try container.decodeIfPresent(
                [String: NotificationDeliveryRecord].self,
                forKey: .deliveries
            ) ?? [:]
            summaryItems = try container.decodeIfPresent(
                [String: NotificationDigestResearchItem].self,
                forKey: .summaryItems
            ) ?? [:]
            receipts = try container.decodeIfPresent(
                [NotificationDeliveryReceipt].self,
                forKey: .receipts
            ) ?? []
            enhancedQuotaReservations = try container.decodeIfPresent(
                [String: EnhancedQuotaReservation].self,
                forKey: .enhancedQuotaReservations
            ) ?? [:]
        }
    }

    private var snapshot = Snapshot()
    private var didLoad = false
    private var readOnly = false

    private var fileURL: URL {
        ResearchPaths.applicationSupportRoot
            .appendingPathComponent("Notifications", isDirectory: true)
            .appendingPathComponent("delivery-ledger-v1.json")
    }

    func enqueueSummary(_ item: NotificationDigestResearchItem) -> Bool {
        guard loadIfNeeded(), canRetry(item.id) else { return false }
        if snapshot.deliveries[item.id] == nil {
            snapshot.deliveries[item.id] = makeRecord(item, requestID: "", channel: .summaryQueue)
        } else if var record = snapshot.deliveries[item.id] {
            record.requestID = ""
            record.channel = .summaryQueue
            record.state = .queued
            record.updatedAt = Date()
            record.lastError = nil
            snapshot.deliveries[item.id] = record
        }
        snapshot.summaryItems[item.id] = item
        return persist()
    }

    func pendingSummaryItems() -> [NotificationDigestResearchItem] {
        guard loadIfNeeded() else { return [] }
        return snapshot.summaryItems.values.filter { canRetry($0.id) }.sorted {
            if priority($0) != priority($1) {
                return priority($0) < priority($1)
            }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id < $1.id
        }
    }

    func pendingSummaryCandidates(at date: Date = Date()) -> [NotificationDigestResearchItem] {
        guard loadIfNeeded() else { return [] }
        let pending = snapshot.summaryItems.values.filter { canRetry($0.id) }
        return admissionEligible(Array(pending), at: date)
    }

    /// Returns the highest-priority queued candidates that fit the independent
    /// enhanced-notification frequency budget. Excluded items remain queued.
    func summaryCandidates(
        from candidates: [NotificationDigestResearchItem],
        at date: Date = Date()
    ) -> [NotificationDigestResearchItem] {
        guard loadIfNeeded() else { return [] }
        return admissionEligible(candidates, at: date)
    }

    func beginSubmission(
        _ items: [NotificationDigestResearchItem],
        requestID: String,
        at date: Date = Date()
    ) -> Bool {
        guard loadIfNeeded() else { return false }
        guard !items.isEmpty else { return true }
        // Validate the entire batch before mutating any row. A partially
        // prepared batch must never leave in-memory `submitting` rows when the
        // durable write is rejected.
        guard items.allSatisfy({ canRetry($0.id) }) else { return false }
        trimQuotaReservations(at: date)
        guard canReserve(items, at: date) else { return false }
        var records = snapshot.deliveries
        for item in items {
            var record = records[item.id] ?? makeRecord(item, requestID: requestID)
            record.requestID = requestID
            record.channel = Self.channel(for: requestID)
            record.state = .submitting
            record.attempts += 1
            record.updatedAt = Date()
            record.lastError = nil
            records[item.id] = record
            snapshot.enhancedQuotaReservations[item.id] = EnhancedQuotaReservation(
                eventKey: Self.quotaEventKey(for: item),
                reservedAt: date
            )
        }
        snapshot.deliveries = records
        return persist()
    }

    func markAccepted(_ items: [NotificationDigestResearchItem], requestID: String) {
        guard loadIfNeeded() else { return }
        for item in items {
            var record = snapshot.deliveries[item.id] ?? makeRecord(item, requestID: requestID)
            record.requestID = requestID
            record.channel = Self.channel(for: requestID)
            record.state = .accepted
            record.updatedAt = Date()
            record.lastError = nil
            snapshot.deliveries[item.id] = record
            snapshot.summaryItems[item.id] = nil
            if snapshot.enhancedQuotaReservations[item.id] == nil {
                snapshot.enhancedQuotaReservations[item.id] = EnhancedQuotaReservation(
                    eventKey: Self.quotaEventKey(for: item),
                    reservedAt: Date()
                )
            }
        }
        snapshot.receipts.append(NotificationDeliveryReceipt(
            id: UUID(),
            requestID: requestID,
            channel: Self.channel(for: requestID),
            semanticIDs: items.map(\.id),
            eventIDs: Array(Set(items.compactMap(\.eventID))).sorted(),
            recordIDs: Array(Set(items.compactMap(\.recordID))).sorted(),
            acceptedAt: Date()
        ))
        if snapshot.receipts.count > 500 {
            snapshot.receipts.removeFirst(snapshot.receipts.count - 500)
        }
        _ = persist()
    }

    func markFailed(_ items: [NotificationDigestResearchItem], requestID: String, error: String) {
        guard loadIfNeeded() else { return }
        for item in items {
            var record = snapshot.deliveries[item.id] ?? makeRecord(item, requestID: requestID)
            record.requestID = requestID
            record.channel = Self.channel(for: requestID)
            record.state = .failed
            record.updatedAt = Date()
            record.lastError = SecurityPolicies.sanitizeHTMLContent(error).prefix(180).description
            snapshot.deliveries[item.id] = record
            snapshot.enhancedQuotaReservations[item.id] = nil
        }
        _ = persist()
    }

    func markSuppressed(_ item: NotificationDigestResearchItem) {
        guard loadIfNeeded() else { return }
        var record = snapshot.deliveries[item.id] ?? makeRecord(item, requestID: "")
        record.state = .suppressed
        record.updatedAt = Date()
        snapshot.deliveries[item.id] = record
        snapshot.summaryItems[item.id] = nil
        _ = persist()
    }

    func markSuppressed(semanticID: String) {
        guard loadIfNeeded(), var record = snapshot.deliveries[semanticID] else { return }
        record.state = .suppressed
        record.updatedAt = Date()
        snapshot.deliveries[semanticID] = record
        snapshot.summaryItems[semanticID] = nil
        _ = persist()
    }

    func markRead(semanticID: String) {
        guard loadIfNeeded(), var record = snapshot.deliveries[semanticID] else { return }
        record.state = .read
        record.updatedAt = Date()
        snapshot.deliveries[semanticID] = record
        _ = persist()
    }

    func metrics(since date: Date = .distantPast) -> NotificationDeliveryMetrics {
        guard loadIfNeeded() else {
            return NotificationDeliveryMetrics(
                distinctEventCount: 0,
                distinctReportCount: 0,
                systemAcceptedRequestCount: 0,
                userReadCount: 0,
                summaryRequestCount: 0
            )
        }
        let acceptedIDs = Set(snapshot.receipts
            .filter { $0.acceptedAt >= date }
            .flatMap(\.semanticIDs))
        let acceptedRecords = acceptedIDs.compactMap { snapshot.deliveries[$0] }
        let acceptedEvents = Set(acceptedRecords.compactMap(\.eventID))
        let acceptedReports = Set(acceptedRecords.compactMap(\.recordID))
        let readCount = snapshot.deliveries.values.filter {
            $0.state == .read && $0.updatedAt >= date
        }.count
        let receipts = snapshot.receipts.filter { $0.acceptedAt >= date }
        return NotificationDeliveryMetrics(
            distinctEventCount: acceptedEvents.count,
            distinctReportCount: acceptedReports.count,
            systemAcceptedRequestCount: receipts.count,
            userReadCount: readCount,
            summaryRequestCount: receipts.filter {
                $0.channel == .hourlySummary || $0.channel == .dailySummary
            }.count
        )
    }

    func wasAccepted(semanticID: String) -> Bool {
        guard loadIfNeeded() else { return false }
        return snapshot.receipts.contains { $0.semanticIDs.contains(semanticID) }
    }

    /// Reconciles crash-interrupted `submitting` intents with the system's own
    /// request lists. An absent request is unknown and is never retried blindly.
    func recoverSystemState() async {
        guard loadIfNeeded() else { return }
        let center = UNUserNotificationCenter.current()
        let pending = await Self.pendingRequests(center)
        let delivered = await Self.deliveredNotifications(center)
        var pendingItemIDs = Set<String>()
        for request in pending {
            if let semanticID = request.content.userInfo["semanticID"] as? String {
                pendingItemIDs.insert(semanticID)
            }
            if let digest = NotificationDigest.decode(
                request.content.userInfo["digest"] as? String
            ) {
                pendingItemIDs.formUnion(digest.researchItems.map(\.id))
            }
        }
        let pendingIDs = Set(pending.map(\.identifier))
        var deliveredItems = Set<String>()
        for notification in delivered {
            if let semanticID = notification.request.content.userInfo["semanticID"] as? String {
                deliveredItems.insert(semanticID)
            }
            if let digest = NotificationDigest.decode(
                notification.request.content.userInfo["digest"] as? String
            ) {
                deliveredItems.formUnion(digest.researchItems.map(\.id))
            }
        }

        var recoveredByRequest: [String: [String]] = [:]
        for key in Array(snapshot.deliveries.keys) {
            guard var record = snapshot.deliveries[key], record.state == .submitting else { continue }
            let directRequestPending = pendingIDs.contains(record.requestID)
                && record.requestID != NotificationIdentifier.dailyRequest
                && record.requestID != NotificationIdentifier.hourlyRequest
            if pendingItemIDs.contains(key) || deliveredItems.contains(key) || directRequestPending {
                record.state = .accepted
                record.lastError = nil
                snapshot.summaryItems[key] = nil
                recoveredByRequest[record.requestID, default: []].append(key)
            } else {
                record.state = .unknown
                record.lastError = "System request was not found after restart."
                snapshot.summaryItems[key] = nil
            }
            record.updatedAt = Date()
            snapshot.deliveries[key] = record
        }
        for (requestID, semanticIDs) in recoveredByRequest {
            let records = semanticIDs.compactMap { snapshot.deliveries[$0] }
            snapshot.receipts.append(NotificationDeliveryReceipt(
                id: UUID(),
                requestID: requestID,
                channel: Self.channel(for: requestID),
                semanticIDs: semanticIDs.sorted(),
                eventIDs: Array(Set(records.compactMap(\.eventID))).sorted(),
                recordIDs: Array(Set(records.compactMap(\.recordID))).sorted(),
                acceptedAt: Date()
            ))
        }
        if snapshot.receipts.count > 500 {
            snapshot.receipts.removeFirst(snapshot.receipts.count - 500)
        }
        _ = persist()
    }

    func markUnknown(semanticIDs: [String], requestID: String, reason: String) {
        guard loadIfNeeded() else { return }
        for semanticID in semanticIDs {
            guard var record = snapshot.deliveries[semanticID] else { continue }
            record.requestID = requestID
            record.channel = Self.channel(for: requestID)
            record.state = .unknown
            record.updatedAt = Date()
            record.lastError = reason
            snapshot.deliveries[semanticID] = record
            snapshot.summaryItems[semanticID] = nil
        }
        _ = persist()
    }

    private func loadIfNeeded() -> Bool {
        guard !didLoad else { return !readOnly }
        didLoad = true
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Snapshot.self, from: data),
              decoded.version == 1 else {
            readOnly = true
            NSLog("[NotificationDeliveryLedger] Existing ledger could not be decoded; delivery is paused to avoid duplicates.")
            return false
        }
        snapshot = decoded
        return true
    }

    private func persist() -> Bool {
        guard !readOnly else { return false }
        do {
            let data = try JSONEncoder().encode(snapshot)
            try PrivateFile.write(data, to: fileURL, durable: true)
            return true
        } catch {
            readOnly = true
            NSLog("[NotificationDeliveryLedger] Could not persist delivery state: %@", error.localizedDescription)
            return false
        }
    }

    private func canRetry(_ semanticID: String) -> Bool {
        guard let record = snapshot.deliveries[semanticID] else { return true }
        switch record.state {
        case .accepted, .unknown, .read, .suppressed, .submitting:
            return false
        case .queued:
            return record.attempts < Self.maximumAttempts
        case .failed:
            return record.attempts < Self.maximumAttempts
        }
    }

    private func makeRecord(
        _ item: NotificationDigestResearchItem,
        requestID: String,
        channel: NotificationDeliveryChannel? = nil
    ) -> NotificationDeliveryRecord {
        NotificationDeliveryRecord(
            semanticID: item.id,
            requestID: requestID,
            channel: channel ?? Self.channel(for: requestID),
            kind: item.kind,
            eventID: item.eventID,
            recordID: item.recordID,
            versionID: item.versionID,
            state: .queued,
            attempts: 0,
            updatedAt: Date(),
            lastError: nil
        )
    }

    private static func channel(for requestID: String) -> NotificationDeliveryChannel {
        switch requestID {
        case NotificationIdentifier.hourlyRequest: return .hourlySummary
        case NotificationIdentifier.dailyRequest: return .dailySummary
        default:
            if requestID.hasPrefix("research-v2-") { return .researchAlert }
            if requestID.hasPrefix("news-event-") { return .eventAlert }
            return requestID.isEmpty ? .summaryQueue : .other
        }
    }

    private func admissionEligible(
        _ candidates: [NotificationDigestResearchItem],
        at date: Date
    ) -> [NotificationDigestResearchItem] {
        var dayEventKeys = Set(snapshot.enhancedQuotaReservations.values.compactMap { reservation in
            Calendar.current.isDate(reservation.reservedAt, inSameDayAs: date)
                ? reservation.eventKey
                : nil
        })
        var hourEventKeys = Set(snapshot.enhancedQuotaReservations.values.compactMap { reservation in
            let age = date.timeIntervalSince(reservation.reservedAt)
            return age >= 0 && age < 60 * 60 ? reservation.eventKey : nil
        })
        var consideredKeys: Set<String> = []
        var selected: [NotificationDigestResearchItem] = []

        let ordered = candidates.sorted {
            if priority($0) != priority($1) { return priority($0) < priority($1) }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id < $1.id
        }
        for item in ordered {
            let key = Self.quotaEventKey(for: item)
            guard consideredKeys.insert(key).inserted else { continue }
            guard canAdmit(
                key: key,
                urgency: Self.effectiveUrgency(for: item),
                dayEventKeys: &dayEventKeys,
                hourEventKeys: &hourEventKeys
            ) else { continue }
            selected.append(item)
        }
        return selected
    }

    private func canReserve(_ items: [NotificationDigestResearchItem], at date: Date) -> Bool {
        var dayEventKeys = Set(snapshot.enhancedQuotaReservations.values.compactMap { reservation in
            Calendar.current.isDate(reservation.reservedAt, inSameDayAs: date)
                ? reservation.eventKey
                : nil
        })
        var hourEventKeys = Set(snapshot.enhancedQuotaReservations.values.compactMap { reservation in
            let age = date.timeIntervalSince(reservation.reservedAt)
            return age >= 0 && age < 60 * 60 ? reservation.eventKey : nil
        })
        let ordered = items.sorted {
            if priority($0) != priority($1) { return priority($0) < priority($1) }
            return $0.id < $1.id
        }
        for item in ordered {
            guard canAdmit(
                key: Self.quotaEventKey(for: item),
                urgency: Self.effectiveUrgency(for: item),
                dayEventKeys: &dayEventKeys,
                hourEventKeys: &hourEventKeys
            ) else { return false }
        }
        return true
    }

    private func canAdmit(
        key: String,
        urgency: NotificationDigestUrgency,
        dayEventKeys: inout Set<String>,
        hourEventKeys: inout Set<String>
    ) -> Bool {
        if dayEventKeys.contains(key) {
            hourEventKeys.insert(key)
            return true
        }
        if urgency == .urgentCorrection {
            dayEventKeys.insert(key)
            hourEventKeys.insert(key)
            return true
        }

        let hasHourlySlot = hourEventKeys.contains(key)
            || hourEventKeys.count < Self.rollingHourLimit
        let hasDailySlot = dayEventKeys.count < Self.normalDayLimit
            || (dayEventKeys.count < Self.busyDayLimit && urgency == .major)
        guard hasHourlySlot && hasDailySlot else { return false }
        dayEventKeys.insert(key)
        hourEventKeys.insert(key)
        return true
    }

    private func trimQuotaReservations(at date: Date) {
        let cutoff = date.addingTimeInterval(-3 * 24 * 60 * 60)
        snapshot.enhancedQuotaReservations = snapshot.enhancedQuotaReservations.filter {
            $0.value.reservedAt >= cutoff
        }
        if snapshot.enhancedQuotaReservations.count > 1_000 {
            let retainedIDs = snapshot.enhancedQuotaReservations
                .sorted { $0.value.reservedAt > $1.value.reservedAt }
                .prefix(1_000)
                .map(\.key)
            let retained = Set(retainedIDs)
            snapshot.enhancedQuotaReservations = snapshot.enhancedQuotaReservations.filter {
                retained.contains($0.key)
            }
        }
    }

    private func priority(_ item: NotificationDigestResearchItem) -> Int {
        switch Self.effectiveUrgency(for: item) {
        case .urgentCorrection: 0
        case .major: 1
        case .ordinary:
            switch item.kind {
            case .correction: 0
            case .reportReady: 2
            case .eventUpdate: 3
            }
        }
    }

    private static func effectiveUrgency(for item: NotificationDigestResearchItem) -> NotificationDigestUrgency {
        if item.kind == .correction { return .urgentCorrection }
        return item.urgency ?? .ordinary
    }

    private static func quotaEventKey(for item: NotificationDigestResearchItem) -> String {
        if let eventID = item.eventID, !eventID.isEmpty { return "event:\(eventID)" }
        if let recordID = item.recordID, !recordID.isEmpty { return "record:\(recordID)" }
        return "item:\(item.id)"
    }

    private static func pendingRequests(_ center: UNUserNotificationCenter) async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { continuation.resume(returning: $0) }
        }
    }

    private static func deliveredNotifications(_ center: UNUserNotificationCenter) async -> [UNNotification] {
        await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { continuation.resume(returning: $0) }
        }
    }
}

enum ResearchNotificationPreferences {
    static let enabledKey = "researchNotificationsEnabled"
    static let detailedPreviewKey = "researchNotificationDetailedPreviewEnabled"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var detailedPreviewEnabled: Bool {
        UserDefaults.standard.bool(forKey: detailedPreviewKey)
    }
}
