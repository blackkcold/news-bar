import Foundation
import LocalAuthentication
import Security

enum KeyExistence {
    case notFound
    case existsAccessible
    case existsNeedsAuth
}

enum KeychainManager {

    /// Keychain service name — unchanged for backward compatibility.
    private static let serviceName = "com.newsbar.deepseek"
    private static let apiKeyAccountPrefix = "ai-key-"

    // MARK: - No-UI Protection (CodexBar pattern)

    /// Applies dual-layer No-UI protection to a Keychain query.
    /// Uses both the modern `LAContext.interactionNotAllowed` API and the legacy
    /// `kSecUseAuthenticationUIFail` constant (resolved at runtime to avoid
    /// deprecation warnings).  The legacy flag remains necessary — on some macOS
    /// keychain configurations `interactionNotAllowed` alone can still surface
    /// Allow/Deny prompts.
    private static func applyNoUI(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    }

    // MARK: - Debug Keychain Access Gate

    /// When enabled, all Keychain operations are skipped — reads return `nil`,
    /// writes are no-ops, and existence checks return `.notFound`.  Useful
    /// during development to avoid repeated macOS keychain authorization prompts
    /// caused by ad-hoc signing identity changes between builds.
    ///
    /// Enable: `defaults write com.newsbar.app debugDisableKeychainAccess -bool YES`
    /// Disable: `defaults delete com.newsbar.app debugDisableKeychainAccess`
    static var isDisabled: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "debugDisableKeychainAccess")
        #else
        return false
        #endif
    }

    // MARK: - Query Helpers

    /// Build a base keychain query dictionary.
    ///
    /// - Parameter account: The keychain account identifier.
    /// - Parameter useDataProtection: When `true` (the default for all normal
    ///   operations), sets `kSecUseDataProtectionKeychain` to target the modern
    ///   data protection keychain.  When `false`, targets the legacy file-based
    ///   keychain (used only for silent migration reads).
    private static func baseQuery(account: String, useDataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private static func providerKeyExistsFlag(for account: String) -> String? {
        guard account.hasPrefix(apiKeyAccountPrefix) else { return nil }
        let providerRawValue = String(account.dropFirst(apiKeyAccountPrefix.count))
        return "hasAIKey-\(providerRawValue)"
    }

    private static func markAPIKeySaved(account: String) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "apiKeyLastSaved-\(account)")
        // Keep the older account-scoped flag for users upgrading from builds
        // that saved `hasAIKey-ai-key-{provider}` before provider-scoped flags
        // became the app-level precheck source.
        UserDefaults.standard.set(true, forKey: "hasAIKey-\(account)")
        if let providerFlag = providerKeyExistsFlag(for: account) {
            UserDefaults.standard.set(true, forKey: providerFlag)
        }
    }

    private static func clearAPIKeySavedFlag(account: String) {
        UserDefaults.standard.removeObject(forKey: "hasAIKey-\(account)")
        if let providerFlag = providerKeyExistsFlag(for: account) {
            UserDefaults.standard.removeObject(forKey: providerFlag)
        }
    }

    // MARK: - Silent Legacy Migration

    /// Reads an item from the legacy file-based keychain (no UI), and if found,
    /// attempts to write it into the data protection keychain.  The legacy copy
    /// is deleted **only after a successful write** to the new backend.
    ///
    /// - Returns: The legacy `Data` when a legacy item is readable.  If the
    ///   data protection write fails, the legacy copy is preserved and the data
    ///   is still returned so existing users are not locked out.
    private static func migrateFromLegacy(account: String) -> Data? {
        var legacyQuery = baseQuery(account: account, useDataProtection: false)
        legacyQuery[kSecReturnData as String] = true
        legacyQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        applyNoUI(to: &legacyQuery)

        var result: AnyObject?
        guard SecItemCopyMatching(legacyQuery as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }

        let dpDeleteQuery = baseQuery(account: account, useDataProtection: true)
        SecItemDelete(dpDeleteQuery as CFDictionary)

        var dpAddQuery = baseQuery(account: account, useDataProtection: true)
        dpAddQuery[kSecValueData as String] = data
        dpAddQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        dpAddQuery[kSecAttrSynchronizable as String] = false
        let didWriteToDataProtection = SecItemAdd(dpAddQuery as CFDictionary, nil) == errSecSuccess

        if didWriteToDataProtection {
            let deleteQuery = baseQuery(account: account, useDataProtection: false)
            SecItemDelete(deleteQuery as CFDictionary)
        }

        return data
    }

    /// Compatibility fallback for environments where the data protection
    /// keychain is unavailable because the app is not signed/provisioned for it.
    /// This still stores secrets in macOS Keychain, never in UserDefaults/files.
    private static func saveToLegacyFallback(_ data: Data, account: String) -> Bool {
        let deleteQuery = baseQuery(account: account, useDataProtection: false)
        SecItemDelete(deleteQuery as CFDictionary)

        var addQuery = baseQuery(account: account, useDataProtection: false)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        addQuery[kSecAttrSynchronizable as String] = false
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - API Key (account-parameterized)

    static func saveAPIKey(_ key: String, account: String) -> Bool {
        guard !isDisabled else { return true }
        guard let data = key.data(using: .utf8) else { return false }

        let dpDeleteQuery = baseQuery(account: account, useDataProtection: true)
        SecItemDelete(dpDeleteQuery as CFDictionary)

        var dpAddQuery = baseQuery(account: account, useDataProtection: true)
        dpAddQuery[kSecValueData as String] = data
        dpAddQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        dpAddQuery[kSecAttrSynchronizable as String] = false
        if SecItemAdd(dpAddQuery as CFDictionary, nil) == errSecSuccess {
            let legacyDeleteQuery = baseQuery(account: account, useDataProtection: false)
            SecItemDelete(legacyDeleteQuery as CFDictionary)
            markAPIKeySaved(account: account)
            return true
        }

        if saveToLegacyFallback(data, account: account) {
            markAPIKeySaved(account: account)
            return true
        }
        return false
    }

    static func readAPIKey(account: String, allowUI: Bool = false) -> String? {
        guard !isDisabled else { return nil }

        // 1. Primary path: data protection keychain
        var dpQuery = baseQuery(account: account, useDataProtection: true)
        dpQuery[kSecReturnData as String] = true
        dpQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowUI {
            applyNoUI(to: &dpQuery)
        }

        var result: AnyObject?
        let dpStatus = SecItemCopyMatching(dpQuery as CFDictionary, &result)

        if dpStatus == errSecSuccess,
           let data = result as? Data,
           let key = String(data: data, encoding: .utf8) {
            return key
        }

        // 2. Fallback only when the data protection item is absent/unavailable.
        // Do not continue probing legacy keychains after auth/ACL failures.
        if dpStatus == errSecItemNotFound || dpStatus == errSecMissingEntitlement || dpStatus == errSecNotAvailable {
            if let migratedData = migrateFromLegacy(account: account),
               let key = String(data: migratedData, encoding: .utf8) {
                return key
            }
        }

        return nil
    }

    static func checkAPIKeyExistence(account: String) -> KeyExistence {
        guard !isDisabled else { return .notFound }

        // 1. Primary path: data protection keychain
        var dpQuery = baseQuery(account: account, useDataProtection: true)
        dpQuery[kSecReturnAttributes as String] = true
        dpQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        applyNoUI(to: &dpQuery)

        var result: AnyObject?
        let dpStatus = SecItemCopyMatching(dpQuery as CFDictionary, &result)
        let dataProtectionNeedsAuth: Bool
        switch dpStatus {
        case errSecSuccess:
            return .existsAccessible
        case errSecItemNotFound, errSecMissingEntitlement, errSecNotAvailable:
            dataProtectionNeedsAuth = false
        default:
            dataProtectionNeedsAuth = true
        }

        guard !dataProtectionNeedsAuth else {
            return .existsNeedsAuth
        }

        // 2. Fallback: legacy file-based keychain — attempt silent migration.
        if migrateFromLegacy(account: account) != nil {
            return .existsAccessible
        }

        // 3. Final check: did the legacy item exist but need auth?
        var legacyQuery = baseQuery(account: account, useDataProtection: false)
        legacyQuery[kSecReturnAttributes as String] = true
        legacyQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        applyNoUI(to: &legacyQuery)

        var legacyResult: AnyObject?
        let legacyStatus = SecItemCopyMatching(legacyQuery as CFDictionary, &legacyResult)
        switch legacyStatus {
        case errSecSuccess:
            return .existsAccessible
        case errSecItemNotFound:
            return dataProtectionNeedsAuth ? .existsNeedsAuth : .notFound
        default:
            return .existsNeedsAuth
        }
    }

    static func deleteAPIKey(account: String) {
        guard !isDisabled else { return }

        // Purge both backends
        let dpQuery = baseQuery(account: account, useDataProtection: true)
        SecItemDelete(dpQuery as CFDictionary)

        let legacyQuery = baseQuery(account: account, useDataProtection: false)
        SecItemDelete(legacyQuery as CFDictionary)

        clearAPIKeySavedFlag(account: account)
    }

    // MARK: - Staleness

    static func isKeyStale(account: String) -> Bool {
        let lastSaved = UserDefaults.standard.double(forKey: "apiKeyLastSaved-\(account)")
        guard lastSaved > 0 else { return true }
        return Date().timeIntervalSince1970 - lastSaved > 30 * 24 * 3600
    }

    // MARK: - Legacy Convenience (deprecated, for migration only)

    /// Reads from the old hardcoded "deepseek-api-key" account. Exists only
    /// for the one-time migration in AppSettings.
    static func readLegacyAPIKey() -> String? {
        readAPIKey(account: "deepseek-api-key")
    }

    static func deleteLegacyAPIKey() {
        deleteAPIKey(account: "deepseek-api-key")
    }

    // MARK: - 1Password Reference

    private static let onePasswordRefAccount = "one-password-ref"

    static func saveOnePasswordRef(_ ref: String) -> Bool {
        guard !isDisabled else { return true }
        guard let data = ref.data(using: .utf8) else { return false }

        let dpDeleteQuery = baseQuery(account: onePasswordRefAccount, useDataProtection: true)
        SecItemDelete(dpDeleteQuery as CFDictionary)

        var dpAddQuery = baseQuery(account: onePasswordRefAccount, useDataProtection: true)
        dpAddQuery[kSecValueData as String] = data
        dpAddQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        dpAddQuery[kSecAttrSynchronizable as String] = false
        if SecItemAdd(dpAddQuery as CFDictionary, nil) == errSecSuccess {
            let legacyDeleteQuery = baseQuery(account: onePasswordRefAccount, useDataProtection: false)
            SecItemDelete(legacyDeleteQuery as CFDictionary)
            return true
        }

        return saveToLegacyFallback(data, account: onePasswordRefAccount)
    }

    static func readOnePasswordRef(allowUI: Bool = false) -> String? {
        guard !isDisabled else { return nil }

        // 1. Primary path: data protection keychain
        var dpQuery = baseQuery(account: onePasswordRefAccount, useDataProtection: true)
        dpQuery[kSecReturnData as String] = true
        dpQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowUI {
            applyNoUI(to: &dpQuery)
        }

        var result: AnyObject?
        let dpStatus = SecItemCopyMatching(dpQuery as CFDictionary, &result)

        if dpStatus == errSecSuccess,
           let data = result as? Data,
           let ref = String(data: data, encoding: .utf8) {
            return ref
        }

        // 2. Fallback only when the data protection item is absent/unavailable.
        // Do not continue probing legacy keychains after auth/ACL failures.
        if dpStatus == errSecItemNotFound || dpStatus == errSecMissingEntitlement || dpStatus == errSecNotAvailable {
            if let migratedData = migrateFromLegacy(account: onePasswordRefAccount),
               let ref = String(data: migratedData, encoding: .utf8) {
                return ref
            }
        }

        return nil
    }

    static func deleteOnePasswordRef() {
        guard !isDisabled else { return }

        // Purge both backends
        let dpQuery = baseQuery(account: onePasswordRefAccount, useDataProtection: true)
        SecItemDelete(dpQuery as CFDictionary)

        let legacyQuery = baseQuery(account: onePasswordRefAccount, useDataProtection: false)
        SecItemDelete(legacyQuery as CFDictionary)
    }
}
