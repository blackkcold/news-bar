import XCTest
@testable import NewsBar

final class AIQuotaStoreTests: XCTestCase {
    private let day1 = Date(timeIntervalSince1970: 1_800_000_000)
    private let day2 = Date(timeIntervalSince1970: 1_800_100_000)

    private func makeStore() throws -> (AIQuotaStore, URL) {
        let directory = try researchTestDirectory()
        let url = directory.appendingPathComponent("quota.json")
        return (AIQuotaStore(fileURL: url), url)
    }

    private func countPolicy(_ cap: Int?) -> AIQuotaPolicy {
        AIQuotaPolicy(mode: .count, countCap: cap)
    }

    private func costPolicy(_ capMicros: Int64?) -> AIQuotaPolicy {
        AIQuotaPolicy(mode: .cost, costCapMicros: capMicros)
    }

    // MARK: - Count limit

    func testReserveEnforcesCountCap() throws {
        let (store, _) = try makeStore()
        let policy = countPolicy(3)

        XCTAssertTrue(store.reserve(.summary, policy: policy, at: day1))
        XCTAssertTrue(store.reserve(.research, policy: policy, at: day1))
        XCTAssertTrue(store.reserve(.triage, policy: policy, at: day1))
        XCTAssertFalse(store.reserve(.summary, policy: policy, at: day1))

        let snapshot = store.snapshot(at: day1)
        XCTAssertEqual(snapshot.count, 3)
        XCTAssertEqual(snapshot.calls(.summary), 1)
        XCTAssertEqual(snapshot.calls(.research), 1)
        XCTAssertEqual(snapshot.calls(.triage), 1)
        XCTAssertTrue(snapshot.isUsable)
    }

    func testUnlimitedCountNeverBlocks() throws {
        let (store, _) = try makeStore()
        for _ in 0..<250 {
            XCTAssertTrue(store.reserve(.summary, policy: countPolicy(nil), at: day1))
        }
        XCTAssertEqual(store.snapshot(at: day1).count, 250)
    }

    // MARK: - Cost limit

    func testCostCapBlocksUsingReservedCost() throws {
        let (store, _) = try makeStore()
        let policy = costPolicy(1_000)

        XCTAssertTrue(store.reserve(.summary, policy: policy, reservedCostMicros: 600, at: day1))
        XCTAssertTrue(store.reserve(.summary, policy: policy, reservedCostMicros: 399, at: day1))
        XCTAssertFalse(store.reserve(.summary, policy: policy, reservedCostMicros: 1, at: day1))

        XCTAssertEqual(store.snapshot(at: day1).costMicros, 999)
    }

    func testSettleReplacesEstimateWithActual() throws {
        let (store, _) = try makeStore()
        let policy = costPolicy(10_000)

        XCTAssertTrue(store.reserve(.summary, policy: policy, reservedCostMicros: 1_000, at: day1))
        XCTAssertTrue(store.settle(
            reservedCostMicros: 1_000,
            actualCostMicros: 400,
            inputTokens: 120,
            outputTokens: 30,
            priced: true,
            at: day1
        ))

        let snapshot = store.snapshot(at: day1)
        XCTAssertEqual(snapshot.costMicros, 400)
        XCTAssertEqual(snapshot.inputTokens, 120)
        XCTAssertEqual(snapshot.outputTokens, 30)
        XCTAssertEqual(snapshot.unpricedCalls, 0)
    }

    func testSettleCountsUnpricedCalls() throws {
        let (store, _) = try makeStore()
        XCTAssertTrue(store.reserve(.summary, policy: costPolicy(10_000), at: day1))
        XCTAssertTrue(store.settle(
            reservedCostMicros: 0,
            actualCostMicros: 0,
            inputTokens: 0,
            outputTokens: 0,
            priced: false,
            at: day1
        ))
        XCTAssertEqual(store.snapshot(at: day1).unpricedCalls, 1)
    }

    // MARK: - Rollover

    func testSnapshotRollsOverOnNewDay() throws {
        let (store, _) = try makeStore()
        XCTAssertTrue(store.reserve(.summary, policy: countPolicy(5), at: day1))
        XCTAssertTrue(store.reserve(.summary, policy: countPolicy(5), at: day1))
        XCTAssertEqual(store.snapshot(at: day1).count, 2)

        let nextDay = store.snapshot(at: day2)
        XCTAssertEqual(nextDay.count, 0)
        XCTAssertEqual(nextDay.costMicros, 0)
        XCTAssertTrue(nextDay.isUsable)

        XCTAssertTrue(store.reserve(.summary, policy: countPolicy(5), at: day2))
        XCTAssertEqual(store.snapshot(at: day2).count, 1)
    }

    // MARK: - Failure handling

    func testCorruptFileFailsClosedAndResetRecovers() throws {
        let (_, url) = try makeStore()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: url)

        let store = AIQuotaStore(fileURL: url)
        XCTAssertEqual(store.snapshot(at: day1).availability, .corrupt)
        XCTAssertFalse(store.reserve(.summary, policy: countPolicy(5), at: day1))

        XCTAssertTrue(store.resetToday(at: day1))
        XCTAssertEqual(store.snapshot(at: day1).availability, .available)
        XCTAssertTrue(store.reserve(.summary, policy: countPolicy(5), at: day1))
    }

    func testUnsupportedVersionIsReadOnly() throws {
        let (_, url) = try makeStore()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = try JSONSerialization.data(withJSONObject: [
            "version": 99,
            "day": AIQuotaStore.dayKey(for: day1),
            "count": 2,
        ])
        try payload.write(to: url)

        let store = AIQuotaStore(fileURL: url)
        XCTAssertEqual(store.snapshot(at: day1).availability, .unsupportedVersion)
        XCTAssertFalse(store.reserve(.summary, policy: countPolicy(5), at: day1))
        XCTAssertFalse(store.resetToday(at: day1))
    }

    func testMissingOptionalFieldsDecodeWithDefaults() throws {
        let (_, url) = try makeStore()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = try JSONSerialization.data(withJSONObject: [
            "day": AIQuotaStore.dayKey(for: day1),
            "count": 4,
        ])
        try payload.write(to: url)

        let store = AIQuotaStore(fileURL: url)
        let snapshot = store.snapshot(at: day1)
        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertEqual(snapshot.count, 4)
        XCTAssertEqual(snapshot.costMicros, 0)
    }

    // MARK: - Migration

    func testSeedLegacyUsageIsIdempotent() throws {
        let (store, _) = try makeStore()
        XCTAssertTrue(store.seedLegacyUsage(summaryCount: 3, researchCount: 2, at: day1))
        XCTAssertEqual(store.snapshot(at: day1).count, 5)

        XCTAssertTrue(store.seedLegacyUsage(summaryCount: 10, researchCount: 10, at: day1))
        XCTAssertEqual(store.snapshot(at: day1).count, 5, "A second seed must not double count")
    }

    func testSeedLegacySplitsOrigins() throws {
        let (store, _) = try makeStore()
        XCTAssertTrue(store.seedLegacyUsage(summaryCount: 4, researchCount: 6, at: day1))
        let snapshot = store.snapshot(at: day1)
        XCTAssertEqual(snapshot.calls(.summary), 4)
        XCTAssertEqual(snapshot.calls(.research), 6)
        XCTAssertEqual(snapshot.count, 10)
    }

    func testSeedLegacyNoOpWhenNothingWasUsed() throws {
        let (store, _) = try makeStore()
        XCTAssertTrue(store.seedLegacyUsage(summaryCount: 0, researchCount: 0, at: day1))
        XCTAssertEqual(store.snapshot(at: day1).count, 0)
    }

    // MARK: - File permissions

    func testQuotaFileIsOwnerOnly() throws {
        let (store, url) = try makeStore()
        XCTAssertTrue(store.reserve(.summary, policy: countPolicy(5), at: day1))

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
}
