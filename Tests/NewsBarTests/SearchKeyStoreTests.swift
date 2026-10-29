import XCTest
@testable import NewsBar

final class SearchKeyStoreTests: XCTestCase {
    func testAccountNamesAreStableAndProviderScoped() {
        XCTAssertEqual(SearchKeyStore.account(for: .tavily), "search-key-tavily")
        XCTAssertEqual(SearchKeyStore.account(for: .firecrawl), "search-key-firecrawl")
        XCTAssertEqual(SearchKeyStore.account(for: .brave), "search-key-brave")
    }

    func testMigrationCopiesTrimmedLegacyKey() async {
        var saved: String?
        let result = await SearchKeyStore.migrateLegacyKey(
            legacy: "  fc-legacy  ",
            existing: ""
        ) { key in
            saved = key
            return true
        }

        XCTAssertEqual(result, .migrated)
        XCTAssertEqual(saved, "fc-legacy")
    }

    func testMigrationIsNoOpWithoutLegacyValue() async {
        var saveCalled = false
        let result = await SearchKeyStore.migrateLegacyKey(legacy: "   ", existing: "") { _ in
            saveCalled = true
            return true
        }

        XCTAssertEqual(result, .notNeeded)
        XCTAssertFalse(saveCalled)
    }

    func testMigrationDoesNotOverwriteExistingEncryptedKey() async {
        var saveCalled = false
        let result = await SearchKeyStore.migrateLegacyKey(
            legacy: "old-plaintext",
            existing: "current-encrypted"
        ) { _ in
            saveCalled = true
            return true
        }

        XCTAssertEqual(result, .notNeeded)
        XCTAssertFalse(saveCalled)
    }

    func testMigrationReportsFailureAndKeepsRetryableState() async {
        let result = await SearchKeyStore.migrateLegacyKey(
            legacy: "fc-legacy",
            existing: ""
        ) { _ in
            false
        }

        XCTAssertEqual(result, .failed)
    }

    func testProviderAuthModeMatchesProductPolicy() {
        // Firecrawl and Tavily both have documented keyless search routes;
        // the other providers are not contacted until a key exists.
        XCTAssertEqual(SearchProviderID.tavily.authMode, .optionalKey)
        XCTAssertEqual(SearchProviderID.firecrawl.authMode, .optionalKey)
        XCTAssertEqual(SearchProviderID.tinyfish.authMode, .requiredKey)
        XCTAssertEqual(SearchProviderID.exa.authMode, .requiredKey)
        XCTAssertEqual(SearchProviderID.parallel.authMode, .requiredKey)
        XCTAssertEqual(SearchProviderID.brave.authMode, .requiredKey)
        XCTAssertEqual(
            SearchProviderID.failoverOrder,
            [.tavily, .firecrawl, .tinyfish, .exa, .parallel, .brave]
        )
    }

    @MainActor
    func testWrapperMigrationClearsPlaintextAndStoresEncryptedKey() async throws {
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: "firecrawlAPIKey")
        defer {
            if let original {
                defaults.set(original, forKey: "firecrawlAPIKey")
            } else {
                defaults.removeObject(forKey: "firecrawlAPIKey")
            }
        }
        defaults.set("  fc-legacy  ", forKey: "firecrawlAPIKey")
        let settings = AppSettings()
        let store = EncryptedKeyStore(directory: try researchTestDirectory())

        let result = await SearchKeyStore.migrateLegacyFirecrawlKey(
            settings: settings,
            store: store
        )

        XCTAssertEqual(result, .migrated)
        XCTAssertTrue(settings.firecrawlAPIKey.isEmpty)
        XCTAssertNil(defaults.string(forKey: "firecrawlAPIKey"))
        let stored = await store.readAPIKey(account: SearchKeyStore.account(for: .firecrawl))
        XCTAssertEqual(stored, "fc-legacy")
    }

    @MainActor
    func testWrapperMigrationKeepsPlaintextWhenStoreCannotWrite() async throws {
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: "firecrawlAPIKey")
        defer {
            if let original {
                defaults.set(original, forKey: "firecrawlAPIKey")
            } else {
                defaults.removeObject(forKey: "firecrawlAPIKey")
            }
        }
        defaults.set("fc-legacy", forKey: "firecrawlAPIKey")
        let settings = AppSettings()
        let broken = EncryptedKeyStore(
            directory: URL(fileURLWithPath: "/dev/null/newsbar-\(UUID().uuidString)")
        )

        let result = await SearchKeyStore.migrateLegacyFirecrawlKey(
            settings: settings,
            store: broken
        )

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(settings.firecrawlAPIKey, "fc-legacy")
        XCTAssertEqual(defaults.string(forKey: "firecrawlAPIKey"), "fc-legacy")
    }
}
