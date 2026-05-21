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

    // MARK: - No-UI Protection (CodexBar pattern)

    /// Applies dual-layer No-UI protection to a Keychain query.
    /// Uses both the modern `LAContext.interactionNotAllowed` API and the legacy
    /// `kSecUseAuthenticationUIFail` constant (resolved at runtime to avoid
    /// deprecation warnings).  On macOS file-based keychains the legacy flag
    /// remains necessary — `interactionNotAllowed` alone can still surface
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

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
    }

    // MARK: - API Key (account-parameterized)

    static func saveAPIKey(_ key: String, account: String) -> Bool {
        guard !isDisabled else { return true }
        guard let data = key.data(using: .utf8) else { return false }

        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        addQuery[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(addQuery as CFDictionary, nil)

        if status == errSecSuccess {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "apiKeyLastSaved-\(account)")
            UserDefaults.standard.set(true, forKey: "hasAIKey-\(account)")
            return true
        }
        return false
    }

    static func readAPIKey(account: String, allowUI: Bool = false) -> String? {
        guard !isDisabled else { return nil }

        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowUI {
            applyNoUI(to: &query)
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }

        return key
    }

    static func checkAPIKeyExistence(account: String) -> KeyExistence {
        guard !isDisabled else { return .notFound }

        var query = baseQuery(account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        applyNoUI(to: &query)

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:         return .existsAccessible
        case errSecItemNotFound:    return .notFound
        default:                    return .existsNeedsAuth
        }
    }

    static func deleteAPIKey(account: String) {
        guard !isDisabled else { return }
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "hasAIKey-\(account)")
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

        let query = baseQuery(account: onePasswordRefAccount)
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        addQuery[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func readOnePasswordRef(allowUI: Bool = false) -> String? {
        guard !isDisabled else { return nil }

        var query = baseQuery(account: onePasswordRefAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowUI {
            applyNoUI(to: &query)
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let ref = String(data: data, encoding: .utf8) else {
            return nil
        }

        return ref
    }

    static func deleteOnePasswordRef() {
        guard !isDisabled else { return }
        let query = baseQuery(account: onePasswordRefAccount)
        SecItemDelete(query as CFDictionary)
    }
}
