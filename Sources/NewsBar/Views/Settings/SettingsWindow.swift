import SwiftUI

struct SettingsWindow: View {
    @Environment(AppSettings.self) private var settings
    @State private var selectedTab: Int

    init(initialTab: Int = 0) {
        self._selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader

            TabView(selection: $selectedTab) {
                GeneralTab()
                    .tabItem {
                        Label("settings.tab.general".localized, systemImage: "gearshape")
                    }
                    .tag(0)

                RSSTab()
                    .tabItem {
                        Label("settings.tab.rss".localized, systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .tag(1)

                AITab()
                    .tabItem {
                        Label("settings.tab.ai".localized, systemImage: "sparkles")
                    }
                    .tag(2)

                NotificationTab()
                    .tabItem {
                        Label("settings.tab.notifications".localized, systemImage: "bell.fill")
                    }
                    .tag(4)

                AboutTab()
                    .tabItem {
                        Label("settings.tab.about".localized, systemImage: "info.circle")
                    }
                    .tag(3)
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToAITab)) { _ in
                selectedTab = 2
            }

            Divider()

            HStack {
                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("settings.quit".localized)
                        .font(.system(size: 12))
                }
                .buttonStyle(EditorialActionButtonStyle(tone: .destructive, compact: true))
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 460, minHeight: 380)
        .padding(.top, 8)
        .adaptiveColorScheme()
        .appThemeSurface()
    }

    private var settingsHeader: some View {
        HStack(spacing: 10) {
            if selectedTab == 1 {
                EditorialSourceBadge(mark: .rss, fallbackTint: .blue, size: 32, rotation: -1)
            } else {
                EditorialSymbolBadge(
                    symbol: selectedTabSymbol,
                    fallbackTint: .accentColor,
                    size: 32,
                    rotation: -1
                )
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(selectedTabTitle)
                    .editorialHeading(size: 16)
                    .lineLimit(1)
                Text(selectedTabSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            EditorialTag(text: "settings.badge".localized, fallbackTint: .secondary, filled: settings.appTheme == .retroEditorial)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .editorialMasthead()
        .accessibilityElement(children: .combine)
    }

    private var selectedTabTitle: String {
        switch selectedTab {
        case 1: return "settings.rss".localized
        case 2: return "settings.ai".localized
        case 3: return "settings.about".localized
        case 4: return "settings.notifications".localized
        default: return "settings.general".localized
        }
    }

    private var selectedTabSubtitle: String {
        switch selectedTab {
        case 1: return "settings.rss.subtitle".localized
        case 2: return "settings.ai.subtitle".localized
        case 3: return "settings.about.subtitle".localized
        case 4: return "settings.notifications.subtitle".localized
        default: return "settings.general.subtitle".localized
        }
    }

    private var selectedTabSymbol: String {
        switch selectedTab {
        case 2: return "sparkles"
        case 3: return "info.circle"
        case 4: return "bell.fill"
        default: return "gearshape"
        }
    }
}
