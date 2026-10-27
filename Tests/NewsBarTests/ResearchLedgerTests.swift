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
        XCTAssertEqual(ledger.snapshot(at: now).availability, .corrupt)
        XCTAssertNil(ledger.used(.ai, at: now))

        XCTAssertTrue(ledger.resetToday(at: now))
        XCTAssertEqual(ledger.snapshot(at: now).availability, .available)
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

    // MARK: - Version and availability

    func testUnversionedLedgerStillReads() throws {
        let directory = try researchTestDirectory()
        let url = directory.appendingPathComponent("ledger.json")
        let json = """
        {"day":20000101,"ai":{"burst":2,"keyword":0,"manual":0},
         "search":{"burst":1,"keyword":0,"manual":0},
         "tasks":{"burst":1,"keyword":0,"manual":0}}
        """
        try Data(json.utf8).write(to: url)

        let ledger = ResearchLedger(fileURL: url)
        let snapshot = ledger.snapshot(at: Date(timeIntervalSince1970: 946_684_800))
        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertEqual(snapshot.totalAI, 2)
    }

    func testFutureVersionIsReadOnlyAndCannotBeReset() throws {
        let directory = try researchTestDirectory()
        let url = directory.appendingPathComponent("ledger.json")
        let original = Data(#"{"version":99,"day":20000101,"futureField":true}"#.utf8)
        try original.write(to: url)

        let ledger = ResearchLedger(fileURL: url)
        XCTAssertEqual(ledger.snapshot().availability, .unsupportedVersion)
        XCTAssertNil(ledger.used(.ai))
        XCTAssertFalse(ledger.reserve(.ai, origin: .manual, cap: 10))
        XCTAssertFalse(ledger.resetToday())
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testResetArchivesCorruptFileWithOwnerOnlyPermissions() throws {
        let directory = try researchTestDirectory()
        let url = directory.appendingPathComponent("ledger.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: url)

        let ledger = ResearchLedger(fileURL: url)
        XCTAssertTrue(ledger.resetToday())
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let archived = try XCTUnwrap(files.first { $0.contains("corrupt-") })
        let archiveURL = directory.appendingPathComponent(archived)
        XCTAssertEqual(try Data(contentsOf: archiveURL), corrupt)
        let mode = try FileManager.default.attributesOfItem(atPath: archiveURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testLedgerFileIsCreatedOwnerOnly() throws {
        let (ledger, url) = try makeLedger()
        XCTAssertTrue(ledger.reserve(.ai, origin: .manual, cap: 10, at: now))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testResetIsRefusedWhileResearchIsRunning() throws {
        let (ledger, _) = try makeLedger()
        ResearchActivity.begin()
        defer { ResearchActivity.end() }

        XCTAssertFalse(ledger.resetToday(at: now))
        XCTAssertEqual(ledger.snapshot(at: now).availability, .available)
    }

    func testUnreadableLedgerIsNotReportedAsCorrupt() throws {
        let directory = try researchTestDirectory()
        let url = directory.appendingPathComponent("ledger.json")
        try Data(#"{"day":20000101,"ai":{"burst":1,"keyword":0,"manual":0},"search":{"burst":0,"keyword":0,"manual":0},"tasks":{"burst":0,"keyword":0,"manual":0}}"#.utf8)
            .write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        let ledger = ResearchLedger(fileURL: url)
        // Root can read mode-000 files; accept either explicit failure mode.
        let availability = ledger.snapshot().availability
        XCTAssertTrue(availability == .ioUnavailable || availability == .available)
        XCTAssertNotEqual(availability, .corrupt)
    }
}
