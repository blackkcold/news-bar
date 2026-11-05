import XCTest
@testable import NewsBar

private actor OnePasswordRefreshTestGate {
    private var entered = false
    private var released = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        guard !released else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

final class AIKeySettingsTests: XCTestCase {
    func testSaveFeedbackIsSuccessOnlyForARealSuccess() {
        XCTAssertTrue(AIKeyFeedback.saved.isSuccess)
        XCTAssertTrue(AIKeyFeedback.keyDeleted.isSuccess)
        XCTAssertFalse(AIKeyFeedback.saveFailed.isSuccess)
        XCTAssertFalse(AIKeyFeedback.deleteFailed.isSuccess)
    }

    /// The old UI chose red/green by searching the rendered string for a
    /// localized fragment, so a failure whose text happened to contain the
    /// success text flipped colour. Tone must come from the case, not the text.
    func testToneComesFromTheCaseNotTheRenderedText() {
        XCTAssertEqual(AIKeyFeedback.saved.tone, .success)
        XCTAssertEqual(AIKeyFeedback.saveFailed.tone, .error)
        for feedback in AIKeyFeedback.allCases {
            let isKnownSuccess = feedback == .saved || feedback == .keyDeleted || feedback == .loaded
                || feedback == .customProviderDeleted
            XCTAssertEqual(feedback.tone == .success, isKnownSuccess, "\(feedback)")
        }
        XCTAssertFalse(AIKeyFeedback.saveFailed.text(language: .zh).isEmpty)
        XCTAssertFalse(AIKeyFeedback.saveFailed.text(language: .en).isEmpty)
    }

    func testOnePasswordReferenceIsScopedPerProviderAccount() {
        let first = AIProvider.deepseek.apiKeyAccount()
        let second = AIProvider.minimaxAPI.apiKeyAccount()
        XCTAssertNotEqual(first, second)

        var refs: [String: String] = [:]
        refs = AIKeyReferenceScope.assign("op://Personal/DeepSeek/key", to: first, in: refs)
        refs = AIKeyReferenceScope.assign("op://Personal/MiniMax/key", to: second, in: refs)

        XCTAssertEqual(refs[first], "op://Personal/DeepSeek/key")
        XCTAssertEqual(refs[second], "op://Personal/MiniMax/key")

        // Saving a key for one provider must not overwrite another provider's
        // reference, which is exactly what a single global value used to do.
        refs = AIKeyReferenceScope.assign("op://Personal/MiniMax/key2", to: second, in: refs)
        XCTAssertEqual(refs[first], "op://Personal/DeepSeek/key")
        XCTAssertEqual(refs[second], "op://Personal/MiniMax/key2")

        refs = AIKeyReferenceScope.assign("", to: second, in: refs)
        XCTAssertNil(refs[second])
        XCTAssertEqual(refs[first], "op://Personal/DeepSeek/key")
    }

    func testLoadedKeyFlagsDoNotMarkDeepSeekForACustomProvider() {
        XCTAssertEqual(
            AIProvider.loadedKeyFlagNames(providerID: "custom:fictional", account: "custom:fictional"),
            ["hasAIKey-custom:fictional"]
        )
        XCTAssertEqual(
            AIProvider.loadedKeyFlagNames(providerID: "deepseek", account: "ai-key-deepseek"),
            ["hasAIKey-ai-key-deepseek", "hasAIKey-deepseek"]
        )
        XCTAssertEqual(
            AIProvider.loadedKeyFlagNames(providerID: "deepseek", account: "ai-key-fictional"),
            ["hasAIKey-ai-key-fictional"]
        )
    }

    func testKeyStatusDistinguishesMissingFromAStaleFlag() {
        XCTAssertEqual(AIKeyStatus.resolve(stored: nil, hasFlag: false), .missing)
        XCTAssertEqual(AIKeyStatus.resolve(stored: "sk-test", hasFlag: false), .saved)
        XCTAssertEqual(AIKeyStatus.resolve(stored: nil, hasFlag: true), .flagWithoutSecret)
    }

    func testUnboundCustomCredentialsAreReportedWithoutClaimingTheyAreMissing() {
        XCTAssertEqual(AIKeyStatus.resolve(bound: .unbound, hasFlag: true), .unbound)
        XCTAssertEqual(AIKeyStatus.resolve(bound: .endpointMismatch, hasFlag: true), .endpointMismatch)
        XCTAssertEqual(AIKeyStatus.resolve(bound: .failed, hasFlag: true), .unverified)
        XCTAssertEqual(AIKeyStatus.resolve(bound: .found("fictional-key"), hasFlag: false), .saved)
    }

    func testUnboundReferenceIsNotShownOrReused() {
        for result: EncryptedKeyStore.BoundCustomCredentialReadResult in [.unbound, .endpointMismatch] {
            let decision = AIKeyReferencePolicy.boundReadDecision(for: result)
            XCTAssertEqual(decision.reference, "")
            XCTAssertEqual(decision.feedback, .referenceBindingRequired)
        }
    }

    func testPendingReferenceIsNotCarriedToAnotherEndpoint() {
        let pending = AIKeyReferencePolicy.PendingUpdate(
            reference: "op://fictional/item/key", feedback: .referenceSaveFailed,
            customProviderGeneration: "fictional-generation", endpointIdentity: "endpoint-A"
        )
        XCTAssertNotNil(AIKeyReferencePolicy.pendingForEndpoint(pending, endpointIdentity: "endpoint-A"))
        XCTAssertNil(AIKeyReferencePolicy.pendingForEndpoint(pending, endpointIdentity: "endpoint-B"))
    }

    @MainActor
    func testDelayedCredentialReadIsDiscardedAfterConnectionChanges() async {
        let gate = OnePasswordRefreshTestGate()
        let started = AIKeyContext(providerID: "custom:fictional", account: "custom:fictional", revision: UUID())
        var current = started
        let read = Task { @MainActor in
            await AIKeyAccess.readForPresentation(
                isCurrent: { current == started },
                read: {
                    await gate.pause()
                    return AIKeyStatus.saved
                }
            )
        }
        await gate.waitUntilEntered()
        current = AIKeyContext(providerID: started.providerID, account: started.account, revision: UUID())
        await gate.release()
        let stale = await read.value
        XCTAssertNil(stale)
    }

    @MainActor
    func testDelayedReferenceReadIsDiscardedAfterNewCredentialIntent() async {
        let gate = OnePasswordRefreshTestGate()
        let startedIntent = UUID()
        var currentIntent = startedIntent
        let read = Task { @MainActor in
            await AIKeyAccess.readForPresentation(
                isCurrent: { currentIntent == startedIntent },
                read: {
                    await gate.pause()
                    return EncryptedKeyStore.ReadResult.found("op://fictional/old/key")
                }
            )
        }
        await gate.waitUntilEntered()
        currentIntent = UUID()
        await gate.release()
        let stale = await read.value
        XCTAssertNil(stale)
    }

    @MainActor
    func testCurrentCredentialReadCanStillBePresented() async {
        let result = await AIKeyAccess.readForPresentation(
            isCurrent: { true }, read: { AIKeyStatus.missing }
        )
        XCTAssertEqual(result, .missing)
    }

    func testDeleteFeedbackDistinguishesUncommittedFromUncertainResults() {
        let failed = AIKeyDeletionPolicy.decision(for: .notCommitted)
        XCTAssertFalse(failed.clearCachedKey)
        XCTAssertNil(failed.status)
        XCTAssertEqual(failed.feedback, .deleteFailed)

        let unsynced = AIKeyDeletionPolicy.decision(for: .committedDurabilityUnknown)
        XCTAssertTrue(unsynced.clearCachedKey)
        XCTAssertEqual(unsynced.status, .missing)
        XCTAssertEqual(unsynced.feedback, .deleteDurabilityUnknown)
        XCTAssertTrue(unsynced.retryAllowed)

        let unverified = AIKeyDeletionPolicy.decision(for: .unverified)
        XCTAssertTrue(unverified.clearCachedKey)
        XCTAssertEqual(unverified.status, .unverified)
        XCTAssertEqual(unverified.feedback, .deleteUnverified)
        XCTAssertTrue(unverified.retryAllowed)

        let durable = AIKeyDeletionPolicy.decision(for: .durable)
        XCTAssertTrue(durable.clearCachedKey)
        XCTAssertEqual(durable.status, .missing)
        XCTAssertEqual(durable.feedback, .keyDeleted)
        XCTAssertFalse(durable.retryAllowed)
    }

    func testSaveFeedbackDistinguishesUncommittedFromUncertainResults() {
        let failed = AIKeySavePolicy.decision(for: .notCommitted)
        XCTAssertFalse(failed.activateKey)
        XCTAssertFalse(failed.clearCachedKey)
        XCTAssertFalse(failed.clearInput)
        XCTAssertNil(failed.status)
        XCTAssertEqual(failed.feedback, .saveFailed)

        let unsynced = AIKeySavePolicy.decision(for: .committedDurabilityUnknown)
        XCTAssertTrue(unsynced.activateKey)
        XCTAssertTrue(unsynced.clearInput)
        XCTAssertEqual(unsynced.status, .saved)
        XCTAssertEqual(unsynced.feedback, .saveDurabilityUnknown)
        XCTAssertTrue(unsynced.retrySyncAllowed)

        let unverified = AIKeySavePolicy.decision(for: .unverified)
        XCTAssertFalse(unverified.activateKey)
        XCTAssertTrue(unverified.clearCachedKey)
        XCTAssertFalse(unverified.clearInput)
        XCTAssertEqual(unverified.status, .unverified)
        XCTAssertEqual(unverified.feedback, .saveUnverified)
        XCTAssertFalse(unverified.retrySyncAllowed)

        let durable = AIKeySavePolicy.decision(for: .durable)
        XCTAssertTrue(durable.activateKey)
        XCTAssertTrue(durable.clearInput)
        XCTAssertEqual(durable.status, .saved)
        XCTAssertEqual(durable.feedback, .saved)
        XCTAssertFalse(durable.retrySyncAllowed)
    }

    func testOnePasswordImportPreservesCredentialWriteOutcomes() async throws {
        enum Fault: Equatable {
            case none, beforeRename, afterRename, verification
        }
        let fixtures: [(Fault, EncryptedKeyStore.MutationResult, AIKeyFeedback, AIKeyStatus?, Bool, Bool, Bool)] = [
            (.none, .durable, .loaded, .saved, true, false, false),
            (.beforeRename, .notCommitted, .loadedButNotSaved, nil, false, false, false),
            (.afterRename, .committedDurabilityUnknown, .saveDurabilityUnknown, .saved, true, false, true),
            (.verification, .unverified, .saveUnverified, .unverified, false, true, false)
        ]

        for (fault, expectedResult, expectedFeedback, expectedStatus, activate, clearCache, retrySync) in fixtures {
            let directory = try researchTestDirectory()
            let suiteName = "NewsBarOnePasswordImportTests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer {
                PrivateFileFaults.reset()
                defaults.removePersistentDomain(forName: suiteName)
                try? FileManager.default.removeItem(at: directory)
            }
            let account = "ai-key-fictional"
            let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
            // Initialize the isolated machine-ID snapshot before fault injection;
            // these faults must exercise the credential write, not setup.
            let initialized = await store.saveAPIKey("fixture-seed", account: "fixture-seed")
            XCTAssertTrue(initialized)
            switch fault {
            case .none: break
            case .beforeRename: PrivateFileFaults.failBeforeRename = true
            case .afterRename: PrivateFileFaults.failAfterRename = true
            case .verification: PrivateFileFaults.failVerificationAfterWrite = true
            }

            let outcome = try await AIOnePasswordKeyImport.run(
                reference: "op://fictional/item/field", account: account, store: store
            ) { reference in
                XCTAssertEqual(reference, "op://fictional/item/field")
                return "fictional-key"
            }
            PrivateFileFaults.reset()

            XCTAssertEqual(outcome.result, expectedResult)
            XCTAssertEqual(outcome.feedback, expectedFeedback)
            XCTAssertEqual(outcome.saveDecision.status, expectedStatus)
            XCTAssertEqual(outcome.saveDecision.activateKey, activate)
            XCTAssertEqual(outcome.saveDecision.clearCachedKey, clearCache)
            XCTAssertEqual(outcome.saveDecision.retrySyncAllowed, retrySync)
            let actual = await store.readAPIKeyResult(account: account)
            XCTAssertEqual(actual, fault == .beforeRename ? .missing : .found("fictional-key"))
        }
    }

    func testOnePasswordImportDoesNotWriteWhenSecretReaderFails() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarOnePasswordImportTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let account = "ai-key-fictional"
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)

        do {
            _ = try await AIOnePasswordKeyImport.run(
                reference: "op://fictional/item/field", account: account, store: store
            ) { _ in
                throw OnePasswordError.timeout
            }
            XCTFail("A failed secret read must stop the import")
        } catch OnePasswordError.timeout {
            // Expected: no secret was returned by the injected reader.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let actual = await store.readAPIKeyResult(account: account)
        XCTAssertEqual(actual, .missing)
    }

    func testOnePasswordImportDoesNotInitializeStoreWhenSecretReaderFails() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarOnePasswordImportTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        var storeInitialized = false
        func makeStore() -> EncryptedKeyStore {
            storeInitialized = true
            return EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        }

        do {
            _ = try await AIOnePasswordKeyImport.run(
                reference: "op://fictional/item/field", account: "ai-key-fictional", store: makeStore()
            ) { _ in
                throw OnePasswordError.timeout
            }
            XCTFail("A failed secret read must stop the import")
        } catch OnePasswordError.timeout {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(storeInitialized)
    }

    func testExplicitSaveCanRecoverARevokedCustomProvider() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarCustomRecovery-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let account = "custom:fictional-provider"
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let deleted = await store.deleteCustomProviderCredentialsResult(account: account)
        XCTAssertEqual(deleted, .durable)

        let generation = try await AICustomProviderCredentialAccess.generation(
            account: account, store: store, allowRecovery: true
        )
        XCTAssertNotNil(generation)
        let saved = await store.saveAPIKeyResult("fictional-new-key", account: account, customProviderGeneration: generation)
        XCTAssertEqual(saved, .durable)
        let stored = await store.readBoundCustomKeyResult(account: account, endpointIdentity: "endpoint-A")
        XCTAssertEqual(stored, .unbound)
        let oldReference = await store.readBoundCustomReferenceResult(account: account, endpointIdentity: "endpoint-A")
        XCTAssertEqual(oldReference, .missing)
    }

    func testFailedOnePasswordReadDoesNotRecoverRevokedProvider() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarCustomImportFailure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let account = "custom:fictional-provider"
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let deleted = await store.deleteCustomProviderCredentialsResult(account: account)
        XCTAssertEqual(deleted, .durable)
        let before = await store.customProviderCredentialStateResult(account: account)

        do {
            _ = try await AIOnePasswordKeyImport.run(
                reference: "op://fictional/item/field", account: account, store: store,
                endpointIdentity: "endpoint-A", referenceWasEdited: true
            ) { _ in throw OnePasswordError.timeout }
            XCTFail("A failed secret read must not recover the provider")
        } catch OnePasswordError.timeout {
            // Expected.
        }
        let after = await store.customProviderCredentialStateResult(account: account)
        let key = await store.readAPIKeyResult(account: account)
        XCTAssertEqual(after, before)
        XCTAssertEqual(key, .missing)
    }

    func testCancelledOnePasswordReadDoesNotRecoverRevokedProvider() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarCustomImportCancellation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let account = "custom:fictional-provider"
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let deleted = await store.deleteCustomProviderCredentialsResult(account: account)
        XCTAssertEqual(deleted, .durable)
        let before = await store.customProviderCredentialStateResult(account: account)
        let gate = OnePasswordRefreshTestGate()
        let importing = Task {
            try await AIOnePasswordKeyImport.run(
                reference: "op://fictional/item/field", account: account, store: store,
                endpointIdentity: "endpoint-A", referenceWasEdited: true
            ) { _ in
                await gate.pause()
                return "fictional-key"
            }
        }
        await gate.waitUntilEntered()
        importing.cancel()
        await gate.release()
        do {
            _ = try await importing.value
            XCTFail("Cancellation before recovery must stop the import")
        } catch is CancellationError {
            // Expected.
        }
        let after = await store.customProviderCredentialStateResult(account: account)
        XCTAssertEqual(after, before)
    }

    func testFailedKeyEncryptionDoesNotPartiallyRecoverARevokedProvider() async throws {
        enum FixtureFailure: Error { case unavailable }
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarAtomicImportFailure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let account = "custom:fictional-provider"
        let store = EncryptedKeyStore(
            directory: directory, metadataDefaults: defaults,
            testMachineIdentifier: { throw FixtureFailure.unavailable }
        )
        let deleted = await store.deleteCustomProviderCredentialsResult(account: account)
        XCTAssertEqual(deleted, .durable)
        let before = await store.customProviderCredentialStateResult(account: account)

        do {
            let outcome = try await AIOnePasswordKeyImport.run(
                reference: "op://fictional/item/field", account: account, store: store,
                endpointIdentity: "endpoint-A", referenceWasEdited: true
            ) { _ in "fictional-key" }
            XCTAssertEqual(outcome.result, .notCommitted)
        } catch let error as AICustomProviderCredentialError {
            XCTAssertEqual(error.result, .notCommitted)
        }

        let after = await store.customProviderCredentialStateResult(account: account)
        let key = await store.readAPIKeyResult(account: account)
        XCTAssertEqual(after, before)
        XCTAssertEqual(key, .missing)
    }

    func testManualKeySaveFailureDoesNotPartiallyRecoverARevokedProvider() async throws {
        enum FixtureFailure: Error { case unavailable }
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarAtomicManualFailure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let account = "custom:fictional-provider"
        let store = EncryptedKeyStore(
            directory: directory, metadataDefaults: defaults,
            testMachineIdentifier: { throw FixtureFailure.unavailable }
        )
        let deleted = await store.deleteCustomProviderCredentialsResult(account: account)
        XCTAssertEqual(deleted, .durable)
        let before = await store.customProviderCredentialStateResult(account: account)
        guard case let .state(state) = before else { return XCTFail("Missing revoked state") }
        do {
            let result = try await AICustomProviderCredentialAccess.save(
                "fictional-key", account: account, store: store, capturedState: state,
                endpointIdentity: "endpoint-A"
            )
            XCTAssertEqual(result.result, .notCommitted)
        } catch let error as AICustomProviderCredentialError {
            XCTAssertEqual(error.result, .notCommitted)
        }
        let after = await store.customProviderCredentialStateResult(account: account)
        let key = await store.readAPIKeyResult(account: account)
        XCTAssertEqual(after, before)
        XCTAssertEqual(key, .missing)
    }

    func testRevokedImportCommitsKeyAndRecoveryTogetherWhenVerificationIsUncertain() async throws {
        enum Fault { case afterRename, verification }
        for fault in [Fault.afterRename, .verification] {
            let directory = try researchTestDirectory()
            let suiteName = "NewsBarAtomicImportFault-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer {
                PrivateFileFaults.reset()
                defaults.removePersistentDomain(forName: suiteName)
                try? FileManager.default.removeItem(at: directory)
            }
            let account = "custom:fictional-provider"
            let store = EncryptedKeyStore(
                directory: directory, metadataDefaults: defaults,
                testMachineIdentifier: { "fictional-machine" }
            )
            let deleted = await store.deleteCustomProviderCredentialsResult(account: account)
            XCTAssertEqual(deleted, .durable)
            let outcome = try await AIOnePasswordKeyImport.run(
                reference: "op://fictional/item/field", account: account, store: store,
                endpointIdentity: "endpoint-A", referenceWasEdited: true
            ) { _ in
                switch fault {
                case .afterRename: PrivateFileFaults.failAfterRename = true
                case .verification: PrivateFileFaults.failVerificationAfterWrite = true
                }
                return "fictional-key"
            }
            PrivateFileFaults.reset()
            switch fault {
            case .afterRename: XCTAssertEqual(outcome.result, .committedDurabilityUnknown)
            case .verification: XCTAssertEqual(outcome.result, .unverified)
            }
            let stateResult = await store.customProviderCredentialStateResult(account: account)
            guard case let .state(state) = stateResult else { return XCTFail("Missing recovered state") }
            XCTAssertFalse(state.revoked)
            let key = await store.readBoundCustomKeyResult(account: account, endpointIdentity: "endpoint-A")
            XCTAssertEqual(key, .found("fictional-key"))
        }
    }

    func testOldOnePasswordReadCannotRecoverNewerRevocation() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarCustomImportRevocation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let account = "custom:fictional-provider"
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let firstDelete = await store.deleteCustomProviderCredentialsResult(account: account)
        XCTAssertEqual(firstDelete, .durable)
        let originalResult = await store.customProviderCredentialStateResult(account: account)
        guard case let .state(original) = originalResult else { return XCTFail("Missing revocation") }
        let gate = OnePasswordRefreshTestGate()
        let importing = Task {
            try await AIOnePasswordKeyImport.run(
                reference: "op://fictional/item/field", account: account, store: store,
                endpointIdentity: "endpoint-A", referenceWasEdited: true
            ) { _ in
                await gate.pause()
                return "fictional-old-key"
            }
        }
        await gate.waitUntilEntered()
        let secondDelete = await store.deleteCustomProviderCredentialsResult(account: account, expectedState: original)
        XCTAssertEqual(secondDelete, .durable)
        let newer = await store.customProviderCredentialStateResult(account: account)
        await gate.release()
        do {
            _ = try await importing.value
            XCTFail("A stale read must not recover a newer revocation")
        } catch let error as AICustomProviderCredentialError {
            XCTAssertEqual(error.result, .notCommitted)
        }
        let after = await store.customProviderCredentialStateResult(account: account)
        let key = await store.readAPIKeyResult(account: account)
        XCTAssertEqual(after, newer)
        XCTAssertEqual(key, .missing)
    }

    func testSuccessfulOnePasswordReadCanRecoverRevokedProvider() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarCustomImportRecovery-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let account = "custom:fictional-provider"
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let deleted = await store.deleteCustomProviderCredentialsResult(account: account)
        XCTAssertEqual(deleted, .durable)

        let outcome = try await AIOnePasswordKeyImport.run(
            reference: "op://fictional/item/field", account: account, store: store,
            endpointIdentity: "endpoint-A", referenceWasEdited: true
        ) { _ in "fictional-new-key" }
        let current = await store.customProviderCredentialStateResult(account: account)
        guard case let .state(state) = current else { return XCTFail("Missing recovered generation") }
        XCTAssertFalse(state.revoked)
        XCTAssertEqual(outcome.customProviderGeneration, state.generation)
        XCTAssertEqual(outcome.result, .durable)
        let key = await store.readBoundCustomKeyResult(account: account, endpointIdentity: "endpoint-A")
        XCTAssertEqual(key, .found("fictional-new-key"))
    }

    func testOnePasswordImportCannotWriteAcrossConnectionChange() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarCustomImportRace-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let account = "custom:fictional-provider"
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let gate = OnePasswordRefreshTestGate()
        let importing = Task {
            try await AIOnePasswordKeyImport.run(
                reference: "op://fictional/item/field", account: account, store: store,
                endpointIdentity: "endpoint-A", referenceWasEdited: true
            ) { _ in
                await gate.pause()
                return "fictional-old-key"
            }
        }
        await gate.waitUntilEntered()
        let reset = await store.resetCustomProviderCredentialsForConnectionChange(account: account, expectedState: nil)
        XCTAssertEqual(reset, .durable)
        await gate.release()

        let outcome = try await importing.value
        XCTAssertEqual(outcome.result, .notCommitted)
        let stored = await store.readAPIKeyResult(account: account)
        XCTAssertEqual(stored, .missing)
    }

    @MainActor
    func testAutomaticOnePasswordRefreshDoesNotActivateAnotherProvidersKey() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarOnePasswordAutoRefreshTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let account = "ai-key-fictional-a"
        let seeded = await store.saveAPIKey("fictional-old", account: account)
        XCTAssertTrue(seeded)
        let initialSnapshot = await store.onePasswordRefreshSnapshot(account: account)
        let snapshot = try XCTUnwrap(initialSnapshot)
        let intent = UUID()
        let gate = OnePasswordRefreshTestGate()
        var activeAccount = account
        var activatedKey: String?

        let refresh = Task { @MainActor in
            try await AIOnePasswordAutoRefresh.run(
                reference: "op://fictional/item/field", snapshot: snapshot, store: store,
                expectedIntent: intent,
                readSecret: { _ in
                    await gate.pause()
                    return "fictional-key-a"
                },
                currentAccount: { activeAccount },
                currentIntent: { intent },
                activate: { activatedKey = $0 }
            )
        }
        await gate.waitUntilEntered()
        activeAccount = "ai-key-fictional-b"
        await gate.release()
        try await refresh.value

        XCTAssertNil(activatedKey)
        let stored = await store.readAPIKeyResult(account: account)
        XCTAssertEqual(stored, .found("fictional-key-a"))
    }

    @MainActor
    func testAutomaticOnePasswordRefreshStillActivatesForSameAccount() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarOnePasswordAutoRefreshTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let account = "ai-key-fictional-a"
        let seeded = await store.saveAPIKey("fictional-old", account: account)
        XCTAssertTrue(seeded)
        let initialSnapshot = await store.onePasswordRefreshSnapshot(account: account)
        let snapshot = try XCTUnwrap(initialSnapshot)
        let intent = UUID()
        var activatedKey: String?

        try await AIOnePasswordAutoRefresh.run(
            reference: "op://fictional/item/field", snapshot: snapshot, store: store,
            expectedIntent: intent,
            readSecret: { _ in "fictional-key-a" },
            currentAccount: { account },
            currentIntent: { intent },
            activate: { activatedKey = $0 }
        )

        XCTAssertEqual(activatedKey, "fictional-key-a")
        let stored = await store.readAPIKeyResult(account: account)
        XCTAssertEqual(stored, .found("fictional-key-a"))
    }

    @MainActor
    func testAutomaticOnePasswordRefreshDoesNotActivateUnsyncedWrite() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarOnePasswordAutoRefreshTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            PrivateFileFaults.reset()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let account = "ai-key-fictional-a"
        let seeded = await store.saveAPIKey("fictional-old", account: account)
        XCTAssertTrue(seeded)
        let initialSnapshot = await store.onePasswordRefreshSnapshot(account: account)
        let snapshot = try XCTUnwrap(initialSnapshot)
        let intent = UUID()
        var activatedKey: String?
        PrivateFileFaults.failAfterRename = true

        try await AIOnePasswordAutoRefresh.run(
            reference: "op://fictional/item/field", snapshot: snapshot, store: store,
            expectedIntent: intent,
            readSecret: { _ in "fictional-key-a" },
            currentAccount: { account },
            currentIntent: { intent },
            activate: { activatedKey = $0 }
        )
        PrivateFileFaults.reset()

        XCTAssertNil(activatedKey)
        let stored = await store.readAPIKeyResult(account: account)
        XCTAssertEqual(stored, .found("fictional-key-a"))
    }

    @MainActor
    func testAutomaticRefreshDoesNotOverwriteConcurrentUserCredentialChanges() async throws {
        enum Change: CaseIterable {
            case replaceKey, deleteKey, clearReference
        }
        for change in Change.allCases {
            let directory = try researchTestDirectory()
            let suiteName = "NewsBarOnePasswordAutoRefreshTests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer {
                defaults.removePersistentDomain(forName: suiteName)
                try? FileManager.default.removeItem(at: directory)
            }
            let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
            let writer = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
            let account = "ai-key-fictional-a"
            let seeded = await store.saveAPIKey("fictional-old", account: account)
            let referenceSaved = await store.saveOnePasswordRef("op://fictional/item/field", account: account)
            XCTAssertTrue(seeded && referenceSaved)
            let initialSnapshot = await store.onePasswordRefreshSnapshot(account: account)
            let snapshot = try XCTUnwrap(initialSnapshot)
            let intent = UUID()
            let gate = OnePasswordRefreshTestGate()
            var activated: String?

            let refresh = Task { @MainActor in
                try await AIOnePasswordAutoRefresh.run(
                    reference: "op://fictional/item/field", snapshot: snapshot, store: store,
                    expectedIntent: intent,
                    readSecret: { _ in await gate.pause(); return "fictional-refreshed" },
                    currentAccount: { account }, currentIntent: { intent },
                    activate: { activated = $0 }
                )
            }
            await gate.waitUntilEntered()
            switch change {
            case .replaceKey:
                let result = await writer.saveAPIKeyResult("fictional-user-new", account: account)
                XCTAssertEqual(result, .durable)
            case .deleteKey:
                let result = await writer.deleteAPIKeyResult(account: account)
                XCTAssertEqual(result, .durable)
            case .clearReference:
                let result = await writer.deleteOnePasswordRefResult(account: account)
                XCTAssertEqual(result, .durable)
            }
            await gate.release()
            try await refresh.value

            XCTAssertNil(activated, "A stale refresh must not activate after \(change)")
            let stored = await store.readAPIKeyResult(account: account)
            switch change {
            case .replaceKey: XCTAssertEqual(stored, .found("fictional-user-new"))
            case .deleteKey: XCTAssertEqual(stored, .missing)
            case .clearReference: XCTAssertEqual(stored, .found("fictional-old"))
            }
        }
    }

    @MainActor
    func testAutomaticRefreshDoesNotActivateAfterAUserDeletionStarts() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarOnePasswordAutoRefreshTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let writer = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let account = "ai-key-fictional-a"
        let seeded = await store.saveAPIKey("fictional-old", account: account)
        XCTAssertTrue(seeded)
        let initialSnapshot = await store.onePasswordRefreshSnapshot(account: account)
        let snapshot = try XCTUnwrap(initialSnapshot)
        let initialIntent = UUID()
        var currentIntent = initialIntent
        var activated: String?

        try await AIOnePasswordAutoRefresh.run(
            reference: "op://fictional/item/field", snapshot: snapshot, store: store,
            expectedIntent: initialIntent,
            readSecret: { _ in "fictional-refreshed" },
            currentAccount: { account }, currentIntent: { currentIntent },
            afterStoreWrite: {
                currentIntent = UUID()
                let result = await writer.deleteAPIKeyResult(account: account)
                XCTAssertEqual(result, .durable)
            },
            activate: { activated = $0 }
        )

        XCTAssertNil(activated)
        let stored = await store.readAPIKeyResult(account: account)
        XCTAssertEqual(stored, .missing)
    }

    func testOnePasswordRefreshSnapshotIgnoresOtherAccounts() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarOnePasswordAutoRefreshTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let other = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let account = "ai-key-fictional-a"
        let seeded = await store.saveAPIKey("fictional-old", account: account)
        XCTAssertTrue(seeded)
        let initialSnapshot = await store.onePasswordRefreshSnapshot(account: account)
        let snapshot = try XCTUnwrap(initialSnapshot)
        let otherSaved = await other.saveAPIKey("fictional-other", account: "ai-key-fictional-b")
        XCTAssertTrue(otherSaved)

        let refreshed = await store.saveRefreshedAPIKey("fictional-refreshed", snapshot: snapshot)
        XCTAssertEqual(refreshed, .durable)
        let stored = await store.readAPIKeyResult(account: account)
        let otherStored = await store.readAPIKeyResult(account: "ai-key-fictional-b")
        XCTAssertEqual(stored, .found("fictional-refreshed"))
        XCTAssertEqual(otherStored, .found("fictional-other"))
    }

    func testOnePasswordRefreshSnapshotPreservesActiveCustomGeneration() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarOnePasswordAutoRefreshTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let account = "custom:fictional-provider"
        let removed = await store.deleteCustomProviderCredentials(account: account)
        XCTAssertTrue(removed)
        let revocation = await store.customProviderRevocationGeneration(account: account)
        let generation = try XCTUnwrap(revocation)
        let activated = await store.reactivateCustomProviderCredentials(account: account, matchingRevocation: generation)
        let activeGeneration = try XCTUnwrap(activated)
        let stateResult = await store.customProviderCredentialStateResult(account: account)
        guard case let .state(activeState) = stateResult else { return XCTFail("Missing active state") }
        let saved = await store.saveBoundCustomKeyResult(
            "fictional-old", account: account, expectedState: activeState, endpointIdentity: "endpoint-A"
        )
        XCTAssertEqual(saved.result, .durable)
        guard let keyState = saved.state else { return XCTFail("Missing key state") }
        let referenceSaved = await store.saveBoundCustomReferenceResult(
            "op://fictional/item/field", account: account, expectedState: keyState, endpointIdentity: "endpoint-A"
        )
        XCTAssertEqual(referenceSaved, .durable)
        let initialSnapshot = await store.onePasswordRefreshSnapshot(
            account: account, endpointIdentity: "endpoint-A"
        )
        let snapshot = try XCTUnwrap(initialSnapshot)

        let refreshed = await store.saveRefreshedAPIKey("fictional-refreshed", snapshot: snapshot)
        XCTAssertEqual(refreshed, .durable)
        let stored = await store.readBoundCustomKeyResult(account: account, endpointIdentity: "endpoint-A")
        XCTAssertEqual(stored, .found("fictional-refreshed"))
    }

    @MainActor
    func testDelayedProviderKeyReadCannotActivateAfterProviderSwitch() async throws {
        let started = AIKeyContext(providerID: "fictional-a", account: "ai-key-a", revision: UUID())
        let switched = AIKeyContext(providerID: "fictional-b", account: "ai-key-b", revision: UUID())
        let gate = OnePasswordRefreshTestGate()
        var current = started
        var activated: String?

        let task = Task { @MainActor in
            try await AIKeyAccess.read(
                started: started,
                current: { current },
                read: { account in
                    XCTAssertEqual(account, "ai-key-a")
                    await gate.pause()
                    return .found("fictional-key-a")
                },
                activate: { key in activated = key; return true }
            )
        }
        await gate.waitUntilEntered()
        current = switched
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("A key read for a previous provider must not succeed")
        } catch {
            XCTAssertEqual(error as? AISearchError, .configurationChanged)
        }
        XCTAssertNil(activated)
    }

    @MainActor
    func testProviderKeyReadBindsPostActivationRevisionAndRejectsStaleCache() async throws {
        let started = AIKeyContext(providerID: "fictional-a", account: "ai-key-a", revision: UUID())
        let activated = AIKeyContext(providerID: "fictional-a", account: "ai-key-a", revision: UUID())
        let switched = AIKeyContext(providerID: "fictional-b", account: "ai-key-b", revision: UUID())
        var current = started
        var cached: String?

        let bound = try await AIKeyAccess.read(
            started: started,
            current: { current },
            read: { _ in .found("fictional-key-a") },
            activate: { key in cached = key; current = activated; return true }
        )
        XCTAssertEqual(bound.context, activated)
        XCTAssertTrue(AIKeyAccess.isCurrent(bound, context: current, cachedKey: cached))
        XCTAssertFalse(AIKeyAccess.isCurrent(bound, context: switched, cachedKey: cached))
        XCTAssertFalse(AIKeyAccess.isCurrent(bound, context: current, cachedKey: "fictional-key-b"))
    }

    @MainActor
    func testProviderKeyReadPreservesKeylessAccountWithoutActivating() async throws {
        let started = AIKeyContext(providerID: "ollamaCloud", account: "ai-key-ollamaCloud", revision: UUID())
        var activated = false
        let bound = try await AIKeyAccess.read(
            started: started,
            current: { started },
            read: { _ in .missing },
            activate: { _ in activated = true; return true }
        )
        XCTAssertEqual(bound.key, "")
        XCTAssertFalse(activated)
        XCTAssertTrue(AIKeyAccess.isCurrent(bound, context: started, cachedKey: nil))
        XCTAssertFalse(AIKeyAccess.isCurrent(bound, context: started, cachedKey: "fictional-new-key"))
    }

    @MainActor
    func testUnreadableOllamaKeyDoesNotBecomeAnAnonymousCredential() async {
        let started = AIKeyContext(providerID: "ollamaCloud", account: "ai-key-ollamaCloud", revision: UUID())
        var activated = false
        do {
            _ = try await AIKeyAccess.read(
                started: started,
                current: { started },
                read: { _ in .failed },
                activate: { _ in activated = true; return true }
            )
            XCTFail("An unreadable key must not be treated as absent")
        } catch {
            XCTAssertEqual(error as? AISearchError, .keyReadFailed)
        }
        XCTAssertFalse(activated)
    }

    @MainActor
    func testKeyReadStartedBeforeCredentialMutationCannotActivateItsOldValue() async throws {
        let started = AIKeyContext(providerID: "fictional-a", account: "ai-key-a", revision: UUID())
        var current = started
        var activated = false
        let gate = OnePasswordRefreshTestGate()
        let task = Task { @MainActor in
            try await AIKeyAccess.read(
                started: started,
                current: { current },
                read: { _ in await gate.pause(); return .found("fictional-old") },
                activate: { _ in activated = true; return true }
            )
        }
        await gate.waitUntilEntered()
        current = AIKeyContext(providerID: started.providerID, account: started.account, revision: UUID())
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("A credential mutation must invalidate an older read")
        } catch {
            XCTAssertEqual(error as? AISearchError, .configurationChanged)
        }
        XCTAssertFalse(activated)
    }

    func testUnreadableScopedOnePasswordReferenceDoesNotFallBackToLegacy() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarOnePasswordReferenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let account = "ai-key-fictional"
        let legacy = "op://fictional/legacy/field"
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let saved = await store.saveOnePasswordRef(legacy)
        XCTAssertTrue(saved)
        let file = directory.appendingPathComponent("apikeys.enc")
        var payload = try JSONDecoder().decode(EncryptedKeyStore.EncryptedPayload.self, from: Data(contentsOf: file))
        payload.entries.append(.init(
            account: "one-password-ref.\(account)", nonce: Data([1]), ciphertext: Data([2])
        ))
        try PrivateFile.write(JSONEncoder().encode(payload), to: file, durable: false)

        let actual = await store.readOnePasswordRef(account: account)
        let result = await store.readOnePasswordRefResult(account: account)
        let preservedLegacy = await store.readOnePasswordRef()

        XCTAssertNil(actual, "A damaged scoped entry must not use an unrelated shared reference")
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(preservedLegacy, legacy, "The shared reference must not be deleted")
    }

    func testMissingScopedOnePasswordReferenceStillUsesLegacy() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarOnePasswordReferenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let account = "ai-key-fictional"
        let legacy = "op://fictional/legacy/field"
        let scoped = "op://fictional/scoped/field"
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let absent = await store.readOnePasswordRefResult(account: account)
        XCTAssertEqual(absent, .missing)
        let legacySaved = await store.saveOnePasswordRef(legacy)
        XCTAssertTrue(legacySaved)

        let fallback = await store.readOnePasswordRef(account: account)
        XCTAssertEqual(fallback, legacy)
        let fallbackResult = await store.readOnePasswordRefResult(account: account)
        XCTAssertEqual(fallbackResult, .found(legacy))
        let scopedSaved = await store.saveOnePasswordRef(scoped, account: account)
        XCTAssertTrue(scopedSaved)
        let current = await store.readOnePasswordRef(account: account)
        XCTAssertEqual(current, scoped)
        let currentResult = await store.readOnePasswordRefResult(account: account)
        XCTAssertEqual(currentResult, .found(scoped))
    }

    func testOnePasswordReferenceMutationsReportActualCommitState() async throws {
        enum Fault: Equatable {
            case none, beforeRename, afterRename, verification
        }
        let fixtures: [(Fault, EncryptedKeyStore.MutationResult)] = [
            (.none, .durable),
            (.beforeRename, .notCommitted),
            (.afterRename, .committedDurabilityUnknown),
            (.verification, .unverified)
        ]

        for deleting in [false, true] {
            for (fault, expectedResult) in fixtures {
                let directory = try researchTestDirectory()
                let suiteName = "NewsBarOnePasswordReferenceTests-\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
                defer {
                    PrivateFileFaults.reset()
                    defaults.removePersistentDomain(forName: suiteName)
                    try? FileManager.default.removeItem(at: directory)
                }
                let account = "ai-key-fictional"
                let original = "op://fictional/original/field"
                let updated = "op://fictional/updated/field"
                let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
                let saved = await store.saveOnePasswordRef(original, account: account)
                XCTAssertTrue(saved)
                switch fault {
                case .none: break
                case .beforeRename: PrivateFileFaults.failBeforeRename = true
                case .afterRename: PrivateFileFaults.failAfterRename = true
                case .verification: PrivateFileFaults.failVerificationAfterWrite = true
                }

                let result: EncryptedKeyStore.MutationResult
                if deleting {
                    result = await store.deleteOnePasswordRefResult(account: account)
                } else {
                    result = await store.saveOnePasswordRefResult(updated, account: account)
                }
                PrivateFileFaults.reset()

                XCTAssertEqual(result, expectedResult, "deleting=\(deleting), fault=\(fault)")
                let actual = await store.readOnePasswordRef(account: account)
                let expected: String? = fault == .beforeRename ? original : (deleting ? nil : updated)
                XCTAssertEqual(actual, expected, "deleting=\(deleting), fault=\(fault)")
            }
        }
    }

    func testOnePasswordReferenceReadFeedbackDistinguishesFailureFromMissing() {
        let missing = AIKeyReferencePolicy.readDecision(for: .missing)
        XCTAssertEqual(missing.reference, "")
        XCTAssertNil(missing.feedback)

        let unreadable = AIKeyReferencePolicy.readDecision(for: .failed)
        XCTAssertEqual(unreadable.reference, "")
        XCTAssertEqual(unreadable.feedback, .referenceReadFailed)

        let found = AIKeyReferencePolicy.readDecision(for: .found("op://fictional/item/field"))
        XCTAssertEqual(found.reference, "op://fictional/item/field")
        XCTAssertNil(found.feedback)
    }

    func testOnePasswordReferenceWriteFeedbackKeepsUncertainResultsRetryable() {
        let saved = AIKeyReferencePolicy.mutationDecision(for: .durable, deleting: false)
        XCTAssertNil(saved.feedback)
        XCTAssertFalse(saved.retryAllowed)

        let failedSave = AIKeyReferencePolicy.mutationDecision(for: .notCommitted, deleting: false)
        XCTAssertEqual(failedSave.feedback, .referenceSaveFailed)
        XCTAssertTrue(failedSave.retryAllowed)

        let failedDelete = AIKeyReferencePolicy.mutationDecision(for: .notCommitted, deleting: true)
        XCTAssertEqual(failedDelete.feedback, .referenceDeleteFailed)
        XCTAssertTrue(failedDelete.retryAllowed)

        let unsynced = AIKeyReferencePolicy.mutationDecision(for: .committedDurabilityUnknown, deleting: false)
        XCTAssertEqual(unsynced.feedback, .referenceDurabilityUnknown)
        XCTAssertTrue(unsynced.retryAllowed)

        let unverified = AIKeyReferencePolicy.mutationDecision(for: .unverified, deleting: true)
        XCTAssertEqual(unverified.feedback, .referenceUnverified)
        XCTAssertTrue(unverified.retryAllowed)
    }

    func testPendingOnePasswordReferenceUpdateKeepsItsIntentAfterReload() {
        let pending = AIKeyReferencePolicy.PendingUpdate(
            reference: "op://fictional/new/field", feedback: .referenceUnverified
        )

        let oldStored = AIKeyReferencePolicy.readDecision(
            for: .found("op://fictional/old/field"), pending: pending
        )
        XCTAssertEqual(oldStored.reference, "op://fictional/new/field")
        XCTAssertEqual(oldStored.feedback, .referenceUnverified)

        let unreadable = AIKeyReferencePolicy.readDecision(for: .failed, pending: pending)
        XCTAssertEqual(unreadable.reference, "op://fictional/new/field")
        XCTAssertEqual(unreadable.feedback, .referenceReadFailed)

        let missing = AIKeyReferencePolicy.readDecision(for: .missing, pending: pending)
        XCTAssertEqual(missing.reference, "op://fictional/new/field")
        XCTAssertEqual(missing.feedback, .referenceUnverified)
    }

    func testLegacyReferenceFallbackOnlyAppliesWhenStoredReferenceIsMissing() {
        let legacy = "op://fictional/legacy/field"
        let scoped = "op://fictional/scoped/field"

        XCTAssertNil(EncryptedKeyStore.ReadResult.failed.value(orIfMissing: legacy))
        XCTAssertEqual(EncryptedKeyStore.ReadResult.missing.value(orIfMissing: legacy), legacy)
        XCTAssertEqual(EncryptedKeyStore.ReadResult.found(scoped).value(orIfMissing: legacy), scoped)
    }

    func testLateOnePasswordCompletionCannotUpdateAnotherProviderOrPersistAStaleReference() {
        let revision = UUID()
        let started = AIOnePasswordCompletionPolicy.Context(
            providerID: "fictional-a", account: "ai-key-a", revision: revision
        )
        let switched = AIOnePasswordCompletionPolicy.Context(
            providerID: "fictional-b", account: "ai-key-b", revision: UUID()
        )
        let switchedBack = AIOnePasswordCompletionPolicy.Context(
            providerID: "fictional-a", account: "ai-key-a", revision: UUID()
        )

        XCTAssertTrue(AIOnePasswordCompletionPolicy.mayPresent(started: started, current: started))
        XCTAssertFalse(AIOnePasswordCompletionPolicy.mayPresent(started: started, current: switched))
        XCTAssertFalse(AIOnePasswordCompletionPolicy.mayPresent(started: started, current: switchedBack))
        XCTAssertFalse(AIOnePasswordCompletionPolicy.mayPersistReference(
            result: .durable, started: started, current: switched
        ))
        XCTAssertFalse(AIOnePasswordCompletionPolicy.mayPersistReference(
            result: .committedDurabilityUnknown, started: started, current: switchedBack
        ))
        XCTAssertFalse(AIOnePasswordCompletionPolicy.mayPersistReference(
            result: .unverified, started: started, current: started
        ))
        XCTAssertTrue(AIOnePasswordCompletionPolicy.mayPersistReference(
            result: .durable, started: started, current: started
        ))
        XCTAssertTrue(AIOnePasswordCompletionPolicy.mayPersistReference(
            result: .committedDurabilityUnknown, started: started, current: started
        ))
    }

    func testChangingProviderImmediatelyHidesThePreviousOnePasswordReference() {
        let reference = "op://fictional/provider-a/field"
        XCTAssertEqual(
            AIKeyReferencePolicy.referenceAfterProviderChange(reference, from: "a", to: "b"), ""
        )
        XCTAssertEqual(
            AIKeyReferencePolicy.referenceAfterProviderChange(reference, from: "a", to: "a"), reference
        )
    }

    func testClearingScopedOnePasswordReferenceDoesNotRestoreSharedLegacyReference() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarOnePasswordClearTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let legacy = "op://fictional/shared/field"
        let accountA = "ai-key-fictional-a"
        let accountB = "ai-key-fictional-b"
        let referenceA = "op://fictional/provider-a/field"
        let referenceB = "op://fictional/provider-b/field"
        let legacySaved = await store.saveOnePasswordRef(legacy)
        let aSaved = await store.saveOnePasswordRef(referenceA, account: accountA)
        let bSaved = await store.saveOnePasswordRef(referenceB, account: accountB)
        XCTAssertTrue(legacySaved && aSaved && bSaved)

        let result = await store.deleteOnePasswordRefResult(account: accountA)

        XCTAssertEqual(result, .durable)
        let cleared = await store.readOnePasswordRef(account: accountA)
        XCTAssertNil(cleared)
        let clearedState = await store.readOnePasswordRefResult(account: accountA)
        let effectiveReference = clearedState.value(orIfMissing: legacy)
        XCTAssertTrue(effectiveReference == nil || effectiveReference == "")
        let retainedB = await store.readOnePasswordRef(account: accountB)
        let retainedLegacy = await store.readOnePasswordRef()
        XCTAssertEqual(retainedB, referenceB)
        XCTAssertEqual(retainedLegacy, legacy)

        let reopened = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let reopenedState = await reopened.readOnePasswordRefResult(account: accountA)
        let reopenedReference = reopenedState.value(orIfMissing: legacy)
        XCTAssertTrue(reopenedReference == nil || reopenedReference == "")
        let restored = await reopened.saveOnePasswordRef("op://fictional/new-a/field", account: accountA)
        XCTAssertTrue(restored)
        let newReference = await store.readOnePasswordRef(account: accountA)
        XCTAssertEqual(newReference, "op://fictional/new-a/field")
    }

    func testClearingMissingScopedOnePasswordReferenceStopsOnlyThatAccountsLegacyFallback() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarOnePasswordClearTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let legacy = "op://fictional/shared/field"
        let accountA = "ai-key-fictional-a"
        let accountB = "ai-key-fictional-b"
        let legacySaved = await store.saveOnePasswordRef(legacy)
        XCTAssertTrue(legacySaved)
        let before = await store.readOnePasswordRef(account: accountA)
        XCTAssertEqual(before, legacy)

        let result = await store.deleteOnePasswordRefResult(account: accountA)

        XCTAssertEqual(result, .durable)
        let after = await store.readOnePasswordRef(account: accountA)
        let other = await store.readOnePasswordRef(account: accountB)
        let shared = await store.readOnePasswordRef()
        XCTAssertNil(after)
        XCTAssertEqual(other, legacy)
        XCTAssertEqual(shared, legacy)
    }

    func testFailedClearOfMissingScopedReferenceKeepsLegacyFallback() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarOnePasswordClearTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            PrivateFileFaults.reset()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let legacy = "op://fictional/shared/field"
        let account = "ai-key-fictional-a"
        let saved = await store.saveOnePasswordRef(legacy)
        XCTAssertTrue(saved)

        PrivateFileFaults.failBeforeRename = true
        let result = await store.deleteOnePasswordRefResult(account: account)
        PrivateFileFaults.reset()

        XCTAssertEqual(result, .notCommitted)
        let current = await store.readOnePasswordRef(account: account)
        let shared = await store.readOnePasswordRef()
        XCTAssertEqual(current, legacy)
        XCTAssertEqual(shared, legacy)
    }

    func testUncertainClearOfMissingScopedReferenceDoesNotReviveLegacy() async throws {
        for verificationFailure in [false, true] {
            let directory = try researchTestDirectory()
            let suiteName = "NewsBarOnePasswordClearTests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer {
                PrivateFileFaults.reset()
                defaults.removePersistentDomain(forName: suiteName)
                try? FileManager.default.removeItem(at: directory)
            }
            let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
            let legacy = "op://fictional/shared/field"
            let account = "ai-key-fictional-a"
            let saved = await store.saveOnePasswordRef(legacy)
            XCTAssertTrue(saved)
            if verificationFailure {
                PrivateFileFaults.failVerificationAfterWrite = true
            } else {
                PrivateFileFaults.failAfterRename = true
            }

            let result = await store.deleteOnePasswordRefResult(account: account)
            PrivateFileFaults.reset()

            XCTAssertEqual(result, verificationFailure ? .unverified : .committedDurabilityUnknown)
            let state = await store.readOnePasswordRefResult(account: account)
            let effective = state.value(orIfMissing: legacy)
            XCTAssertTrue(effective == nil || effective == "")
            let shared = await store.readOnePasswordRef()
            XCTAssertEqual(shared, legacy)
        }
    }

    func testGenericScopedReferenceDeleteRespectsClearAndMetadataOnRetry() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarOnePasswordClearTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            PrivateFileFaults.reset()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let legacy = "op://fictional/shared/field"
        let current = "op://fictional/current/field"
        let account = "ai-key-fictional"
        let scoped = "one-password-ref.\(account)"
        let legacySaved = await store.saveOnePasswordRef(legacy)
        let currentSaved = await store.saveOnePasswordRef(current, account: account)
        XCTAssertTrue(legacySaved && currentSaved)
        let originalTimestamp = defaults.double(forKey: "apiKeyLastSaved-\(scoped)")
        XCTAssertTrue(defaults.bool(forKey: "hasAIKey-\(scoped)"))
        XCTAssertGreaterThan(originalTimestamp, 0)

        PrivateFileFaults.failBeforeRename = true
        let failed = await store.deleteAPIKeyResult(account: scoped)
        PrivateFileFaults.reset()
        let preserved = await store.readOnePasswordRef(account: account)
        XCTAssertEqual(failed, .notCommitted)
        XCTAssertEqual(preserved, current)
        XCTAssertTrue(defaults.bool(forKey: "hasAIKey-\(scoped)"))
        XCTAssertEqual(defaults.double(forKey: "apiKeyLastSaved-\(scoped)"), originalTimestamp)

        let retried = await store.deleteAPIKeyResult(account: scoped)
        let cleared = await store.readOnePasswordRef(account: account)
        let shared = await store.readOnePasswordRef()
        XCTAssertEqual(retried, .durable)
        XCTAssertNil(cleared)
        XCTAssertEqual(shared, legacy)
        XCTAssertNil(defaults.object(forKey: "hasAIKey-\(scoped)"))
        XCTAssertNil(defaults.object(forKey: "apiKeyLastSaved-\(scoped)"))
    }

    func testFailedReferenceResaveKeepsPreviousClearAcrossStoreInstances() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarOnePasswordClearTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            PrivateFileFaults.reset()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let legacy = "op://fictional/shared/field"
        let account = "ai-key-fictional"
        let saved = await store.saveOnePasswordRef(legacy)
        XCTAssertTrue(saved)
        let cleared = await store.deleteOnePasswordRefResult(account: account)
        XCTAssertEqual(cleared, .durable)

        PrivateFileFaults.failBeforeRename = true
        let failed = await store.saveOnePasswordRefResult("op://fictional/new/field", account: account)
        PrivateFileFaults.reset()

        XCTAssertEqual(failed, .notCommitted)
        let reopened = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let state = await reopened.readOnePasswordRefResult(account: account)
        XCTAssertNotEqual(state.value(orIfMissing: legacy), legacy)
        XCTAssertNil(defaults.object(forKey: "hasAIKey-one-password-ref.\(account)"))
        let shared = await reopened.readOnePasswordRef()
        XCTAssertEqual(shared, legacy)
    }

    func testCustomProviderRevocationDoesNotRestoreLegacyReferenceOnReactivation() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarOnePasswordClearTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let account = "custom:fictional-provider"
        let legacy = "op://fictional/shared/field"
        let legacySaved = await store.saveOnePasswordRef(legacy)
        let scopedSaved = await store.saveOnePasswordRef("op://fictional/custom/field", account: account)
        XCTAssertTrue(legacySaved && scopedSaved)

        let deleted = await store.deleteCustomProviderCredentials(account: account)
        XCTAssertTrue(deleted)
        let revokedRead = await store.readBoundCustomReferenceResult(account: account, endpointIdentity: "endpoint-A")
        XCTAssertEqual(revokedRead, .missing)
        let revokedGeneration = await store.customProviderRevocationGeneration(account: account)
        let generation = try XCTUnwrap(revokedGeneration)
        let reactivated = await store.reactivateCustomProviderCredentials(account: account, matchingRevocation: generation)
        let activeGeneration = try XCTUnwrap(reactivated)

        let afterReactivation = await store.readBoundCustomReferenceResult(account: account, endpointIdentity: "endpoint-A")
        XCTAssertEqual(afterReactivation, .missing)
        let staleSave = await store.saveOnePasswordRefResult("op://fictional/stale/field", account: account)
        XCTAssertEqual(staleSave, .notCommitted)
        let currentSave = await store.saveOnePasswordRefResult(
            "op://fictional/new/field", account: account, customProviderGeneration: activeGeneration
        )
        XCTAssertEqual(currentSave, .durable)
        let current = await store.readBoundCustomReferenceResult(account: account, endpointIdentity: "endpoint-A")
        let shared = await store.readOnePasswordRef()
        XCTAssertEqual(current, .unbound)
        XCTAssertEqual(shared, legacy)
    }

    func testUncertainReferenceClearRetryKeepsClearAndRemovesMetadata() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarOnePasswordClearTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            PrivateFileFaults.reset()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let account = "ai-key-fictional"
        let legacy = "op://fictional/shared/field"
        let legacySaved = await store.saveOnePasswordRef(legacy)
        let scopedSaved = await store.saveOnePasswordRef("op://fictional/current/field", account: account)
        XCTAssertTrue(legacySaved && scopedSaved)

        PrivateFileFaults.failAfterRename = true
        let uncertain = await store.deleteOnePasswordRefResult(account: account)
        PrivateFileFaults.reset()
        XCTAssertEqual(uncertain, .committedDurabilityUnknown)
        let firstState = await store.readOnePasswordRefResult(account: account)
        XCTAssertNotEqual(firstState.value(orIfMissing: legacy), legacy)

        let retried = await store.deleteOnePasswordRefResult(account: account)
        let finalState = await store.readOnePasswordRefResult(account: account)
        XCTAssertEqual(retried, .durable)
        XCTAssertNotEqual(finalState.value(orIfMissing: legacy), legacy)
        XCTAssertNil(defaults.object(forKey: "hasAIKey-one-password-ref.\(account)"))
        XCTAssertNil(defaults.object(forKey: "apiKeyLastSaved-one-password-ref.\(account)"))
        let shared = await store.readOnePasswordRef()
        XCTAssertEqual(shared, legacy)
    }

    func testGenericCredentialOperationsCannotOverwriteOrDeleteReferenceClearMarker() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarOnePasswordClearTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let account = "ai-key-fictional"
        let legacy = "op://fictional/shared/field"
        let saved = await store.saveOnePasswordRef(legacy)
        let cleared = await store.deleteOnePasswordRefResult(account: account)
        XCTAssertTrue(saved)
        XCTAssertEqual(cleared, .durable)
        let file = directory.appendingPathComponent("apikeys.enc")
        let payload = try JSONDecoder().decode(EncryptedKeyStore.EncryptedPayload.self, from: Data(contentsOf: file))
        let marker = try XCTUnwrap(payload.entries.first(where: { $0.account.hasPrefix("__newsbar_1password_cleared_v1__.") }))

        let overwritten = await store.saveAPIKeyResult("fictional-value", account: marker.account)
        let removed = await store.deleteAPIKeyResult(account: marker.account)
        XCTAssertEqual(overwritten, .notCommitted)
        XCTAssertEqual(removed, .notCommitted)
        let state = await store.readOnePasswordRefResult(account: account)
        XCTAssertNotEqual(state.value(orIfMissing: legacy), legacy)
    }

    func testManualKeySaveOnlyUpdatesReferenceWhenUserEditedIt() {
        XCTAssertNil(AIKeyReferencePolicy.manualKeySaveReference("", userEdited: false))
        XCTAssertNil(AIKeyReferencePolicy.manualKeySaveReference("op://fictional/legacy/field", userEdited: false))
        XCTAssertEqual(AIKeyReferencePolicy.manualKeySaveReference("", userEdited: true), "")
        XCTAssertEqual(
            AIKeyReferencePolicy.manualKeySaveReference("op://fictional/new/field", userEdited: true),
            "op://fictional/new/field"
        )
    }
}
