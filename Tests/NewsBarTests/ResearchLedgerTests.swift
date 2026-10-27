import XCTest
@testable import NewsBar

final class ResearchLedgerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeLedger() throws -> (ResearchLedger, URL) {
        let directory = try researchTestDirectory()
        let url = directory.appendingPathComponent("ledger.json")
        return (ResearchLedger(fileURL: url), url)
    }

    func testReservesPerOriginAndSharedAICap() throws {
        let (ledger, _) = try makeLedger()

        XCTAssertTrue(ledger.reserve(.ai, origin: .burst, cap: 3, at: now))
        XCTAssertTrue(ledger.reserve(.ai, origin: .keyword, cap: 3, at: now))
        XCTAssertTrue(ledger.reserve(.ai, origin: .manual, cap: 3, at: now))
        XCTAssertFalse(ledger.reserve(.ai, origin: .burst, cap: 3, at: now))

        let snapshot = ledger.snapshot(at: now)
        XCTAssertFalse(snapshot.isCorrupt)
        XCTAssertEqual(snapshot.ai.burst, 1)
        XCTAssertEqual(snapshot.ai.keyword, 1)
        XCTAssertEqual(snapshot.ai.manual, 1)
        XCTAssertEqual(snapshot.totalAI, 3)
    }

    func testTaskCapIsSharedAcrossOrigins() throws {
        let (ledger, _) = try makeLedger()

        XCTAssertTrue(ledger.reserve(.task, origin: .burst, cap: 1, at: now))
        XCTAssertFalse(ledger.reserve(.task, origin: .keyword, cap: 1, at: now))
        XCTAssertFalse(ledger.reserve(.task, origin: .manual, cap: 1, at: now))

        let snapshot = ledger.snapshot(at: now)
        XCTAssertEqual(snapshot.tasks.burst, 1)
        XCTAssertEqual(snapshot.tasks.keyword, 0)
        XCTAssertEqual(snapshot.totalTasks, 1)
    }

    func testSearchIsCountedWithoutDailyCap() throws {
        let (ledger, _) = try makeLedger()

        for _ in 0..<5 {
            XCTAssertTrue(ledger.reserve(.search, origin: .burst, cap: 0, at: now))
        }
        XCTAssertTrue(ledger.reserve(.search, origin: .manual, cap: 0, at: now))

        let snapshot = ledger.snapshot(at: now)
        XCTAssertEqual(snapshot.search.burst, 5)
        XCTAssertEqual(snapshot.search.manual, 1)
        XCTAssertEqual(snapshot.totalSearch, 6)
        XCTAssertEqual(ledger.used(.search, at: now), 6)
    }

    func testDayRolloverStartsFreshCounts() throws {
        let (ledger, _) = try makeLedger()
        XCTAssertTrue(ledger.reserve(.ai, origin: .burst, cap: 1, at: now))

        let nextDay = now.addingTimeInterval(2 * 86_400)
        let rolled = ledger.snapshot(at: nextDay)
        XCTAssertEqual(rolled.totalAI, 0)
        XCTAssertEqual(rolled.totalTasks, 0)

        XCTAssertTrue(ledger.reserve(.ai, origin: .keyword, cap: 1, at: nextDay))
        XCTAssertEqual(ledger.snapshot(at: nextDay).ai.keyword, 1)
    }

    func testCorruptLedgerFailsClosedUntilReset() throws {
        let directory = try researchTestDirectory()
        let url = directory.appendingPathComponent("ledger.json")
        try Data("not-json".utf8).write(to: url)

        let ledger = ResearchLedger(fileURL: url)
        XCTAssertFalse(ledger.reserve(.ai, origin: .manual, cap: 10, at: now))
        XCTAssertTrue(ledger.snapshot(at: now).isCorrupt)
        XCTAssertEqual(ledger.used(.ai, at: now), Int.max)

        XCTAssertTrue(ledger.resetToday(at: now))
        XCTAssertFalse(ledger.snapshot(at: now).isCorrupt)
        XCTAssertTrue(ledger.reserve(.ai, origin: .manual, cap: 1, at: now))
    }

    func testCountsPersistAcrossInstances() throws {
        let (ledger, url) = try makeLedger()
        XCTAssertTrue(ledger.reserve(.ai, origin: .keyword, cap: 10, at: now))
        XCTAssertTrue(ledger.reserve(.search, origin: .manual, cap: 0, at: now))

        let reloaded = ResearchLedger(fileURL: url)
        let snapshot = reloaded.snapshot(at: now)
        XCTAssertEqual(snapshot.ai.keyword, 1)
        XCTAssertEqual(snapshot.search.manual, 1)
        XCTAssertEqual(reloaded.used(.ai, at: now), 1)
    }
}
