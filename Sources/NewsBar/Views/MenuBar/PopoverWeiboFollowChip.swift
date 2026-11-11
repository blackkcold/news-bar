import SwiftUI

/// Single-row popover entry for the following feed. It only exists when there
/// is something unread; an empty entry would compete with the news list for no
/// reason.
struct PopoverWeiboFollowChip: View {
    @Environment(AppSettings.self) private var settings
    let unreadCount: Int
    let onOpen: () -> Void
    var compact = false

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var tint: Color { isRetro ? RetroEditorialTokens.brick : .accentColor }

    var body: some View {
        if unreadCount > 0 {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(tint)

                    Text(
                        L10n.string(
                            "weibo.popover.chip",
                            language: settings.appLanguage,
                            unreadCount
                        )
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                    Spacer(minLength: 0)

                    Circle()
                        .fill(tint)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
                .background(
                    isRetro
                        ? AnyShapeStyle(RetroEditorialTokens.raisedPaper)
                        : AnyShapeStyle(Color.accentColor.opacity(0.08))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isRetro
                                ? RetroEditorialTokens.ink.opacity(0.35)
                                : Color.accentColor.opacity(0.18),
                            lineWidth: 1
                        )
                }
                .editorialClipShape(cornerRadius: 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, compact ? 0 : PopoverLayout.horizontalInset)
            .padding(.bottom, compact ? 0 : 6)
            .accessibilityLabel(
                L10n.string(
                    "weibo.popover.chip",
                    language: settings.appLanguage,
                    unreadCount
                )
            )
            .help(L10n.string("weibo.popover.chipHint", language: settings.appLanguage))
        }
    }
}
