import AppKit
import Foundation

/// A headless startup probe.
///
/// It proves the app entry leaves the main actor free while AppKit's run loop
/// is running. In v3.4.0 the top-level `await` turned the entry into a
/// main-actor task; `app.run()` then held that task forever and the probe file
/// never appeared. `enteredRun` separates "crashed before the run loop" from
/// "main actor starved".
enum LaunchProbe {
    static func requestedPath(arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--launch-probe"),
              arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    static func run(path: String) {
        // The top-level app entry is synchronous and runs on the main thread.
        // Assume that isolation for AppKit instead of making the entry async.
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let policy = app.setActivationPolicy(.prohibited)
            write(
                ["enteredRun": true, "activationPolicy": policy ? "prohibited" : "failed"],
                to: path
            )

            Task { @MainActor in
                write(["enteredRun": true, "mainActorTask": true], to: path)
                exit(0)
            }

            app.run()
        }
    }

    private static func write(_ values: [String: Any], to path: String) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: values,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
