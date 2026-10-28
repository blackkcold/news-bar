import SwiftUI

struct AITab: View {
    @Environment(AppSettings.self) private var settings

    @State private var selectedProviderID: String
    @State private var apiKeyInput = ""
    @State private var onePasswordRef = ""
    @State private var testResult: String?
    @State private var testSucceeded = false
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var isDeletingKey = false
    @State private var keyFeedback: AIKeyFeedback?
    @State private var onePasswordFeedback: AIKeyFeedback?
    @State private var keyStatus: AIKeyStatus = .missing
    @State private var pendingKeyDeletion = false
    @State private var isLoadingFrom1Password = false
    @State private var showCustomEditor = false
    @State private var editingCustom: CustomAIProviderConfig?
    @State private var pendingCustomDeletion: CustomAIProviderConfig?

    init() {
        let saved = UserDefaults.standard.string(forKey: "aiProvider") ?? AIProvider.deepseek.rawValue
        _selectedProviderID = State(initialValue: saved)
    }

    var body: some View {
        Form {
            Section {
                Toggle("ai.enable".localized, isOn: Binding(
                    get: { settings.aiSummaryEnabled },
                    set: { settings.aiSummaryEnabled = $0 }
                ))
            } header: {
                Text("ai.feature".localized)
            }

            Section {
                Picker("ai.provider".localized, selection: Binding(
                    get: { selectedProviderID },
                    set: { newProvider in
                        selectedProviderID = newProvider
                        settings.aiProvider = newProvider
                        settings.cachedAPIKey = nil
                        apiKeyInput = ""
                        testResult = nil
                        keyFeedback = nil
                        onePasswordFeedback = nil
                    }
                )) {
                    ForEach(settings.providerOptions, id: \.id) { option in
                        Text(option.name).tag(option.id)
                    }
                }

                HStack {
                    Button {
                        editingCustom = nil
                        showCustomEditor = true
                    } label: {
                        Label("ai.addCustomProvider".localized, systemImage: "plus.circle")
                    }
                    .font(.caption)
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
                    .controlSize(.small)

                    Spacer()

                    if settings.isUsingCustomProvider, let custom = settings.selectedCustomProvider {
                        Button {
                            editingCustom = custom
                            showCustomEditor = true
                        } label: {
                            Text(L10n.string("ai.editProvider", custom.name))
                        }
                        .font(.caption)
                        .buttonStyle(EditorialActionButtonStyle(compact: true))
                        .controlSize(.small)

                        Button {
                            pendingCustomDeletion = custom
                        } label: {
                            Text("ai.delete".localized)
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("ai.provider".localized)
            } footer: {
                if settings.isUsingCustomProvider {
                    Text("ai.provider.footer.custom".localized)
                }
            }

            Section {
                HStack(spacing: 6) {
                    Image(systemName: keyStatus == .saved ? "checkmark.seal.fill" : "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(keyStatus == .saved ? .green : .secondary)
                    Text(keyStatus.label(language: settings.appLanguage))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                SecureField(settings.providerApiKeyPlaceholder(forID: selectedProviderID), text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onChange(of: selectedProviderID) { _, _ in
                        apiKeyInput = ""
                    }
                    .accessibilityLabel("ai.apiKey".localized)

                HStack {
                    Button {
                        saveAPIKey()
                    } label: {
                        Text(isSaving ? "ai.saving".localized : "ai.save".localized)
                    }
                    .disabled(apiKeyInput.isEmpty || isSaving)
                    .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
                    .controlSize(.small)

                    Button {
                        testConnection()
                    } label: {
                        Text(isTesting ? "ai.testing".localized : "ai.test".localized)
                    }
                    .disabled((apiKeyInput.isEmpty && (settings.cachedAPIKey?.isEmpty ?? true)) || isTesting)
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
                    .controlSize(.small)

                    Spacer()

                    Button {
                        pendingKeyDeletion = true
                    } label: {
                        Text("ai.deleteKey".localized)
                    }
                    .disabled(keyStatus == .missing || isDeletingKey)
                    .foregroundStyle(.red)
                    .controlSize(.small)
                }

                if let feedback = keyFeedback {
                    Text(feedback.text(language: settings.appLanguage))
                        .font(.caption)
                        .foregroundStyle(feedback.color)
                        .accessibilityLabel(feedback.text(language: settings.appLanguage))
                }

                if let result = testResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(testSucceeded ? .green : .orange)
                }
            } header: {
                Text("ai.apiKey".localized)
            } footer: {
                Text(L10n.string("ai.apiKey.footer", settings.providerKeyRetrievalURL(forID: selectedProviderID)))
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(settings.providerOnePasswordHint(forID: selectedProviderID), text: $onePasswordRef)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .accessibilityLabel("ai.1password".localized)
                        .onChange(of: selectedProviderID) { _, _ in
                            Task { await loadScopedOnePasswordRef() }
                        }

                    HStack {
                        Button {
                            loadFrom1Password()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "key.horizontal")
                                Text(isLoadingFrom1Password ? "ai.loading".localized : "ai.loadFrom1Password".localized)
                            }
                        }
                        .disabled(onePasswordRef.isEmpty || isLoadingFrom1Password)
                        .buttonStyle(EditorialActionButtonStyle(compact: true))
                        .controlSize(.small)
                    }

                    if let feedback = onePasswordFeedback {
                        Text(feedback.text(language: settings.appLanguage))
                            .font(.caption)
                            .foregroundStyle(feedback.color)
                    }
                }
            } header: {
                Text("ai.1password".localized)
            } footer: {
                Text("ai.1password.footer".localized)
            }

            Section {
                Picker("ai.model".localized, selection: Binding(
                    get: { settings.aiModel },
                    set: { settings.aiModel = $0 }
                )) {
                    if !settings.currentAIModels.contains(settings.aiModel) {
                        Text("ai.models.unselected".localized).tag(settings.aiModel)
                    }
                    ForEach(settings.providerModels(forID: selectedProviderID), id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .disabled(settings.currentAIModels.isEmpty || settings.isLoadingModelCatalog)

                HStack {
                    if settings.isLoadingModelCatalog {
                        ProgressView().controlSize(.small)
                        Text("ai.models.loading".localized).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await settings.refreshModelCatalog(force: true) }
                    } label: {
                        Label("ai.models.refresh".localized, systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
                    .disabled(settings.isLoadingModelCatalog)
                }

                if let error = settings.modelCatalogError {
                    Text(error.message(language: settings.appLanguage))
                        .font(.caption).foregroundStyle(.orange)
                }
                if let updated = settings.modelCatalogUpdatedAt {
                    HStack(spacing: 4) {
                        Text(settings.modelCatalogIsStale ? "ai.models.stale".localized : "ai.models.updated".localized)
                        Text(updated, style: .relative)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            } header: {
                Text("ai.modelSettings".localized)
            } footer: {
                Text("ai.model.footer".localized)
            }

            Section {
                Toggle("ai.disableThinking".localized, isOn: Binding(
                    get: { settings.aiDisableDeepSeekThinking },
                    set: { settings.aiDisableDeepSeekThinking = $0 }
                ))
            } footer: {
                Text("ai.disableThinking.footer".localized)
            }

            Section {
                summaryLengthRow(
                    title: "ai.summaryLength".localized,
                    selection: Binding(
                        get: { settings.aiDashboardMaxWords },
                        set: { settings.aiDashboardMaxWords = $0 }
                    ),
                    presets: Array(AppSettings.validAIDashboardMaxWords).sorted()
                )
            } header: {
                Text("ai.summaryLength".localized)
            } footer: {
                Text("ai.summaryLength.footer".localized)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ai.pricing".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(settings.providerPricingInfo(forID: selectedProviderID), id: \.title) { item in
                        Text("\(item.title): \(item.detail)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text("ai.pricing".localized)
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("ai.usage.today".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(settings.aiUsageText)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(settings.todayAIRequestCount >= settings.aiDailyCap ? .red : .primary)
                    }
                    ProgressView(
                        value: min(Double(settings.todayAIRequestCount), Double(settings.aiDailyCap)),
                        total: Double(settings.aiDailyCap)
                    )
                    .tint(settings.todayAIRequestCount >= settings.aiDailyCap ? .red : .blue)

                    Text("ai.usage.shared".localized)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("ai.usage.reset".localized)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } header: {
                Text("ai.usage".localized)
            }

            Section {
                HStack {
                    Text("ai.dailyCap".localized)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { settings.aiDailyCap },
                        set: { settings.aiDailyCap = $0 }
                    )) {
                        ForEach(Array(AppSettings.validAICaps).sorted(), id: \.self) { cap in
                            Text(L10n.string("ai.capTimes", cap)).tag(cap)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
            } header: {
                Text("ai.limit".localized)
            } footer: {
                Text("ai.limit.footer".localized)
            }

            Section {
                Label("ai.researchSection".localized, systemImage: "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ResearchSettingsSection()

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("ai.privacy.body".localized)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                    }
                }
            } header: {
                Text("ai.privacy".localized)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task(id: settings.modelCatalogRevision) {
            selectedProviderID = settings.aiProvider
            await settings.refreshModelCatalog()
        }
        .sheet(isPresented: $showCustomEditor) {
            CustomAIProviderEditor(provider: editingCustom) { saved in
                editingCustom = nil
                showCustomEditor = false
                if let saved, !saved.id.isEmpty {
                    let customID = "custom:\(saved.id)"
                    selectedProviderID = customID
                    settings.aiProvider = customID
                    settings.cachedAPIKey = nil
                    apiKeyInput = ""
                    testResult = nil
                    keyFeedback = nil
                    onePasswordFeedback = nil
                }
            }
            .environment(settings)
            .frame(minWidth: 460, minHeight: 460)
        }
        .confirmationDialog(
            "ai.deleteCustom.title".localized,
            isPresented: Binding(
                get: { pendingCustomDeletion != nil },
                set: { if !$0 { pendingCustomDeletion = nil } }
            ),
            presenting: pendingCustomDeletion
        ) { custom in
            Button(L10n.string("ai.deleteCustom.confirm", custom.name), role: .destructive) {
                deleteCustomProvider(custom)
            }
            Button("ai.cancel".localized, role: .cancel) { }
        } message: { custom in
            Text(L10n.string("ai.deleteCustom.message", custom.name))
        }
        .confirmationDialog(
            "ai.deleteKey.title".localized,
            isPresented: $pendingKeyDeletion
        ) {
            Button("ai.deleteKey.confirm".localized, role: .destructive) {
                deleteAPIKey()
            }
            Button("ai.cancel".localized, role: .cancel) { }
        } message: {
            Text("ai.deleteKey.message".localized)
        }
        .task(id: settings.activeAPIKeyAccount) {
            await refreshKeyStatus()
            await loadScopedOnePasswordRef()
        }
    }

    private func deleteCustomProvider(_ custom: CustomAIProviderConfig) {
        settings.customAIProviders.removeAll { $0.id == custom.id }
        pendingCustomDeletion = nil
        if settings.isUsingCustomProvider == false, settings.aiProvider == "custom:\(custom.id)" {
            settings.aiProvider = AIProvider.deepseek.rawValue
            selectedProviderID = AIProvider.deepseek.rawValue
            settings.aiModel = settings.providerDefaultModel(forID: selectedProviderID)
            settings.cachedAPIKey = nil
        }
    }

    private func saveAPIKey() {
        isSaving = true
        keyFeedback = nil
        let sanitized = SecurityPolicies.sanitizeUserInput(apiKeyInput)
        let account = settings.activeAPIKeyAccount
        let providerID = settings.aiProvider
        let revision = settings.modelCatalogRevision
        let reference = onePasswordRef
        Task {
            let store = EncryptedKeyStore()
            let success = await store.saveAPIKey(sanitized, account: account)
            await MainActor.run {
                if success {
                    guard settings.activateAPIKey(sanitized, providerID: providerID, revision: revision) else { isSaving = false; return }
                    apiKeyInput = ""
                    keyFeedback = .saved
                    keyStatus = .saved
                    UserDefaults.standard.set(true, forKey: "hasAIKey-\(account)")
                    NotificationCenter.default.post(name: .apiKeyConfigured, object: nil)
                    Task { await persistOnePasswordReference(reference, for: account) }
                } else {
                    keyFeedback = .saveFailed
                }
                isSaving = false
            }
        }
    }

    /// Removes the encrypted copy on this Mac. The 1Password item and the
    /// provider-side key are deliberately left untouched.
    private func deleteAPIKey() {
        isDeletingKey = true
        keyFeedback = nil
        let account = settings.activeAPIKeyAccount
        Task {
            await EncryptedKeyStore().deleteAPIKey(account: account)
            await MainActor.run {
                settings.cachedAPIKey = nil
                keyStatus = .missing
                keyFeedback = .keyDeleted
                isDeletingKey = false
                NotificationCenter.default.post(name: .apiKeyConfigured, object: nil)
            }
        }
    }

    private func refreshKeyStatus() async {
        let account = settings.activeAPIKeyAccount
        let stored = await EncryptedKeyStore().readAPIKey(account: account)
        let hasFlag = UserDefaults.standard.bool(forKey: "hasAIKey-\(account)")
        await MainActor.run {
            guard account == settings.activeAPIKeyAccount else { return }
            keyStatus = AIKeyStatus.resolve(stored: stored, hasFlag: hasFlag)
        }
    }

    private func loadScopedOnePasswordRef() async {
        let account = settings.activeAPIKeyAccount
        let reference = await EncryptedKeyStore().readOnePasswordRef(account: account) ?? ""
        await MainActor.run {
            guard account == settings.activeAPIKeyAccount else { return }
            onePasswordRef = reference
            onePasswordFeedback = nil
        }
    }

    private func persistOnePasswordReference(_ reference: String, for account: String) async {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let store = EncryptedKeyStore()
        if trimmed.isEmpty {
            await store.deleteOnePasswordRef(account: account)
        } else {
            await store.saveOnePasswordRef(trimmed, account: account)
        }
    }

    private func loadFrom1Password() {
        guard !onePasswordRef.isEmpty else { return }
        guard OnePasswordService.isValidReference(onePasswordRef) else {
            onePasswordFeedback = .invalidReference
            return
        }

        isLoadingFrom1Password = true
        onePasswordFeedback = nil
        let providerID = settings.aiProvider
        let revision = settings.modelCatalogRevision
        let account = settings.activeAPIKeyAccount
        let reference = onePasswordRef

        Task {
            do {
                let key = try await OnePasswordService.readSecretAsync(reference: reference)
                let store = EncryptedKeyStore()
                let success = await store.saveAPIKey(key, account: account)
                await MainActor.run {
                    if success {
                        guard settings.activateAPIKey(key, providerID: providerID, revision: revision) else { isLoadingFrom1Password = false; return }
                        // The secret stays in the encrypted store; never echo it
                        // back into a field the user could re-save or screenshot.
                        keyStatus = .saved
                        keyFeedback = .saved
                        NotificationCenter.default.post(name: .apiKeyConfigured, object: nil)
                    }
                    onePasswordFeedback = success ? .loaded : .loadedButNotSaved
                    isLoadingFrom1Password = false
                }
                if success {
                    await persistOnePasswordReference(reference, for: account)
                }
            } catch OnePasswordError.notInstalled {
                await MainActor.run {
                    onePasswordFeedback = .notInstalled
                    isLoadingFrom1Password = false
                }
            } catch OnePasswordError.timeout {
                await MainActor.run {
                    onePasswordFeedback = .timedOut
                    isLoadingFrom1Password = false
                }
            } catch OnePasswordError.readFailed {
                await MainActor.run {
                    onePasswordFeedback = .readFailed
                    isLoadingFrom1Password = false
                }
            } catch OnePasswordError.invalidReference {
                await MainActor.run {
                    onePasswordFeedback = .invalidReference
                    isLoadingFrom1Password = false
                }
            } catch {
                NSLog("[AITab] loadFrom1Password failed: %@", error.localizedDescription)
                await MainActor.run {
                    onePasswordFeedback = .unknown
                    isLoadingFrom1Password = false
                }
            }
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        testSucceeded = false
        let providerID = settings.aiProvider
        let revision = settings.modelCatalogRevision
        let key = SecurityPolicies.sanitizeUserInput(apiKeyInput.isEmpty ? (settings.cachedAPIKey ?? "") : apiKeyInput)

        Task {
            defer { isTesting = false }
            do {
                guard !key.isEmpty else {
                    testResult = "ai.test.emptyKey".localized
                    return
                }
                let result = try await settings.checkModelConnection(apiKey: key)
                guard providerID == settings.aiProvider, revision == settings.modelCatalogRevision else { return }
                if result.source == .live {
                    testSucceeded = true
                    testResult = "ai.models.connectionSuccess".localized
                } else {
                    testResult = "ai.models.connectionStale".localized
                }
            } catch is CancellationError {
                return
            } catch {
                guard providerID == settings.aiProvider, revision == settings.modelCatalogRevision else { return }
                testResult = (error as? ProviderModelError ?? .network).message(language: settings.appLanguage)
            }
        }
    }

    private func summaryLengthRow(title: String, selection: Binding<Int>, presets: [Int], unitLabel: String = "字") -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(presets, id: \.self) { value in
                    Text("\(value) \(unitLabel)").tag(value)
                }
            }
            .labelsHidden()
            .frame(width: 92)
        }
    }
}

private struct CustomAIProviderEditor: View {
    @Environment(AppSettings.self) private var settings
    let provider: CustomAIProviderConfig?
    let onSaved: (CustomAIProviderConfig?) -> Void

    @State private var name: String
    @State private var baseURL: String
    @State private var isAnthropicFormat = false
    @State private var authHeaderName: String
    @State private var authHeaderPrefix: String
    @State private var apiVersion: String
    @State private var pricingNote: String
    @State private var errorMessage: String?

    init(provider: CustomAIProviderConfig?, onSaved: @escaping (CustomAIProviderConfig?) -> Void) {
        self.provider = provider
        self.onSaved = onSaved
        _name = State(initialValue: provider?.name ?? "")
        _baseURL = State(initialValue: provider?.baseURL ?? "")
        _isAnthropicFormat = State(initialValue: provider?.responseFormat == .anthropic)
        _authHeaderName = State(initialValue: provider?.authHeaderName ?? "Authorization")
        _authHeaderPrefix = State(initialValue: provider?.authHeaderPrefix ?? "Bearer ")
        _apiVersion = State(initialValue: provider?.apiVersion ?? "")
        _pricingNote = State(initialValue: provider?.pricingNote ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(provider == nil ? "ai.custom.title.add".localized : "ai.custom.title.edit".localized)
                .font(.system(size: 15, weight: .semibold))

            TextField("ai.custom.name".localized, text: $name)
                .textFieldStyle(.roundedBorder)

            TextField("ai.custom.endpoint".localized, text: $baseURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))

            Text("ai.models.customDiscovery".localized)
                .font(.caption).foregroundStyle(.secondary)

            Toggle("ai.custom.anthropic".localized, isOn: $isAnthropicFormat)

            if isAnthropicFormat {
                TextField("ai.custom.authHeaderName".localized, text: $authHeaderName)
                    .textFieldStyle(.roundedBorder)
                TextField("ai.custom.authPrefix".localized, text: $authHeaderPrefix)
                    .textFieldStyle(.roundedBorder)
                TextField("ai.custom.apiVersion".localized, text: $apiVersion)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField("ai.custom.authHeaderNameOpenAI".localized, text: $authHeaderName)
                    .textFieldStyle(.roundedBorder)
                TextField("ai.custom.authPrefixOpenAI".localized, text: $authHeaderPrefix)
                    .textFieldStyle(.roundedBorder)
            }

            TextField("ai.custom.pricing".localized, text: $pricingNote)
                .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("ai.custom.cancel".localized) {
                    onSaved(nil)
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))

                Spacer()

                Button("ai.custom.save".localized) {
                    save()
                }
                .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
                .disabled(name.isEmpty || baseURL.isEmpty)
            }
        }
        .padding(20)
        .adaptiveColorScheme()
        .appThemeSurface()
    }

    private func save() {
        guard !name.isEmpty, !baseURL.isEmpty else { return }

        var normalizedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if URL(string: normalizedURL)?.scheme == nil {
            normalizedURL = "https://" + normalizedURL
        }
        guard let parts = URLComponents(string: normalizedURL), parts.scheme?.lowercased() == "https",
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil else {
            errorMessage = "ai.custom.invalidURL".localized
            return
        }

        let config = CustomAIProviderConfig(
            id: provider?.id ?? UUID().uuidString,
            name: SecurityPolicies.sanitizeUserInput(name),
            baseURL: normalizedURL,
            models: [],
            responseFormat: isAnthropicFormat ? .anthropic : .openAI,
            authHeaderName: authHeaderName.isEmpty ? (isAnthropicFormat ? "x-api-key" : "Authorization") : authHeaderName,
            authHeaderPrefix: authHeaderPrefix,
            apiVersion: apiVersion.isEmpty ? nil : apiVersion,
            pricingNote: pricingNote.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        if let existing = provider, let idx = settings.customAIProviders.firstIndex(where: { $0.id == existing.id }) {
            settings.customAIProviders[idx] = config
        } else {
            settings.customAIProviders.append(config)
        }
        onSaved(config)
    }
}
