import Foundation

struct NewsEventTrackingDefaults: Sendable {
    let followupOffsets: [TimeInterval] = [300, 900, 1_800, 3_600, 7_200]
    let quietInterval: TimeInterval = 21_600
    let expireAfterSilence: TimeInterval = 604_800
    let provisionalCandidateSilence: TimeInterval = 86_400
    let protectedEventSilence: TimeInterval = 2_592_000
    let terminalRetention: TimeInterval = 2_592_000
    let maximumEvents = 500
    let maxRSSChecksPerRollingHour = 12
    let maxConcurrentRequests = 1
}

enum NewsEventScheduler {
    static let defaults = NewsEventTrackingDefaults()

    static func dueAt(for event: NewsEvent) -> Date? {
        guard event.lifecycle != .expired else { return nil }
        if let nextCheckAt = event.nextCheckAt { return nextCheckAt }
        if event.followupIndex < defaults.followupOffsets.count {
            return event.firstSeenAt.addingTimeInterval(defaults.followupOffsets[max(0, event.followupIndex)])
        }
        return (event.lastCheckedAt ?? event.firstSeenAt).addingTimeInterval(defaults.quietInterval)
    }

    static func isDue(_ event: NewsEvent, at now: Date) -> Bool {
        guard let dueAt = dueAt(for: event) else { return false }
        return dueAt <= now
    }

    /// A single successful check satisfies the current due point and folds all
    /// elapsed checkpoints. Wake never creates a burst of historical requests.
    static func markChecked(_ event: inout NewsEvent, at now: Date, message: String) {
        event.lastCheckedAt = now
        let elapsed = now.timeIntervalSince(event.firstSeenAt)
        if let nextIndex = defaults.followupOffsets.firstIndex(where: { $0 > elapsed }) {
            event.followupIndex = nextIndex
            event.nextCheckAt = event.firstSeenAt.addingTimeInterval(defaults.followupOffsets[nextIndex])
        } else {
            event.followupIndex = defaults.followupOffsets.count
            event.nextCheckAt = now.addingTimeInterval(defaults.quietInterval)
        }
        event.trackingStatus = .scheduled
        event.trackingMessage = message
    }

    static func markFailed(_ event: inout NewsEvent, message: String) {
        // Keep nextCheckAt and followupIndex unchanged so a failed network
        // attempt cannot masquerade as a successful check.
        event.trackingStatus = .failed
        event.trackingMessage = message
    }

    static func markBudgetDeferred(_ event: inout NewsEvent, resetsAt: Date?) {
        event.trackingStatus = .budgetDeferred
        if let resetsAt {
            event.trackingMessage = "追踪预算已用完；due 保留，将于 \(resetsAt.formatted(date: .abbreviated, time: .shortened)) 后恢复。"
        } else {
            event.trackingMessage = "追踪预算已用完；due 保留，等待滚动窗口释放额度。"
        }
    }

    static func markNoFreshSource(_ event: inout NewsEvent) {
        event.trackingStatus = .noFreshSource
        event.trackingMessage = "没有已启用 RSS 来源；本轮未执行实时检查，不代表无更新或已核实。"
    }

    static func expireIfSilent(_ event: inout NewsEvent, at now: Date) -> Bool {
        guard event.lifecycle != .expired else { return false }
        let isProtectedEvent = event.lastNotifiedAt != nil || event.lastMajorProgressAt != nil
        let isProvisionalCandidate = !isProtectedEvent
            && event.countablePublisherCount < 3
            && event.notificationKeys.isEmpty
        let silenceLimit = isProtectedEvent
            ? defaults.protectedEventSilence
            : (isProvisionalCandidate ? defaults.provisionalCandidateSilence : defaults.expireAfterSilence)
        guard now.timeIntervalSince(event.lastEvidenceAt) >= silenceLimit else { return false }
        event.lifecycle = .expired
        event.expiresAt = event.lastEvidenceAt.addingTimeInterval(silenceLimit)
        if isProvisionalCandidate { event.provisionalCandidateExpiredAt = event.expiresAt }
        event.nextCheckAt = nil
        if isProtectedEvent {
            event.trackingMessage = "连续 30 天没有新证据，长周期追踪生命周期已结束。"
        } else if isProvisionalCandidate {
            event.trackingMessage = "未通知候选 24 小时仍不足三源且没有新证据；已结束追踪，可由新实质证据重新评估。"
        } else {
            event.trackingMessage = "连续 7 天没有新证据，追踪生命周期已结束。"
        }
        return true
    }
}
