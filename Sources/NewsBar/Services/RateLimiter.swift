import Foundation

actor RateLimiter {

    /// Timestamps of manual refreshes in the past hour (rolling window).
    private var manualTimestamps: [Date] = []

    private let warningThreshold = 3
    private let windowSeconds: TimeInterval = 3600

    init() {
        // No persistence needed — hourly rolling window resets naturally.
    }

    /// Always allow auto-refresh; interval is controlled by Timer elsewhere.
    func canAutoRefresh() -> Bool {
        return true
    }

    /// Always allow manual refresh; warning is shown if threshold exceeded.
    func canManualRefresh() -> Bool {
        return true
    }

    /// Record a manual refresh and prune timestamps older than 1 hour.
    func recordManualRefresh() {
        let now = Date()
        manualTimestamps.append(now)
        manualTimestamps = manualTimestamps.filter {
            now.timeIntervalSince($0) < windowSeconds
        }
    }

    /// Number of manual refreshes in the last hour.
    func manualRefreshCount() -> Int {
        let now = Date()
        manualTimestamps = manualTimestamps.filter {
            now.timeIntervalSince($0) < windowSeconds
        }
        return manualTimestamps.count
    }

    /// Returns a warning string if the user has manually refreshed
    /// too many times in the past hour, nil otherwise.
    func manualRefreshWarning() -> String? {
        let count = manualTimestamps.count
        guard count >= warningThreshold else { return nil }
        return "过去 1 小时内已手动刷新 \(count) 次，频繁请求可能被封"
    }
}
