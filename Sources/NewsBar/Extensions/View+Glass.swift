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
    @State private var systemColorScheme: ColorScheme = {
        NSApp.effectiveAppearance.name == .darkAqua ? .dark : .light
    }()

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(settings.resolvedColorScheme ?? systemColorScheme)
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
        systemColorScheme = NSApp.effectiveAppearance.name == .darkAqua ? .dark : .light
    }
}

extension View {
    func adaptiveColorScheme() -> some View {
        modifier(AdaptiveColorSchemeModifier())
    }
}
