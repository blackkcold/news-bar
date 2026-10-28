import SwiftUI

/// Outcome of a credential action. The tone is derived from the case so the UI
/// never decides colour by searching rendered, localized text.
enum AIKeyFeedback: String, Equatable, CaseIterable {
    case saved
    case saveFailed
    case keyDeleted
    case deleteFailed
    case loaded
    case invalidReference
    case notInstalled
    case timedOut
    case readFailed
    case loadedButNotSaved
    case unknown

    enum Tone: Equatable {
        case success
        case warning
        case error
    }

    var tone: Tone {
        switch self {
        case .saved, .keyDeleted, .loaded:
            return .success
        case .invalidReference, .notInstalled, .timedOut, .readFailed, .loadedButNotSaved, .unknown:
            return .warning
        case .saveFailed, .deleteFailed:
            return .error
        }
    }

    var isSuccess: Bool { tone == .success }

    private var key: String {
        switch self {
        case .saved: return "ai.saved"
        case .saveFailed: return "ai.saveFailed"
        case .keyDeleted: return "ai.keyDeleted"
        case .deleteFailed: return "ai.keyDeleteFailed"
        case .loaded: return "ai.1p.success"
        case .invalidReference: return "ai.1p.invalidRef"
        case .notInstalled: return "ai.1p.notInstalled"
        case .timedOut: return "ai.1p.timeout"
        case .readFailed: return "ai.1p.readFailed"
        case .loadedButNotSaved: return "ai.1p.saveFailed"
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

/// What the settings page may claim about the active provider's key.
enum AIKeyStatus: Equatable {
    /// A key was read back from the encrypted store.
    case saved
    /// No key and no flag: nothing was ever stored for this provider.
    case missing
    /// The flag says a key exists but the store returned nothing, so the page
    /// must not claim the key is usable.
    case flagWithoutSecret

    static func resolve(stored: String?, hasFlag: Bool) -> AIKeyStatus {
        if let stored, !stored.isEmpty { return .saved }
        return hasFlag ? .flagWithoutSecret : .missing
    }

    func label(language: AppLanguage) -> String {
        switch self {
        case .saved: return L10n.string("ai.keyStatus.saved", language: language)
        case .missing: return L10n.string("ai.keyStatus.missing", language: language)
        case .flagWithoutSecret: return L10n.string("ai.keyStatus.unreadable", language: language)
        }
    }
}
