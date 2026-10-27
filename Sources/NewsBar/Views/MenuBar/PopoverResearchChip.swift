import SwiftUI

/// Single-row popover entry for burst research. Deliberately not a horizontal
/// card strip: at 400×520 that would push at least two news rows out of view.
struct PopoverResearchChip: View {
    @Environment(AppSettings.self) private var settings
    let summary: ResearchSummary
    let onOpen: () -> Void

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    var body: some View {
        if summary.burstCount > 0 {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(isRetro ? RetroEditorialTokens.brick : Color.orange)

                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if summary.unreadBurstCount > 0 {
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
                .background(isRetro ? AnyShapeStyle(RetroEditorialTokens.raisedPaper) : AnyShapeStyle(Color.orange.opacity(0.08)))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isRetro ? RetroEditorialTokens.ink.opacity(0.35) : Color.orange.opacity(0.18),
                            lineWidth: 1
                        )
                }
                .editorialClipShape(cornerRadius: 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, PopoverLayout.horizontalInset)
            .padding(.bottom, 6)
            .accessibilityLabel(title)
            .help("research.chip.help".localized)
        }
    }

    private var title: String {
        if summary.unreadBurstCount > 0 {
            return L10n.string(
                "research.chip",
                language: settings.appLanguage,
                summary.burstCount,
                summary.unreadBurstCount
            )
        }
        return L10n.string(
            "research.chip.noUnread",
            language: settings.appLanguage,
            summary.burstCount
        )
    }
}
