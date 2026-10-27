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

    func testProviderRequiresKeyMatchesProductPolicy() {
        XCTAssertTrue(SearchProviderID.tavily.requiresAPIKey)
        XCTAssertFalse(SearchProviderID.firecrawl.requiresAPIKey)
        XCTAssertTrue(SearchProviderID.brave.requiresAPIKey)
    }
}
