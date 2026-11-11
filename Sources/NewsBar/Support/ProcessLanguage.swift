import Foundation

/// Keeps the process language in step with the app's own language setting.
///
/// `L10n` only translates strings this app looks up itself. Everything macOS
/// resolves on its own — Sparkle's update window, AppKit's standard buttons,
/// alerts raised by frameworks — reads the process's `AppleLanguages`
/// preference instead. A hand-assembled bundle that declares no localizations
/// resolves that preference to English whatever the in-app picker says, which
/// is how the update window stayed English while the rest of the app was
/// Chinese.
///
/// `Info.plist` declares `zh_CN` and `en`; this type makes the setting, not
/// the system language, choose between them. The write has to happen before
/// the first bundle resolves its localizations: `NSBundle` caches them for the
/// rest of the process, so a later write is ignored. `main.swift` calls it
/// before `NSApplication` exists.
enum ProcessLanguage {
    /// The preference `NSBundle` reads to decide what the process speaks.
    static let defaultsKey = "AppleLanguages"

    /// The value `AppleLanguages` should hold for `language`.
    static func preferredLocalizations(for language: AppLanguage) -> [String] {
        [language.bcp47]
    }

    /// Aligns the process language with `language` when running from a real
    /// app bundle.
    ///
    /// - Returns: `true` when the preference was written, so callers and tests
    ///   can assert idempotency without reading the process preference back
    ///   (that read is cached and would make the assertion tautological).
    @discardableResult
    static func sync(
        language: AppLanguage,
        defaults: UserDefaults = .standard,
        bundlePath: String = Bundle.main.bundlePath
    ) -> Bool {
        // `swift run`, XCTest and helper tools share this code path but must
        // never rewrite the preference of whatever host bundle they run in.
        guard bundlePath.hasSuffix(".app") else { return false }

        let desired = preferredLocalizations(for: language)
        guard defaults.stringArray(forKey: defaultsKey) != desired else { return false }

        defaults.set(desired, forKey: defaultsKey)
        // The value has to reach cfprefsd before NSBundle asks for it,
        // otherwise the first launch after a language change can still read
        // the previous value.
        _ = defaults.synchronize()
        return true
    }

    /// The language the current process actually resolved to.
    ///
    /// The settings pane compares this with the chosen language to explain
    /// that Sparkle's window follows on the next launch.
    static func resolvedLanguage(bundle: Bundle = .main) -> AppLanguage? {
        resolvedLanguage(preferredLocalizations: bundle.preferredLocalizations)
    }

    /// Maps a resolved localization list onto the languages this app ships.
    /// Kept separate from `Bundle` so the mapping is testable.
    static func resolvedLanguage(preferredLocalizations: [String]) -> AppLanguage? {
        guard let preferred = preferredLocalizations.first?.lowercased() else {
            return nil
        }
        return preferred.hasPrefix("zh") ? .zh : .en
    }
}
