import SwiftUI

/// Three-segment browse switch. Unlike the native segmented picker, the
/// "关注" segment can carry its unread badge inside the segment, so the badge
/// is never a detached capsule that follows the whole control around.
struct DashboardModeSegmentedControl: View {
    @Binding var mode: DashboardBrowseMode
    let followingUnread: Int
    var badgeEnabled = true

    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var accent: Color { isRetro ? RetroEditorialTokens.brick : Color.accentColor }
    private var badgeColor: Color { isRetro ? RetroEditorialTokens.brick : Color.red }
    private var language: AppLanguage { settings.appLanguage }

    static func badgeText(
        for mode: DashboardBrowseMode,
        unread: Int,
        enabled: Bool
    ) -> String? {
        guard mode == .following, enabled, unread > 0 else { return nil }
        return unread > 99 ? "99+" : "\(unread)"
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, min(420, proxy.size.width))
            let segmentWidth = max(1, (width - 8) / 3)

            HStack(spacing: 2) {
                ForEach(DashboardBrowseMode.allCases) { item in
                    segment(item, width: segmentWidth)
                }
            }
            .padding(2)
            .frame(width: width, height: 32, alignment: .leading)
            .background {
                if isRetro {
                    Rectangle().fill(RetroEditorialTokens.raisedPaper)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                }
            }
            .overlay {
                if isRetro {
                    Rectangle().strokeBorder(RetroEditorialTokens.ink, lineWidth: 1.2)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
                }
            }
            .animation(reduceMotion ? nil : DashboardMotion.micro, value: mode)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.string("weibo.feed.mode", language: language))
        }
        .frame(height: 32)
    }

    private func segment(_ item: DashboardBrowseMode, width: CGFloat) -> some View {
        let selected = mode == item
        let badge = Self.badgeText(
            for: item,
            unread: followingUnread,
            enabled: badgeEnabled
        )

        return Button {
            guard mode != item else { return }
            mode = item
        } label: {
            HStack(spacing: 4) {
                Text(L10n.string(item.titleKey, language: language))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                if let badge {
                    Text(badge)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 13, minHeight: 13)
                        .background(Capsule().fill(badgeColor))
                        .accessibilityHidden(true)
                }
            }
            .font(.system(
                size: 11,
                weight: selected ? .semibold : .medium,
                design: isRetro ? .serif : .default
            ))
            .foregroundStyle(
                selected
                    ? (isRetro ? RetroEditorialTokens.raisedPaper : accent)
                    : .primary
            )
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: width)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isRetro ? RetroEditorialTokens.brick : accent.opacity(0.16))
            }
        }
        .accessibilityLabel(accessibilityLabel(for: item, badge: badge))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func accessibilityLabel(for item: DashboardBrowseMode, badge: String?) -> String {
        let title = L10n.string(item.titleKey, language: language)
        guard let badge else { return title }
        return "\(title), \(L10n.string("weibo.feed.unreadCount", language: language, Int(badge) ?? followingUnread))"
    }
}
