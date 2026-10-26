import Foundation

/// Minimal, side-effect-free launch diagnostic for the bundled recommendation
/// guide.
///
/// Packaged apps must prove the guide resource survives into
/// `Contents/Resources`, but normal startup touches user settings, stores and
/// the network. This hook is checked in `main.swift` before the single-instance
/// check, `NSApplication`, or `AppDelegate` exist, so it only reads the guide
/// bundle and exits.
///
/// Output is fixed ASCII with section counts only; guide prose (user-facing
/// content) is never printed.
enum RecommendationGuideDiagnostic {
    static let flag = "--verify-recommendation-guide"

    /// The guide contract shipped with this build. Kept literal so a guide that
    /// silently grows sections fails the diagnostic instead of passing.
    static let expectedSectionCount = 8

    /// Injectable seam so tests can exercise success, missing-resource and
    /// ordinary-launch branches without the real bundle or any app state.
    struct Probe {
        var isAvailable: () -> Bool
        var sectionCount: (AppLanguage) -> Int

        static let live = Probe(
            isAvailable: { RecommendationGuide.isAvailable },
            sectionCount: { RecommendationGuide.sections(language: $0).count }
        )
    }

    /// Returns `nil` when the flag is absent, so normal startup is byte-for-byte
    /// unchanged and the guide is not read. Otherwise emits one line per
    /// `output` call and returns the process status (0 success, 1 failure).
    static func runIfRequested(
        arguments: [String],
        output: (String) -> Void
    ) -> Int32? {
        runIfRequested(arguments: arguments, output: output, probe: .live)
    }

    static func runIfRequested(
        arguments: [String],
        output: (String) -> Void,
        probe: Probe
    ) -> Int32? {
        guard arguments.contains(flag) else { return nil }

        guard probe.isAvailable() else {
            output("recommendation-guide available=false")
            output("recommendation-guide result=unavailable")
            return 1
        }

        let languages: [AppLanguage] = [.zh, .en]
        let counts = languages.map { probe.sectionCount($0) }
        output("recommendation-guide available=true")
        output("recommendation-guide sections " + zip(languages, counts)
            .map { "\($0.rawValue)=\($1)" }
            .joined(separator: " "))

        guard counts.allSatisfy({ $0 == expectedSectionCount }) else {
            output("recommendation-guide result=unexpected-section-count")
            return 1
        }

        output("recommendation-guide result=ok")
        return 0
    }
}
