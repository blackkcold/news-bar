import SwiftUI

/// Shared leaf controls for the dashboard filter bar and the Weibo following
/// filter bar.
///
/// These values are the dashboard baseline. Changing one changes both pages,
/// so update `DashboardLayoutParityTests` in the same commit.
enum DashboardFilterMetrics {
    static let searchIconSize: CGFloat = 13
    static let searchTextSize: CGFloat = 13
    static let searchClearSize: CGFloat = 12
    static let searchHorizontalPadding: CGFloat = 12
    static let searchVerticalPadding: CGFloat = 9
    static let searchCornerRadius: CGFloat = 12
    static let searchStackSpacing: CGFloat = 10
    static let searchRetroBorderWidth: CGFloat = 1.4

    static let chipFontSize: CGFloat = 11
    static let chipHorizontalPadding: CGFloat = 12
    static let chipVerticalPadding: CGFloat = 6

    static let countFontSize: CGFloat = 10
}

struct DashboardSearchField: View {
    @Environment(AppSettings.self) private var settings
    @Binding var text: String
    let placeholder: String

    var iconSize: CGFloat = DashboardFilterMetrics.searchIconSize
    var textSize: CGFloat = DashboardFilterMetrics.searchTextSize
    var clearSize: CGFloat = DashboardFilterMetrics.searchClearSize
    var horizontalPadding: CGFloat = DashboardFilterMetrics.searchHorizontalPadding
    var verticalPadding: CGFloat = DashboardFilterMetrics.searchVerticalPadding
    var cornerRadius: CGFloat = DashboardFilterMetrics.searchCornerRadius
    var stackSpacing: CGFloat = DashboardFilterMetrics.searchStackSpacing
    var retroBorderWidth: CGFloat = DashboardFilterMetrics.searchRetroBorderWidth

    private var isActive: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: stackSpacing) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: textSize))

            if isActive {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: clearSize))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("dash.searchClear".localized)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background {
            if settings.appTheme == .retroEditorial {
                Rectangle().fill(RetroEditorialTokens.raisedPaper)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
        }
        .overlay {
            if settings.appTheme == .retroEditorial {
                Rectangle().strokeBorder(RetroEditorialTokens.ink, lineWidth: retroBorderWidth)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
            }
        }
    }
}

struct DashboardFilterChip: View {
    @Environment(AppSettings.self) private var settings
    let title: String
    let isSelected: Bool

    var fontSize: CGFloat = DashboardFilterMetrics.chipFontSize
    var horizontalPadding: CGFloat = DashboardFilterMetrics.chipHorizontalPadding
    var verticalPadding: CGFloat = DashboardFilterMetrics.chipVerticalPadding

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: fontSize, weight: .medium))
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background {
                    if settings.appTheme == .retroEditorial {
                        Rectangle().fill(
                            isSelected
                                ? RetroEditorialTokens.brick
                                : RetroEditorialTokens.raisedPaper
                        )
                    } else {
                        Capsule().fill(
                            isSelected
                                ? Color.accentColor.opacity(0.16)
                                : Color(nsColor: .controlBackgroundColor)
                        )
                    }
                }
                .overlay {
                    if settings.appTheme == .retroEditorial {
                        Rectangle().strokeBorder(RetroEditorialTokens.ink, lineWidth: 1)
                    } else {
                        Capsule().strokeBorder(
                            Color(nsColor: .separatorColor).opacity(0.35),
                            lineWidth: 1
                        )
                    }
                }
                .foregroundStyle(
                    isSelected
                        ? (settings.appTheme == .retroEditorial
                            ? RetroEditorialTokens.raisedPaper
                            : Color.accentColor)
                        : .primary
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct DashboardFilterCountText: View {
    let text: String
    var fontSize: CGFloat = DashboardFilterMetrics.countFontSize

    var body: some View {
        Text(text)
            .font(.system(size: fontSize))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}
