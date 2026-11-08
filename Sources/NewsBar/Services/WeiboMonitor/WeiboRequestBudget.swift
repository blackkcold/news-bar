import Foundation

enum WeiboBudgetOutcome: Equatable, Sendable {
    case allowed
    case deferred(until: Date)

    var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

/// Global request budget: a token bucket for smoothness, a hard one-minute
/// window for safety, and a short warm-up window for cold starts. All request
/// paths share one instance; the service is serial, so acquiring a token is
/// also permission to issue the request.
struct WeiboRequestBudget: Sendable {
    var capacity: Double
    var refillPerMinute: Double
    var hardWindowLimit: Int
    var warmupLimit: Int

    private var tokens: Double
    private var lastRefill: Date
    private var requestTimes: [Date]
    private var warmupStart: Date?
    private var warmupCount: Int

    init(
        capacity: Double = 6,
        refillPerMinute: Double = 10,
        hardWindowLimit: Int = 15,
        warmupLimit: Int = 3,
        now: Date = Date()
    ) {
        self.capacity = capacity
        self.refillPerMinute = refillPerMinute
        self.hardWindowLimit = hardWindowLimit
        self.warmupLimit = warmupLimit
        self.tokens = capacity
        self.lastRefill = now
        self.requestTimes = []
        self.warmupStart = nil
        self.warmupCount = 0
    }

    mutating func startWarmup(now: Date) {
        warmupStart = now
        warmupCount = 0
    }

    mutating func acquire(now: Date, priority: WeiboMonitorPriority) -> WeiboBudgetOutcome {
        refill(now: now)
        prune(now: now)

        if let warmupStart,
           now.timeIntervalSince(warmupStart) < 60,
           warmupCount >= warmupLimit {
            return .deferred(until: warmupStart.addingTimeInterval(60))
        }

        guard tokens >= 1, requestTimes.count < hardWindowLimit else {
            let retry: Date
            if tokens < 1 {
                let seconds = (1 - tokens) / max(refillPerMinute / 60, 0.0001)
                retry = now.addingTimeInterval(seconds)
            } else if let first = requestTimes.first {
                retry = first.addingTimeInterval(60)
            } else {
                retry = now.addingTimeInterval(6)
            }

            // P0 may wait up to five minutes; P1/P2 are pushed into a
            // 30–60 second window so they never starve P0.
            let bounded: Date
            if priority == .p0 {
                bounded = min(retry, now.addingTimeInterval(300))
            } else {
                let lower = now.addingTimeInterval(30)
                let upper = now.addingTimeInterval(60)
                bounded = min(max(retry, lower), upper)
            }
            return .deferred(until: bounded)
        }

        tokens -= 1
        requestTimes.append(now)
        if let warmupStart, now.timeIntervalSince(warmupStart) < 60 {
            warmupCount += 1
        }
        return .allowed
    }

    /// Test/UI visibility. The bucket itself never exposes request details.
    var availableTokens: Double { tokens }
    var requestsInWindow: Int { requestTimes.count }

    private mutating func refill(now: Date) {
        let elapsed = max(0, now.timeIntervalSince(lastRefill))
        guard elapsed > 0 else { return }
        tokens = min(capacity, tokens + elapsed * refillPerMinute / 60)
        lastRefill = now
    }

    private mutating func prune(now: Date) {
        requestTimes.removeAll { now.timeIntervalSince($0) >= 60 }
    }
}

/// Three different accounts hitting a rate-limit signal inside ten minutes
/// means the problem is global, not one blogger. The breaker pauses everyone,
/// then allows one probe. A failed probe doubles the next pause.
struct WeiboCircuitBreaker: Sendable {
    private var openUntil: Date?
    private var lastOpenDuration: TimeInterval
    private var hits: [(date: Date, uid: String)]

    init() {
        self.openUntil = nil
        self.lastOpenDuration = 0
        self.hits = []
    }

    func canRequest(now: Date) -> Bool {
        guard let openUntil else { return true }
        return now >= openUntil
    }

    func isOpen(now: Date) -> Bool {
        guard let openUntil else { return false }
        return openUntil > now
    }

    /// The cooldown has elapsed but no probe has run yet. The service uses this
    /// to allow exactly one request before re-opening the circuit on failure.
    var isAwaitingProbe: Bool { openUntil != nil }

    mutating func reset() {
        openUntil = nil
        lastOpenDuration = 0
        hits.removeAll()
    }

    /// Returns true when this signal opened the circuit.
    mutating func noteRateLimit(
        uid: String,
        now: Date,
        openDuration: TimeInterval
    ) -> Bool {
        hits.append((now, uid))
        hits.removeAll { now.timeIntervalSince($0.date) >= 10 * 60 }
        let distinct = Set(hits.map(\.uid))
        guard distinct.count >= 3 else { return false }
        let duration = max(60, openDuration)
        lastOpenDuration = duration
        openUntil = now.addingTimeInterval(duration)
        return true
    }

    mutating func noteSuccess(now: Date) {
        openUntil = nil
        lastOpenDuration = 0
        hits.removeAll()
    }

    mutating func noteFailure(now: Date) {
        guard openUntil != nil else { return }
        let next = max(60, max(lastOpenDuration, 30 * 60) * 2)
        lastOpenDuration = next
        openUntil = now.addingTimeInterval(next)
    }

    var openUntilDate: Date? { openUntil }
}
