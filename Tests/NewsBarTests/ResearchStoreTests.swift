import XCTest
@testable import NewsBar

final class ResearchStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testReaderMatchingPrefersItemThenCanonicalURLThenTopic() async throws {
        let store = ResearchStore(directoryURL: try researchTestDirectory())
        var itemMatch = researchTestRecord(title: "Item", updatedAt: now.addingTimeInterval(-100))
        itemMatch.seed.itemID = "item-1"
        itemMatch.seed.url = "https://example.org/item"
        var urlMatch = researchTestRecord(title: "URL", updatedAt: now)
        urlMatch.seed.itemID = "item-2"
        urlMatch.seed.url = "https://example.org/story?id=1&utm_source=feed"
        var topicMatch = researchTestRecord(title: "Topic", updatedAt: now.addingTimeInterval(100))
        topicMatch.topicKey = "topic-key"
        try await store.saveAll([itemMatch, urlMatch, topicMatch])

        let exact = await store.indexEntry(matchingItemID: "item-1", url: "https://example.org/story?id=1#section", topicKey: "topic-key")
        let byURL = await store.indexEntry(matchingItemID: nil, url: "https://example.org/story?id=1#section", topicKey: "topic-key")
        let byTopic = await store.indexEntry(matchingItemID: nil, url: nil, topicKey: "topic-key")
        let empty = await store.indexEntry(matchingItemID: "", url: "", topicKey: "")
        XCTAssertEqual(exact?.id, itemMatch.id)
        XCTAssertEqual(byURL?.id, urlMatch.id)
        XCTAssertEqual(byTopic?.id, topicMatch.id)
        XCTAssertNil(empty)
    }

    func testLegacyIndexRebuildsSeedProjectionWithoutChangingRecord() async throws {
        let directory = try researchTestDirectory()
        let store = ResearchStore(directoryURL: directory)
        var record = researchTestRecord(title: "Legacy", updatedAt: now)
        record.seed.itemID = "legacy-item"
        record.seed.url = "https://example.org/legacy"
        try await store.save(record)
        let recordURL = directory.appendingPathComponent("records/\(record.id).json")
        let original = try Data(contentsOf: recordURL)
        let indexURL = directory.appendingPathComponent("index.json")
        var index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
        index["version"] = 1
        var entries = try XCTUnwrap(index["entries"] as? [[String: Any]])
        entries[0].removeValue(forKey: "seedItemID")
        entries[0].removeValue(forKey: "seedURL")
        index["entries"] = entries
        try JSONSerialization.data(withJSONObject: index).write(to: indexURL)

        let reloaded = ResearchStore(directoryURL: directory)
        let bootstrap = await reloaded.bootstrap()
        let match = await reloaded.indexEntry(matchingItemID: "legacy-item", url: nil, topicKey: nil)
        XCTAssertTrue(bootstrap.rebuiltIndex)
        XCTAssertEqual(match?.id, record.id)
        XCTAssertEqual(try Data(contentsOf: recordURL), original)
    }

    func testSaveLoadAndIndexRebuild() async throws {
        let directory = try researchTestDirectory()
        let store = ResearchStore(directoryURL: directory)
        let record = researchTestRecord(title: "事件 A", updatedAt: now)
        try await store.save(record)

        let reloaded = ResearchStore(directoryURL: directory)
        let bootstrap = await reloaded.bootstrap()
        XCTAssertFalse(bootstrap.rebuiltIndex)
        XCTAssertEqual(bootstrap.entries.map(\.id), [record.id])

        try FileManager.default.removeItem(at: directory.appendingPathComponent("index.json"))

        let rebuilt = ResearchStore(directoryURL: directory)
        let rebuiltBootstrap = await rebuilt.bootstrap()
        XCTAssertTrue(rebuiltBootstrap.rebuiltIndex)
        XCTAssertEqual(rebuiltBootstrap.entries.map(\.id), [record.id])
        let loaded = await rebuilt.record(id: record.id)
        XCTAssertEqual(loaded?.topic, "事件 A")
    }

    func testRunningRecordBecomesInterruptedOnBootstrap() async throws {
        let directory = try researchTestDirectory()
        let store = ResearchStore(directoryURL: directory)
        let record = researchTestRecord(title: "运行中", status: .running, updatedAt: now)
        try await store.save(record)

        let reloaded = ResearchStore(directoryURL: directory)
        let bootstrap = await reloaded.bootstrap()

        XCTAssertEqual(bootstrap.interruptedIDs, [record.id])
        let loaded = await reloaded.record(id: record.id)
        XCTAssertEqual(loaded?.status, .interrupted)
        XCTAssertEqual(loaded?.run.phase, .done)
        XCTAssertNotNil(loaded?.run.lastError)
    }

    func testQueuedRecordBecomesInterruptedOnBootstrap() async throws {
        let directory = try researchTestDirectory()
        let store = ResearchStore(directoryURL: directory)
        var record = researchTestRecord(title: "排队中", status: .queued, updatedAt: now)
        record.run.startedAt = nil
        try await store.save(record)

        let reloaded = ResearchStore(directoryURL: directory)
        let bootstrap = await reloaded.bootstrap()

        XCTAssertEqual(bootstrap.interruptedIDs, [record.id])
        let loaded = await reloaded.record(id: record.id)
        XCTAssertEqual(loaded?.status, .interrupted)
        XCTAssertEqual(loaded?.run.phase, .done)
    }

    func testCorruptRecordIsIsolatedWithoutDeletingFile() async throws {
        let directory = try researchTestDirectory()
        let store = ResearchStore(directoryURL: directory)
        let good = researchTestRecord(title: "正常记录", updatedAt: now)
        try await store.save(good)

        let badID = UUID().uuidString
        let badURL = directory
            .appendingPathComponent("records", isDirectory: true)
            .appendingPathComponent("\(badID).json")
        try Data("not-json".utf8).write(to: badURL)

        let reloaded = ResearchStore(directoryURL: directory)
        let bootstrap = await reloaded.bootstrap()

        XCTAssertTrue(bootstrap.rebuiltIndex)
        XCTAssertEqual(bootstrap.corruptIDs, [badID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: badURL.path))

        let entries = await reloaded.index()
        XCTAssertEqual(Set(entries.map(\.id)), Set([good.id, badID]))
        let corrupt = entries.first { $0.id == badID }
        XCTAssertEqual(corrupt?.status, .corrupt)

        let goodLoaded = await reloaded.record(id: good.id)
        XCTAssertEqual(goodLoaded?.topic, "正常记录")
        let corruptLoaded = await reloaded.record(id: badID)
        XCTAssertEqual(corruptLoaded?.status, .corrupt)
    }

    func testIndexMismatchRebuildsMissingRecord() async throws {
        let directory = try researchTestDirectory()
        let store = ResearchStore(directoryURL: directory)
        let first = researchTestRecord(title: "甲", updatedAt: now)
        let second = researchTestRecord(title: "乙", updatedAt: now.addingTimeInterval(-60))
        try await store.saveAll([first, second])

        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("records/\(first.id).json")
        )

        let reloaded = ResearchStore(directoryURL: directory)
        let bootstrap = await reloaded.bootstrap()
        XCTAssertTrue(bootstrap.rebuiltIndex)
        XCTAssertEqual(bootstrap.entries.map(\.id), [second.id])
    }

    func testRetentionEvictionRespectsPinnedAndExcluded() async throws {
        let directory = try researchTestDirectory()
        let store = ResearchStore(directoryURL: directory)
        let old = researchTestRecord(
            title: "旧且未固定",
            updatedAt: now.addingTimeInterval(-100 * 86_400)
        )
        let pinned = researchTestRecord(
            title: "旧但固定",
            updatedAt: now.addingTimeInterval(-100 * 86_400),
            isPinned: true
        )
        let excluded = researchTestRecord(
            title: "旧但被引用",
            updatedAt: now.addingTimeInterval(-100 * 86_400)
        )
        let recent = researchTestRecord(title: "新记录", updatedAt: now)
        try await store.saveAll([old, pinned, excluded, recent])

        let removed = await store.enforceLimits(
            now: now,
            historyLimit: 10,
            retentionDays: 30,
            excluding: [excluded.id]
        )

        XCTAssertEqual(removed, [old.id])
        let remaining = Set(await store.index().map(\.id))
        XCTAssertEqual(remaining, Set([pinned.id, excluded.id, recent.id]))
    }

    func testLRUEvictionKeepsPinnedAndDeletesOldestAccess() async throws {
        let directory = try researchTestDirectory()
        let store = ResearchStore(directoryURL: directory)
        let oldest = researchTestRecord(
            title: "最久未打开",
            updatedAt: now,
            lastAccessedAt: now.addingTimeInterval(-400)
        )
        let second = researchTestRecord(
            title: "次久未打开",
            updatedAt: now,
            lastAccessedAt: now.addingTimeInterval(-300)
        )
        let pinned = researchTestRecord(
            title: "固定但最久未打开",
            updatedAt: now,
            lastAccessedAt: now.addingTimeInterval(-500),
            isPinned: true
        )
        let newest = researchTestRecord(
            title: "最近打开",
            updatedAt: now,
            lastAccessedAt: now.addingTimeInterval(-100)
        )
        try await store.saveAll([oldest, second, pinned, newest])

        let removed = await store.enforceLimits(
            now: now,
            historyLimit: 2,
            retentionDays: 0
        )

        XCTAssertEqual(Set(removed), Set([oldest.id, second.id]))
        let remaining = Set(await store.index().map(\.id))
        XCTAssertEqual(remaining, Set([pinned.id, newest.id]))
    }

    func testDeleteRemovesOnlyTargetRecord() async throws {
        let directory = try researchTestDirectory()
        let store = ResearchStore(directoryURL: directory)
        let first = researchTestRecord(title: "甲", updatedAt: now)
        let second = researchTestRecord(title: "乙", updatedAt: now)
        try await store.saveAll([first, second])

        try await store.delete(id: first.id)

        let entries = await store.index()
        XCTAssertEqual(entries.map(\.id), [second.id])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("records/\(first.id).json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("records/\(second.id).json").path
            )
        )
    }

    func testProgressWritesAreThrottledAndFlushed() async throws {
        let directory = try researchTestDirectory()
        let clock = ResearchTestClock(now)
        let store = ResearchStore(directoryURL: directory, now: { clock.now })

        var record = researchTestRecord(title: "进度", status: .running, updatedAt: clock.now)
        record.run.phase = .idle
        try await store.save(record)

        record.run.phase = .searching
        clock.advance(0.2)
        await store.saveProgress(record)

        let url = directory.appendingPathComponent("records/\(record.id).json")
        var onDisk = try JSONDecoder().decode(ResearchRecord.self, from: Data(contentsOf: url))
        XCTAssertEqual(onDisk.run.phase, .idle, "a sub-second progress write must stay pending")

        clock.advance(1)
        await store.flushPendingWrites()

        onDisk = try JSONDecoder().decode(ResearchRecord.self, from: Data(contentsOf: url))
        XCTAssertEqual(onDisk.run.phase, .searching)
    }

    func testIndexWriteFailureDoesNotRollbackRecord() async throws {
        let directory = try researchTestDirectory()
        // A directory at index.json makes every index write fail.
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("index.json"),
            withIntermediateDirectories: false
        )

        let store = ResearchStore(directoryURL: directory)
        let record = researchTestRecord(title: "索引失败仍可保存", updatedAt: now)
        try await store.save(record)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("records/\(record.id).json").path
            )
        )
        let loaded = await store.record(id: record.id)
        XCTAssertEqual(loaded?.topic, "索引失败仍可保存")
    }

    func testEqualUpdatedAtOrderIsStableByTopic() async throws {
        let directory = try researchTestDirectory()
        let store = ResearchStore(directoryURL: directory)
        let first = researchTestRecord(title: "A事件", updatedAt: now)
        let second = researchTestRecord(title: "B事件", updatedAt: now)
        try await store.saveAll([second, first])

        let entries = await store.index()
        XCTAssertEqual(entries.map(\.topic), ["A事件", "B事件"])

        let reloaded = ResearchStore(directoryURL: directory)
        let reloadedTopics = await reloaded.index().map(\.topic)
        XCTAssertEqual(reloadedTopics, ["A事件", "B事件"])
    }

    func testDeleteAllLeavesNoRecordsAfterRestart() async throws {
        let directory = try researchTestDirectory()
        let store = ResearchStore(directoryURL: directory)
        let first = researchTestRecord(title: "甲", updatedAt: now)
        let second = researchTestRecord(title: "乙", updatedAt: now)
        try await store.saveAll([first, second])

        try await store.deleteAll()

        let reloaded = ResearchStore(directoryURL: directory)
        let bootstrap = await reloaded.bootstrap()
        XCTAssertTrue(bootstrap.entries.isEmpty)
        let recordFiles = try FileManager.default.contentsOfDirectory(
            atPath: directory.appendingPathComponent("records", isDirectory: true).path
        )
        XCTAssertTrue(recordFiles.isEmpty)
    }

    func testRecordAndDirectoryPermissions() async throws {
        let directory = try researchTestDirectory()
        let store = ResearchStore(directoryURL: directory)
        let record = researchTestRecord(title: "权限", updatedAt: now)
        try await store.save(record)

        let recordsDirectory = directory.appendingPathComponent("records", isDirectory: true)
        let directoryPermissions = try FileManager.default
            .attributesOfItem(atPath: recordsDirectory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryPermissions?.intValue, 0o700)

        let filePermissions = try FileManager.default
            .attributesOfItem(
                atPath: recordsDirectory.appendingPathComponent("\(record.id).json").path
            )[.posixPermissions] as? NSNumber
        XCTAssertEqual(filePermissions?.intValue, 0o600)
    }

    func testStaleIndexDoesNotMarkFinishedRecordInterrupted() async throws {
        let directory = try researchTestDirectory()
        let store = ResearchStore(directoryURL: directory)
        var record = researchTestRecord(title: "已完成", status: .running, updatedAt: now)
        try await store.save(record)

        // Simulate a crash between the record write and the index write: the
        // file says ready while the index still says running.
        record.status = .ready
        record.run.phase = .done
        record.run.finishedAt = now
        let url = directory.appendingPathComponent("records/\(record.id).json")
        try JSONEncoder().encode(record).write(to: url)

        let reloaded = ResearchStore(directoryURL: directory)
        let bootstrap = await reloaded.bootstrap()

        XCTAssertTrue(bootstrap.interruptedIDs.isEmpty)
        let loaded = await reloaded.record(id: record.id)
        XCTAssertEqual(loaded?.status, .ready)
    }

    func testDeletedRecordIsNotResurrectedByLateProgress() async throws {
        let directory = try researchTestDirectory()
        let store = ResearchStore(directoryURL: directory)
        let record = researchTestRecord(title: "删除后迟到进度", status: .running, updatedAt: now)
        try await store.save(record)
        try await store.delete(id: record.id)

        try await store.save(record)
        await store.saveProgress(record)
        await store.flushPendingWrites()

        let loaded = await store.record(id: record.id)
        XCTAssertNil(loaded)
    }
}
