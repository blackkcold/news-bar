import XCTest
@testable import NewsBar

final class SearchKeyStoreTests: XCTestCase {
    func testAccountNamesAreStableAndProviderScoped() {
        XCTAssertEqual(SearchKeyStore.account(for: .tavily), "search-key-tavily")
        XCTAssertEqual(SearchKeyStore.account(for: .firecrawl), "search-key-firecrawl")
        XCTAssertEqual(SearchKeyStore.account(for: .brave), "search-key-brave")
    }

    func testDeleteReportsEncryptedStoreWriteFailure() async throws {
        let directory = try researchTestDirectory()
        defer {
            PrivateFileFaults.reset()
            try? FileManager.default.removeItem(at: directory)
        }
        let account = SearchKeyStore.account(for: .tavily)
        let payload = EncryptedKeyStore.EncryptedPayload(
            version: EncryptedKeyStore.currentVersion,
            entries: [EncryptedKeyStore.Entry(account: account, nonce: Data([1]), ciphertext: Data([2]))]
        )
        try PrivateFile.write(
            JSONEncoder().encode(payload),
            to: directory.appendingPathComponent("apikeys.enc"),
            durable: false
        )
        let store = EncryptedKeyStore(directory: directory)
        PrivateFileFaults.failBeforeRename = true

        let result = await SearchKeyStore.delete(for: .tavily, store: store)

        XCTAssertFalse(result)
        let retained = await store.checkAPIKeyExistence(account: account)
        XCTAssertTrue(retained)
    }

    func testDeleteResultReportsVisibleCommitWithoutClaimingDurability() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarSearchKeyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            PrivateFileFaults.reset()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let saved = await SearchKeyStore.save("fictional-key", for: .tavily, store: store)
        XCTAssertTrue(saved)

        PrivateFileFaults.failAfterRename = true
        let result = await SearchKeyStore.deleteResult(for: .tavily, store: store)
        PrivateFileFaults.reset()

        XCTAssertEqual(result, .committedDurabilityUnknown)
        let retained = await SearchKeyStore.hasKey(for: .tavily, store: store)
        XCTAssertFalse(retained)
    }

    func testDeletePresentationDoesNotClaimSuccessForUncertainResults() {
        let committed = SearchKeyDeletionPolicy.decision(for: .committedDurabilityUnknown)
        XCTAssertEqual(committed.configured, false)
        XCTAssertEqual(committed.unverified, false)
        XCTAssertTrue(committed.retryAllowed)
        XCTAssertTrue(committed.isError)

        let unverified = SearchKeyDeletionPolicy.decision(for: .unverified)
        XCTAssertNil(unverified.configured)
        XCTAssertEqual(unverified.unverified, true)
        XCTAssertTrue(unverified.retryAllowed)
        XCTAssertTrue(unverified.isError)

        let failed = SearchKeyDeletionPolicy.decision(for: .notCommitted)
        XCTAssertNil(failed.configured)
        XCTAssertNil(failed.unverified)
        XCTAssertTrue(failed.retryAllowed)

        let durable = SearchKeyDeletionPolicy.decision(for: .durable)
        XCTAssertEqual(durable.configured, false)
        XCTAssertFalse(durable.retryAllowed)
        XCTAssertFalse(durable.isError)
    }

    func testSaveResultReportsVisibleCommitWithoutClaimingDurability() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarSearchKeySaveTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            PrivateFileFaults.reset()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let initial = await SearchKeyStore.save("fictional-old", for: .tavily, store: store)
        XCTAssertTrue(initial)

        PrivateFileFaults.failAfterRename = true
        let result = await SearchKeyStore.saveResult("fictional-new", for: .tavily, store: store)
        PrivateFileFaults.reset()

        XCTAssertEqual(result, .committedDurabilityUnknown)
        let stored = await store.readAPIKey(account: SearchKeyStore.account(for: .tavily))
        XCTAssertEqual(stored, "fictional-new")
    }

    func testSavePresentationDistinguishesUnverifiedFromNotCommitted() {
        let failed = SearchKeySavePolicy.decision(for: .notCommitted)
        XCTAssertNil(failed.configured)
        XCTAssertNil(failed.unverified)
        XCTAssertFalse(failed.clearInput)
        XCTAssertTrue(failed.isError)

        let unverified = SearchKeySavePolicy.decision(for: .unverified)
        XCTAssertNil(unverified.configured)
        XCTAssertEqual(unverified.unverified, true)
        XCTAssertFalse(unverified.clearInput)
        XCTAssertTrue(unverified.isError)

        let unsynced = SearchKeySavePolicy.decision(for: .committedDurabilityUnknown)
        XCTAssertEqual(unsynced.configured, true)
        XCTAssertEqual(unsynced.unverified, false)
        XCTAssertTrue(unsynced.clearInput)
        XCTAssertTrue(unsynced.retrySyncAllowed)
        XCTAssertTrue(unsynced.isError)

        let durable = SearchKeySavePolicy.decision(for: .durable)
        XCTAssertEqual(durable.configured, true)
        XCTAssertFalse(durable.retrySyncAllowed)
        XCTAssertFalse(durable.isError)
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

    func testExplicitFirecrawlDeletionPreventsInFlightLegacyMigrationAndFallback() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarSearchDeleteRaceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let writer = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let account = SearchKeyStore.account(for: .firecrawl)
        let result = await SearchKeyStore.migrateLegacyFirecrawlKey(
            legacy: "fictional-legacy", store: store,
            beforeStoreMutation: {
                let deletion = await writer.deleteAPIKeyResult(account: account)
                XCTAssertEqual(deletion, .durable)
            }
        )

        XCTAssertEqual(result, .notNeeded)
        let stored = await store.readAPIKeyResult(account: account)
        let resolved = await SearchKeyStore.key(for: .firecrawl, fallback: "fictional-legacy", store: store)
        XCTAssertEqual(stored, .missing)
        XCTAssertEqual(resolved, "")
    }

    func testFirecrawlDeletionAfterMigrationDoesNotResurrectLegacyOnRetry() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarSearchDeleteRaceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let first = await SearchKeyStore.migrateLegacyFirecrawlKey(legacy: "fictional-legacy", store: store)
        XCTAssertEqual(first, .migrated)
        let deletion = await SearchKeyStore.deleteResult(for: .firecrawl, store: store)
        XCTAssertEqual(deletion, .durable)
        let retry = await SearchKeyStore.migrateLegacyFirecrawlKey(legacy: "fictional-legacy", store: store)
        XCTAssertEqual(retry, .notNeeded)
        let stored = await store.readAPIKeyResult(account: SearchKeyStore.account(for: .firecrawl))
        XCTAssertEqual(stored, .missing)
    }

    func testFirecrawlNewKeyWorksWithoutRevivingLegacyAfterItsDeletion() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarSearchDeleteRaceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let deleted = await SearchKeyStore.deleteResult(for: .firecrawl, store: store)
        XCTAssertEqual(deleted, .durable)
        let saved = await SearchKeyStore.saveResult("fictional-new", for: .firecrawl, store: store)
        XCTAssertEqual(saved, .durable)
        let resolved = await SearchKeyStore.key(for: .firecrawl, fallback: "fictional-legacy", store: store)
        XCTAssertEqual(resolved, "fictional-new")
        let deletedAgain = await SearchKeyStore.deleteResult(for: .firecrawl, store: store)
        XCTAssertEqual(deletedAgain, .durable)
        let after = await SearchKeyStore.key(for: .firecrawl, fallback: "fictional-legacy", store: store)
        XCTAssertEqual(after, "")
    }

    func testFailedFirecrawlDeletionDoesNotSilentlyRevokeTheLegacyFallback() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarSearchDeleteRaceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            PrivateFileFaults.reset()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let seed = await store.saveAPIKey("fictional-seed", account: "fixture-seed")
        XCTAssertTrue(seed)
        PrivateFileFaults.failBeforeRename = true
        let result = await SearchKeyStore.deleteResult(for: .firecrawl, store: store)
        PrivateFileFaults.reset()

        XCTAssertEqual(result, .notCommitted)
        let resolved = await SearchKeyStore.key(for: .firecrawl, fallback: "fictional-legacy", store: store)
        XCTAssertEqual(resolved, "fictional-legacy")
    }

    func testVisibleUnsyncedFirecrawlDeletionBlocksLegacyWithoutDiscardingIt() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarSearchDeleteRaceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            PrivateFileFaults.reset()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let seed = await store.saveAPIKey("fictional-old", account: SearchKeyStore.account(for: .firecrawl))
        XCTAssertTrue(seed)
        PrivateFileFaults.failAfterRename = true
        let deletion = await SearchKeyStore.deleteResult(for: .firecrawl, store: store)
        let migration = await SearchKeyStore.migrateLegacyFirecrawlKey(legacy: "fictional-legacy", store: store)
        let resolved = await SearchKeyStore.key(for: .firecrawl, fallback: "fictional-legacy", store: store)
        PrivateFileFaults.reset()

        XCTAssertEqual(deletion, .committedDurabilityUnknown)
        XCTAssertEqual(migration, .durabilityUnknown)
        XCTAssertFalse(SearchKeyStore.shouldClearLegacy(current: "fictional-legacy", captured: "fictional-legacy", result: migration))
        XCTAssertEqual(resolved, "")
    }

    func testFirecrawlMigrationDoesNotOverwriteUnreadableEncryptedKey() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarSearchMigrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let account = SearchKeyStore.account(for: .firecrawl)
        let payload = EncryptedKeyStore.EncryptedPayload(
            version: EncryptedKeyStore.currentVersion,
            entries: [EncryptedKeyStore.Entry(account: account, nonce: Data([1]), ciphertext: Data([2]))]
        )
        let original = try JSONEncoder().encode(payload)
        let file = directory.appendingPathComponent("apikeys.enc")
        try PrivateFile.write(original, to: file, durable: false)
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let read = await store.readAPIKeyResult(account: account)
        XCTAssertEqual(read, .failed)

        let result = await SearchKeyStore.migrateLegacyFirecrawlKey(legacy: "fictional-legacy", store: store)
        let fallback = await SearchKeyStore.key(for: .firecrawl, fallback: "fictional-legacy", store: store)

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(fallback, "", "An unreadable encrypted entry must not activate the legacy key")
        XCTAssertEqual(try Data(contentsOf: file), original, "The unreadable encrypted entry must not be replaced")
        XCTAssertNil(defaults.object(forKey: "hasAIKey-\(account)"))
    }

    func testFirecrawlMigrationStillImportsWhenEncryptedKeyIsMissing() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarSearchMigrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)

        let result = await SearchKeyStore.migrateLegacyFirecrawlKey(legacy: " fictional-legacy ", store: store)

        XCTAssertEqual(result, .migrated)
        let stored = await store.readAPIKeyResult(account: SearchKeyStore.account(for: .firecrawl))
        XCTAssertEqual(stored, .found("fictional-legacy"))
    }

    func testFirecrawlMigrationStillPreservesExistingEncryptedKey() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarSearchMigrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let saved = await store.saveAPIKey("fictional-current", account: SearchKeyStore.account(for: .firecrawl))
        XCTAssertTrue(saved)

        let result = await SearchKeyStore.migrateLegacyFirecrawlKey(legacy: "fictional-legacy", store: store)

        XCTAssertEqual(result, .notNeeded)
        let stored = await store.readAPIKeyResult(account: SearchKeyStore.account(for: .firecrawl))
        XCTAssertEqual(stored, .found("fictional-current"))
    }

    func testFirecrawlMigrationDoesNotOverwriteKeySavedAfterInitialRead() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarSearchMigrationRaceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let migratingStore = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let writer = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let account = SearchKeyStore.account(for: .firecrawl)

        let result = await SearchKeyStore.migrateLegacyFirecrawlKey(
            legacy: "fictional-legacy", store: migratingStore
        ) {
            let saved = await writer.saveAPIKeyResult("fictional-new", account: account)
            XCTAssertEqual(saved, .durable)
        }

        XCTAssertEqual(result, .notNeeded)
        let stored = await migratingStore.readAPIKeyResult(account: account)
        XCTAssertEqual(stored, .found("fictional-new"))
    }

    func testFirecrawlMigrationDoesNotOverwriteUnreadableEntryCreatedAfterInitialRead() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarSearchMigrationRaceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let account = SearchKeyStore.account(for: .firecrawl)
        let payload = EncryptedKeyStore.EncryptedPayload(
            version: EncryptedKeyStore.currentVersion,
            entries: [EncryptedKeyStore.Entry(account: account, nonce: Data([1]), ciphertext: Data([2]))]
        )
        let original = try JSONEncoder().encode(payload)
        let file = directory.appendingPathComponent("apikeys.enc")

        let result = await SearchKeyStore.migrateLegacyFirecrawlKey(
            legacy: "fictional-legacy", store: store
        ) {
            do {
                try PrivateFile.write(original, to: file, durable: false)
            } catch {
                XCTFail("Could not prepare unreadable test entry: \(error)")
            }
        }

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testFirecrawlMigrationDoesNotTreatUnsyncedExistingKeyAsSafeToClearLegacy() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarSearchMigrationRaceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            PrivateFileFaults.reset()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let seed = await store.saveAPIKey("fictional-seed", account: "fixture-seed")
        XCTAssertTrue(seed)
        PrivateFileFaults.failAfterRename = true

        let first = await SearchKeyStore.migrateLegacyFirecrawlKey(legacy: "fictional-legacy", store: store)
        let retry = await SearchKeyStore.migrateLegacyFirecrawlKey(legacy: "fictional-legacy", store: store)
        XCTAssertEqual(first, .durabilityUnknown)
        XCTAssertEqual(retry, .durabilityUnknown, "A still-unsynced directory is not a durable existing key")

        PrivateFileFaults.reset()
        let syncedRetry = await SearchKeyStore.migrateLegacyFirecrawlKey(legacy: "fictional-legacy", store: store)
        XCTAssertEqual(syncedRetry, .notNeeded)
        let stored = await store.readAPIKeyResult(account: SearchKeyStore.account(for: .firecrawl))
        XCTAssertEqual(stored, .found("fictional-legacy"))
    }

    func testLegacyPlaintextIsClearedOnlyWhenUnchangedAndDurablyCovered() {
        let original = "fictional-legacy"
        XCTAssertTrue(SearchKeyStore.shouldClearLegacy(current: original, captured: original, result: .migrated))
        XCTAssertTrue(SearchKeyStore.shouldClearLegacy(current: original, captured: original, result: .notNeeded))
        XCTAssertFalse(SearchKeyStore.shouldClearLegacy(current: "fictional-new", captured: original, result: .migrated))
        XCTAssertFalse(SearchKeyStore.shouldClearLegacy(current: original, captured: original, result: .failed))
        XCTAssertFalse(SearchKeyStore.shouldClearLegacy(current: original, captured: original, result: .durabilityUnknown))
        XCTAssertFalse(SearchKeyStore.shouldClearLegacy(current: original, captured: original, result: .unverified))
    }

    func testFirecrawlMigrationReportsUnverifiedWriteWithoutClaimingFailureOrSuccess() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarSearchMigrationRaceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            PrivateFileFaults.reset()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let seed = await store.saveAPIKey("fictional-seed", account: "fixture-seed")
        XCTAssertTrue(seed)
        PrivateFileFaults.failVerificationAfterWrite = true
        let result = await SearchKeyStore.migrateLegacyFirecrawlKey(legacy: "fictional-legacy", store: store)
        PrivateFileFaults.reset()

        XCTAssertEqual(result, .unverified)
        let stored = await store.readAPIKeyResult(account: SearchKeyStore.account(for: .firecrawl))
        XCTAssertEqual(stored, .found("fictional-legacy"))
        XCTAssertFalse(SearchKeyStore.shouldClearLegacy(current: "fictional-legacy", captured: "fictional-legacy", result: result))
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
        let defaults = TestIsolation.defaults
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
        let defaults = TestIsolation.defaults
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
