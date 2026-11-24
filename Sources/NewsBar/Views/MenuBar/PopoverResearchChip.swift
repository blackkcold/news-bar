import SwiftUI

/// Single-row popover entry for burst research. Deliberately not a horizontal
/// card strip: at 400×520 that would push at least two news rows out of view.
///
/// The chip only reports unread work. With everything read it becomes a plain
/// "Research Center" entry: the archive total (for example 25 burst studies)
/// belongs inside the center, not in the popover.
struct PopoverResearchChip: View {
    @Environment(AppSettings.self) private var settings
    let summary: ResearchSummary
    let onOpen: () -> Void
    var compact = false

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var hasUnread: Bool { summary.unreadBurstCount > 0 }

    private var iconColor: Color {
        guard hasUnread else { return .secondary }
        return isRetro ? RetroEditorialTokens.brick : .orange
    }

    var body: some View {
        if summary.burstCount > 0 {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Image(systemName: hasUnread ? "flame.fill" : "books.vertical")
                        .font(.system(size: 10))
                        .foregroundStyle(iconColor)

                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if hasUnread {
                        Circle()
                            .fill(Color.accentColor)
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
            .help("research.chip.help".localized)
        }
    }

    private var backgroundStyle: AnyShapeStyle {
        if isRetro { return AnyShapeStyle(RetroEditorialTokens.raisedPaper) }
        return hasUnread
            ? AnyShapeStyle(Color.orange.opacity(0.08))
            : AnyShapeStyle(Color.secondary.opacity(0.07))
    }

    private var strokeColor: Color {
        if isRetro { return RetroEditorialTokens.ink.opacity(0.35) }
        return hasUnread
            ? Color.orange.opacity(0.18)
            : Color.secondary.opacity(0.18)
    }

    private var title: String {
        Self.displayTitle(language: settings.appLanguage, summary: summary)
    }

    /// Internal so the unread-only wording can be tested without a view graph.
    static func displayTitle(language: AppLanguage, summary: ResearchSummary) -> String {
        if summary.unreadBurstCount > 0 {
            return L10n.string(
                "research.chip",
                language: language,
                summary.unreadBurstCount
            )
        }
        return L10n.string("research.chip.center", language: language)
    }
}
