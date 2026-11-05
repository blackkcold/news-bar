import SwiftUI

/// The seven settings groups. A group is a place a person would look for a
/// thing, not a subsystem: the RSS sources, the interest profile and the
/// cleanup actions used to be scattered across three tabs.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case reading
    case ai
    case notifications
    case privacy
    case advanced
    case about

    var id: String { rawValue }

    /// Short form for the sidebar.
    var titleKey: String { "settings.group.\(rawValue)" }

    /// Long form for the pane masthead.
    var headingKey: String {
        switch self {
        case .general: return "settings.general"
        case .reading: return "settings.rss"
        case .ai: return "settings.ai"
        case .notifications: return "settings.reminder"
        case .privacy: return "settings.group.privacy"
        case .advanced: return "settings.group.advanced"
        case .about: return "settings.about"
        }
    }

    var subtitleKey: String {
        switch self {
        case .general: return "settings.general.subtitle"
        case .reading: return "settings.rss.subtitle"
        case .ai: return "settings.ai.subtitle"
        case .notifications: return "settings.reminder.subtitle"
        case .privacy: return "settings.privacy.subtitle"
        case .advanced: return "settings.advanced.subtitle"
        case .about: return "settings.about.subtitle"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .reading: return "antenna.radiowaves.left.and.right"
        case .ai: return "sparkles"
        case .notifications: return "bell.fill"
        case .privacy: return "lock.shield"
        case .advanced: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }
}

struct SettingsWindow: View {
    @Environment(AppSettings.self) private var settings
    @State private var pane: SettingsPane

    init(initialPane: SettingsPane = .general) {
        _pane = State(initialValue: initialPane)
    }

    var body: some View {
        Group {
            if isRetro {
                legacyShell
            } else {
                splitShell
            }
        }
        .frame(minWidth: 780, minHeight: 580)
        .adaptiveColorScheme(forcing: isRetro ? .light : nil)
        .appThemeSurface()
        // Settings has a fixed pane list; a collapsible sidebar would leave
        // the window without navigation. Apply the removal at the window root
        // so it also works when NavigationSplitView is hosted in an AppKit
        // NSWindow rather than a SwiftUI WindowGroup.
        .toolbar(removing: .sidebarToggle)
        // Rebuild after a language change so every `.localized` label refreshes.
        .id(settings.appLanguage)
    }

    /// The retro paper theme keeps its existing two-column shell: the paper
    /// surface and hard rules are part of the skin, and a floating system
    /// sidebar would fight it.
    private var legacyShell: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 194)

            Divider()

            detail
        }
    }

    /// The modern theme lets NavigationSplitView provide the floating sidebar,
    /// its material and its selection behavior.
    private var splitShell: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 194, max: 230)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
            List(selection: selection) {
                ForEach(SettingsPane.allCases) { item in
                    Label(L10n.string(item.titleKey), systemImage: item.symbol)
                        .font(.system(size: 12.5))
                        .padding(.vertical, 2)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            // The host provides the background: the native sidebar material in
            // the modern theme, the paper surface in the retro theme. Hiding the
            // List's own background lets that surface show through instead of
            // painting a second, opaque column on top of it.
            .scrollContentBackground(.hidden)
        }
        .background {
            if isRetro {
                RetroEditorialTokens.raisedPaper
            }
        }
        // NavigationSplitView proposes the sidebar column size; the VStack must
        // accept it so the brand and the List are not compressed to zero height.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var isRetro: Bool {
        settings.appTheme == .retroEditorial
    }

    private var selection: Binding<SettingsPane?> {
        Binding(
            get: { pane },
            set: { if let next = $0 { pane = next } }
        )
    }

    private var brand: some View {
        HStack(spacing: 8) {
            EditorialSymbolBadge(
                symbol: "newspaper.fill",
                fallbackTint: RetroEditorialTokens.brick,
                size: 26,
                rotation: -2
            )

            VStack(alignment: .leading, spacing: 0) {
                Text("NewsBar")
                    .editorialHeading(size: 14)
                    .lineLimit(1)
                Text("v\(AppVersion.current)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(spacing: 0) {
            paneHeader

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
        }
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .general: GeneralTab()
        case .reading: RSSTab()
        case .ai: AITab()
        case .notifications: ReminderTab()
        case .privacy: PrivacyTab()
        case .advanced: AdvancedTab()
        case .about: AboutTab()
        }
    }

    private var paneHeader: some View {
        HStack(spacing: 10) {
            if pane == .reading {
                EditorialSourceBadge(mark: .rss, fallbackTint: .blue, size: 32, rotation: -1)
            } else {
                EditorialSymbolBadge(
                    symbol: pane.symbol,
                    fallbackTint: .accentColor,
                    size: 32,
                    rotation: -1
                )
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.string(pane.headingKey))
                    .editorialHeading(size: 16)
                    .lineLimit(1)
                Text(L10n.string(pane.subtitleKey))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            EditorialTag(
                text: "settings.badge".localized,
                fallbackTint: .secondary,
                filled: settings.appTheme == .retroEditorial
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .editorialMasthead()
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
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
}
