import XCTest
@testable import NewsBar

final class WeiboPollPlannerTests: XCTestCase {
    private let calendar = WeiboMonitorTestSupport.calendar
    private var planner: WeiboPollPlanner { WeiboPollPlanner(calendar: calendar) }
    private let config = WeiboMonitorConfig(
        enabled: true,
        nightEnabled: true,
        nightStartMinute: 30,
        nightEndMinute: 450
    )

    func testSeededDueIsReproducible() {
        let now = WeiboMonitorTestSupport.date(2026, 11, 7, 12, 0)
        let user = WeiboMonitorTestSupport.user(now: now)
        var firstRNG = WeiboRNG(seed: 42)
        var secondRNG = WeiboRNG(seed: 42)

        let first = planner.nextDue(
            for: user, now: now, config: config, isLowPower: false, rng: &firstRNG
        )
        let second = planner.nextDue(
            for: user, now: now, config: config, isLowPower: false, rng: &secondRNG
        )

        XCTAssertEqual(first, second)
    }

    func testNightP0UsesFiveTimesBase() {
        let now = WeiboMonitorTestSupport.date(2026, 11, 7, 2, 0)
        let user = WeiboMonitorTestSupport.user(now: now)
        var rng = WeiboRNG(seed: 7)
        let due = planner.nextDue(
            for: user, now: now, config: config, isLowPower: false, rng: &rng
        )
        let delay = due.timeIntervalSince(now)

        XCTAssertGreaterThan(delay, 200)
        XCTAssertLessThanOrEqual(delay, 120 * 5 * 1.3 + 1)
    }

    func testNightP1DefersToMorning() {
        let now = WeiboMonitorTestSupport.date(2026, 11, 7, 2, 0)
        let user = WeiboMonitorTestSupport.user(priority: .p1, now: now)
        var rng = WeiboRNG(seed: 7)
        let due = planner.nextDue(
            for: user, now: now, config: config, isLowPower: false, rng: &rng
        )
        let components = calendar.dateComponents([.hour, .minute], from: due)

        XCTAssertEqual(components.hour, 7)
        XCTAssertEqual(components.minute, 30)
        XCTAssertEqual(calendar.startOfDay(for: due), calendar.startOfDay(for: now))
    }

    func testHotWindowCapsBaseAtNinetySeconds() {
        let now = WeiboMonitorTestSupport.date(2026, 11, 7, 12, 0)
        let user = WeiboMonitorTestSupport.user(
            priority: .p2,
            now: now,
            hotWindowUntil: now.addingTimeInterval(600)
        )
        var rng = WeiboRNG(seed: 9)
        let due = planner.nextDue(
            for: user, now: now, config: config, isLowPower: false, rng: &rng
        )
        let delay = due.timeIntervalSince(now)

        XCTAssertGreaterThanOrEqual(delay, 90)
        XCTAssertLessThanOrEqual(delay, 90 * 1.3 + 1)
    }

    func testDormantP1SlowsDownAndCaps() {
        let now = WeiboMonitorTestSupport.date(2026, 11, 7, 12, 0)
        let user = WeiboMonitorTestSupport.user(
            priority: .p1,
            now: now,
            lastPostAt: now.addingTimeInterval(-8 * 24 * 60 * 60)
        )
        var rng = WeiboRNG(seed: 11)
        let due = planner.nextDue(
            for: user, now: now, config: config, isLowPower: false, rng: &rng
        )
        let delay = due.timeIntervalSince(now)

        XCTAssertGreaterThan(delay, 900)
        XCTAssertLessThanOrEqual(delay, 1800 * 1.3 + 1)
    }

    func testLowPowerDoublesTheSameSeededDelay() {
        let now = WeiboMonitorTestSupport.date(2026, 11, 7, 12, 0)
        let user = WeiboMonitorTestSupport.user(
            priority: .p1,
            now: now,
            lastPostAt: now.addingTimeInterval(-3600)
        )
        var normalRNG = WeiboRNG(seed: 99)
        var lowPowerRNG = WeiboRNG(seed: 99)

        let normal = planner.nextDue(
            for: user, now: now, config: config, isLowPower: false, rng: &normalRNG
        )
        let lowPower = planner.nextDue(
            for: user, now: now, config: config, isLowPower: true, rng: &lowPowerRNG
        )

        XCTAssertEqual(
            lowPower.timeIntervalSince(now),
            normal.timeIntervalSince(now) * 2,
            accuracy: 0.001
        )
    }

    func testSpreadWakeUpFirstThreeImmediateAndRestBounded() {
        let now = WeiboMonitorTestSupport.date(2026, 11, 7, 12, 0)
        var users = (0..<6).map { index in
            WeiboMonitorTestSupport.user(uid: "\(index)", now: now)
        }
        for index in users.indices {
            users[index].nextDueAt = now.addingTimeInterval(-600)
        }
        var rng = WeiboRNG(seed: 123)

        planner.spreadWakeUp(users: &users, now: now, rng: &rng)
        let delays = users.map { $0.nextDueAt.timeIntervalSince(now) }

        XCTAssertTrue(delays.prefix(3).allSatisfy { $0 <= 5.001 })
        XCTAssertEqual(delays[3], 20, accuracy: 0.001)
        XCTAssertEqual(delays[4], 40, accuracy: 0.001)
        XCTAssertEqual(delays[5], 60, accuracy: 0.001)
    }

    func testP0NeverSkipsAnIdleRound() {
        var rng = WeiboRNG(seed: 5)
        for _ in 0..<200 {
            XCTAssertFalse(planner.shouldSkipIdleRound(priority: .p0, rng: &rng))
        }
    }

    func testP1SkipsOccasionallyButNotAlways() {
        var rng = WeiboRNG(seed: 5)
        var skips = 0
        for _ in 0..<1000 where planner.shouldSkipIdleRound(priority: .p1, rng: &rng) {
            skips += 1
        }
        XCTAssertGreaterThan(skips, 20)
        XCTAssertLessThan(skips, 120)
    }

    func testInitialDueIsBetweenThirtyAndOneTwentySeconds() {
        var rng = WeiboRNG(seed: 77)
        let now = WeiboMonitorTestSupport.date(2026, 11, 7, 12, 0)
        for _ in 0..<200 {
            let delay = planner.initialDue(now: now, rng: &rng).timeIntervalSince(now)
            XCTAssertGreaterThanOrEqual(delay, 30)
            XCTAssertLessThanOrEqual(delay, 120)
        }
    }

    func testNightWakeDoesNotPollP1OrP2() {
        let night = WeiboMonitorTestSupport.date(2026, 11, 7, 3, 0)
        var users = [
            WeiboMonitorTestSupport.user(uid: "p0", priority: .p0, now: night),
            WeiboMonitorTestSupport.user(uid: "p1", priority: .p1, now: night),
            WeiboMonitorTestSupport.user(uid: "p2", priority: .p2, now: night),
        ]
        for index in users.indices {
            users[index].nextDueAt = night.addingTimeInterval(-600)
        }
        var rng = WeiboRNG(seed: 5)
        planner.spreadWakeUp(users: &users, now: night, config: config, rng: &rng)

        XCTAssertLessThan(users[0].nextDueAt.timeIntervalSince(night), 6)
        for index in 1...2 {
            let components = calendar.dateComponents([.hour, .minute], from: users[index].nextDueAt)
            XCTAssertEqual(components.hour, 7)
            XCTAssertEqual(components.minute, 30)
        }
    }

    func testNightWindowWithWrapAroundIsHandled() {
        let wrapped = WeiboMonitorConfig(
            enabled: true,
            nightStartMinute: 23 * 60 + 30,
            nightEndMinute: 8 * 60
        )
        XCTAssertTrue(
            planner.isNight(
                WeiboMonitorTestSupport.date(2026, 11, 7, 23, 45),
                config: wrapped
            )
        )
        XCTAssertTrue(
            planner.isNight(
                WeiboMonitorTestSupport.date(2026, 11, 7, 6, 0),
                config: wrapped
            )
        )
        XCTAssertFalse(
            planner.isNight(
                WeiboMonitorTestSupport.date(2026, 11, 7, 12, 0),
                config: wrapped
            )
        )
    }
}
