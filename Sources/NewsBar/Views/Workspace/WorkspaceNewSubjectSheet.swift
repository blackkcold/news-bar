import SwiftUI

struct WorkspaceNewSubjectSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ResearchWorkspaceModel

    @State private var title = ""
    @State private var aliasesText = ""
    @State private var seedURL = ""
    @State private var isSaving = false
    @State private var localError: String?
    @FocusState private var titleFocused: Bool

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    private var parsedAliases: [String] {
        aliasesText
            .components(separatedBy: CharacterSet(charactersIn: ",\n，、;；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, alias in
                guard result.count < 8 else { return }
                let key = TopicFingerprint.normalized(alias)
                guard !key.isEmpty,
                      !result.contains(where: { TopicFingerprint.normalized($0) == key })
                else { return }
                result.append(alias)
            }
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSeedURL: String {
        seedURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var seedURLError: String? {
        guard !trimmedSeedURL.isEmpty else { return nil }
        return ReaderNavigationPolicy.allowedURL(trimmedSeedURL) == nil
            ? "workspace.new.urlInvalid".localized
            : nil
    }

    private var canSave: Bool {
        !trimmedTitle.isEmpty && seedURLError == nil && !isSaving
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("workspace.new.title".localized)
                    .font(.system(size: 15, weight: isRetro ? .black : .semibold,
                                  design: isRetro ? .serif : .default))
                Spacer(minLength: 8)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("workspace.action.cancel".localized)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    field("workspace.new.name".localized, required: true) {
                        TextField("workspace.new.name.placeholder".localized, text: $title)
                            .textFieldStyle(.roundedBorder)
                            .focused($titleFocused)
                            .onSubmit { saveIfPossible() }
                    }

                    field("workspace.new.aliases".localized, required: false) {
                        TextField("workspace.new.aliases.placeholder".localized,
                                  text: $aliasesText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...4)
                    }

                    field("workspace.new.seedURL".localized, required: false) {
                        TextField("https://…", text: $seedURL)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                        if let seedURLError {
                            Text(seedURLError)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.red)
                        }
                    }

                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.top, 1)
                        Text("workspace.new.hint".localized)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let localError {
                        Text(localError)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
            }

            Divider()

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("workspace.action.cancel".localized) {
                    dismiss()
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))
                .keyboardShortcut(.cancelAction)

                Button {
                    saveIfPossible()
                } label: {
                    HStack(spacing: 5) {
                        if isSaving {
                            ProgressView().controlSize(.mini)
                        }
                        Text("workspace.new.create".localized)
                    }
                }
                .buttonStyle(EditorialActionButtonStyle(tone: .prominent, compact: true))
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 470, height: 390)
        .adaptiveColorScheme()
        .appThemeSurface()
        .onAppear { titleFocused = true }
    }

    private func field<Content: View>(
        _ label: String,
        required: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                if required {
                    Text("*")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }
            content()
        }
    }

    private func saveIfPossible() {
        guard canSave else { return }
        localError = nil
        isSaving = true
        Task {
            let created = await model.createSubject(
                title: trimmedTitle,
                aliases: parsedAliases,
                seedURL: trimmedSeedURL.isEmpty ? nil : trimmedSeedURL
            )
            isSaving = false
            if created != nil {
                dismiss()
            } else {
                localError = "workspace.new.failed".localized
            }
        }
    }
}
