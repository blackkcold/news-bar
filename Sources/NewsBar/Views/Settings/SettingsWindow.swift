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
        HStack(spacing: 0) {
            sidebar
                .frame(width: 194)

            Divider()

            detail
        }
        .frame(minWidth: 780, minHeight: 580)
        .adaptiveColorScheme(forcing: settings.appTheme == .retroEditorial ? .light : nil)
        .appThemeSurface()
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
            // The retro paper needs its own fill; the modern theme must let the
            // sidebar list draw the system background. Hiding it and painting a
            // solid colour on top is what turned the column into a grey slab.
            .scrollContentBackground(isRetro ? .hidden : .automatic)
        }
        .background(isRetro ? RetroEditorialTokens.raisedPaper : Color.clear)
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
