import AppKit

/// The app's synchronous entry. It must never become `async`: an async main
/// task that calls `NSApplication.run()` holds the main actor forever and
/// starves every `Task { @MainActor }` in the app (the v3.4.0 regression).
public func runApp() {
    if let probePath = LaunchProbe.requestedPath(arguments: CommandLine.arguments) {
        LaunchProbe.run(path: probePath)
        exit(0)
    }

    // The agent CLI lives in its own executable. Keep a loud failure here so
    // an old script cannot accidentally launch the GUI.
    if CommandLine.arguments.dropFirst().first == "--agent" {
        FileHandle.standardError.write(Data(
            "agent commands moved out of the app; use NewsBarAgent.\n".utf8
        ))
        exit(2)
    }

    // The in-app language setting decides what every surface speaks: the app's
    // own strings via `L10n`, and — through the process preference — Sparkle's
    // update window and AppKit's standard buttons. This has to run before the
    // first bundle localization lookup, so it comes before NSApplication.
    ProcessLanguage.sync(language: storedAppLanguage())

    // Packaged-app verification: must run before the single-instance check,
    // NSApplication, AppDelegate, stores or any network access. Returns nil for
    // normal launches, leaving startup untouched.
    if let status = RecommendationGuideDiagnostic.runIfRequested(
        arguments: CommandLine.arguments,
        output: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) }
    ) {
        exit(status)
    }

    // Packaged-app check: reader-mode.js must be readable from the app bundle.
    // The old `Bundle.module` accessor embedded the build-machine path and
    // would `fatalError` on a user's Mac; this check fails the package instead.
    if CommandLine.arguments.contains("--verify-reader-script") {
        let source = MainActor.assumeIsolated { ReaderModeScript.source() }
        if source != nil {
            print("reader-mode OK")
            exit(0)
        }
        FileHandle.standardError.write(Data("reader-mode.js missing\n".utf8))
        exit(1)
    }

    // Single-instance check: prevent running multiple copies.
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
}

/// The headless entry. It never calls `app.run()`; the agent process exits
/// before any AppKit event loop is started.
public func runNewsBarAgent(arguments: [String]) async -> Int32 {
    TestIsolation.activate()
    return await AgentHeadless.run(arguments: arguments)
}

/// Reads the picker value directly instead of building `AppSettings`, which
/// would drag the stores in before the app has even started.
private func storedAppLanguage() -> AppLanguage {
    AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .zh
}
