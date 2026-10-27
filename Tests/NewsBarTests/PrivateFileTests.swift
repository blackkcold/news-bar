import Darwin
import XCTest
@testable import NewsBar

final class PrivateFileTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func mode(_ url: URL) throws -> Int {
        let value = try FileManager.default
            .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return value?.intValue ?? -1
    }

    func testWriteCreatesOwnerOnlyFileAndLeavesNoTemporary() throws {
        let directory = try researchTestDirectory()
        let url = directory.appendingPathComponent("payload.json")
        try PrivateFile.write(Data("hello".utf8), to: url, durable: true)

        XCTAssertEqual(try mode(url), 0o600)
        XCTAssertEqual(try Data(contentsOf: url), Data("hello".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(PrivateFile.temporaryPrefix) }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testWriteCreatesOwnerOnlyEvenWithPermissiveUmask() throws {
        let directory = try researchTestDirectory()
        let url = directory.appendingPathComponent("payload.json")
        let previous = umask(0)
        defer { _ = umask(previous) }

        try PrivateFile.write(Data("hello".utf8), to: url, durable: false)

        XCTAssertEqual(try mode(url), 0o600)
    }

    func testEnsureDirectoryTightensExistingPermissions() throws {
        let directory = try researchTestDirectory()
            .appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        try PrivateFile.ensureDirectory(directory)

        XCTAssertEqual(try mode(directory), 0o700)
    }

    func testOverwriteFailureLeavesOriginalIntact() throws {
        let directory = try researchTestDirectory()
        let url = directory.appendingPathComponent("payload.json")
        let original = Data("original".utf8)
        try PrivateFile.write(original, to: url, durable: false)

        PrivateFileFaults.failBeforeRename = true
        defer { PrivateFileFaults.reset() }

        XCTAssertThrowsError(
            try PrivateFile.write(Data("replacement".utf8), to: url, durable: false)
        )
        XCTAssertEqual(try Data(contentsOf: url), original)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(PrivateFile.temporaryPrefix) }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testStoreWritesIndexMetaAndRecordsOwnerOnly() async throws {
        let directory = try researchTestDirectory()
        let store = ResearchStore(directoryURL: directory)
        let record = researchTestRecord(title: "权限", updatedAt: now)
        try await store.save(record)
        _ = await store.updateMeta { $0.legacyImportVersion = 1 }

        XCTAssertEqual(try mode(directory.appendingPathComponent("index.json")), 0o600)
        XCTAssertEqual(try mode(directory.appendingPathComponent("meta.json")), 0o600)
        XCTAssertEqual(
            try mode(
                directory
                    .appendingPathComponent("records", isDirectory: true)
                    .appendingPathComponent("\(record.id).json")
            ),
            0o600
        )
    }

    func testCacheFilesAreOwnerOnly() async throws {
        let directory = try researchTestDirectory()
        let cache = ResearchCacheStore(directoryURL: directory)
        await cache.store(Data("payload".utf8), kind: .pages, key: "u", now: now)
        let key = await cache.fileKey(kind: .pages, key: "u")
        let url = directory
            .appendingPathComponent(ResearchCacheKind.pages.rawValue, isDirectory: true)
            .appendingPathComponent(key + ".json")
        XCTAssertEqual(try mode(url), 0o600)
    }

    func testBootstrapTightensLegacyWorldReadableRecord() async throws {
        let directory = try researchTestDirectory()
        let records = directory.appendingPathComponent("records", isDirectory: true)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let record = researchTestRecord(title: "旧权限", updatedAt: now)
        let data = try JSONEncoder().encode(record)
        let url = records.appendingPathComponent("\(record.id).json")
        try PrivateFile.write(data, to: url, durable: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        let store = ResearchStore(directoryURL: directory)
        _ = await store.bootstrap()

        XCTAssertEqual(try mode(url), 0o600)
    }

    func testStaleTemporariesAreRemovedButUnknownHiddenFilesAreKept() throws {
        let directory = try researchTestDirectory()
        let stale = directory.appendingPathComponent(
            PrivateFile.temporaryPrefix + "stale"
        )
        let unrelated = directory.appendingPathComponent(".other-app-cache")
        try Data("x".utf8).write(to: stale)
        try Data("x".utf8).write(to: unrelated)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7_200)],
            ofItemAtPath: stale.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7_200)],
            ofItemAtPath: unrelated.path
        )

        let removed = PrivateFile.removeStaleTemporaries(
            in: directory,
            olderThan: now.addingTimeInterval(-3_600),
            now: now
        )

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testLedgerSurvivesTemporaryIOFailureWithoutResetting() throws {
        let directory = try researchTestDirectory()
        let url = directory.appendingPathComponent("ledger.json")
        let ledger = ResearchLedger(fileURL: url)
        XCTAssertTrue(ledger.reserve(.ai, origin: .manual, cap: 10, at: now))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: url.path
        )
        let unavailable = ResearchLedger(fileURL: url)
        let availability = unavailable.snapshot(at: now).availability
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        // Running as root can still read mode-000 files.
        if availability != .available {
            XCTAssertEqual(availability, .ioUnavailable)
        }

        // Recovery must not require clearing today's usage first.
        let recovered = ResearchLedger(fileURL: url)
        XCTAssertEqual(recovered.snapshot(at: now).availability, .available)
        XCTAssertEqual(recovered.used(.ai, at: now), 1)
    }

    func testEmptyLedgerSnapshotIsLoadingNotZero() {
        XCTAssertEqual(LedgerSnapshot.empty.availability, .loading)
    }
}
