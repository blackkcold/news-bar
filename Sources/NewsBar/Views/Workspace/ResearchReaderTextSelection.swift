import SwiftUI

/// Turns text selection on for a whole reading column, or leaves it off.
///
/// This exists as a modifier instead of a `.textSelection(.enabled)` call
/// because the choice belongs to the presentation: the popup has no chapter
/// tabs, so it opts in for every text run, while the workbench keeps its
/// existing per-view opt-ins untouched.
struct ResearchReaderTextSelection: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.textSelection(.enabled)
        } else {
            content
        }
    }
}
