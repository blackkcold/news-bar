import AppKit

// The in-app language setting decides what every surface speaks: the app's
// own strings via `L10n`, and — through the process preference — Sparkle's
// update window and AppKit's standard buttons. This has to run before the
// first bundle localization lookup, so it comes before NSApplication.
ProcessLanguage.sync(language: storedAppLanguage())

/// Reads the picker value directly instead of building `AppSettings`, which
/// would drag the stores in before the app has even started.
private func storedAppLanguage() -> AppLanguage {
    AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .zh
}

// Packaged-app verification: must run before the single-instance check,
// NSApplication, AppDelegate, stores or any network access. Returns nil for
// normal launches, leaving startup untouched.
if let status = RecommendationGuideDiagnostic.runIfRequested(
    arguments: CommandLine.arguments,
    output: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) }
) {
    exit(status)
}

// Single-instance check: prevent running multiple copies
let bundleID = Bundle.main.bundleIdentifier ?? "com.newsbar"
let existingInstances = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == bundleID && $0 != NSRunningApplication.current
}
if !existingInstances.isEmpty {
    existingInstances.first?.activate()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
