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
    let onOpenSource: (URL) -> Void
    let canLookUp: Bool
    let onLookUp: () -> Void
    let onConfirmLookUp: () -> Void
    let onCancelLookUp: () -> Void

    private var english: Bool { language == .en }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(.secondary)
                Text(L10n.string("reader.selection.title", language: language))
                    .font(.headline)
                Spacer(minLength: 0)
                if let document = model.document {
                    Button {
                        onCopy(document.plainText(language))
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isRevealing)
                    .help(L10n.string("answer.copy", language: language))
                    .accessibilityLabel(L10n.string("answer.copy", language: language))
                }
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
        .frame(width: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 4)
        .accessibilityElement(children: .contain)
        .alert(
            L10n.string("reader.selection.lookUp.title", language: language),
            isPresented: Binding(
                get: { model.isConfirmingLookUp },
                set: { if !$0 { onCancelLookUp() } }
            )
        ) {
            Button(L10n.string("reader.selection.lookUp.cancel", language: language), role: .cancel) {
                onCancelLookUp()
            }
            Button(L10n.string("reader.selection.lookUp.confirm", language: language)) {
                onConfirmLookUp()
            }
        } message: {
            Text(L10n.string("reader.selection.lookUp.message", language: language))
        }
    }

    /// What the badge row cannot say on its own: whether the offline answer was
    /// a judgment or a fallback. Only meaningful for offline documents, which
    /// is the only case where "未联网" is ambiguous.
    private var noticeText: String? {
        guard model.document?.mode == .offline else { return nil }
        switch model.lookupNotice {
        case .judgedOffline:
            return L10n.string("answer.auto.judged", language: language)
        case .lookupFailed:
            return L10n.string("answer.auto.failed", language: language)
        case .searchUnavailable:
            return L10n.string("answer.auto.noSearch", language: language)
        case nil:
            return nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if let document = model.document {
            AnswerDocumentView(
                document: document,
                language: language,
                maxHeight: 380,
                onOpenSource: { source in
                    if let url = URL(string: source.url) { onOpenSource(url) }
                },
                onLookUp: canLookUp ? onLookUp : nil,
                notice: noticeText,
                isStreaming: model.isRevealing
            )
            HStack(spacing: 8) {
                Button(L10n.string("reader.selection.retry", language: language), action: onRetry)
                Spacer(minLength: 0)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            contentWithoutAnswer
        }
    }

    @ViewBuilder
    private var contentWithoutAnswer: some View {
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
        case .ready(let document):
            AnswerDocumentView(
                document: document,
                language: language,
                maxHeight: 380,
                onOpenSource: { source in
                    if let url = URL(string: source.url) { onOpenSource(url) }
                },
                notice: noticeText,
                isStreaming: model.isRevealing
            )
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
