import Foundation

/// Conservative admission for feed-triggered runs; manual actions do not use it.
enum ResearchAutoAdmission {
    static let retryCooldown: TimeInterval = 6 * 3_600
    static let queueLifetime: TimeInterval = 15 * 60
    static let attemptLimit = 3

    static func allows(_ record: ResearchRecord, now: Date) -> Bool {
        guard record.loadIssue == nil else { return false }
        switch record.status {
        case .queued:
            // lastSeenAt is refreshed on every feed pass, so it cannot establish
            // whether an orphaned, never-started record is still fresh.
            return record.run.startedAt == nil
                && now.timeIntervalSince(record.createdAt) >= 0
                && now.timeIntervalSince(record.createdAt) <= queueLifetime
        case .failed:
            guard max(record.automaticAttempts, 1) < attemptLimit else { return false }
            let dates = [record.lastAutomaticAttemptAt, record.run.startedAt, record.run.finishedAt].compactMap { $0 }
            guard let lastAttempt = dates.max() else { return false }
            return now.timeIntervalSince(lastAttempt) >= retryCooldown
        case .ready, .partial:
            return now.timeIntervalSince(record.updatedAt) >= retryCooldown
        case .running, .cancelled, .interrupted, .corrupt:
            return false
        }
    }
}
