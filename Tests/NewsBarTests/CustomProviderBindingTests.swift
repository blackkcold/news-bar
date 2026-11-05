import XCTest
@testable import NewsBar

final class CustomProviderBindingTests: XCTestCase {
    func testUnboundStoredReferenceIsRejectedBeforeSecretRead() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarBindingImportRefusal-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults, testMachineIdentifier: { "fictional-machine" })
        let account = "custom:fictional"
        let oldReferenceSaved = await store.saveOnePasswordRef("op://fictional/old/key", account: account)
        XCTAssertTrue(oldReferenceSaved)
        var didReadSecret = false
        do {
            _ = try await AIOnePasswordKeyImport.run(
                reference: "op://fictional/old/key", account: account, store: store,
                endpointIdentity: "endpoint-A", referenceWasEdited: false
            ) { _ in
                didReadSecret = true
                return "fictional-secret"
            }
            XCTFail("An unbound stored reference must not be read")
        } catch let error as AICustomProviderCredentialError {
            XCTAssertEqual(error.result, .notCommitted)
        }
        XCTAssertFalse(didReadSecret)
        let retained = await store.readOnePasswordRefResult(account: account)
        let bound = await store.readBoundCustomReferenceResult(account: account, endpointIdentity: "endpoint-A")
        XCTAssertEqual(retained, .missing)
        XCTAssertEqual(bound, .unbound)
    }

    func testExplicitlyEnteredReferenceBindsImportedKeyToCurrentEndpoint() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarBindingImportExplicit-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults, testMachineIdentifier: { "fictional-machine" })
        let account = "custom:fictional"
        let outcome = try await AIOnePasswordKeyImport.run(
            reference: "op://fictional/item/key", account: account, store: store,
            endpointIdentity: "endpoint-A", referenceWasEdited: true
        ) { _ in "fictional-key" }
        XCTAssertEqual(outcome.result, .durable)
        XCTAssertEqual(outcome.customProviderState?.endpointIdentity, "endpoint-A")
        XCTAssertEqual(outcome.customProviderState?.generation, outcome.customProviderGeneration)
        let same = await store.readBoundCustomKeyResult(account: account, endpointIdentity: "endpoint-A")
        let other = await store.readBoundCustomKeyResult(account: account, endpointIdentity: "endpoint-B")
        XCTAssertEqual(same, .found("fictional-key"))
        XCTAssertEqual(other, .endpointMismatch)
    }

    func testLegacyCredentialIsUnboundAndRetained() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarBindingLegacy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults, testMachineIdentifier: { "fictional-machine" })
        let account = "custom:fictional"
        let keySaved = await store.saveAPIKey("fictional-old-key", account: account)
        let referenceSaved = await store.saveOnePasswordRef("op://fictional/old/key", account: account)
        let sharedSaved = await store.saveOnePasswordRef("op://fictional/shared/key")
        XCTAssertTrue(keySaved && referenceSaved && sharedSaved)

        let key = await store.readBoundCustomKeyResult(account: account, endpointIdentity: "endpoint-A")
        let reference = await store.readBoundCustomReferenceResult(account: account, endpointIdentity: "endpoint-A")
        let oldKey = await store.readAPIKeyResult(account: account)
        let oldReference = await store.readOnePasswordRefResult(account: account)
        let shared = await store.readOnePasswordRef()
        XCTAssertEqual(key, .unbound)
        XCTAssertEqual(reference, .unbound)
        // The generic readers have no endpoint context and now fail closed for
        // custom credentials; the bound readers above prove retention.
        XCTAssertEqual(oldKey, .missing)
        XCTAssertEqual(oldReference, .missing)
        XCTAssertEqual(shared, "op://fictional/shared/key")
    }

    func testBoundKeyAndReferenceCannotBeReadForAnotherEndpoint() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarBindingDestination-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults, testMachineIdentifier: { "fictional-machine" })
        let account = "custom:fictional"
        let saved = await store.saveBoundCustomKeyResult(
            "fictional-key", account: account, expectedState: nil, endpointIdentity: "endpoint-A"
        )
        XCTAssertEqual(saved.result, .durable)
        let state = try XCTUnwrap(saved.state)
        let savedReference = await store.saveBoundCustomReferenceResult(
            "op://fictional/item/key", account: account, expectedState: state, endpointIdentity: "endpoint-A"
        )
        XCTAssertEqual(savedReference, .durable)

        let sameKey = await store.readBoundCustomKeyResult(account: account, endpointIdentity: "endpoint-A")
        let otherKey = await store.readBoundCustomKeyResult(account: account, endpointIdentity: "endpoint-B")
        let sameRef = await store.readBoundCustomReferenceResult(account: account, endpointIdentity: "endpoint-A")
        let otherRef = await store.readBoundCustomReferenceResult(account: account, endpointIdentity: "endpoint-B")
        XCTAssertEqual(sameKey, .found("fictional-key"))
        XCTAssertEqual(otherKey, .endpointMismatch)
        XCTAssertEqual(sameRef, .found("op://fictional/item/key"))
        XCTAssertEqual(otherRef, .endpointMismatch)
    }

    func testRebindingInvalidatesStaleWriterAndKeepsOldReference() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarBindingRebind-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let first = EncryptedKeyStore(directory: directory, metadataDefaults: defaults, testMachineIdentifier: { "fictional-machine" })
        let second = EncryptedKeyStore(directory: directory, metadataDefaults: defaults, testMachineIdentifier: { "fictional-machine" })
        let account = "custom:fictional"
        let saved = await first.saveBoundCustomKeyResult("fictional-A", account: account, expectedState: nil, endpointIdentity: "endpoint-A")
        let initial = try XCTUnwrap(saved.state)
        let referenceSaved = await first.saveBoundCustomReferenceResult(
            "op://fictional/old/key", account: account, expectedState: initial, endpointIdentity: "endpoint-A"
        )
        XCTAssertEqual(referenceSaved, .durable)
        let referenceStateResult = await first.customProviderCredentialStateResult(account: account)
        guard case let .state(referenceState) = referenceStateResult else { return XCTFail("Missing active state") }

        let rebound = await first.saveBoundCustomKeyResult(
            "fictional-B", account: account, expectedState: referenceState, endpointIdentity: "endpoint-B"
        )
        XCTAssertEqual(rebound.result, .durable)
        let stale = await second.saveBoundCustomKeyResult(
            "fictional-stale", account: account, expectedState: referenceState, endpointIdentity: "endpoint-A"
        )
        XCTAssertEqual(stale.result, .notCommitted)
        let current = await first.readBoundCustomKeyResult(account: account, endpointIdentity: "endpoint-B")
        let reference = await first.readBoundCustomReferenceResult(account: account, endpointIdentity: "endpoint-B")
        let oldEndpointReference = await first.readBoundCustomReferenceResult(account: account, endpointIdentity: "endpoint-A")
        let retainedReference = await first.readOnePasswordRefResult(account: account)
        XCTAssertEqual(current, .found("fictional-B"))
        XCTAssertEqual(reference, .unbound)
        XCTAssertEqual(oldEndpointReference, .unbound)
        // The generic reader fails closed; the old entry is still retained but
        // cannot be returned without an endpoint binding.
        XCTAssertEqual(retainedReference, .missing)
    }

    func testReferenceChangeInvalidatesEarlierImportSnapshot() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarBindingReferenceRace-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults, testMachineIdentifier: { "fictional-machine" })
        let account = "custom:fictional"
        let firstKey = await store.saveBoundCustomKeyResult("fictional-A", account: account, expectedState: nil, endpointIdentity: "endpoint-A")
        let initial = try XCTUnwrap(firstKey.state)
        let firstReference = await store.saveBoundCustomReferenceResult(
            "op://fictional/first/key", account: account, expectedState: initial, endpointIdentity: "endpoint-A"
        )
        XCTAssertEqual(firstReference, .durable)
        let capturedResult = await store.customProviderCredentialStateResult(account: account)
        guard case let .state(captured) = capturedResult else { return XCTFail("Missing state") }
        let newerReference = await store.saveBoundCustomReferenceResult(
            "op://fictional/second/key", account: account, expectedState: captured, endpointIdentity: "endpoint-A"
        )
        XCTAssertEqual(newerReference, .durable)
        let staleImport = await store.saveBoundCustomKeyResult(
            "fictional-stale", account: account, expectedState: captured, endpointIdentity: "endpoint-A"
        )
        XCTAssertEqual(staleImport.result, .notCommitted)
        let key = await store.readBoundCustomKeyResult(account: account, endpointIdentity: "endpoint-A")
        XCTAssertEqual(key, .found("fictional-A"))
    }

    func testReferenceRetryCannotOverwriteANewerReference() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarReferenceRetryRace-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            PrivateFileFaults.reset()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let first = EncryptedKeyStore(directory: directory, metadataDefaults: defaults, testMachineIdentifier: { "fictional-machine" })
        let second = EncryptedKeyStore(directory: directory, metadataDefaults: defaults, testMachineIdentifier: { "fictional-machine" })
        let account = "custom:fictional"
        let key = await first.saveBoundCustomKeyResult("fictional-key", account: account, expectedState: nil, endpointIdentity: "endpoint-A")
        let before = try XCTUnwrap(key.state)

        PrivateFileFaults.failBeforeRename = true
        let failed = await first.applyBoundCustomReferenceResult(
            "op://fictional/old/key", account: account, expectedState: before,
            endpointIdentity: "endpoint-A", operationRevision: "old-operation"
        )
        PrivateFileFaults.reset()
        XCTAssertEqual(failed, .notCommitted)
        let newer = await second.applyBoundCustomReferenceResult(
            "op://fictional/new/key", account: account, expectedState: before,
            endpointIdentity: "endpoint-A", operationRevision: "new-operation"
        )
        XCTAssertEqual(newer, .durable)
        let retried = await first.applyBoundCustomReferenceResult(
            "op://fictional/old/key", account: account, expectedState: before,
            endpointIdentity: "endpoint-A", operationRevision: "old-operation"
        )
        XCTAssertEqual(retried, .notCommitted)
        let current = await first.readBoundCustomReferenceResult(account: account, endpointIdentity: "endpoint-A")
        XCTAssertEqual(current, .found("op://fictional/new/key"))
    }

    func testKeySaveCarriesItsExactReferenceRevisionIntoTheFollowupWrite() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarReferenceAfterKeySave-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let first = EncryptedKeyStore(directory: directory, metadataDefaults: defaults, testMachineIdentifier: { "fictional-machine" })
        let second = EncryptedKeyStore(directory: directory, metadataDefaults: defaults, testMachineIdentifier: { "fictional-machine" })
        let account = "custom:fictional"
        let initial = await first.saveBoundCustomKeyResult(
            "fictional-key-A", account: account, expectedState: nil, endpointIdentity: "endpoint-A"
        )
        let initialState = try XCTUnwrap(initial.state)
        let initialReference = await first.saveBoundCustomReferenceResult(
            "op://fictional/initial/key", account: account, expectedState: initialState, endpointIdentity: "endpoint-A"
        )
        XCTAssertEqual(initialReference, .durable)
        guard case let .state(beforeSave) = await first.customProviderCredentialStateResult(account: account) else {
            return XCTFail("Missing reference state")
        }
        let saved = try await AICustomProviderCredentialAccess.save(
            "fictional-key-B", account: account, store: first,
            capturedState: beforeSave, endpointIdentity: "endpoint-A"
        )
        XCTAssertEqual(saved.result, .durable)
        let savedState = try XCTUnwrap(saved.state)
        XCTAssertEqual(savedState.referenceRevision, beforeSave.referenceRevision)
        let newer = await second.saveBoundCustomReferenceResult(
            "op://fictional/new/key", account: account, expectedState: savedState, endpointIdentity: "endpoint-A"
        )
        XCTAssertEqual(newer, .durable)
        let staleFollowup = await first.applyBoundCustomReferenceResult(
            "op://fictional/old/key", account: account, expectedState: savedState,
            endpointIdentity: "endpoint-A", operationRevision: "fixture-old-followup"
        )
        XCTAssertEqual(staleFollowup, .notCommitted)
        let current = await first.readBoundCustomReferenceResult(account: account, endpointIdentity: "endpoint-A")
        XCTAssertEqual(current, .found("op://fictional/new/key"))
    }

    func testReferenceRetryCannotRestoreADeletedReference() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarReferenceRetryDeletion-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            PrivateFileFaults.reset()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let first = EncryptedKeyStore(directory: directory, metadataDefaults: defaults, testMachineIdentifier: { "fictional-machine" })
        let second = EncryptedKeyStore(directory: directory, metadataDefaults: defaults, testMachineIdentifier: { "fictional-machine" })
        let account = "custom:fictional"
        let key = await first.saveBoundCustomKeyResult("fictional-key", account: account, expectedState: nil, endpointIdentity: "endpoint-A")
        let initial = try XCTUnwrap(key.state)
        let saved = await first.saveBoundCustomReferenceResult(
            "op://fictional/original/key", account: account, expectedState: initial, endpointIdentity: "endpoint-A"
        )
        XCTAssertEqual(saved, .durable)
        guard case let .state(before) = await first.customProviderCredentialStateResult(account: account) else {
            return XCTFail("Missing reference state")
        }
        PrivateFileFaults.failBeforeRename = true
        let failed = await first.applyBoundCustomReferenceResult(
            "op://fictional/old/key", account: account, expectedState: before,
            endpointIdentity: "endpoint-A", operationRevision: "old-operation"
        )
        PrivateFileFaults.reset()
        XCTAssertEqual(failed, .notCommitted)
        let deleted = await second.deleteBoundCustomReferenceResult(
            account: account, expectedState: before, endpointIdentity: "endpoint-A"
        )
        XCTAssertEqual(deleted, .durable)
        let retried = await first.applyBoundCustomReferenceResult(
            "op://fictional/old/key", account: account, expectedState: before,
            endpointIdentity: "endpoint-A", operationRevision: "old-operation"
        )
        XCTAssertEqual(retried, .notCommitted)
        let current = await first.readBoundCustomReferenceResult(account: account, endpointIdentity: "endpoint-A")
        XCTAssertEqual(current, .missing)
    }

    func testReferenceRetryConfirmsOrRetriesItsOwnUncertainWrite() async throws {
        enum Fault { case beforeRename, afterRename, verification }
        for fault in [Fault.beforeRename, .afterRename, .verification] {
            let directory = try researchTestDirectory()
            let suiteName = "NewsBarReferenceRetryFault-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer {
                PrivateFileFaults.reset()
                defaults.removePersistentDomain(forName: suiteName)
                try? FileManager.default.removeItem(at: directory)
            }
            let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults, testMachineIdentifier: { "fictional-machine" })
            let account = "custom:fictional"
            let key = await store.saveBoundCustomKeyResult("fictional-key", account: account, expectedState: nil, endpointIdentity: "endpoint-A")
            let before = try XCTUnwrap(key.state)
            switch fault {
            case .beforeRename: PrivateFileFaults.failBeforeRename = true
            case .afterRename: PrivateFileFaults.failAfterRename = true
            case .verification: PrivateFileFaults.failVerificationAfterWrite = true
            }
            let first = await store.applyBoundCustomReferenceResult(
                "op://fictional/item/key", account: account, expectedState: before,
                endpointIdentity: "endpoint-A", operationRevision: "fixture-operation"
            )
            PrivateFileFaults.reset()
            switch fault {
            case .beforeRename: XCTAssertEqual(first, .notCommitted)
            case .afterRename: XCTAssertEqual(first, .committedDurabilityUnknown)
            case .verification: XCTAssertEqual(first, .unverified)
            }
            let file = directory.appendingPathComponent("apikeys.enc")
            let beforeRetry = try Data(contentsOf: file)
            let retried = await store.applyBoundCustomReferenceResult(
                "op://fictional/item/key", account: account, expectedState: before,
                endpointIdentity: "endpoint-A", operationRevision: "fixture-operation"
            )
            XCTAssertEqual(retried, .durable)
            let afterRetry = try Data(contentsOf: file)
            if fault != .beforeRename { XCTAssertEqual(afterRetry, beforeRetry) }
            let current = await store.readBoundCustomReferenceResult(account: account, endpointIdentity: "endpoint-A")
            XCTAssertEqual(current, .found("op://fictional/item/key"))
            guard case let .state(state) = await store.customProviderCredentialStateResult(account: account) else {
                return XCTFail("Missing reference state")
            }
            XCTAssertEqual(state.referenceRevision, "fixture-operation")
        }
    }

    func testCustomReferenceNeverFallsBackToSharedReference() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarBindingSharedReference-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults, testMachineIdentifier: { "fictional-machine" })
        let sharedSaved = await store.saveOnePasswordRef("op://fictional/shared/key")
        XCTAssertTrue(sharedSaved)
        let result = await store.readBoundCustomReferenceResult(account: "custom:fictional", endpointIdentity: "endpoint-A")
        let shared = await store.readOnePasswordRef()
        XCTAssertEqual(result, .missing)
        XCTAssertEqual(shared, "op://fictional/shared/key")
    }

    func testAutomaticRefreshRequiresMatchingKeyAndReferenceBindings() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarBindingRefresh-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults, testMachineIdentifier: { "fictional-machine" })
        let account = "custom:fictional"
        let sharedSaved = await store.saveOnePasswordRef("op://fictional/shared/key")
        XCTAssertTrue(sharedSaved)
        let saved = await store.saveBoundCustomKeyResult("fictional-key", account: account, expectedState: nil, endpointIdentity: "endpoint-A")
        let state = try XCTUnwrap(saved.state)
        let withoutScopedReference = await store.onePasswordRefreshSnapshot(account: account, endpointIdentity: "endpoint-A")
        XCTAssertNil(withoutScopedReference)
        let savedRef = await store.saveBoundCustomReferenceResult(
            "op://fictional/item/key", account: account, expectedState: state, endpointIdentity: "endpoint-A"
        )
        XCTAssertEqual(savedRef, .durable)
        let sameEndpoint = await store.onePasswordRefreshSnapshot(account: account, endpointIdentity: "endpoint-A")
        let otherEndpoint = await store.onePasswordRefreshSnapshot(account: account, endpointIdentity: "endpoint-B")
        let unknownEndpoint = await store.onePasswordRefreshSnapshot(account: account)
        XCTAssertEqual(sameEndpoint?.reference, .found("op://fictional/item/key"))
        XCTAssertNil(otherEndpoint)
        XCTAssertNil(unknownEndpoint)
    }

    func testDeletingKeyKeepsBoundReferenceAndInvalidatesEarlierGeneration() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarBindingKeyDeletion-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults, testMachineIdentifier: { "fictional-machine" })
        let account = "custom:fictional"
        let key = await store.saveBoundCustomKeyResult("fictional-key", account: account, expectedState: nil, endpointIdentity: "endpoint-A")
        let initial = try XCTUnwrap(key.state)
        let reference = await store.saveBoundCustomReferenceResult(
            "op://fictional/item/key", account: account, expectedState: initial, endpointIdentity: "endpoint-A"
        )
        XCTAssertEqual(reference, .durable)
        let deleted = await store.deleteAPIKeyResult(account: account, customProviderGeneration: initial.generation)
        XCTAssertEqual(deleted, .durable)
        let storedKey = await store.readBoundCustomKeyResult(account: account, endpointIdentity: "endpoint-A")
        let storedReference = await store.readBoundCustomReferenceResult(account: account, endpointIdentity: "endpoint-A")
        let stale = await store.saveBoundCustomKeyResult("fictional-stale", account: account, expectedState: initial, endpointIdentity: "endpoint-A")
        XCTAssertEqual(storedKey, .missing)
        // The key deletion also unbinds the saved reference so auto-renewal
        // cannot restore an old secret over a key saved later.
        XCTAssertEqual(storedReference, .unbound)
        XCTAssertEqual(stale.result, .notCommitted)
    }

    func testDeletingBoundReferenceKeepsSharedReferenceAndRejectsStaleSnapshot() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarBindingReferenceDeletion-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults, testMachineIdentifier: { "fictional-machine" })
        let account = "custom:fictional"
        let sharedSaved = await store.saveOnePasswordRef("op://fictional/shared/key")
        XCTAssertTrue(sharedSaved)
        let key = await store.saveBoundCustomKeyResult("fictional-key", account: account, expectedState: nil, endpointIdentity: "endpoint-A")
        let initial = try XCTUnwrap(key.state)
        let saved = await store.saveBoundCustomReferenceResult(
            "op://fictional/item/key", account: account, expectedState: initial, endpointIdentity: "endpoint-A"
        )
        XCTAssertEqual(saved, .durable)
        let currentResult = await store.customProviderCredentialStateResult(account: account)
        guard case let .state(current) = currentResult else { return XCTFail("Missing state") }
        let deleted = await store.deleteBoundCustomReferenceResult(account: account, expectedState: current, endpointIdentity: "endpoint-A")
        XCTAssertEqual(deleted, .durable)
        let stale = await store.saveBoundCustomReferenceResult(
            "op://fictional/stale/key", account: account, expectedState: current, endpointIdentity: "endpoint-A"
        )
        let remaining = await store.readBoundCustomReferenceResult(account: account, endpointIdentity: "endpoint-A")
        let shared = await store.readOnePasswordRef()
        XCTAssertEqual(stale, .notCommitted)
        XCTAssertEqual(remaining, .missing)
        XCTAssertEqual(shared, "op://fictional/shared/key")
    }

    func testExplicitLegacyBindingMigratesKeyAndReference() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarLegacyBinding-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(
            directory: directory, metadataDefaults: defaults,
            testMachineIdentifier: { "fictional-machine" }
        )
        let account = "custom:fictional"
        let keySaved = await store.saveAPIKey("legacy-key", account: account)
        let referenceSaved = await store.saveOnePasswordRef(
            "op://fictional/legacy/key", account: account
        )
        XCTAssertTrue(keySaved && referenceSaved)

        let unbound = await store.readBoundCustomKeyResult(
            account: account, endpointIdentity: "endpoint-A"
        )
        XCTAssertEqual(unbound, .unbound)

        let bound = await store.bindLegacyCustomCredentialsResult(
            account: account, endpointIdentity: "endpoint-A"
        )
        XCTAssertEqual(bound, .durable)

        let key = await store.readBoundCustomKeyResult(
            account: account, endpointIdentity: "endpoint-A"
        )
        let reference = await store.readBoundCustomReferenceResult(
            account: account, endpointIdentity: "endpoint-A"
        )
        XCTAssertEqual(key, .found("legacy-key"))
        XCTAssertEqual(reference, .found("op://fictional/legacy/key"))

        let rebound = await store.bindLegacyCustomCredentialsResult(
            account: account, endpointIdentity: "endpoint-B"
        )
        XCTAssertEqual(rebound, .notCommitted)
    }
}
