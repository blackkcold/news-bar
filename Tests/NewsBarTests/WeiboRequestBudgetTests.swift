import XCTest
@testable import NewsBar

final class WeiboRequestBudgetTests: XCTestCase {
    private let now = WeiboMonitorTestSupport.date(2026, 11, 7, 12, 0)

    func testWarmupAllowsOnlyThreeRequestsInTheFirstMinute() {
        var budget = WeiboRequestBudget(now: now)
        budget.startWarmup(now: now)

        for index in 0..<3 {
            XCTAssertTrue(
                budget.acquire(now: now, priority: .p0).isAllowed,
                "request \(index) should be allowed"
            )
        }

        guard case let .deferred(until) = budget.acquire(now: now, priority: .p0) else {
            return XCTFail("fourth warm-up request should be deferred")
        }
        XCTAssertEqual(until, now.addingTimeInterval(60))
    }

    func testHardWindowStopsAtFifteenRequests() {
        var budget = WeiboRequestBudget(
            capacity: 100,
            refillPerMinute: 100,
            hardWindowLimit: 15,
            warmupLimit: 100,
            now: now
        )

        for _ in 0..<15 {
            XCTAssertTrue(budget.acquire(now: now, priority: .p0).isAllowed)
        }
        XCTAssertFalse(budget.acquire(now: now, priority: .p0).isAllowed)
    }

    func testTokenRefillUnblocksAfterSixSeconds() {
        var budget = WeiboRequestBudget(
            capacity: 6,
            refillPerMinute: 10,
            hardWindowLimit: 100,
            warmupLimit: 100,
            now: now
        )
        for _ in 0..<6 {
            XCTAssertTrue(budget.acquire(now: now, priority: .p0).isAllowed)
        }
        guard case let .deferred(until) = budget.acquire(now: now, priority: .p0) else {
            return XCTFail("expected a deferral")
        }
        XCTAssertLessThanOrEqual(until.timeIntervalSince(now), 6.1)

        XCTAssertTrue(
            budget.acquire(now: now.addingTimeInterval(6.2), priority: .p0).isAllowed
        )
    }

    func testP1DeferralIsBoundedToThirtySixtySeconds() {
        var budget = WeiboRequestBudget(
            capacity: 1,
            refillPerMinute: 1,
            hardWindowLimit: 100,
            warmupLimit: 100,
            now: now
        )
        XCTAssertTrue(budget.acquire(now: now, priority: .p0).isAllowed)

        guard case let .deferred(until) = budget.acquire(now: now, priority: .p1) else {
            return XCTFail("expected a deferral")
        }
        let delay = until.timeIntervalSince(now)
        XCTAssertGreaterThanOrEqual(delay, 30)
        XCTAssertLessThanOrEqual(delay, 60)
    }

    func testP0DeferralNeverExceedsFiveMinutes() {
        var budget = WeiboRequestBudget(
            capacity: 100,
            refillPerMinute: 100,
            hardWindowLimit: 1,
            warmupLimit: 100,
            now: now
        )
        XCTAssertTrue(budget.acquire(now: now, priority: .p0).isAllowed)

        guard case let .deferred(until) = budget.acquire(now: now, priority: .p0) else {
            return XCTFail("expected a deferral")
        }
        XCTAssertLessThanOrEqual(until.timeIntervalSince(now), 300)
    }

    func testCircuitOpensOnThreeDistinctAccounts() {
        var breaker = WeiboCircuitBreaker()
        XCTAssertFalse(breaker.noteRateLimit(uid: "a", now: now, openDuration: 45 * 60))
        XCTAssertFalse(breaker.noteRateLimit(uid: "a", now: now, openDuration: 45 * 60))
        XCTAssertFalse(breaker.noteRateLimit(uid: "b", now: now, openDuration: 45 * 60))
        XCTAssertTrue(breaker.noteRateLimit(uid: "c", now: now, openDuration: 45 * 60))
        XCTAssertTrue(breaker.isOpen(now: now))
        XCTAssertFalse(breaker.canRequest(now: now.addingTimeInterval(60)))
        XCTAssertTrue(breaker.canRequest(now: now.addingTimeInterval(45 * 60 + 1)))
    }

    func testCircuitRequiresDistinctAccounts() {
        var breaker = WeiboCircuitBreaker()
        for _ in 0..<5 {
            XCTAssertFalse(
                breaker.noteRateLimit(uid: "same", now: now, openDuration: 45 * 60)
            )
        }
        XCTAssertFalse(breaker.isOpen(now: now))
    }

    func testCircuitPrunesHitsOlderThanTenMinutes() {
        var breaker = WeiboCircuitBreaker()
        XCTAssertFalse(breaker.noteRateLimit(uid: "a", now: now, openDuration: 45 * 60))
        XCTAssertFalse(
            breaker.noteRateLimit(
                uid: "b",
                now: now.addingTimeInterval(11 * 60),
                openDuration: 45 * 60
            )
        )
        XCTAssertFalse(
            breaker.noteRateLimit(
                uid: "c",
                now: now.addingTimeInterval(12 * 60),
                openDuration: 45 * 60
            )
        )
        XCTAssertFalse(breaker.isOpen(now: now))
    }

    func testCircuitResetClosesAndClearsHits() {
        var breaker = WeiboCircuitBreaker()
        _ = breaker.noteRateLimit(uid: "a", now: now, openDuration: 30 * 60)
        _ = breaker.noteRateLimit(uid: "b", now: now, openDuration: 30 * 60)
        XCTAssertTrue(breaker.noteRateLimit(uid: "c", now: now, openDuration: 30 * 60))
        breaker.reset()
        XCTAssertFalse(breaker.isOpen(now: now))
        XCTAssertTrue(breaker.canRequest(now: now))
    }

    func testCircuitSuccessClosesAndFailureDoubles() {        var breaker = WeiboCircuitBreaker()
        _ = breaker.noteRateLimit(uid: "a", now: now, openDuration: 30 * 60)
        _ = breaker.noteRateLimit(
            uid: "b", now: now, openDuration: 30 * 60
        )
        XCTAssertTrue(breaker.noteRateLimit(uid: "c", now: now, openDuration: 30 * 60))

        breaker.noteFailure(now: now.addingTimeInterval(60))
        XCTAssertFalse(breaker.canRequest(now: now.addingTimeInterval(61)))
        XCTAssertTrue(breaker.canRequest(now: now.addingTimeInterval(61 * 60)))

        breaker.noteSuccess(now: now)
        XCTAssertFalse(breaker.isOpen(now: now))
    }
}
