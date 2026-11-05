import XCTest
@testable import NewsBar

final class EncryptedKeyStoreIsolationTests: XCTestCase {
    func testInjectedDefaultsControlTheStoreDebugGate() async throws {
        #if DEBUG
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarStoreIsolation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        defaults.set(true, forKey: "debugDisableEncryptedStore")
        let disabled = await store.saveAPIKeyResult("fictional-key", account: "fictional-account")
        XCTAssertEqual(disabled, .notCommitted)

        defaults.set(false, forKey: "debugDisableEncryptedStore")
        let enabled = await store.saveAPIKeyResult("fictional-key", account: "fictional-account")
        XCTAssertEqual(enabled, .durable)
        #endif
    }
}
