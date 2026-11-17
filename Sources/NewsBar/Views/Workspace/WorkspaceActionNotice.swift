import SwiftUI

struct WorkspaceActionNoticeBar: View {
    @Environment(AppSettings.self) private var settings

    let notice: WorkspaceActionNotice
    let onDismiss: () -> Void
    let onAction: (WorkspaceNoticeAction) -> Void

    private var tint: Color {
        if notice.tone == .error { return .red }
        return settings.appTheme == .retroEditorial
            ? RetroEditorialTokens.brick
            : .accentColor
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notice.tone == .error
                  ? "exclamationmark.triangle.fill"
                  : "info.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            Text(notice.message)
                .font(.system(size: 11))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 6)

            if let action = notice.action {
                Button(actionTitle(action)) {
                    onAction(action)
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))
                .accessibilityLabel(actionTitle(action))
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("workspace.notice.dismiss".localized)
            .help("workspace.notice.dismiss".localized)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(tint.opacity(0.10))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tint)
                .frame(width: 2)
        }
        .accessibilityElement(children: .contain)
    }

    private func actionTitle(_ action: WorkspaceNoticeAction) -> String {
        switch action {
        case .configureAI:
            return L10n.string("workspace.notice.configureAI", language: settings.appLanguage)
        case .configureRSS:
            return L10n.string("workspace.notice.configureRSS", language: settings.appLanguage)
        case .undoArchive:
            return L10n.string("workspace.notice.undo", language: settings.appLanguage)
        case .openSubject:
            return L10n.string("workspace.notice.open", language: settings.appLanguage)
        }
    }
}
