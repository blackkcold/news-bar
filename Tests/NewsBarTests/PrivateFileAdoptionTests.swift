import XCTest
@testable import NewsBar

/// Verifies that the personal-data writers that moved onto `PrivateFile`
/// create owner-only files from the first write, not after a chmod.
final class PrivateFileAdoptionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func mode(_ url: URL) throws -> Int {
        let value = try FileManager.default
            .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return value?.intValue ?? -1
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NewsBarPrivateFile-\(UUID().uuidString)", isDirectory: true)
    }

    func testTranslationCacheFileIsOwnerOnly() async throws {
        let directory = temporaryDirectory()
        let store = TranslationCacheStore(cacheDirectory: directory)

        await store.saveTranslation("Title", for: "标题", targetLang: "en")

        let url = directory.appendingPathComponent("en|标题.json")
        XCTAssertEqual(try mode(directory), 0o700)
        XCTAssertEqual(try mode(url), 0o600)
    }

    func testAISummaryCacheFileIsOwnerOnly() async throws {
        let directory = temporaryDirectory()
        let url = directory.appendingPathComponent("ai-summary-zh.json")
        let store = AISummaryCacheStore(fileURL: url)
        let entry = AISummaryCacheEntry(
            summary: "摘要",
            items: [],
            contentHash: "content",
            trendHistoryHash: "trend",
            generatedAt: now,
            trendItemCount: 0
        )

        await store.save(entry)

        XCTAssertEqual(try mode(directory), 0o700)
        XCTAssertEqual(try mode(url), 0o600)
    }

    func testReaderHistoryFileIsOwnerOnly() async throws {
        let directory = temporaryDirectory()
        let url = directory.appendingPathComponent("history.json")
        let persistence = FileReaderHistoryPersistence(fileURL: url)

        try await persistence.save(Data("{}".utf8))

        XCTAssertEqual(try mode(directory), 0o700)
        XCTAssertEqual(try mode(url), 0o600)
    }

    func testRequestBudgetFileIsOwnerOnly() throws {
        let directory = temporaryDirectory()
        let url = directory.appendingPathComponent("budget.json")
        let budget = PersistentRequestBudget(fileURL: url)

        XCTAssertTrue(budget.reserve(cap: 5, at: now))

        XCTAssertEqual(try mode(directory), 0o700)
        XCTAssertEqual(try mode(url), 0o600)
    }

    func testEncryptedKeyStoreAndMachineUUIDAreOwnerOnly() async throws {
        let account = "test-private-file-\(UUID().uuidString)"
        let store = EncryptedKeyStore()

        let saved = await store.saveAPIKey("sk-test-private", account: account)
        XCTAssertTrue(saved)
        defer {
            let cleanup = DispatchSemaphore(value: 0)
            Task {
                await store.deleteAPIKey(account: account)
                cleanup.signal()
            }
            cleanup.wait()
        }

        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.newsbar")

        XCTAssertEqual(try mode(directory), 0o700)
        XCTAssertEqual(try mode(directory.appendingPathComponent("apikeys.enc")), 0o600)
        XCTAssertEqual(try mode(directory.appendingPathComponent(".machine-uuid")), 0o600)
    }

    func testReadingLegacyWorldReadableTranslationTightensIt() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let store = TranslationCacheStore(cacheDirectory: directory)
        let url = directory.appendingPathComponent("en|Legacy.json")
        let entry = """
        {"translated":"Legacy","timestamp":0}
        """
        try Data(entry.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: url.path
        )

        let cached = await store.cachedTranslation(for: "Legacy", targetLang: "en")

        XCTAssertEqual(cached, "Legacy")
        XCTAssertEqual(try mode(url), 0o600)
    }
}
