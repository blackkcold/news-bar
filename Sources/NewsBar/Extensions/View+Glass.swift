import SwiftUI

extension View {

    @ViewBuilder
    func glassBackground() -> some View {
        self.background(.ultraThinMaterial)
    }

    func materialCard() -> some View {
        self
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    func glassButton() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6))
            .clipShape(Capsule())
    }
}

// MARK: - Adaptive Color Scheme

private extension Notification.Name {
    static let appleInterfaceThemeChanged = Notification.Name("AppleInterfaceThemeChangedNotification")
}

private struct AdaptiveColorSchemeModifier: ViewModifier {
    @Environment(AppSettings.self) private var settings

    /// Pins the appearance regardless of the user's choice. The retro theme
    /// paints light paper, so a dark system appearance must not style its
    /// controls — otherwise segmented pickers and text fields draw white
    /// labels on cream.
    var forced: ColorScheme?

    @State private var systemColorScheme: ColorScheme = {
        // `NSApp` is nil until an NSApplication exists, which is the case in a
        // single-test process. `NSApplication.shared` creates it on demand.
        NSApplication.shared.effectiveAppearance.name == .darkAqua ? .dark : .light
    }()

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(forced ?? settings.resolvedColorScheme ?? systemColorScheme)
            .onAppear { syncSystemColorScheme() }
            .onChange(of: settings.colorScheme) { _, newValue in
                if newValue == "system" { syncSystemColorScheme() }
            }
            .onReceive(
                DistributedNotificationCenter.default()
                    .publisher(for: .appleInterfaceThemeChanged)
            ) { _ in
                if settings.colorScheme == "system" { syncSystemColorScheme() }
            }
    }

    private func syncSystemColorScheme() {
        systemColorScheme = NSApplication.shared.effectiveAppearance.name == .darkAqua ? .dark : .light
    }
}

extension View {
    func adaptiveColorScheme(forcing forced: ColorScheme? = nil) -> some View {
        modifier(AdaptiveColorSchemeModifier(forced: forced))
    }
}
