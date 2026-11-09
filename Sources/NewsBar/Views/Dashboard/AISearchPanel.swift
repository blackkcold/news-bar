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
    /// Embedded panels live inside the reader auxiliary rail, which already
    /// supplies the width, padding, material and close control.
    var embedded = false
    /// Only the visible rail tab may take keyboard focus.
    var isActive = true
    /// The rail measures the free space under its header and passes the cap
    /// down, so a long answer can never push the footer out of the rail.
    var answerMaxHeight: CGFloat = 360

    @FocusState private var questionFocused: Bool

    var body: some View {
        chrome(panel)
            .accessibilityElement(children: .contain)
            .onAppear {
                if isActive { questionFocused = true }
            }
            .onChange(of: isActive) { _, active in
                questionFocused = active
            }
    }

    @ViewBuilder
    private func chrome<Content: View>(_ content: Content) -> some View {
        if embedded {
            content
        } else {
            content
                .padding(14)
                .frame(width: 420, alignment: .leading)
                .floatingPanelSurface(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var panel: some View {
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
    }

    @ViewBuilder
    private var header: some View {
        if embedded {
            if let answer = model.answer {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    copyButton(answer)
                }
            }
        } else {
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
                    copyButton(answer)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityLabel(L10n.string("reader.search.close", language: language))
            }
        }
    }

    private func copyButton(_ answer: AnswerDocument) -> some View {
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

    @ViewBuilder
    private var privacyNotice: some View {
        if embedded {
            VStack(alignment: .leading, spacing: 6) {
                privacyMessage
                acknowledgeButton
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .contain)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                privacyMessage
                Spacer(minLength: 0)
                acknowledgeButton
            }
            .padding(8)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .contain)
        }
    }

    private var privacyMessage: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(L10n.string("reader.search.privacy", language: language, providerName))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var acknowledgeButton: some View {
        Button(L10n.string("reader.search.privacyAcknowledge", language: language)) {
            model.acknowledgePrivacy()
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
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
            maxHeight: embedded ? answerMaxHeight : 360,
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
