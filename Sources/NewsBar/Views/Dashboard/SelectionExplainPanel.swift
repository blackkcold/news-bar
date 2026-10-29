import SwiftUI

/// The explanation card that appears after choosing “Explain with AI” for a
/// right-clicked selection. It never edits page content and never persists the
/// selection; only an explicit copy action touches the pasteboard.
struct SelectionExplainPanel: View {
    let model: SelectionExplainModel
    let language: AppLanguage
    let providerName: String
    let onClose: () -> Void
    let onCopy: (String) -> Void
    let onRetry: () -> Void
    let onOpenSettings: () -> Void

    private var english: Bool { language == .en }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(.secondary)
                Text(L10n.string("reader.selection.title", language: language))
                    .font(.headline)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityLabel(L10n.string("reader.selection.close", language: language))
            }

            Text(model.selection)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.leading, 9)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.tertiary).frame(width: 2)
                }

            Divider()
            content

            HStack(spacing: 8) {
                Text(L10n.string("reader.selection.privateNote", language: language, providerName))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.string("reader.selection.loading", language: language))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .ready(let answer):
            ScrollView {
                Text(answer)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            HStack(spacing: 8) {
                Button(L10n.string("reader.selection.copy", language: language)) {
                    onCopy(answer)
                }
                Button(L10n.string("reader.selection.retry", language: language), action: onRetry)
                Spacer(minLength: 0)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .noKey, .quota:
            Text(L10n.string(model.state == .noKey ? "reader.selection.noKey" : "reader.selection.quota", language: language))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.string("reader.selection.openSettings", language: language), action: onOpenSettings)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.string("reader.selection.retry", language: language), action: onRetry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}
