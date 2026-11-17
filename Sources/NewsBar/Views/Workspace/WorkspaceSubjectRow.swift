import SwiftUI

struct WorkspaceSubjectRow: View {
    @Environment(AppSettings.self) private var settings

    let subject: WorkspaceSubject
    let isSelected: Bool
    let isResearchActive: Bool

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var accent: Color { isRetro ? RetroEditorialTokens.brick : .accentColor }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            statusDot
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(subject.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)

                    if subject.isFollowed {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }

                HStack(spacing: 5) {
                    if let alias = subject.normalizedAliases.first {
                        Text(alias)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("·")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Text(modelRelativeTime)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let status = statusLabel {
                        Text(status)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(statusColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(statusColor.opacity(0.10))
                            .editorialClipShape(cornerRadius: 4)
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(isSelected ? accent.opacity(0.11) : Color.clear)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? accent.opacity(0.30) : Color.clear, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
            .opacity(statusLabel == nil ? 0 : 1)
            .accessibilityHidden(true)
    }

    private var statusLabel: String? {
        if isResearchActive {
            return L10n.string("workspace.status.researching", language: settings.appLanguage)
        }
        switch subject.updateState {
        case .needsReview:
            return L10n.string("workspace.status.review", language: settings.appLanguage)
        case .hasUpdates:
            return L10n.string("workspace.status.updated", language: settings.appLanguage)
        case .current:
            return nil
        }
    }

    private var statusColor: Color {
        if isResearchActive { return accent }
        switch subject.updateState {
        case .needsReview: return .orange
        case .hasUpdates: return .blue
        case .current: return .clear
        }
    }

    private var modelRelativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: subject.lastActivityAt, relativeTo: Date())
    }

    private var accessibilityLabel: String {
        var parts = [subject.title]
        if let alias = subject.normalizedAliases.first { parts.append(alias) }
        if let status = statusLabel { parts.append(status) }
        if subject.isFollowed {
            parts.append(L10n.string("workspace.sidebar.following", language: settings.appLanguage))
        }
        return parts.joined(separator: "，")
    }
}
