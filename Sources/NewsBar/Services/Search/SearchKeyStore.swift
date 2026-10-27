import Foundation

enum SearchKeyMigrationResult: Equatable, Sendable {
    case notNeeded
    case migrated
    case failed
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

    static func delete(
        for provider: SearchProviderID,
        store: EncryptedKeyStore = EncryptedKeyStore()
    ) async {
        await store.deleteAPIKey(account: account(for: provider))
    }

    /// Pure migration decision, injected I/O: only copies when a legacy value
    /// exists and no encrypted key is already stored. This keeps a retry after a
    /// crash from overwriting a key the user saved in the meantime.
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

    /// Clears the plaintext UserDefaults value only after the encrypted write
    /// succeeded. A failure keeps both copies so the next launch can retry.
    @MainActor
    static func migrateLegacyFirecrawlKey(settings: AppSettings) async -> SearchKeyMigrationResult {
        let legacy = settings.firecrawlAPIKey
        guard !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .notNeeded
        }

        let store = EncryptedKeyStore()
        let account = account(for: .firecrawl)
        let existing = await store.readAPIKey(account: account) ?? ""
        if !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The encrypted store is already authoritative; the plaintext copy
            // is redundant and must not stay in UserDefaults.
            settings.firecrawlAPIKey = ""
            return .notNeeded
        }

        let result = await migrateLegacyKey(legacy: legacy, existing: existing) { key in
            await store.saveAPIKey(key, account: account)
        }
        if result == .migrated {
            settings.firecrawlAPIKey = ""
        }
        return result
    }
}
