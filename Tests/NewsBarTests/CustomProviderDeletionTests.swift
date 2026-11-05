import XCTest
@testable import NewsBar

final class CustomProviderDeletionTests: XCTestCase {
    func testCredentialEndpointIdentityCoversDestinationAndAuthentication() {
        let connection = ResolvedAIConnection(
            baseURL: "https://fictional.example/v1/chat", responseFormat: .openAI,
            authHeaderName: "Authorization", authHeaderPrefix: "Bearer ", apiVersion: nil,
            providerID: "custom:fictional"
        )
        let identity = connection.credentialEndpointIdentity
        XCTAssertEqual(identity, connection.credentialEndpointIdentity)

        var changed = connection
        changed.baseURL = "https://other.example/v1/chat"
        XCTAssertNotEqual(identity, changed.credentialEndpointIdentity)
        changed = connection
        changed.baseURL = "https://fictional.example/v1/chat?route=other"
        XCTAssertNotEqual(identity, changed.credentialEndpointIdentity)
        changed = connection
        changed.responseFormat = .anthropic
        XCTAssertNotEqual(identity, changed.credentialEndpointIdentity)
        changed = connection
        changed.authHeaderName = "x-api-key"
        XCTAssertNotEqual(identity, changed.credentialEndpointIdentity)
        changed = connection
        changed.authHeaderPrefix = "Token "
        XCTAssertNotEqual(identity, changed.credentialEndpointIdentity)
        changed = connection
        changed.apiVersion = ""
        XCTAssertNotEqual(identity, changed.credentialEndpointIdentity)
        changed = connection
        changed.additionalHeaders = ["X-Route": "fictional"]
        XCTAssertNotEqual(identity, changed.credentialEndpointIdentity)
    }

    func testCredentialEndpointIdentityIgnoresNonRoutingConfiguration() {
        let connection = ResolvedAIConnection(
            baseURL: "https://fictional.example/v1/chat", responseFormat: .openAI,
            authHeaderName: "Authorization", authHeaderPrefix: "Bearer ", apiVersion: nil,
            providerID: "custom:fictional"
        )
        var changed = connection
        changed.providerID = "custom:other"
        changed.thinkingStyle = .none
        XCTAssertEqual(connection.credentialEndpointIdentity, changed.credentialEndpointIdentity)
    }

    func testCredentialEndpointIdentitySeparatesFieldBoundaries() {
        let first = ResolvedAIConnection(
            baseURL: "https://fictional.example/a", responseFormat: .openAI,
            authHeaderName: "x:header", authHeaderPrefix: "prefix", apiVersion: nil
        )
        var second = first
        second.authHeaderName = "x"
        second.authHeaderPrefix = "header:prefix"
        XCTAssertNotEqual(first.credentialEndpointIdentity, second.credentialEndpointIdentity)
    }

    func testConnectionChangesRequireExplicitCredentialReset() {
        let original = CustomAIProviderConfig(
            id: "fictional", name: "Old name", baseURL: "https://old.example.com/v1/chat/completions", models: []
        )
        var changed = original
        changed.name = "New name"
        changed.pricingNote = "fictional pricing"
        XCTAssertFalse(AICustomProviderConnectionPolicy.requiresCredentialReset(from: original, to: changed))

        changed = original
        changed.baseURL = "https://new.example.com/v1/chat/completions"
        XCTAssertTrue(AICustomProviderConnectionPolicy.requiresCredentialReset(from: original, to: changed))
        changed = original
        changed.authHeaderName = "x-api-key"
        XCTAssertTrue(AICustomProviderConnectionPolicy.requiresCredentialReset(from: original, to: changed))
        changed = original
        changed.responseFormat = .anthropic
        XCTAssertTrue(AICustomProviderConnectionPolicy.requiresCredentialReset(from: original, to: changed))
    }

    func testDeletionOnlyRemovesConfigurationAfterConfirmedDurableRevocation() {
        let durable = AICustomProviderDeletionPolicy.decision(for: .durable)
        XCTAssertTrue(durable.removeProvider)
        XCTAssertTrue(durable.clearCachedKey)
        XCTAssertEqual(durable.feedback, .customProviderDeleted)

        let failed = AICustomProviderDeletionPolicy.decision(for: .notCommitted)
        XCTAssertFalse(failed.removeProvider)
        XCTAssertFalse(failed.clearCachedKey)
        XCTAssertEqual(failed.feedback, .customProviderDeleteFailed)

        let unsynced = AICustomProviderDeletionPolicy.decision(for: .committedDurabilityUnknown)
        XCTAssertFalse(unsynced.removeProvider)
        XCTAssertTrue(unsynced.clearCachedKey)
        XCTAssertEqual(unsynced.feedback, .customProviderDeleteDurabilityUnknown)

        let unverified = AICustomProviderDeletionPolicy.decision(for: .unverified)
        XCTAssertFalse(unverified.removeProvider)
        XCTAssertTrue(unverified.clearCachedKey)
        XCTAssertEqual(unverified.feedback, .customProviderDeleteUnverified)
    }

    func testDeletingProviderRemovesOnlyItsKeyAndReference() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarCustomProviderDeletion-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let account = "custom:fictional-provider"
        let keySaved = await store.saveAPIKey("fictional-key", account: account)
        let refSaved = await store.saveOnePasswordRef("op://fictional/scoped/key", account: account)
        let sharedSaved = await store.saveOnePasswordRef("op://fictional/shared/key")
        let otherSaved = await store.saveAPIKey("fictional-other", account: "ai-key-other")
        XCTAssertTrue(keySaved && refSaved && sharedSaved && otherSaved)

        let result = await store.deleteCustomProviderCredentialsResult(account: account)
        XCTAssertEqual(result, .durable)
        let key = await store.readAPIKeyResult(account: account)
        let ref = await store.readOnePasswordRefResult(account: account)
        let shared = await store.readOnePasswordRef()
        let other = await store.readAPIKeyResult(account: "ai-key-other")
        XCTAssertEqual(key, .missing)
        XCTAssertEqual(ref, .missing)
        XCTAssertEqual(shared, "op://fictional/shared/key")
        XCTAssertEqual(other, .found("fictional-other"))
        let late = await store.saveAPIKeyResult("fictional-late", account: account)
        XCTAssertEqual(late, .notCommitted)
    }

    func testDeletionReportsEachWriteOutcomeWithoutClaimingDurability() async throws {
        enum Fault: CaseIterable { case beforeRename, afterRename, verification }
        for fault in Fault.allCases {
            let directory = try researchTestDirectory()
            let suiteName = "NewsBarCustomProviderDeletion-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer {
                PrivateFileFaults.reset()
                defaults.removePersistentDomain(forName: suiteName)
                try? FileManager.default.removeItem(at: directory)
            }
            let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
            let account = "custom:fictional-provider"
            let saved = await store.saveAPIKey("fictional-key", account: account)
            XCTAssertTrue(saved)
            switch fault {
            case .beforeRename: PrivateFileFaults.failBeforeRename = true
            case .afterRename: PrivateFileFaults.failAfterRename = true
            case .verification: PrivateFileFaults.failVerificationAfterWrite = true
            }
            let result = await store.deleteCustomProviderCredentialsResult(account: account)
            PrivateFileFaults.reset()

            let actual = await store.readBoundCustomKeyResult(account: account, endpointIdentity: "endpoint-A")
            switch fault {
            case .beforeRename:
                XCTAssertEqual(result, .notCommitted)
                XCTAssertEqual(actual, .unbound)
            case .afterRename:
                XCTAssertEqual(result, .committedDurabilityUnknown)
                XCTAssertEqual(actual, .missing)
            case .verification:
                XCTAssertEqual(result, .unverified)
                XCTAssertEqual(actual, .missing)
            }
        }
    }

    func testRevokedProviderCannotReadAResidualKey() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarCustomProviderDeletion-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let account = "custom:fictional-provider"
        let saved = await store.saveAPIKey("fictional-key", account: account)
        XCTAssertTrue(saved)
        let file = directory.appendingPathComponent("apikeys.enc")
        var payload = try JSONDecoder().decode(EncryptedKeyStore.EncryptedPayload.self, from: Data(contentsOf: file))
        payload.customProviderCredentials = [account: .init(generation: "fictional-revocation", revoked: true)]
        try PrivateFile.write(JSONEncoder().encode(payload), to: file, durable: false)

        let result = await store.readAPIKeyResult(account: account)
        let exists = await store.checkAPIKeyExistence(account: account)
        XCTAssertEqual(result, .missing)
        XCTAssertFalse(exists)
    }

    func testOldDeletionCannotRevokeAProviderAfterItIsRestored() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarCustomProviderGeneration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let account = "custom:fictional-provider"
        let firstDelete = await store.deleteCustomProviderCredentialsResult(account: account, expectedState: nil)
        XCTAssertEqual(firstDelete, .durable)
        let revoked = await store.customProviderCredentialStateResult(account: account)
        guard case let .state(revokedState) = revoked else { return XCTFail("Missing revocation") }
        let restored = await store.reactivateCustomProviderCredentialsResult(
            account: account, matchingRevocation: revokedState.generation
        )
        guard case let .activated(generation) = restored else { return XCTFail("Recovery failed") }
        let saved = await store.saveAPIKeyResult("new-fictional-key", account: account, customProviderGeneration: generation)
        XCTAssertEqual(saved, .durable)

        let staleDelete = await store.deleteCustomProviderCredentialsResult(account: account, expectedState: nil)
        XCTAssertEqual(staleDelete, .notCommitted)
        let reloaded = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let current = await reloaded.customProviderCredentialStateResult(account: account)
        XCTAssertEqual(current, .state(.init(generation: generation, revoked: false)))
        let retainedKey = await reloaded.readBoundCustomKeyResult(account: account, endpointIdentity: "endpoint-A")
        XCTAssertEqual(retainedKey, .unbound)
    }

    func testConnectionChangeRejectsOldWritesWithoutRemovingSharedReference() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarCustomProviderEndpoint-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let account = "custom:fictional-provider"
        let initialKey = await store.saveAPIKey("old-fictional-key", account: account)
        let scopedRef = await store.saveOnePasswordRef("op://fictional/old/key", account: account)
        let sharedRef = await store.saveOnePasswordRef("op://fictional/shared/key")
        XCTAssertTrue(initialKey && scopedRef && sharedRef)

        let reset = await store.resetCustomProviderCredentialsForConnectionChange(account: account, expectedState: nil)
        XCTAssertEqual(reset, .durable)
        let result = await store.customProviderCredentialStateResult(account: account)
        guard case let .state(state) = result else { return XCTFail("Missing new generation") }
        XCTAssertFalse(state.revoked)
        let keyAfterReset = await store.readAPIKeyResult(account: account)
        let refAfterReset = await store.readOnePasswordRefResult(account: account)
        let sharedAfterReset = await store.readOnePasswordRef()
        XCTAssertEqual(keyAfterReset, .missing)
        XCTAssertEqual(refAfterReset, .missing)
        XCTAssertEqual(sharedAfterReset, "op://fictional/shared/key")

        let lateKey = await store.saveAPIKeyResult("late-fictional-key", account: account)
        let lateRef = await store.saveOnePasswordRefResult("op://fictional/late/key", account: account)
        XCTAssertEqual(lateKey, .notCommitted)
        XCTAssertEqual(lateRef, .notCommitted)
        let newKey = await store.saveAPIKeyResult("new-fictional-key", account: account, customProviderGeneration: state.generation)
        XCTAssertEqual(newKey, .durable)
    }

    func testDeletingCustomKeyRejectsOldGenerationAndKeepsReferences() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarCustomKeyDelete-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let oldWriter = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let account = "custom:fictional-provider"
        let reset = await store.resetCustomProviderCredentialsForConnectionChange(account: account, expectedState: nil)
        XCTAssertEqual(reset, .durable)
        let initialState = await store.customProviderCredentialStateResult(account: account)
        guard case let .state(initial) = initialState else { return XCTFail("Missing active generation") }
        let saved = await store.saveAPIKeyResult("fictional-old-key", account: account, customProviderGeneration: initial.generation)
        let reference = await store.saveOnePasswordRefResult("op://fictional/scoped/key", account: account, customProviderGeneration: initial.generation)
        let shared = await store.saveOnePasswordRef("op://fictional/shared/key")
        XCTAssertEqual(saved, .durable)
        XCTAssertEqual(reference, .durable)
        XCTAssertTrue(shared)

        let deleted = await store.deleteAPIKeyResult(account: account, customProviderGeneration: initial.generation)
        XCTAssertEqual(deleted, .durable)
        let nextState = await store.customProviderCredentialStateResult(account: account)
        guard case let .state(next) = nextState else { return XCTFail("Missing post-deletion generation") }
        XCTAssertFalse(next.revoked)
        XCTAssertNotEqual(next.generation, initial.generation)
        let oldKey = await oldWriter.saveAPIKeyResult("fictional-late-key", account: account, customProviderGeneration: initial.generation)
        let oldReference = await oldWriter.saveOnePasswordRefResult("op://fictional/late/key", account: account, customProviderGeneration: initial.generation)
        XCTAssertEqual(oldKey, .notCommitted)
        XCTAssertEqual(oldReference, .notCommitted)
        let retainedReference = await store.readOnePasswordRefResult(account: account)
        let boundReference = await store.readBoundCustomReferenceResult(account: account, endpointIdentity: "endpoint-A")
        let retainedShared = await store.readOnePasswordRef()
        XCTAssertEqual(retainedReference, .missing)
        XCTAssertEqual(boundReference, .unbound)
        XCTAssertEqual(retainedShared, "op://fictional/shared/key")

        let newKey = await store.saveAPIKeyResult("fictional-new-key", account: account, customProviderGeneration: next.generation)
        let staleDelete = await oldWriter.deleteAPIKeyResult(account: account, customProviderGeneration: initial.generation)
        let retainedKey = await store.readBoundCustomKeyResult(account: account, endpointIdentity: "endpoint-A")
        XCTAssertEqual(newKey, .durable)
        XCTAssertEqual(staleDelete, .notCommitted)
        XCTAssertEqual(retainedKey, .unbound)
    }

    func testDeletingMissingLegacyCustomKeyStillInvalidatesOldWriters() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarMissingCustomKeyDelete-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let account = "custom:fictional-provider"

        let deleted = await store.deleteAPIKeyResult(account: account)
        XCTAssertEqual(deleted, .durable)
        let stateResult = await store.customProviderCredentialStateResult(account: account)
        guard case let .state(state) = stateResult else { return XCTFail("Deletion must create a generation") }
        XCTAssertFalse(state.revoked)
        let lateWrite = await store.saveAPIKeyResult("fictional-late-key", account: account)
        let key = await store.readAPIKeyResult(account: account)
        XCTAssertEqual(lateWrite, .notCommitted)
        XCTAssertEqual(key, .missing)
    }
}
