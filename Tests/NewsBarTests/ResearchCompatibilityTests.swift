import XCTest
@testable import NewsBar

final class ResearchCompatibilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func recordURL(_ directory: URL, id: String) -> URL {
        directory
            .appendingPathComponent("records", isDirectory: true)
            .appendingPathComponent("\(id).json")
    }

    private func minimalJSON(id: String = "A") -> Data {
        Data("""
        {"id":"\(id)","topicKey":"k","origin":"manual","topic":"标题",
         "seed":{"title":"标题","source":{"type":"weibo"}},
         "createdAt":715000000,"status":"ready"}
        """.utf8)
    }

    func testMissingDisplayFieldsUseDurableFallbacksNotNow() throws {
        let decoded = try JSONDecoder().decode(ResearchRecord.self, from: minimalJSON())
        let createdAt = Date(timeIntervalSinceReferenceDate: 715_000_000)
        XCTAssertEqual(decoded.createdAt, createdAt)
        XCTAssertEqual(decoded.updatedAt, createdAt)
        XCTAssertEqual(decoded.lastSeenAt, createdAt)
        XCTAssertEqual(decoded.lastAccessedAt, createdAt)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertFalse(decoded.isRead)
        XCTAssertFalse(decoded.isPinned)
        XCTAssertNil(decoded.report)
        XCTAssertEqual(decoded.run.origin, .manual)
    }

    func testMissingAuthorityFieldIsRejected() {
        let json = Data(#"{"topicKey":"k","origin":"manual","topic":"t","seed":{"title":"t","source":{"type":"weibo"}},"createdAt":715000000,"status":"ready"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ResearchRecord.self, from: json))
    }

    func testNewWriteStatesSchemaVersion() throws {
        var record = researchTestRecord(title: "版本", updatedAt: now)
        record.schemaVersion = ResearchRecord.currentSchemaVersion
        let data = try JSONEncoder().encode(record)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["schemaVersion"] as? Int, ResearchRecord.currentSchemaVersion)
    }

    func testEvidenceDefaultsNeverUpgradeTrust() throws {
        let json = Data("""
        {"id":"E1","url":"https://weibo.com/a"}
        """.utf8)
        let item = try JSONDecoder().decode(EvidenceItem.self, from: json)
        XCTAssertFalse(item.quoteVerified)
        XCTAssertEqual(item.stance, .unclear)
        XCTAssertNotEqual(item.tier, .primary)
        XCTAssertEqual(item.canonicalURL, "https://weibo.com/a")
        XCTAssertNotEqual(item.fetchedAt, Date())
    }

    func testEvidenceWrongTypeIsNotTreatedAsMissing() {
        let json = Data(#"{"id":"E1","url":"https://example.com/a","stance":42}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(EvidenceItem.self, from: json))
    }

    func testBrokenEvidenceReferenceDowngradesConfidence() {
        let report = BurstResearch(
            summary: "s",
            evidence: [],
            verification: VerificationReport(
                verdict: .confirmed,
                strength: 4,
                independentSources: 3,
                claims: [ClaimCheck(claim: "x", status: .supports, evidenceIDs: ["E9"], note: "")],
                conflicts: [],
                missing: []
            )
        )
        var record = researchTestRecord(title: "降级", updatedAt: now, report: report)
        record.status = .ready

        let normalized = record.normalizedForRead()
        XCTAssertEqual(normalized.status, .partial)
        XCTAssertEqual(normalized.report?.verification?.verdict, .unverified)
        XCTAssertEqual(normalized.report?.verification?.strength, 0)
        XCTAssertEqual(normalized.report?.verification?.independentSources, 0)
        XCTAssertTrue(
            normalized.report?.limitations.contains(
                L10n.string("research.limitation.brokenEvidence")
            ) == true
        )
        // Readable content is preserved.
        XCTAssertEqual(normalized.report?.summary, "s")
    }

    func testFutureRecordIsReadOnlyAndBytesArePreserved() async throws {
        let directory = try researchTestDirectory()
        let store = ResearchStore(directoryURL: directory)
        try await store.bootstrap()

        var record = researchTestRecord(title: "未来版本", updatedAt: now)
        record.schemaVersion = 99
        let original = try JSONEncoder().encode(record)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("records", isDirectory: true),
            withIntermediateDirectories: true
        )
        let url = recordURL(directory, id: record.id)
        try original.write(to: url)

        let reloaded = ResearchStore(directoryURL: directory)
        let bootstrap = await reloaded.bootstrap()
        XCTAssertEqual(bootstrap.unsupportedVersionIDs, [record.id])
        let entry = await reloaded.index().first
        XCTAssertEqual(entry?.issue, .unsupportedVersion)

        let loaded = await reloaded.record(id: record.id)
        XCTAssertEqual(loaded?.loadIssue, .unsupportedVersion)
        XCTAssertEqual(loaded?.status, .corrupt)

        await reloaded.touch(id: record.id, at: now)
        XCTAssertEqual(try Data(contentsOf: url), original)

        do {
            try await reloaded.save(record)
            XCTFail("a future-version record must not be writable")
        } catch {
            XCTAssertEqual(error as? ResearchStoreError, .readOnlyRecord)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testFutureRecordStaysReadOnlyAfterIndexRebuildAndReload() async throws {
        let directory = try researchTestDirectory()
        let store = ResearchStore(directoryURL: directory)
        try await store.bootstrap()

        var record = researchTestRecord(title: "未来版本二次加载", updatedAt: now)
        record.schemaVersion = 99
        let original = try JSONEncoder().encode(record)
        let records = directory.appendingPathComponent("records", isDirectory: true)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let url = recordURL(directory, id: record.id)
        try original.write(to: url)

        // First load rebuilds the index; the projection carries the issue but
        // the placeholder schema version is not authoritative.
        let first = ResearchStore(directoryURL: directory)
        let rebuilt = await first.bootstrap()
        XCTAssertTrue(rebuilt.rebuiltIndex)
        XCTAssertEqual(rebuilt.unsupportedVersionIDs, [record.id])

        // Second load trusts that index. The write gate must be restored from
        // the projection even though the version probe is skipped.
        let second = ResearchStore(directoryURL: directory)
        let trusted = await second.bootstrap()
        XCTAssertFalse(trusted.rebuiltIndex)
        XCTAssertEqual(trusted.unsupportedVersionIDs, [record.id])
        let loaded = await second.record(id: record.id)
        XCTAssertEqual(loaded?.loadIssue, .unsupportedVersion)

        await second.touch(id: record.id, at: now)
        do {
            try await second.save(try XCTUnwrap(loaded))
            XCTFail("a future-version record must stay read-only after reload")
        } catch {
            XCTAssertEqual(error as? ResearchStoreError, .readOnlyRecord)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testCorruptPlaceholderCannotOverwriteOriginal() async throws {
        let directory = try researchTestDirectory()
        let store = ResearchStore(directoryURL: directory)
        try await store.bootstrap()
        let id = UUID().uuidString
        let original = Data("not-json".utf8)
        let records = directory.appendingPathComponent("records", isDirectory: true)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let url = recordURL(directory, id: id)
        try original.write(to: url)

        let reloaded = ResearchStore(directoryURL: directory)
        let placeholder = await reloaded.record(id: id)
        XCTAssertEqual(placeholder?.status, .corrupt)
        XCTAssertEqual(placeholder?.loadIssue, .corrupt)

        do {
            try await reloaded.save(try XCTUnwrap(placeholder))
            XCTFail("a corrupt placeholder must not be writable")
        } catch {
            XCTAssertEqual(error as? ResearchStoreError, .readOnlyRecord)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testFutureMetaIsPreservedAndBlocksUpdates() async throws {
        let directory = try researchTestDirectory()
        let store = ResearchStore(directoryURL: directory)
        try await store.bootstrap()
        let metaURL = directory.appendingPathComponent("meta.json")
        let original = Data(#"{"version":9,"legacyImportVersion":1,"future":true}"#.utf8)
        try original.write(to: metaURL)

        let reloaded = ResearchStore(directoryURL: directory)
        let availability = await reloaded.metaAvailability()
        XCTAssertEqual(availability, .unsupportedVersion)
        let updated = await reloaded.updateMeta { $0.legacyImportVersion = 0 }
        XCTAssertFalse(updated)
        XCTAssertEqual(try Data(contentsOf: metaURL), original)
    }

    func testMetaUnavailableDoesNotBreakRecordWrites() async throws {
        let directory = try researchTestDirectory()
        let store = ResearchStore(directoryURL: directory)
        try await store.bootstrap()
        try Data("broken".utf8).write(to: directory.appendingPathComponent("meta.json"))

        let reloaded = ResearchStore(directoryURL: directory)
        let availability = await reloaded.metaAvailability()
        XCTAssertEqual(availability, .corrupt)
        let record = researchTestRecord(title: "仍可写", updatedAt: now)
        try await reloaded.save(record)
        let stored = await reloaded.record(id: record.id)
        XCTAssertEqual(stored?.topic, "仍可写")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("meta.json")), Data("broken".utf8))
    }
}
