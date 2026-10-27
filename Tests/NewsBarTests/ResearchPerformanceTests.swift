import XCTest
@testable import NewsBar

@MainActor
final class ResearchPerformanceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testThousandRecordIndexLoadsWithinBudget() async throws {
        let directory = try researchTestDirectory()
        let store = ResearchStore(directoryURL: directory)
        var records: [ResearchRecord] = []
        records.reserveCapacity(1_000)
        for index in 0..<1_000 {
            records.append(
                researchTestRecord(
                    title: "事件 \(index)",
                    updatedAt: now.addingTimeInterval(Double(index))
                )
            )
        }
        try await store.saveAll(records)

        let reloaded = ResearchStore(directoryURL: directory)
        let start = Date()
        _ = await reloaded.bootstrap()
        let elapsed = Date().timeIntervalSince(start)
        print("PERF 1000-index-load: \(elapsed * 1_000) ms")
        // Spec gate: under 150 ms in a debug build.
        XCTAssertLessThan(elapsed, 0.15)
    }

    func testProgressWriteStaysWithinBudget() async throws {
        let directory = try researchTestDirectory()
        let clock = ResearchTestClock(now)
        let store = ResearchStore(directoryURL: directory, now: { clock.now })
        var record = researchTestRecord(title: "进度", status: .running, updatedAt: now)
        try await store.save(record)

        clock.advance(2)
        record.run.phase = .reading
        record.run.pagesRead = 3

        let start = Date()
        await store.saveProgress(record)
        let elapsed = Date().timeIntervalSince(start)
        print("PERF progress-write: \(elapsed * 1_000) ms")
        // Spec gate: a single throttled progress tick under 5 ms.
        XCTAssertLessThan(elapsed, 0.005)
    }

    func testFreshDelegateDoesNotCreateResearchCenter() {
        let delegate = AppDelegate()
        let mirror = Mirror(reflecting: delegate)
        XCTAssertTrue(isNil(mirror.descendant("researchCenterWindow")))
        XCTAssertTrue(isNil(mirror.descendant("researchCenterModel")))
    }

    /// Mirror boxes `Optional.none` as a non-nil `Any`, so compare the
    /// description instead of using `XCTAssertNil`.
    private func isNil(_ value: Any?) -> Bool {
        guard let value else { return true }
        return String(describing: value) == "nil"
    }
}
