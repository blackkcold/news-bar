import Foundation

/// A single concrete generator keeps the planner testable without opening an
/// existential in every signature. Production uses the system source; tests
/// pass a seed and get an identical sequence.
struct WeiboRNG: RandomNumberGenerator {
    private var state: UInt64
    private let isSeeded: Bool

    init(seed: UInt64? = nil) {
        if let seed {
            self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
            self.isSeeded = true
        } else {
            self.state = 0
            self.isSeeded = false
        }
    }

    mutating func next() -> UInt64 {
        guard isSeeded else {
            return UInt64.random(in: UInt64.min...UInt64.max)
        }
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// The only source of randomness in the monitor. Everything goes through an
/// injected generator so the 24-hour simulation and the planner tests are
/// reproducible with a fixed seed.
enum WeiboRandom {
    static func unit(_ rng: inout WeiboRNG) -> Double {
        Double(rng.next()) / Double(UInt64.max)
    }

    static func double(in range: ClosedRange<Double>, rng: inout WeiboRNG) -> Double {
        let value = unit(&rng)
        return range.lowerBound + value * (range.upperBound - range.lowerBound)
    }

    static func int(in range: ClosedRange<Int>, rng: inout WeiboRNG) -> Int {
        guard range.lowerBound < range.upperBound else { return range.lowerBound }
        let value = double(in: Double(range.lowerBound)...Double(range.upperBound), rng: &rng)
        return min(range.upperBound, max(range.lowerBound, Int(value)))
    }

    static func chance(_ probability: Double, rng: inout WeiboRNG) -> Bool {
        unit(&rng) < probability
    }
}

/// Pure scheduling arithmetic. It never sends a request, never reads a disk,
/// and never reads the wall clock: every entry point takes `now`.
struct WeiboPollPlanner: Sendable {
    var calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// First launch after the app was opened. A 30–120 second warm-up keeps a
    /// cold start from producing a burst while the user is still watching.
    func initialDue(now: Date, rng: inout WeiboRNG) -> Date {
        now.addingTimeInterval(WeiboRandom.double(in: 30...120, rng: &rng))
    }

    func nextDue(
        for user: WeiboMonitorUser,
        now: Date,
        config: WeiboMonitorConfig,
        isLowPower: Bool,
        rng: inout WeiboRNG
    ) -> Date {
        if isNight(now, config: config) {
            if user.priority == .p0 {
                let base = config.interval(for: .p0) * 5
                return now.addingTimeInterval(max(90, jittered(base, rng: &rng)))
            }
            return nextMorningStart(after: now, config: config)
        }

        var base = config.interval(for: user.priority)
        if isLowPower { base *= 2 }

        if isDormant(user, now: now) {
            switch user.priority {
            case .p0:
                base = min(base * 2, 600)
            case .p1, .p2:
                base = min(base * 4, 1800)
            }
        }

        if let hotWindowUntil = user.hotWindowUntil, hotWindowUntil > now {
            base = min(base, 90)
        }

        return now.addingTimeInterval(max(90, jittered(base, rng: &rng)))
    }

    /// A long-idle P1/P2 account occasionally skips one round. It is a small
    /// amount of noise, not a reliability mechanism.
    func shouldSkipIdleRound(
        priority: WeiboMonitorPriority,
        rng: inout WeiboRNG
    ) -> Bool {
        guard priority != .p0 else { return false }
        return WeiboRandom.chance(0.06, rng: &rng)
    }

    /// After sleep, the first three overdue accounts run immediately and the
    /// rest are spread over at most five minutes. This is the difference
    /// between a wake-up and a thundering herd.
    func spreadWakeUp(
        users: inout [WeiboMonitorUser],
        now: Date,
        config: WeiboMonitorConfig = .default,
        rng: inout WeiboRNG
    ) {
        let overdue = users.indices
            .filter { users[$0].enabled && !users[$0].isPaused(now: now) && users[$0].nextDueAt <= now }
            .sorted { users[$0].priority.rank < users[$1].priority.rank }

        for (position, index) in overdue.enumerated() {
            if isNight(now, config: config), users[index].priority != .p0 {
                // P1/P2 stay paused at night even after a wake or a network
                // recovery. Otherwise a 03:00 wake-up would poll every account.
                users[index].nextDueAt = nextMorningStart(after: now, config: config)
                continue
            }
            let delay: TimeInterval
            if position < 3 {
                delay = WeiboRandom.double(in: 0...5, rng: &rng)
            } else {
                delay = min(300, Double(position - 2) * 20)
            }
            users[index].nextDueAt = now.addingTimeInterval(delay)
        }
    }

    func isNight(_ date: Date, config: WeiboMonitorConfig) -> Bool {
        guard config.nightEnabled else { return false }
        let start = normalizedMinute(config.nightStartMinute)
        let end = normalizedMinute(config.nightEndMinute)
        guard start != end else { return false }
        let minute = minuteOfDay(date)
        if start < end {
            return minute >= start && minute < end
        }
        return minute >= start || minute < end
    }

    func isQuietHours(_ date: Date) -> Bool {
        // Notification quiet hours are deliberately separate from the polling
        // night window: polling slows at 00:30, but P1/P2 stop buzzing at 23:30.
        let minute = minuteOfDay(date)
        return minute >= 23 * 60 + 30 || minute < 8 * 60
    }

    func nextMorningStart(after date: Date, config: WeiboMonitorConfig) -> Date {
        let end = normalizedMinute(config.nightEndMinute)
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = end / 60
        components.minute = end % 60
        components.second = 0
        let today = calendar.date(from: components) ?? date
        if today > date { return today }
        return calendar.date(byAdding: .day, value: 1, to: today)
            ?? date.addingTimeInterval(24 * 60 * 60)
    }

    func isDormant(_ user: WeiboMonitorUser, now: Date) -> Bool {
        let reference = user.stats.lastPostAt ?? user.addedAt
        return now.timeIntervalSince(reference) >= 7 * 24 * 60 * 60
    }

    private func jittered(_ value: TimeInterval, rng: inout WeiboRNG) -> TimeInterval {
        value * WeiboRandom.double(in: 0.8...1.3, rng: &rng)
    }

    private func minuteOfDay(_ date: Date) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private func normalizedMinute(_ value: Int) -> Int {
        let day = 24 * 60
        return ((value % day) + day) % day
    }
}
