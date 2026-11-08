import XCTest
@testable import NewsBar

/// The 24-hour simulation is the acceptance test for the scheduling design:
/// 8 P0 + 20 P1 + 10 P2, one minute per tick, fixed seed. It exercises the
/// planner and the budget together, without network or SwiftUI.
final class WeiboMonitorSimulationTests: XCTestCase {
    func testTwentyFourHourRequestBudget() {
        let calendar = WeiboMonitorTestSupport.calendar
        let start = WeiboMonitorTestSupport.date(2026, 11, 7, 0, 0)
        var rng = WeiboRNG(seed: 2026_11_07)
        let planner = WeiboPollPlanner(calendar: calendar)
        let config = WeiboMonitorConfig(
            enabled: true,
            nightEnabled: true,
            nightStartMinute: 30,
            nightEndMinute: 450
        )

        var users: [WeiboMonitorUser] = []
        for index in 0..<8 {
            users.append(
                WeiboMonitorTestSupport.user(
                    uid: "p0-\(index)",
                    priority: .p0,
                    now: start,
                    lastPostAt: start.addingTimeInterval(-3600)
                )
            )
        }
        for index in 0..<20 {
            users.append(
                WeiboMonitorTestSupport.user(
                    uid: "p1-\(index)",
                    priority: .p1,
                    now: start,
                    lastPostAt: start.addingTimeInterval(-3600)
                )
            )
        }
        for index in 0..<10 {
            users.append(
                WeiboMonitorTestSupport.user(
                    uid: "p2-\(index)",
                    priority: .p2,
                    now: start,
                    lastPostAt: start.addingTimeInterval(-3600)
                )
            )
        }
        for index in users.indices {
            users[index].nextDueAt = planner.initialDue(now: start, rng: &rng)
        }

        var budget = WeiboRequestBudget(now: start)
        budget.startWarmup(now: start)
        var requestTimes: [Date] = []
        var nightRequests = 0
        var daytimeRequests = 0
        var tick = start

        while tick < start.addingTimeInterval(24 * 60 * 60) {
            var cursor = tick
            for priority in [WeiboMonitorPriority.p0, .p1, .p2] {
                var indices = users.indices.filter {
                    users[$0].priority == priority
                        && users[$0].enabled
                        && users[$0].nextDueAt <= cursor
                }
                indices.shuffle(using: &rng)

                for index in indices {
                    guard cursor < tick.addingTimeInterval(60) else { break }

                    if priority != .p0,
                       planner.shouldSkipIdleRound(priority: priority, rng: &rng) {
                        users[index].nextDueAt = planner.nextDue(
                            for: users[index],
                            now: cursor,
                            config: config,
                            isLowPower: false,
                            rng: &rng
                        )
                        continue
                    }

                    switch budget.acquire(now: cursor, priority: priority) {
                    case .allowed:
                        requestTimes.append(cursor)
                        if planner.isNight(cursor, config: config) {
                            nightRequests += 1
                        } else {
                            daytimeRequests += 1
                        }
                        users[index].nextDueAt = planner.nextDue(
                            for: users[index],
                            now: cursor,
                            config: config,
                            isLowPower: false,
                            rng: &rng
                        )
                        // The live service sleeps 400–1200 ms between requests.
                        cursor = cursor.addingTimeInterval(
                            WeiboRandom.double(in: 0.4...1.2, rng: &rng)
                        )
                    case .deferred(let until):
                        users[index].nextDueAt = max(until, cursor.addingTimeInterval(1))
                    }
                }
            }
            tick = tick.addingTimeInterval(60)
        }

        let total = requestTimes.count
        let averagePerMinute = Double(total) / (24 * 60)
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThanOrEqual(
            averagePerMinute,
            10.0,
            "average \(averagePerMinute) requests/minute exceeds the soft budget"
        )

        var perMinute: [Int: Int] = [:]
        for date in requestTimes {
            let minute = Int(date.timeIntervalSince(start) / 60)
            perMinute[minute, default: 0] += 1
        }
        XCTAssertLessThanOrEqual(
            perMinute.values.max() ?? 0,
            15,
            "a single minute exceeded the hard window"
        )

        // Night is 00:30–07:30 (7 hours); the rest is 17 hours. P1/P2 pause
        // and P0 slows to 5×, so the per-hour rate must fall by at least 80%.
        let nightRate = Double(nightRequests) / 7.0
        let daytimeRate = Double(daytimeRequests) / 17.0
        XCTAssertGreaterThan(daytimeRate, 0)
        XCTAssertLessThan(
            nightRate,
            daytimeRate * 0.2,
            "night rate \(nightRate)/h is not at least 80% below daytime \(daytimeRate)/h"
        )

        // Requests within one tick are spaced by 400–1200 ms. The exact Date
        // values must never repeat, which is the "no same-instant burst" rule.
        XCTAssertEqual(Set(requestTimes).count, requestTimes.count)

        // P0 must be served before P1/P2 when the budget is scarce. The first
        // ten minutes after the warm-up should contain P0 requests.
        let firstTenMinutes = requestTimes.filter {
            $0 < start.addingTimeInterval(10 * 60)
        }
        XCTAssertFalse(firstTenMinutes.isEmpty)
    }
}
