import Foundation

enum SearchKeyMigrationResult: Equatable, Sendable {
    case notNeeded
    case migrated
    case failed
    case durabilityUnknown
    case unverified
}

enum SearchKeyDeletionPolicy {
    struct Decision {
        let configured: Bool?
        let unverified: Bool?
        let retryAllowed: Bool
        let isError: Bool
        let messageKey: String
    }

    static func decision(for result: EncryptedKeyStore.MutationResult) -> Decision {
        switch result {
        case .durable:
            return Decision(configured: false, unverified: false, retryAllowed: false, isError: false, messageKey: "research.settings.keyCleared")
        case .notCommitted:
            return Decision(configured: nil, unverified: nil, retryAllowed: true, isError: true, messageKey: "research.settings.keyClearFailed")
        case .committedDurabilityUnknown:
            return Decision(configured: false, unverified: false, retryAllowed: true, isError: true, messageKey: "research.settings.keyClearDurabilityUnknown")
        case .unverified:
            return Decision(configured: nil, unverified: true, retryAllowed: true, isError: true, messageKey: "research.settings.keyClearUnverified")
        }
    }
}

enum SearchKeySavePolicy {
    struct Decision {
        let configured: Bool?
        let unverified: Bool?
        let clearInput: Bool
        let retrySyncAllowed: Bool
        let isError: Bool
        let messageKey: String
    }

    static func decision(for result: EncryptedKeyStore.MutationResult) -> Decision {
        switch result {
        case .durable:
            return Decision(configured: true, unverified: false, clearInput: true, retrySyncAllowed: false, isError: false, messageKey: "research.settings.keySaveSuccess")
        case .notCommitted:
            return Decision(configured: nil, unverified: nil, clearInput: false, retrySyncAllowed: false, isError: true, messageKey: "research.settings.keySaveFailed")
        case .committedDurabilityUnknown:
            return Decision(configured: true, unverified: false, clearInput: true, retrySyncAllowed: true, isError: true, messageKey: "research.settings.keySaveDurabilityUnknown")
        case .unverified:
            return Decision(configured: nil, unverified: true, clearInput: false, retrySyncAllowed: false, isError: true, messageKey: "research.settings.keySaveUnverified")
        }
    }
}

/// All search-service credentials live in `EncryptedKeyStore` under
/// `search-key-<provider>`. The legacy Firecrawl plaintext UserDefaults value is
/// read once, copied into the encrypted store, and then cleared by the caller.
enum SearchKeyStore {
    static func account(for provider: SearchProviderID) -> String {
        "search-key-\(provider.rawValue)"
    }

    static func loadAll(store: EncryptedKeyStore = EncryptedKeyStore()) async -> [SearchProviderID: String] {
        var keys: [SearchProviderID: String] = [:]
        for provider in SearchProviderID.allCases {
            if let key = await store.readAPIKey(account: account(for: provider)), !key.isEmpty {
                keys[provider] = key
            }
        }
        return keys
    }

    static func key(
        for provider: SearchProviderID,
        fallback: String = "",
        store: EncryptedKeyStore = EncryptedKeyStore()
    ) async -> String {
        if provider == .firecrawl {
            switch await store.readLegacyFirecrawlKeyResult() {
            case let .found(key): return key
            case .missing: return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            case .revoked, .failed: return ""
            }
        }
        if let stored = await store.readAPIKey(account: account(for: provider)), !stored.isEmpty {
            return stored
        }
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hasKey(
        for provider: SearchProviderID,
        store: EncryptedKeyStore = EncryptedKeyStore()
    ) async -> Bool {
        await store.checkAPIKeyExistence(account: account(for: provider))
    }

    @discardableResult
    static func save(
        _ key: String,
        for provider: SearchProviderID,
        store: EncryptedKeyStore = EncryptedKeyStore()
    ) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await store.saveAPIKey(trimmed, account: account(for: provider))
    }

    static func saveResult(
        _ key: String,
        for provider: SearchProviderID,
        store: EncryptedKeyStore = EncryptedKeyStore()
    ) async -> EncryptedKeyStore.MutationResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notCommitted }
        return await store.saveAPIKeyResult(trimmed, account: account(for: provider))
    }

    @discardableResult
    static func delete(
        for provider: SearchProviderID,
        store: EncryptedKeyStore = EncryptedKeyStore()
    ) async -> Bool {
        await store.deleteAPIKey(account: account(for: provider))
    }

    static func deleteResult(
        for provider: SearchProviderID,
        store: EncryptedKeyStore = EncryptedKeyStore()
    ) async -> EncryptedKeyStore.MutationResult {
        await store.deleteAPIKeyResult(account: account(for: provider))
    }

    /// Pure migration decision for callers whose injected save is already safe.
    static func migrateLegacyKey(
        legacy: String,
        existing: String,
        save: (String) async -> Bool
    ) async -> SearchKeyMigrationResult {
        let legacyKey = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacyKey.isEmpty else { return .notNeeded }
        let existingKey = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard existingKey.isEmpty else { return .notNeeded }
        return await save(legacyKey) ? .migrated : .failed
    }

    static func migrateLegacyFirecrawlKey(
        legacy: String,
        store: EncryptedKeyStore,
        beforeStoreMutation: (() async -> Void)? = nil
    ) async -> SearchKeyMigrationResult {
        let legacyKey = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacyKey.isEmpty else { return .notNeeded }
        let account = account(for: .firecrawl)
        await beforeStoreMutation?()
        switch await store.saveAPIKeyIfMissing(legacyKey, account: account) {
        case .existing:
            return .notNeeded
        case .existingDurabilityUnknown, .mutation(.committedDurabilityUnknown):
            return .durabilityUnknown
        case .mutation(.durable):
            return .migrated
        case .mutation(.notCommitted):
            return .failed
        case .mutation(.unverified):
            return .unverified
        }
    }

    static func shouldClearLegacy(
        current: String, captured: String, result: SearchKeyMigrationResult
    ) -> Bool {
        current == captured && (result == .migrated || result == .notNeeded)
    }

    /// Clears the plaintext UserDefaults value only after the encrypted write
    /// succeeded. A failure keeps both copies so the next launch can retry.
    @MainActor
    static func migrateLegacyFirecrawlKey(
        settings: AppSettings,
        store: EncryptedKeyStore = EncryptedKeyStore()
    ) async -> SearchKeyMigrationResult {
        let legacy = settings.firecrawlAPIKey
        guard !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .notNeeded
        }

        let result = await migrateLegacyFirecrawlKey(legacy: legacy, store: store)
        if shouldClearLegacy(current: settings.firecrawlAPIKey, captured: legacy, result: result) {
            // A durable migration or an existing key makes the plaintext redundant.
            settings.firecrawlAPIKey = ""
        }
        return result
    }
}
