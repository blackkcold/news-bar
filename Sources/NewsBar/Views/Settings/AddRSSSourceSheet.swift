import SwiftUI

/// A focused add form for a custom RSS source.
///
/// The draft and its validation live here, so leaving the sheet never leaves a
/// half-validated URL on the pane behind it. The pane only receives a finished
/// `RSSSourceConfig`, appends it, and posts the usual `.rssSourceAdded`.
struct AddRSSSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    let existingSources: [RSSSourceConfig]
    let onAdd: (RSSSourceConfig) -> Void

    @State private var name = ""
    @State private var url = ""
    @State private var isTesting = false
    @State private var errorMessage: String?
    @State private var warningMessage: String?
    /// A non-blocking security warning asks once more before adding.
    @State private var pendingWarning = false
    @State private var validationTask: Task<Void, Never>?
    @FocusState private var nameFocused: Bool
    @FocusState private var urlFocused: Bool

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isTesting
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            fields
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .frame(width: 520)
        .frame(minHeight: 300)
        .appThemeSurface()
        .onAppear { nameFocused = true }
        .onDisappear {
            // Closing the sheet must also stop a validation that is in flight.
            validationTask?.cancel()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(
                    settings.appTheme == .retroEditorial
                        ? RetroEditorialTokens.brick
                        : Color.accentColor
                )
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("rss.addSource".localized)
                    .font(.system(size: 14, weight: .semibold))
                Text("rss.addSource.subtitle".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("settings.close".localized)
        }
        .padding(16)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("rss.sourceName".localized, text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .accessibilityLabel("rss.sourceName".localized)
                .onSubmit { urlFocused = true }

            TextField("rss.url".localized, text: $url)
                .textFieldStyle(.roundedBorder)
                .focused($urlFocused)
                .accessibilityLabel("rss.url".localized)
                .onSubmit { submit() }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let warningMessage {
                VStack(alignment: .leading, spacing: 3) {
                    Label(warningMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if pendingWarning {
                        Text("rss.warningContinue".localized)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .onChange(of: url) { _, _ in
            guard !isTesting else { return }
            pendingWarning = false
            warningMessage = nil
            errorMessage = nil
        }
        .onChange(of: name) { _, _ in
            guard !isTesting else { return }
            errorMessage = nil
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("rss.addSource.cancel".localized) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(EditorialActionButtonStyle(compact: true))

            Spacer()

            Button(action: submit) {
                HStack(spacing: 6) {
                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                    Text(
                        pendingWarning
                            ? "rss.addAnyway".localized
                            : "rss.addAndValidate".localized
                    )
                }
            }
            .buttonStyle(EditorialActionButtonStyle(tone: .primary))
            .disabled(!canSubmit)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func submit() {
        guard canSubmit else { return }
        errorMessage = nil

        let sanitizedURL = SecurityPolicies.sanitizeUserInput(url)
        let sanitizedName = SecurityPolicies.sanitizeUserInput(name)

        guard !sanitizedURL.isEmpty else {
            errorMessage = "rss.needURL".localized
            return
        }

        var normalizedURL = sanitizedURL
        if URL(string: normalizedURL)?.scheme == nil {
            normalizedURL = "https://" + normalizedURL
        }
        normalizedURL = SecurityPolicies.canonicalRSSURL(normalizedURL)

        guard !existingSources.contains(where: { $0.url == normalizedURL }) else {
            errorMessage = "rss.alreadyExists".localized
            return
        }

        switch SecurityPolicies.validateRSSURL(normalizedURL) {
        case .valid:
            warningMessage = nil
        case .blocked(let reason):
            errorMessage = L10n.string(
                "rss.blocked",
                RSSSecurityCopy.localized(reason, language: settings.appLanguage)
            )
            return
        case .warning(let reason):
            warningMessage = L10n.string(
                "rss.warning",
                RSSSecurityCopy.localized(reason, language: settings.appLanguage)
            )
            guard pendingWarning else {
                pendingWarning = true
                return
            }
        }

        isTesting = true
        validationTask = Task {
            do {
                let isValid = try await RSSService.validate(normalizedURL)
                guard !Task.isCancelled else {
                    isTesting = false
                    return
                }
                if isValid {
                    let source = RSSSourceConfig(
                        name: sanitizedName,
                        url: normalizedURL,
                        displayMode: .text
                    )
                    onAdd(source)
                    dismiss()
                } else {
                    errorMessage = "rss.notValidFeed".localized
                }
            } catch is CancellationError {
                isTesting = false
                return
            } catch {
                guard !Task.isCancelled else {
                    isTesting = false
                    return
                }
                errorMessage = "rss.cannotConnect".localized
            }
            isTesting = false
        }
    }
}
