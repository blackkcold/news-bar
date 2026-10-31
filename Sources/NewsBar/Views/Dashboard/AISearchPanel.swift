import SwiftUI

/// Reader AI search overlay. It sits above the article, keeps the reading
/// position, and never replaces the page. Every citation chip is a page that
/// this run actually read.
struct AISearchPanel: View {
    @Bindable var model: AISearchPanelModel
    let language: AppLanguage
    let providerName: String
    let modelName: String
    let webEnabled: Bool
    let onSubmit: () -> Void
    let onRetry: () -> Void
    let onClose: () -> Void
    let onOpenCitation: (URL) -> Void
    let onCopy: (String) -> Void
    let onOpenSettings: () -> Void
    var onReturnToSearch: () -> Void = {}
    var onOpenArchive: () -> Void = {}

    @FocusState private var questionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            scopePicker
            inputRow
            if !model.hasAcknowledgedPrivacy {
                privacyNotice
            }
            Divider()
            content
            footer
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
        .onAppear { questionFocused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            Text(L10n.string("reader.search.title", language: language))
                .font(.headline)
            Button(action: onReturnToSearch) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(QuickSearchAccessibilityLabels.returnToSearch(language: language))
            .help(QuickSearchAccessibilityLabels.returnToSearch(language: language))
            Button(action: onOpenArchive) {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(QuickSearchAccessibilityLabels.openArchive(language: language))
            .help(QuickSearchAccessibilityLabels.openArchive(language: language))
            Spacer(minLength: 0)
            if let answer = model.answer {
                Button {
                    onCopy(answer.plainText(language))
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
            .accessibilityLabel(L10n.string("reader.search.close", language: language))
        }
    }

    private var scopePicker: some View {
        Picker(L10n.string("reader.search.scope", language: language), selection: Binding(
            get: { model.scope },
            set: { model.scope = $0 }
        )) {
            Text(AISearchScope.currentPage.title(language)).tag(AISearchScope.currentPage)
            Text(AISearchScope.web.title(language)).tag(AISearchScope.web)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(model.state.isBusy || !webEnabled)
        .accessibilityLabel(L10n.string("reader.search.scope", language: language))
        .help(webEnabled
              ? ""
              : L10n.string("reader.search.webUnavailable", language: language))
    }

    private var inputRow: some View {
        HStack(spacing: 6) {
            TextField(L10n.string("reader.search.placeholder", language: language), text: $model.question)
                .textFieldStyle(.roundedBorder)
                .focused($questionFocused)
                .onSubmit { submit() }
                .disabled(model.state.isBusy)
                .accessibilityLabel(L10n.string("reader.search.placeholder", language: language))
            Button(action: submit) {
                if model.state.isBusy {
                    ProgressView().controlSize(.small).frame(width: 22, height: 22)
                } else {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 17))
                }
            }
            .buttonStyle(.borderless)
            .disabled(model.state.isBusy || model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(L10n.string("reader.search.submit", language: language))
            .help(L10n.string("reader.search.submit", language: language))
        }
    }

    private var privacyNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(L10n.string("reader.search.privacy", language: language, providerName))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(L10n.string("reader.search.privacyAcknowledge", language: language)) {
                model.acknowledgePrivacy()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            Text(L10n.string("reader.search.idle", language: language))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .searching, .reading, .answering:
            VStack(alignment: .leading, spacing: 9) {
                AnswerStageRow(state: model.state, scope: model.scope, language: language)
                if let answer = model.answer {
                    answerSection(answer)
                } else {
                    AnswerSkeleton()
                }
            }

        case .done:
            if let answer = model.answer {
                answerSection(answer)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button(L10n.string("reader.search.retry", language: language), action: onRetry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button(L10n.string("reader.search.openSettings", language: language), action: onOpenSettings)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
        }
    }

    private func answerSection(_ answer: AnswerDocument) -> some View {
        AnswerDocumentView(
            document: answer,
            language: language,
            maxHeight: 360,
            onOpenSource: { source in
                if let url = URL(string: source.url) { onOpenCitation(url) }
            },
            isStreaming: model.isRevealing
        )
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.string(
                "answer.meta",
                language: language,
                modelName,
                model.answer?.thinking.title(language) ?? ""
            ))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(2)
            Text(L10n.string("reader.search.privateNote", language: language, providerName))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private func submit() {
        guard !model.state.isBusy,
              !model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSubmit()
    }
}
