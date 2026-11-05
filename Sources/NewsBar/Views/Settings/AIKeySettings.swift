import SwiftUI

/// Outcome of a credential action. The tone is derived from the case so the UI
/// never decides colour by searching rendered, localized text.
enum AIKeyFeedback: String, Equatable, CaseIterable {
    case saved
    case saveFailed
    case saveDurabilityUnknown
    case saveUnverified
    case keyDeleted
    case deleteFailed
    case deleteDurabilityUnknown
    case deleteUnverified
    case customProviderDeleted
    case customProviderDeleteFailed
    case customProviderDeleteDurabilityUnknown
    case customProviderDeleteUnverified
    case customProviderCredentialsReset
    case loaded
    case invalidReference
    case notInstalled
    case timedOut
    case readFailed
    case loadedButNotSaved
    case referenceReadFailed
    case referenceSaveFailed
    case referenceDeleteFailed
    case referenceDurabilityUnknown
    case referenceUnverified
    case referenceBindingRequired
    case referenceChangedDuringRetry
    case unknown

    enum Tone: Equatable {
        case success
        case warning
        case error
    }

    var tone: Tone {
        switch self {
        case .saved, .keyDeleted, .customProviderDeleted, .loaded:
            return .success
        case .saveDurabilityUnknown, .saveUnverified, .deleteDurabilityUnknown, .deleteUnverified, .customProviderDeleteDurabilityUnknown, .customProviderDeleteUnverified, .customProviderCredentialsReset, .invalidReference, .notInstalled, .timedOut, .readFailed, .loadedButNotSaved, .referenceReadFailed, .referenceSaveFailed, .referenceDeleteFailed, .referenceDurabilityUnknown, .referenceUnverified, .referenceBindingRequired, .referenceChangedDuringRetry, .unknown:
            return .warning
        case .saveFailed, .deleteFailed, .customProviderDeleteFailed:
            return .error
        }
    }

    var isSuccess: Bool { tone == .success }

    private var key: String {
        switch self {
        case .saved: return "ai.saved"
        case .saveFailed: return "ai.saveFailed"
        case .saveDurabilityUnknown: return "ai.saveDurabilityUnknown"
        case .saveUnverified: return "ai.saveUnverified"
        case .keyDeleted: return "ai.keyDeleted"
        case .deleteFailed: return "ai.keyDeleteFailed"
        case .deleteDurabilityUnknown: return "ai.keyDeleteDurabilityUnknown"
        case .deleteUnverified: return "ai.keyDeleteUnverified"
        case .customProviderDeleted: return "ai.customProviderDeleted"
        case .customProviderDeleteFailed: return "ai.customProviderDeleteFailed"
        case .customProviderDeleteDurabilityUnknown: return "ai.customProviderDeleteDurabilityUnknown"
        case .customProviderDeleteUnverified: return "ai.customProviderDeleteUnverified"
        case .customProviderCredentialsReset: return "ai.custom.credentialsResetDone"
        case .loaded: return "ai.1p.success"
        case .invalidReference: return "ai.1p.invalidRef"
        case .notInstalled: return "ai.1p.notInstalled"
        case .timedOut: return "ai.1p.timeout"
        case .readFailed: return "ai.1p.readFailed"
        case .loadedButNotSaved: return "ai.1p.saveFailed"
        case .referenceReadFailed: return "ai.1p.referenceReadFailed"
        case .referenceSaveFailed: return "ai.1p.referenceSaveFailed"
        case .referenceDeleteFailed: return "ai.1p.referenceDeleteFailed"
        case .referenceDurabilityUnknown: return "ai.1p.referenceDurabilityUnknown"
        case .referenceUnverified: return "ai.1p.referenceUnverified"
        case .referenceBindingRequired: return "ai.1p.referenceBindingRequired"
        case .referenceChangedDuringRetry: return "ai.1p.referenceChangedDuringRetry"
        case .unknown: return "ai.1p.unknown"
        }
    }

    func text(language: AppLanguage) -> String {
        L10n.string(key, language: language)
    }

    var color: Color {
        switch tone {
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// Keeps one 1Password reference per credential account. A single global value
/// made saving a key for one provider overwrite the reference for another.
enum AIKeyReferenceScope {
    static func assign(_ reference: String, to account: String, in refs: [String: String]) -> [String: String] {
        var updated = refs
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            updated.removeValue(forKey: account)
        } else {
            updated[account] = trimmed
        }
        return updated
    }
}

enum AIKeyReferencePolicy {
    struct PendingUpdate: Equatable {
        let reference: String
        let feedback: AIKeyFeedback
        var customProviderGeneration: String? = nil
        var endpointIdentity: String? = nil
        var customProviderState: EncryptedKeyStore.CustomProviderCredentialState? = nil
        var operationRevision: String? = nil
    }

    struct ReadDecision {
        let reference: String
        let feedback: AIKeyFeedback?
    }

    struct MutationDecision {
        let feedback: AIKeyFeedback?
        let retryAllowed: Bool
    }

    static func referenceAfterProviderChange(_ reference: String, from: String, to: String) -> String {
        from == to ? reference : ""
    }

    static func manualKeySaveReference(_ reference: String, userEdited: Bool) -> String? {
        userEdited ? reference : nil
    }

    static func pendingForEndpoint(_ pending: PendingUpdate?, endpointIdentity: String?) -> PendingUpdate? {
        guard let pending, pending.endpointIdentity == endpointIdentity else { return nil }
        return pending
    }

    static func boundReadDecision(for result: EncryptedKeyStore.BoundCustomCredentialReadResult) -> ReadDecision {
        switch result {
        case let .found(reference): return ReadDecision(reference: reference, feedback: nil)
        case .missing: return ReadDecision(reference: "", feedback: nil)
        case .unbound, .endpointMismatch:
            return ReadDecision(reference: "", feedback: .referenceBindingRequired)
        case .failed: return ReadDecision(reference: "", feedback: .referenceReadFailed)
        }
    }

    static func readDecision(
        for result: EncryptedKeyStore.ReadResult,
        pending: PendingUpdate? = nil
    ) -> ReadDecision {
        if let pending {
            if case .failed = result {
                return ReadDecision(reference: pending.reference, feedback: .referenceReadFailed)
            }
            return ReadDecision(reference: pending.reference, feedback: pending.feedback)
        }
        switch result {
        case let .found(reference):
            return ReadDecision(reference: reference, feedback: nil)
        case .missing:
            return ReadDecision(reference: "", feedback: nil)
        case .failed:
            return ReadDecision(reference: "", feedback: .referenceReadFailed)
        }
    }

    static func mutationDecision(for result: EncryptedKeyStore.MutationResult, deleting: Bool) -> MutationDecision {
        switch result {
        case .durable:
            return MutationDecision(feedback: nil, retryAllowed: false)
        case .notCommitted:
            return MutationDecision(feedback: deleting ? .referenceDeleteFailed : .referenceSaveFailed, retryAllowed: true)
        case .committedDurabilityUnknown:
            return MutationDecision(feedback: .referenceDurabilityUnknown, retryAllowed: true)
        case .unverified:
            return MutationDecision(feedback: .referenceUnverified, retryAllowed: true)
        }
    }
}

enum AIOnePasswordCompletionPolicy {
    struct Context: Equatable {
        let providerID: String
        let account: String
        let revision: UUID
    }

    static func mayPresent(started: Context, current: Context) -> Bool {
        started == current
    }

    static func mayPersistReference(
        result: EncryptedKeyStore.MutationResult, started: Context, current: Context
    ) -> Bool {
        mayPresent(started: started, current: current) && AIKeySavePolicy.decision(for: result).activateKey
    }
}

/// What the settings page may claim about the active provider's key.
enum AIKeyStatus: Equatable {
    /// A key was read back from the encrypted store.
    case saved
    /// No key and no flag: nothing was ever stored for this provider.
    case missing
    /// The flag says a key exists but the store returned nothing, so the page
    /// must not claim the key is usable.
    case flagWithoutSecret
    case unverified
    case unbound
    case endpointMismatch

    static func resolve(stored: String?, hasFlag: Bool) -> AIKeyStatus {
        if let stored, !stored.isEmpty { return .saved }
        return hasFlag ? .flagWithoutSecret : .missing
    }

    static func resolve(bound: EncryptedKeyStore.BoundCustomCredentialReadResult, hasFlag: Bool) -> AIKeyStatus {
        switch bound {
        case let .found(value): return resolve(stored: value, hasFlag: hasFlag)
        case .missing: return resolve(stored: nil, hasFlag: hasFlag)
        case .unbound: return .unbound
        case .endpointMismatch: return .endpointMismatch
        case .failed: return .unverified
        }
    }

    func label(language: AppLanguage) -> String {
        switch self {
        case .saved: return L10n.string("ai.keyStatus.saved", language: language)
        case .missing: return L10n.string("ai.keyStatus.missing", language: language)
        case .flagWithoutSecret: return L10n.string("ai.keyStatus.unreadable", language: language)
        case .unverified: return L10n.string("ai.keyStatus.unverified", language: language)
        case .unbound: return L10n.string("ai.keyStatus.unbound", language: language)
        case .endpointMismatch: return L10n.string("ai.keyStatus.endpointMismatch", language: language)
        }
    }
}

enum AIKeyDeletionPolicy {
    struct Decision {
        let clearCachedKey: Bool
        let status: AIKeyStatus?
        let feedback: AIKeyFeedback
        let retryAllowed: Bool
    }

    static func decision(for result: EncryptedKeyStore.MutationResult) -> Decision {
        switch result {
        case .durable:
            return Decision(clearCachedKey: true, status: .missing, feedback: .keyDeleted, retryAllowed: false)
        case .notCommitted:
            return Decision(clearCachedKey: false, status: nil, feedback: .deleteFailed, retryAllowed: true)
        case .committedDurabilityUnknown:
            return Decision(clearCachedKey: true, status: .missing, feedback: .deleteDurabilityUnknown, retryAllowed: true)
        case .unverified:
            return Decision(clearCachedKey: true, status: .unverified, feedback: .deleteUnverified, retryAllowed: true)
        }
    }
}

enum AICustomProviderDeletionPolicy {
    struct Decision {
        let removeProvider: Bool
        let clearCachedKey: Bool
        let feedback: AIKeyFeedback
    }

    static func decision(for result: EncryptedKeyStore.MutationResult) -> Decision {
        switch result {
        case .durable:
            return Decision(removeProvider: true, clearCachedKey: true, feedback: .customProviderDeleted)
        case .notCommitted:
            return Decision(removeProvider: false, clearCachedKey: false, feedback: .customProviderDeleteFailed)
        case .committedDurabilityUnknown:
            return Decision(removeProvider: false, clearCachedKey: true, feedback: .customProviderDeleteDurabilityUnknown)
        case .unverified:
            return Decision(removeProvider: false, clearCachedKey: true, feedback: .customProviderDeleteUnverified)
        }
    }
}

enum AIKeySavePolicy {
    struct Decision {
        let activateKey: Bool
        let clearCachedKey: Bool
        let clearInput: Bool
        let status: AIKeyStatus?
        let feedback: AIKeyFeedback
        let retrySyncAllowed: Bool
    }

    static func decision(for result: EncryptedKeyStore.MutationResult) -> Decision {
        switch result {
        case .durable:
            return Decision(activateKey: true, clearCachedKey: false, clearInput: true, status: .saved, feedback: .saved, retrySyncAllowed: false)
        case .notCommitted:
            return Decision(activateKey: false, clearCachedKey: false, clearInput: false, status: nil, feedback: .saveFailed, retrySyncAllowed: false)
        case .committedDurabilityUnknown:
            return Decision(activateKey: true, clearCachedKey: false, clearInput: true, status: .saved, feedback: .saveDurabilityUnknown, retrySyncAllowed: true)
        case .unverified:
            return Decision(activateKey: false, clearCachedKey: true, clearInput: false, status: .unverified, feedback: .saveUnverified, retrySyncAllowed: false)
        }
    }
}

struct AICustomProviderCredentialError: Error {
    let result: EncryptedKeyStore.MutationResult
}

/// Capture the persisted generation before a user-initiated credential action
/// suspends. A deliberate new save may recover a previously revoked provider.
enum AICustomProviderCredentialAccess {
    static func capturedState(
        account: String, store: EncryptedKeyStore
    ) async throws -> EncryptedKeyStore.CustomProviderCredentialState? {
        guard account.hasPrefix("custom:") else { return nil }
        switch await store.customProviderCredentialStateResult(account: account) {
        case .legacy: return nil
        case let .state(state): return state
        case .failed: throw AICustomProviderCredentialError(result: .unverified)
        }
    }

    static func save(
        _ key: String, account: String, store: EncryptedKeyStore,
        capturedState: EncryptedKeyStore.CustomProviderCredentialState?, endpointIdentity: String? = nil
    ) async throws -> (
        result: EncryptedKeyStore.MutationResult, generation: String?,
        state: EncryptedKeyStore.CustomProviderCredentialState?
    ) {
        try Task.checkCancellation()
        if account.hasPrefix("custom:") {
            guard let endpointIdentity, !endpointIdentity.isEmpty else {
                throw AICustomProviderCredentialError(result: .notCommitted)
            }
            let outcome = await store.saveBoundCustomKeyResult(
                key, account: account, expectedState: capturedState, endpointIdentity: endpointIdentity
            )
            if outcome.result == .notCommitted, capturedState?.revoked == true {
                try Task.checkCancellation()
                throw AICustomProviderCredentialError(result: .notCommitted)
            }
            return (outcome.result, outcome.state?.generation, outcome.state)
        }
        let generation = capturedState?.generation
        let result = await store.saveAPIKeyResult(key, account: account, customProviderGeneration: generation)
        return (result, generation, nil)
    }

    static func generation(
        account: String, store: EncryptedKeyStore, allowRecovery: Bool
    ) async throws -> String? {
        guard account.hasPrefix("custom:") else { return nil }
        switch await store.customProviderCredentialStateResult(account: account) {
        case .legacy:
            return nil
        case .failed:
            throw AICustomProviderCredentialError(result: .unverified)
        case let .state(state) where !state.revoked:
            return state.generation
        case let .state(state):
            guard allowRecovery else { throw AICustomProviderCredentialError(result: .notCommitted) }
            switch await store.reactivateCustomProviderCredentialsResult(
                account: account, matchingRevocation: state.generation
            ) {
            case let .activated(generation): return generation
            case let .failed(result): throw AICustomProviderCredentialError(result: result)
            }
        }
    }
}

enum AIOnePasswordKeyImport {
    struct Outcome {
        let key: String
        let result: EncryptedKeyStore.MutationResult
        let saveDecision: AIKeySavePolicy.Decision
        let feedback: AIKeyFeedback
        let customProviderGeneration: String?
        let customProviderState: EncryptedKeyStore.CustomProviderCredentialState?
    }

    static func run(
        reference: String,
        account: String,
        store: @autoclosure () -> EncryptedKeyStore,
        endpointIdentity: String? = nil,
        referenceWasEdited: Bool = false,
        readSecret: (String) async throws -> String
    ) async throws -> Outcome {
        let customStore: EncryptedKeyStore?
        let customState: EncryptedKeyStore.CustomProviderCredentialState?
        if account.hasPrefix("custom:") {
            let capturedStore = store()
            customStore = capturedStore
            customState = try await AICustomProviderCredentialAccess.capturedState(
                account: account, store: capturedStore
            )
            guard let endpointIdentity, !endpointIdentity.isEmpty else {
                throw AICustomProviderCredentialError(result: .notCommitted)
            }
            if !referenceWasEdited {
                guard customState?.endpointIdentity == endpointIdentity,
                      customState?.referenceEndpointIdentity == endpointIdentity,
                      case let .found(savedReference) = await capturedStore.readBoundCustomReferenceResult(
                          account: account, endpointIdentity: endpointIdentity
                      ), savedReference == reference else {
                    throw AICustomProviderCredentialError(result: .notCommitted)
                }
            }
        } else {
            customStore = nil
            customState = nil
        }
        try Task.checkCancellation()
        let key = try await readSecret(reference)
        try Task.checkCancellation()
        guard !key.isEmpty else { throw OnePasswordError.readFailed }

        let saved = try await AICustomProviderCredentialAccess.save(
            key, account: account, store: customStore ?? store(), capturedState: customState,
            endpointIdentity: endpointIdentity
        )
        let result = saved.result
        let feedback: AIKeyFeedback
        switch result {
        case .durable:
            feedback = .loaded
        case .notCommitted:
            feedback = .loadedButNotSaved
        case .committedDurabilityUnknown:
            feedback = .saveDurabilityUnknown
        case .unverified:
            feedback = .saveUnverified
        }
        return Outcome(
            key: key,
            result: result,
            saveDecision: AIKeySavePolicy.decision(for: result),
            feedback: feedback,
            customProviderGeneration: saved.generation,
            customProviderState: saved.state
        )
    }
}

@MainActor
enum AIOnePasswordAutoRefresh {
    static func run(
        reference: String,
        snapshot: EncryptedKeyStore.OnePasswordRefreshSnapshot,
        store: EncryptedKeyStore,
        expectedIntent: UUID,
        readSecret: (String) async throws -> String,
        currentAccount: () -> String,
        currentIntent: () -> UUID,
        isContextCurrent: () -> Bool = { true },
        afterStoreWrite: (() async -> Void)? = nil,
        activate: (String) -> Void
    ) async throws {
        guard currentIntent() == expectedIntent, isContextCurrent() else { return }
        let key = try await readSecret(reference)
        guard currentIntent() == expectedIntent, isContextCurrent() else { return }
        let result = await store.saveRefreshedAPIKey(key, snapshot: snapshot)
        await afterStoreWrite?()
        guard result == .durable, currentAccount() == snapshot.account,
              currentIntent() == expectedIntent, isContextCurrent() else { return }
        activate(key)
    }
}
