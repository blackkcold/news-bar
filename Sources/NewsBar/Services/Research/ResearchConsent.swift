import AppKit
import Foundation

/// One-time disclosure before the first manual online verification. Automatic
/// research is covered by the settings toggle and its footer; this prompt exists
/// because manual verification is the first moment a user knowingly sends a
/// specific story to third-party search services.
enum ResearchConsent {
    static let currentVersion = 2

    static func requiresConsent(storedVersion: Int) -> Bool {
        storedVersion < currentVersion
    }

    static func enabledProviders(_ settings: AppSettings) -> [SearchProviderID] {
        SearchProviderID.failoverOrder.filter { settings.enabledSearchProviders.contains($0) }
    }

    static func disclosure(
        providers: [SearchProviderID],
        providerName: String,
        model: String,
        language: AppLanguage
    ) -> String {
        let providerList = providers.isEmpty
            ? L10n.string("research.consent.noProviders", language: language)
            : providers.map(\.displayName).joined(separator: ", ")
        let modelName = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L10n.string("research.consent.noModel", language: language)
            : model
        return L10n.string(
            "research.consent.body",
            language: language,
            providerList,
            providerName,
            modelName
        )
    }

    /// Shows the disclosure once and records the accepted version. Returns
    /// `true` when the caller may proceed.
    @MainActor
    static func presentIfNeeded(settings: AppSettings) -> Bool {
        guard requiresConsent(storedVersion: settings.researchConsentVersion) else {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.string("research.consent.title", language: settings.appLanguage)
        alert.informativeText = disclosure(
            providers: enabledProviders(settings),
            providerName: settings.providerDisplayName(forID: settings.aiProvider),
            model: settings.aiModel,
            language: settings.appLanguage
        )
        alert.addButton(
            withTitle: L10n.string("research.consent.continue", language: settings.appLanguage)
        )
        alert.addButton(
            withTitle: L10n.string("research.consent.cancel", language: settings.appLanguage)
        )

        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        settings.researchConsentVersion = currentVersion
        return true
    }
}
