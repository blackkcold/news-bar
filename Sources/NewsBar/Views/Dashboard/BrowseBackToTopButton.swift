import AppKit
import SwiftUI

/// Floating "back to top" affordance for one browse pane. It only exists while
/// that pane is scrolled past roughly one screen, so the feed keeps its
/// uncluttered top edge and the control never competes with the first card.
struct BrowseBackToTopButton: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    let action: () -> Void

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var language: AppLanguage { settings.appLanguage }

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.up")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 34, height: 34)
                .background(fill, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(stroke, lineWidth: isRetro ? 1.2 : 0.8)
                }
                .foregroundStyle(isRetro ? RetroEditorialTokens.ink : Color.primary)
                .shadow(
                    color: isRetro
                        ? RetroEditorialTokens.ink.opacity(0.7)
                        : .black.opacity(isHovering ? 0.2 : 0.14),
                    radius: isRetro ? 0 : (isHovering ? 10 : 7),
                    x: isRetro ? 2 : 0,
                    y: isRetro ? 2 : 3
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering && !reduceMotion ? 1.04 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
        .help(language == .en ? "Back to top" : "回到顶部")
        .accessibilityLabel(language == .en ? "Back to top" : "回到顶部")
        .accessibilityHint(language == .en ? "Scrolls this tab to the top" : "滚动到当前页签顶部")
    }

    private var fill: Color {
        isRetro ? RetroEditorialTokens.raisedPaper : Color(nsColor: .controlBackgroundColor)
    }

    private var stroke: Color {
        isRetro
            ? RetroEditorialTokens.ink.opacity(0.85)
            : Color(nsColor: .separatorColor).opacity(0.6)
    }
}
