import XCTest
@testable import NewsBar

private actor KeyStoreTestStartGate {
    private let expected: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expected: Int) {
        self.expected = expected
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if waiters.count == expected {
                let ready = waiters
                waiters.removeAll()
                ready.forEach { $0.resume() }
            }
        }
    }
}

private actor KeyStoreWriteProbe {
    private(set) var result: Bool?

    func record(_ result: Bool) {
        self.result = result
    }
}

final class EncryptedKeyStoreTests: XCTestCase {

    var store: EncryptedKeyStore!
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Isolated store: these tests must never read or write the real
        // encrypted credentials file, which holds the user's actual keys.
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewsBarKeyStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = EncryptedKeyStore(directory: directory)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: - 基本 CRUD

    func testSaveAndRead_RoundTrip_Success() async {
        let account = "test-account-\(UUID().uuidString)"
        let key = "sk-test-key-12345"
        let saved = await store.saveAPIKey(key, account: account)
        XCTAssertTrue(saved)
        let read = await store.readAPIKey(account: account)
        XCTAssertEqual(read, key)
        await store.deleteAPIKey(account: account)
    }

    func testRead_NonExistent_ReturnsNil() async {
        let read = await store.readAPIKey(account: "non-existent-\(UUID().uuidString)")
        XCTAssertNil(read)
    }

    func testReadResultDistinguishesAbsentEntryFromUnreadableStore() async throws {
        let account = "test-read-state-\(UUID().uuidString)"
        let missing = await store.readAPIKeyResult(account: account)
        XCTAssertEqual(missing, .missing)

        try Data("not an encrypted payload".utf8)
            .write(to: directory.appendingPathComponent("apikeys.enc"))
        let unreadable = await store.readAPIKeyResult(account: account)

        XCTAssertEqual(unreadable, .failed)
    }

    func testDelete_RemovesEntry() async {
        let account = "test-delete-\(UUID().uuidString)"
        _ = await store.saveAPIKey("key-to-delete", account: account)
        let beforeDelete = await store.readAPIKey(account: account)
        XCTAssertNotNil(beforeDelete)
        await store.deleteAPIKey(account: account)
        let afterDelete = await store.readAPIKey(account: account)
        XCTAssertNil(afterDelete)
    }

    func testDeleteWriteFailurePreservesStoredKeyAndMetadata() async {
        let provider = "test-delete-failure-\(UUID().uuidString)"
        let account = "ai-key-\(provider)"
        let flag = "hasAIKey-\(account)"
        let providerFlag = "hasAIKey-\(provider)"
        let timestamp = "apiKeyLastSaved-\(account)"
        let defaults = TestIsolation.defaults
        defer {
            PrivateFileFaults.reset()
            defaults.removeObject(forKey: flag)
            defaults.removeObject(forKey: providerFlag)
            defaults.removeObject(forKey: timestamp)
        }

        guard await store.saveAPIKey("test-key", account: account) else {
            XCTFail("Could not create the temporary test credential")
            return
        }
        let savedAt = defaults.double(forKey: timestamp)
        XCTAssertGreaterThan(savedAt, 0)

        PrivateFileFaults.failBeforeRename = true
        let deleted = await store.deleteAPIKey(account: account)
        PrivateFileFaults.reset()

        XCTAssertFalse(deleted)
        let retained = await store.readAPIKey(account: account)
        XCTAssertEqual(retained, "test-key")
        XCTAssertTrue(defaults.bool(forKey: flag))
        XCTAssertTrue(defaults.bool(forKey: providerFlag))
        XCTAssertEqual(defaults.double(forKey: timestamp), savedAt)
    }

    func testDeletingMissingEntryClearsStaleMetadata() async {
        let provider = "test-delete-missing-\(UUID().uuidString)"
        let account = "ai-key-\(provider)"
        let flag = "hasAIKey-\(account)"
        let providerFlag = "hasAIKey-\(provider)"
        let timestamp = "apiKeyLastSaved-\(account)"
        let defaults = TestIsolation.defaults
        defer {
            defaults.removeObject(forKey: flag)
            defaults.removeObject(forKey: providerFlag)
            defaults.removeObject(forKey: timestamp)
        }
        defaults.set(true, forKey: flag)
        defaults.set(true, forKey: providerFlag)
        defaults.set(123.0, forKey: timestamp)

        let deleted = await store.deleteAPIKey(account: account)

        XCTAssertTrue(deleted)
        XCTAssertNil(defaults.object(forKey: flag))
        XCTAssertNil(defaults.object(forKey: providerFlag))
        XCTAssertNil(defaults.object(forKey: timestamp))
    }

    func testDeleteAfterRenameReportsVisibleCommitWithUnknownDurability() async {
        let account = "test-delete-post-rename-\(UUID().uuidString)"
        let defaults = TestIsolation.defaults
        defer {
            PrivateFileFaults.reset()
            defaults.removeObject(forKey: "hasAIKey-\(account)")
            defaults.removeObject(forKey: "apiKeyLastSaved-\(account)")
        }
        let saved = await store.saveAPIKey("fictional-key", account: account)
        XCTAssertTrue(saved)

        PrivateFileFaults.failAfterRename = true
        let outcome = await store.deleteAPIKeyResult(account: account)
        PrivateFileFaults.reset()

        XCTAssertEqual(outcome, .committedDurabilityUnknown)
        let retained = await store.readAPIKey(account: account)
        XCTAssertNil(retained)
        XCTAssertNil(defaults.object(forKey: "hasAIKey-\(account)"))
        XCTAssertNil(defaults.object(forKey: "apiKeyLastSaved-\(account)"))
    }

    func testRetryCannotClaimDurableDeletionWhileDirectorySyncStillFails() async {
        let account = "test-retry-post-rename-\(UUID().uuidString)"
        defer {
            PrivateFileFaults.reset()
            TestIsolation.defaults.removeObject(forKey: "hasAIKey-\(account)")
            TestIsolation.defaults.removeObject(forKey: "apiKeyLastSaved-\(account)")
        }
        let saved = await store.saveAPIKey("fictional-key", account: account)
        XCTAssertTrue(saved)
        PrivateFileFaults.failAfterRename = true
        let first = await store.deleteAPIKeyResult(account: account)
        XCTAssertEqual(first, .committedDurabilityUnknown)

        let retry = await store.deleteAPIKeyResult(account: account)
        XCTAssertEqual(retry, .committedDurabilityUnknown)

        PrivateFileFaults.reset()
        let durableRetry = await store.deleteAPIKeyResult(account: account)
        XCTAssertEqual(durableRetry, .durable)
    }

    func testSaveAfterRenameReportsVisibleCommitWithUnknownDurability() async {
        let account = "test-save-post-rename-\(UUID().uuidString)"
        let defaults = TestIsolation.defaults
        defer {
            PrivateFileFaults.reset()
            defaults.removeObject(forKey: "hasAIKey-\(account)")
            defaults.removeObject(forKey: "apiKeyLastSaved-\(account)")
        }
        let saved = await store.saveAPIKey("old-key", account: account)
        XCTAssertTrue(saved)
        defaults.removeObject(forKey: "hasAIKey-\(account)")
        defaults.removeObject(forKey: "apiKeyLastSaved-\(account)")

        PrivateFileFaults.failAfterRename = true
        let outcome = await store.saveAPIKeyResult("new-key", account: account)
        PrivateFileFaults.reset()

        XCTAssertEqual(outcome, .committedDurabilityUnknown)
        let value = await store.readAPIKey(account: account)
        XCTAssertEqual(value, "new-key")
        XCTAssertTrue(defaults.bool(forKey: "hasAIKey-\(account)"))
        XCTAssertGreaterThan(defaults.double(forKey: "apiKeyLastSaved-\(account)"), 0)
    }

    func testDeleteAfterReadbackFailureReportsUnverifiedRatherThanNotCommitted() async {
        let account = "test-unverified-delete-\(UUID().uuidString)"
        let defaults = TestIsolation.defaults
        defer {
            PrivateFileFaults.reset()
            defaults.removeObject(forKey: "hasAIKey-\(account)")
            defaults.removeObject(forKey: "apiKeyLastSaved-\(account)")
        }
        let saved = await store.saveAPIKey("fictional-key", account: account)
        XCTAssertTrue(saved)

        PrivateFileFaults.failVerificationAfterWrite = true
        let outcome = await store.deleteAPIKeyResult(account: account)
        PrivateFileFaults.reset()

        XCTAssertEqual(outcome, .unverified)
        let retained = await store.readAPIKey(account: account)
        XCTAssertNil(retained, "The injected error occurs after the replacement")
        XCTAssertTrue(defaults.bool(forKey: "hasAIKey-\(account)"), "Do not change metadata when the result is unverified")
    }

    func testRemovingCustomProviderCredentialsKeepsOtherAccountsAndLegacyReference() async throws {
        let account = "custom:test-\(UUID().uuidString)"
        let referenceAccount = "one-password-ref.\(account)"
        let other = "test-other-\(UUID().uuidString)"
        let defaults = TestIsolation.defaults
        defer {
            for name in [account, referenceAccount, other] {
                defaults.removeObject(forKey: "hasAIKey-\(name)")
                defaults.removeObject(forKey: "apiKeyLastSaved-\(name)")
            }
        }

        let keySaved = await store.saveAPIKey("fictional-key", account: account)
        let referenceSaved = await store.saveOnePasswordRef("op://test/provider/key", account: account)
        let otherSaved = await store.saveAPIKey("fictional-other", account: other)
        XCTAssertTrue(keySaved && referenceSaved && otherSaved)

        // Add a fictional legacy reference directly to the isolated fixture.
        // Calling saveOnePasswordRef() here would write real, unscoped defaults.
        let path = directory.appendingPathComponent("apikeys.enc")
        var payload = try JSONDecoder().decode(EncryptedKeyStore.EncryptedPayload.self, from: Data(contentsOf: path))
        let otherEntry = try XCTUnwrap(payload.entries.first { $0.account == other })
        payload.entries.append(.init(account: "one-password-ref", nonce: otherEntry.nonce, ciphertext: otherEntry.ciphertext))
        try JSONEncoder().encode(payload).write(to: path)

        let removed = await store.deleteCustomProviderCredentials(account: account)

        XCTAssertTrue(removed)
        let removedKey = await store.readAPIKey(account: account)
        let removedReference = await store.readAPIKey(account: referenceAccount)
        let retainedOther = await store.readAPIKey(account: other)
        let retainedLegacy = await store.readOnePasswordRef()
        XCTAssertNil(removedKey)
        XCTAssertNil(removedReference)
        XCTAssertEqual(retainedOther, "fictional-other")
        XCTAssertEqual(retainedLegacy, "fictional-other")
        for name in [account, referenceAccount] {
            XCTAssertNil(defaults.object(forKey: "hasAIKey-\(name)"))
            XCTAssertNil(defaults.object(forKey: "apiKeyLastSaved-\(name)"))
        }
    }

    func testRemovingCustomProviderCredentialsBeforeRenameFailureKeepsBothEntries() async {
        let account = "custom:test-\(UUID().uuidString)"
        let referenceAccount = "one-password-ref.\(account)"
        let defaults = TestIsolation.defaults
        defer {
            PrivateFileFaults.reset()
            for name in [account, referenceAccount] {
                defaults.removeObject(forKey: "hasAIKey-\(name)")
                defaults.removeObject(forKey: "apiKeyLastSaved-\(name)")
            }
        }

        let keySaved = await store.saveAPIKey("fictional-key", account: account)
        let referenceSaved = await store.saveOnePasswordRef("op://test/provider/key", account: account)
        XCTAssertTrue(keySaved && referenceSaved)
        let keyTimestamp = defaults.double(forKey: "apiKeyLastSaved-\(account)")
        let referenceTimestamp = defaults.double(forKey: "apiKeyLastSaved-\(referenceAccount)")

        PrivateFileFaults.failBeforeRename = true
        let removed = await store.deleteCustomProviderCredentials(account: account)
        PrivateFileFaults.reset()

        XCTAssertFalse(removed)
        let key = await store.readBoundCustomKeyResult(account: account, endpointIdentity: "endpoint-A")
        let reference = await store.readBoundCustomReferenceResult(account: account, endpointIdentity: "endpoint-A")
        XCTAssertEqual(key, .unbound)
        XCTAssertEqual(reference, .unbound)
        XCTAssertTrue(defaults.bool(forKey: "hasAIKey-\(account)"))
        XCTAssertTrue(defaults.bool(forKey: "hasAIKey-\(referenceAccount)"))
        XCTAssertEqual(defaults.double(forKey: "apiKeyLastSaved-\(account)"), keyTimestamp)
        XCTAssertEqual(defaults.double(forKey: "apiKeyLastSaved-\(referenceAccount)"), referenceTimestamp)
    }

    func testLateWritesFromAnotherStoreCannotRestoreRemovedProvider() async {
        let account = "custom:test-\(UUID().uuidString)"
        let referenceAccount = "one-password-ref.\(account)"
        defer {
            for name in [account, referenceAccount] {
                TestIsolation.defaults.removeObject(forKey: "hasAIKey-\(name)")
                TestIsolation.defaults.removeObject(forKey: "apiKeyLastSaved-\(name)")
            }
        }
        let writer = EncryptedKeyStore(directory: directory)
        let initial = await writer.saveAPIKey("fictional-key", account: account)
        XCTAssertTrue(initial)
        let removed = await store.deleteCustomProviderCredentials(account: account)
        XCTAssertTrue(removed)

        // These writes model tasks started before removal whose disk I/O
        // reaches a different store instance after removal has completed.
        let lateKey = await writer.saveAPIKey("late-key", account: account)
        let lateReference = await writer.saveOnePasswordRef("op://test/late/key", account: account)

        XCTAssertFalse(lateKey)
        XCTAssertFalse(lateReference)
        let key = await store.readAPIKey(account: account)
        let reference = await store.readAPIKey(account: referenceAccount)
        XCTAssertNil(key)
        XCTAssertNil(reference)
    }

    func testRestoredProviderAcceptsNewGenerationButRejectsOldWritesAndDeletes() async throws {
        let account = "custom:test-\(UUID().uuidString)"
        let referenceAccount = "one-password-ref.\(account)"
        defer {
            for name in [account, referenceAccount] {
                TestIsolation.defaults.removeObject(forKey: "hasAIKey-\(name)")
                TestIsolation.defaults.removeObject(forKey: "apiKeyLastSaved-\(name)")
            }
        }
        let oldWriter = EncryptedKeyStore(directory: directory)
        let initial = await oldWriter.saveAPIKey("old-key", account: account)
        XCTAssertTrue(initial)
        let removed = await store.deleteCustomProviderCredentials(account: account)
        XCTAssertTrue(removed)

        let observedRevocation = await store.customProviderRevocationGeneration(account: account)
        let revocation = try XCTUnwrap(observedRevocation)
        let restoredGeneration = await store.reactivateCustomProviderCredentials(
            account: account, matchingRevocation: revocation
        )
        let generation = try XCTUnwrap(restoredGeneration)
        let newKey = await store.saveAPIKey("new-key", account: account, customProviderGeneration: generation)
        let newReference = await store.saveOnePasswordRef(
            "op://test/new/key", account: account, customProviderGeneration: generation
        )
        XCTAssertTrue(newKey && newReference)

        let staleKey = await oldWriter.saveAPIKey("stale-key", account: account)
        let staleReference = await oldWriter.saveOnePasswordRef("op://test/old/key", account: account)
        await oldWriter.deleteOnePasswordRef(account: account)
        XCTAssertFalse(staleKey)
        XCTAssertFalse(staleReference)
        let retainedKey = await store.readBoundCustomKeyResult(account: account, endpointIdentity: "endpoint-A")
        let retainedReference = await store.readBoundCustomReferenceResult(account: account, endpointIdentity: "endpoint-A")
        XCTAssertEqual(retainedKey, .unbound)
        XCTAssertEqual(retainedReference, .unbound)
    }

    func testOldRecoveryRequestCannotReactivateProviderAfterANewerRemoval() async throws {
        let account = "custom:test-\(UUID().uuidString)"
        let firstRemoval = await store.deleteCustomProviderCredentials(account: account)
        XCTAssertTrue(firstRemoval)
        let observed = await store.customProviderRevocationGeneration(account: account)
        let oldRevocation = try XCTUnwrap(observed)
        let previousState = EncryptedKeyStore.CustomProviderCredentialState(generation: oldRevocation, revoked: true)
        let secondRemoval = await store.deleteCustomProviderCredentials(account: account, expectedState: previousState)
        XCTAssertTrue(secondRemoval)

        let restored = await store.reactivateCustomProviderCredentials(
            account: account, matchingRevocation: oldRevocation
        )

        XCTAssertNil(restored)
        let stale = await store.saveAPIKey("late-key", account: account)
        XCTAssertFalse(stale)
    }

    // MARK: - 多 account

    func testSave_MultipleAccounts_AllReadable() async {
        let acc1 = "test-multi-1-\(UUID().uuidString)"
        let acc2 = "test-multi-2-\(UUID().uuidString)"
        _ = await store.saveAPIKey("key-one", account: acc1)
        _ = await store.saveAPIKey("key-two", account: acc2)
        let read1 = await store.readAPIKey(account: acc1)
        let read2 = await store.readAPIKey(account: acc2)
        XCTAssertEqual(read1, "key-one")
        XCTAssertEqual(read2, "key-two")
        await store.deleteAPIKey(account: acc1)
        await store.deleteAPIKey(account: acc2)
    }

    func testDelete_OneAccount_OthersPreserved() async {
        let acc1 = "test-preserve-1-\(UUID().uuidString)"
        let acc2 = "test-preserve-2-\(UUID().uuidString)"
        _ = await store.saveAPIKey("key-a", account: acc1)
        _ = await store.saveAPIKey("key-b", account: acc2)
        await store.deleteAPIKey(account: acc1)
        let read1 = await store.readAPIKey(account: acc1)
        let read2 = await store.readAPIKey(account: acc2)
        XCTAssertNil(read1)
        XCTAssertEqual(read2, "key-b")
        await store.deleteAPIKey(account: acc2)
    }

    // MARK: - Nonce 唯一性

    func testSave_SameKeySameAccount_MultipleWrites_AllReadable() async {
        let account = "test-overwrite-\(UUID().uuidString)"
        for i in 0..<5 {
            let key = "sk-key-v\(i)"
            _ = await store.saveAPIKey(key, account: account)
        }
        let read = await store.readAPIKey(account: account)
        XCTAssertEqual(read, "sk-key-v4")
        await store.deleteAPIKey(account: account)
    }

    // MARK: - 存在性检查

    func testCheckExistence_Found_True() async {
        let account = "test-exist-\(UUID().uuidString)"
        _ = await store.saveAPIKey("some-key", account: account)
        let exists = await store.checkAPIKeyExistence(account: account)
        XCTAssertTrue(exists)
        await store.deleteAPIKey(account: account)
    }

    func testCheckExistence_NotFound_False() async {
        let exists = await store.checkAPIKeyExistence(account: "no-such-\(UUID().uuidString)")
        XCTAssertFalse(exists)
    }

    // MARK: - 过期检查

    func testIsKeyStale_Recent_False() async {
        let account = "test-stale-recent-\(UUID().uuidString)"
        _ = await store.saveAPIKey("fresh-key", account: account)
        let stale = await store.isKeyStale(account: account)
        XCTAssertFalse(stale)
        await store.deleteAPIKey(account: account)
    }

    func testIsKeyStale_NoTimestamp_True() async {
        let stale = await store.isKeyStale(account: "never-saved-\(UUID().uuidString)")
        XCTAssertTrue(stale)
    }

    // MARK: - 1Password ref

    func testSaveAndReadOnePasswordRef_RoundTrip() async {
        let ref = "op://Private/TestItem/credential"
        _ = await store.saveOnePasswordRef(ref)
        let read = await store.readOnePasswordRef()
        XCTAssertEqual(read, ref)
        await store.deleteOnePasswordRef()
    }

    func testDeleteOnePasswordRef_RemovesEntry() async {
        _ = await store.saveOnePasswordRef("op://Private/X/Y")
        await store.deleteOnePasswordRef()
        let read = await store.readOnePasswordRef()
        XCTAssertNil(read)
    }

    // MARK: - 并发

    func testConcurrent_ReadWrite_NoDataCorruption() async {
        let account = "test-concurrent-\(UUID().uuidString)"
        let writeCount = 20

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<writeCount {
                group.addTask { [self] in
                    _ = await store.saveAPIKey("concurrent-key-\(i)", account: account)
                }
            }
        }

        let finalKey = await store.readAPIKey(account: account)
        XCTAssertNotNil(finalKey)
        XCTAssertTrue(finalKey?.hasPrefix("concurrent-key-") == true)
        await store.deleteAPIKey(account: account)
    }

    func testConcurrentStoresPreserveEveryAccount() async {
        let prefix = "test-multiple-stores-\(UUID().uuidString)"
        let accounts = (0..<24).map { "\(prefix)-\($0)" }
        let seed = "\(prefix)-seed"
        defer {
            for account in accounts + [seed] {
                TestIsolation.defaults.removeObject(forKey: "hasAIKey-\(account)")
                TestIsolation.defaults.removeObject(forKey: "apiKeyLastSaved-\(account)")
            }
        }
        guard await store.saveAPIKey("seed", account: seed) else {
            XCTFail("Could not create the temporary test store")
            return
        }

        let stores = accounts.map { _ in EncryptedKeyStore(directory: directory) }
        let gate = KeyStoreTestStartGate(expected: accounts.count)
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for (index, account) in accounts.enumerated() {
                let peer = stores[index]
                group.addTask {
                    await gate.wait()
                    return await peer.saveAPIKey("value-\(index)", account: account)
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }

        XCTAssertEqual(successes, accounts.count, "Every independent store must finish its write")
        for (index, account) in accounts.enumerated() {
            let stored = await store.readAPIKey(account: account)
            XCTAssertEqual(stored, "value-\(index)", "An independent store lost account \(index)")
        }
    }

    func testWriteWaitsForExternalProcessLock() async throws {
        let account = "test-process-lock-\(UUID().uuidString)"
        defer {
            TestIsolation.defaults.removeObject(forKey: "hasAIKey-\(account)")
            TestIsolation.defaults.removeObject(forKey: "apiKeyLastSaved-\(account)")
        }
        let lockURL = directory.appendingPathComponent(".apikeys.lock")
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
            import fcntl, os, sys
            descriptor = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            sys.stdout.write('locked\\n')
            sys.stdout.flush()
            os.read(0, 1)
            os.close(descriptor)
            """, lockURL.path]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
        let ready = output.fileHandleForReading.availableData
        guard ready == Data("locked\n".utf8) else {
            XCTFail("The external process did not acquire the temporary lock")
            return
        }

        let probe = KeyStoreWriteProbe()
        let writer = try XCTUnwrap(store)
        let started = expectation(description: "credential write started")
        let task = Task {
            started.fulfill()
            let result = await writer.saveAPIKey("test-key", account: account)
            await probe.record(result)
            return result
        }
        await fulfillment(of: [started], timeout: 2)
        try await Task.sleep(nanoseconds: 250_000_000)
        let whileLocked = await probe.result
        XCTAssertNil(whileLocked, "The write must wait for the other process")

        try input.fileHandleForWriting.close()
        let saved = await task.value
        XCTAssertTrue(saved)
        let stored = await writer.readAPIKey(account: account)
        XCTAssertEqual(stored, "test-key")
    }

    func testLockFileIsOwnerOnly() async throws {
        let account = "test-lock-mode-\(UUID().uuidString)"
        defer {
            TestIsolation.defaults.removeObject(forKey: "hasAIKey-\(account)")
            TestIsolation.defaults.removeObject(forKey: "apiKeyLastSaved-\(account)")
        }
        let saved = await store.saveAPIKey("test-key", account: account)
        XCTAssertTrue(saved)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent(".apikeys.lock").path
        )
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testSymbolicLinkLockIsRejectedWithoutTouchingTarget() async throws {
        let lockURL = directory.appendingPathComponent(".apikeys.lock")
        let target = directory.appendingPathComponent("unrelated-file")
        let original = Data("keep unchanged".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: target)

        let saved = await store.saveAPIKey("test-key", account: "test-symlink-lock")

        XCTAssertFalse(saved)
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("apikeys.enc").path))
    }

    func testInsecureExistingLockFailsWithoutWritingCredentials() async throws {
        let lockURL = directory.appendingPathComponent(".apikeys.lock")
        try Data().write(to: lockURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockURL.path)

        let saved = await store.saveAPIKey("test-key", account: "test-insecure-lock")

        XCTAssertFalse(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("apikeys.enc").path))
    }

    func testStoreCreatedBeforeLockFileRemainsReadableAndWritable() async throws {
        let first = "test-legacy-first-\(UUID().uuidString)"
        let second = "test-legacy-second-\(UUID().uuidString)"
        defer {
            for account in [first, second] {
                TestIsolation.defaults.removeObject(forKey: "hasAIKey-\(account)")
                TestIsolation.defaults.removeObject(forKey: "apiKeyLastSaved-\(account)")
            }
        }
        let source = directory.appendingPathComponent("fixture-source", isDirectory: true)
        let legacy = directory.appendingPathComponent("legacy", isDirectory: true)
        try PrivateFile.ensureDirectory(source)
        try PrivateFile.ensureDirectory(legacy)
        try PrivateFile.write(Data("fictional-test-machine".utf8), to: source.appendingPathComponent(".machine-uuid"))
        let original = EncryptedKeyStore(directory: source)
        let initialSave = await original.saveAPIKey("original-key", account: first)
        XCTAssertTrue(initialSave)
        for name in [".machine-uuid", "apikeys.enc"] {
            try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: legacy.appendingPathComponent(name))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appendingPathComponent(".apikeys.lock").path))

        let upgraded = EncryptedKeyStore(directory: legacy)
        let oldValue = await upgraded.readAPIKey(account: first)
        XCTAssertEqual(oldValue, "original-key")
        let newSave = await upgraded.saveAPIKey("new-key", account: second)
        XCTAssertTrue(newSave)
        let preservedValue = await upgraded.readAPIKey(account: first)
        let newValue = await upgraded.readAPIKey(account: second)
        XCTAssertEqual(preservedValue, "original-key")
        XCTAssertEqual(newValue, "new-key")
    }

    // MARK: - 空 key 防御

    func testSave_EmptyKey_ReturnsFalse() async {
        let result = await store.saveAPIKey("", account: "empty-test")
        XCTAssertFalse(result)
    }

    // MARK: - UserDefaults flag 同步

    func testSave_SetsHasAIKeyFlag() async {
        let account = "test-flag-\(UUID().uuidString)"
        _ = await store.saveAPIKey("flagged-key", account: account)
        XCTAssertTrue(TestIsolation.defaults.bool(forKey: "hasAIKey-\(account)"))
        await store.deleteAPIKey(account: account)
        XCTAssertFalse(TestIsolation.defaults.bool(forKey: "hasAIKey-\(account)"))
    }
}
