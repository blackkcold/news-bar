import Foundation

protocol NewsEventTrackingBudgeting: Sendable {
    func acquire(now: Date) async throws -> Bool
    func release() async
}

actor NewsEventTrackingBudget: NewsEventTrackingBudgeting {
    private let store: any NewsEventPersisting
    private let limit = NewsEventScheduler.defaults.maxRSSChecksPerRollingHour
    private var requestInFlight = false

    init(store: any NewsEventPersisting) {
        self.store = store
    }

    func acquire(now: Date) async throws -> Bool {
        guard !requestInFlight else { return false }
        // Claim the single-flight slot before awaiting the store; actor methods
        // are re-entrant across await and otherwise two callers could pass.
        requestInFlight = true
        do {
            let attempts = try await attemptsInWindow(now: now)
            guard attempts.count < limit else {
                requestInFlight = false
                return false
            }
            // Attempts (including failures and 304 responses) count before the
            // request starts, so a crash cannot refund a network check.
            try await store.recordTrackingAttempt(at: now)
            return true
        } catch {
            requestInFlight = false
            throw error
        }
    }

    func release() async {
        requestInFlight = false
    }

    func snapshot(now: Date) async throws -> NewsEventBudgetSnapshot {
        let attempts = try await attemptsInWindow(now: now)
        let oldestReset = attempts.first.map { $0.addingTimeInterval(3_600) }
        if requestInFlight {
            return NewsEventBudgetSnapshot(
                availability: .paused,
                reason: "已有一个事件 RSS 条件检查正在进行。",
                checksUsed: attempts.count,
                checksLimit: limit,
                resetsAt: oldestReset
            )
        }
        if attempts.count >= limit {
            return NewsEventBudgetSnapshot(
                availability: .paused,
                reason: "滚动 60 分钟事件 RSS 检查预算已用完。",
                checksUsed: attempts.count,
                checksLimit: limit,
                resetsAt: oldestReset
            )
        }
        return NewsEventBudgetSnapshot(
            availability: .available,
            reason: nil,
            checksUsed: attempts.count,
            checksLimit: limit,
            resetsAt: nil
        )
    }

    private func attemptsInWindow(now: Date) async throws -> [Date] {
        let start = now.addingTimeInterval(-3_600)
        return try await store.trackingAttempts(since: start)
            .filter { $0 <= now }
            .sorted()
    }
}
