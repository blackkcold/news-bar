import XCTest
@testable import NewsBar

final class PersistentBudgetTests: XCTestCase {
    func testReservationSurvivesRestartAndFailureDoesNotRefund() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("budget.json")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let budget = PersistentRequestBudget(fileURL: path)
        XCTAssertTrue(budget.reserve(cap: 2, at: now))
        let restarted = PersistentRequestBudget(fileURL: path)
        XCTAssertEqual(restarted.used(at: now), 1)
        XCTAssertTrue(restarted.reserve(cap: 2, at: now))
        XCTAssertFalse(restarted.reserve(cap: 2, at: now))
        XCTAssertEqual(restarted.used(at: now), 2)
        XCTAssertTrue(restarted.reserve(cap: 2, at: now.addingTimeInterval(86400)))
        XCTAssertEqual(restarted.used(at: now.addingTimeInterval(86400)), 1)
    }

    func testCorruptLedgerFailsClosedRatherThanResettingToZero() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("budget.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: path)
        XCTAssertFalse(PersistentRequestBudget(fileURL: path).reserve(cap: 50))
    }
}
