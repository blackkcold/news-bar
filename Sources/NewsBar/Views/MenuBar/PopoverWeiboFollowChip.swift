import SwiftUI

/// Single-row popover entry for the following feed. It only exists when there
/// is something unread; an empty entry would compete with the news list for no
/// reason.
struct PopoverWeiboFollowChip: View {
    @Environment(AppSettings.self) private var settings
    let unreadCount: Int
    /// When false the entry stays tappable but drops the count and the dot:
    /// the badge switches only change what is shown, never whether the feed
    /// opens.
    var showsBadge = true
    let onOpen: () -> Void
    var compact = false

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var tint: Color {
        guard showsBadge else { return .secondary }
        return isRetro ? RetroEditorialTokens.brick : .accentColor
    }

    var body: some View {
        if unreadCount > 0 {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(tint)

                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if showsBadge {
                        Circle()
                            .fill(tint)
                            .frame(width: 5, height: 5)
                            .accessibilityHidden(true)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
                .background(backgroundStyle)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(strokeColor, lineWidth: 1)
                }
                .editorialClipShape(cornerRadius: 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, compact ? 0 : PopoverLayout.horizontalInset)
            .padding(.bottom, compact ? 0 : 6)
            .accessibilityLabel(title)
            .help(L10n.string("weibo.popover.chipHint", language: settings.appLanguage))
        }
    }

    private var title: String {
        Self.displayTitle(
            language: settings.appLanguage,
            unreadCount: unreadCount,
            showsBadge: showsBadge
        )
    }

    /// Internal so the badge-off wording can be tested without a view graph.
    static func displayTitle(
        language: AppLanguage,
        unreadCount: Int,
        showsBadge: Bool
    ) -> String {
        if showsBadge {
            return L10n.string(
                "weibo.popover.chip",
                language: language,
                unreadCount
            )
        }
        return L10n.string("weibo.popover.chipNoBadge", language: language)
    }

    private var backgroundStyle: AnyShapeStyle {
        if isRetro { return AnyShapeStyle(RetroEditorialTokens.raisedPaper) }
        return showsBadge
            ? AnyShapeStyle(Color.accentColor.opacity(0.08))
            : AnyShapeStyle(Color.secondary.opacity(0.07))
    }

    private var strokeColor: Color {
        if isRetro { return RetroEditorialTokens.ink.opacity(0.35) }
        return showsBadge
            ? Color.accentColor.opacity(0.18)
            : Color.secondary.opacity(0.18)
    }
}
