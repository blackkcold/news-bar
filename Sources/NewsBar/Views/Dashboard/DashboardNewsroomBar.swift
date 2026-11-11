import SwiftUI

/// The dashboard's single chrome row: identity, browse modes and window
/// actions share one 20pt grid. Article tabs appear as a second row only when
/// a reader tab exists, so the default window has one header row instead of
/// a native toolbar plus a scene strip.
struct DashboardNewsroomBar: View {
    @Environment(AppSettings.self) private var settings

    let mode: DashboardBrowseMode
    let followingUnread: Int
    let badgeEnabled: Bool
    let tabs: [WorkspaceTab]
    let activeID: UUID?
    let isRefreshing: Bool
    let showsRefresh: Bool

    let onSelectMode: (DashboardBrowseMode) -> Void
    let onSelectBrowse: () -> Void
    let onSelectTab: (UUID) -> Void
    let onCloseTab: (UUID) -> Void
    let onRefresh: () -> Void
    let onOpenResearch: () -> Void
    let onOpenSettings: () -> Void

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var accent: Color { isRetro ? RetroEditorialTokens.brick : .accentColor }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 10) {
                    brand
                    Spacer(minLength: 0)
                    actions
                }

                DashboardModeTabs(
                    mode: mode,
                    followingUnread: followingUnread,
                    badgeEnabled: badgeEnabled,
                    onSelect: onSelectMode
                )
            }
            .padding(.horizontal, 20)
            .frame(height: 46)
            .background(.bar)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isRetro ? RetroEditorialTokens.ink : Color(nsColor: .separatorColor).opacity(0.34))
                    .frame(height: isRetro ? 1.2 : 1)
            }

            if !tabs.isEmpty {
                WorkspaceTabStrip(
                    tabs: tabs,
                    activeID: activeID,
                    onSelectBrowse: onSelectBrowse,
                    onSelect: onSelectTab,
                    onClose: onCloseTab
                )
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var brand: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("NEWS")
                Text("BAR")
                    .foregroundStyle(accent)
            }
            .font(.system(size: 14, weight: .black, design: isRetro ? .serif : .default))
            .tracking(isRetro ? 0.4 : -0.5)

            Text(L10n.string("brand.desk", language: settings.appLanguage))
                .font(.system(size: 8, weight: .semibold, design: isRetro ? .serif : .default))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("NewsBar")
        .layoutPriority(2)
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if showsRefresh {
                DashboardBarAction(
                    symbol: "arrow.clockwise",
                    title: settings.appLanguage == .en ? "Refresh" : "刷新",
                    isBusy: isRefreshing,
                    action: onRefresh
                )
            }

            DashboardBarAction(
                symbol: "sparkles",
                title: L10n.string("research.center.title", language: settings.appLanguage),
                action: onOpenResearch
            )

            DashboardBarAction(
                symbol: "gearshape",
                title: settings.appLanguage == .en ? "Settings" : "设置",
                action: onOpenSettings
            )
        }
        .layoutPriority(2)
    }
}

/// Centered, equal-width browse tabs. The underline is a fixed 22pt capsule
/// instead of the text width so the three cells keep the same optical weight.
struct DashboardModeTabs: View {
    @Environment(AppSettings.self) private var settings

    let mode: DashboardBrowseMode
    let followingUnread: Int
    let badgeEnabled: Bool
    let onSelect: (DashboardBrowseMode) -> Void

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var accent: Color { isRetro ? RetroEditorialTokens.brick : .accentColor }
    private var badgeColor: Color { isRetro ? RetroEditorialTokens.brick : .red }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(DashboardBrowseMode.allCases) { item in
                tab(item)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("weibo.feed.mode", language: settings.appLanguage))
    }

    private func tab(_ item: DashboardBrowseMode) -> some View {
        let selected = mode == item
        let badge = DashboardModeSegmentedControl.badgeText(
            for: item,
            unread: followingUnread,
            enabled: badgeEnabled
        )

        return Button {
            // Always forward: selecting the current mode while a reader tab is
            // open must still return to the list.
            onSelect(item)
        } label: {
            HStack(alignment: .center, spacing: 4) {
                Text(L10n.string(item.titleKey, language: settings.appLanguage))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if let badge {
                    Text(badge)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 12, minHeight: 12)
                        .background(Capsule().fill(badgeColor))
                        .accessibilityHidden(true)
                }
            }
            .font(.system(
                size: 10.5,
                weight: selected ? .semibold : .medium,
                design: isRetro ? .serif : .default
            ))
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .frame(width: 76, height: 46)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if selected {
                    Capsule()
                        .fill(accent)
                        .frame(width: 22, height: 2)
                        .padding(.bottom, 7)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: item, badge: badge))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func accessibilityLabel(for item: DashboardBrowseMode, badge: String?) -> String {
        let title = L10n.string(item.titleKey, language: settings.appLanguage)
        guard let badge else { return title }
        return "\(title), \(L10n.string("weibo.feed.unreadCount", language: settings.appLanguage, Int(badge) ?? followingUnread))"
    }
}

/// Icon-only window action used by the newsroom bar. The native toolbar is
/// gone, so the hover highlight and hit target are owned here.
private struct DashboardBarAction: View {
    @Environment(AppSettings.self) private var settings
    @State private var isHovered = false

    let symbol: String
    let title: String
    var isBusy = false
    let action: () -> Void

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    var body: some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 11.5, weight: .medium))
                }
            }
            .foregroundStyle(isRetro ? RetroEditorialTokens.ink : Color.primary)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.07) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}
