import SwiftUI

struct AITab: View {
    /// The AI group is three pages: how it connects, what it has spent, and
    /// what the reader and research features do with it. Page state lives on
    /// the tab, so a half-typed key survives a page switch.
    enum Page: String, CaseIterable, Identifiable {
        case connection
        case usage
        case research

        var id: String { rawValue }
        var titleKey: String { "settings.ai.page.\(rawValue)" }
    }

    @Environment(AppSettings.self) private var settings

    @State private var page: Page
    @State private var selectedProviderID: String
    @State private var apiKeyInput = ""
    @State private var keyInputContext: AICredentialInputContext?
    @State private var onePasswordRef = ""
    @State private var onePasswordReferenceEdited = false
    @State private var referenceInputContext: AICredentialInputContext?
    @State private var testResult: String?
    @State private var testSucceeded = false
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var isDeletingKey = false
    @State private var isDeletingCustomProvider = false
    @State private var isSavingOnePasswordReference = false
    @State private var keyDeletionRetryAccounts: Set<String> = []
    @State private var keySaveSyncAccounts: Set<String> = []
    @State private var pendingOnePasswordReferences: [String: AIKeyReferencePolicy.PendingUpdate] = [:]
    @State private var keyFeedback: AIKeyFeedback?
    @State private var onePasswordFeedback: AIKeyFeedback?
    @State private var keyStatus: AIKeyStatus = .missing
    @State private var pendingKeyDeletion = false
    /// The credential state the user is looking at. A save, import or delete
    /// is conditional on this snapshot, never on a state read after the intent.
    @State private var credentialStateSnapshot: EncryptedKeyStore.CustomProviderCredentialState?
    @State private var isBindingLegacyCredentials = false
    @State private var isLoadingFrom1Password = false
    @State private var showCustomEditor = false
    @State private var editingCustom: CustomAIProviderConfig?
    @State private var pendingCustomDeletion: CustomAIProviderConfig?
    @State private var costInput = ""
    @State private var showPricingSheet = false
    @FocusState private var costFieldFocused: Bool

    init(page: Page = .connection) {
        let saved = TestIsolation.defaults.string(forKey: "aiProvider") ?? AIProvider.deepseek.rawValue
        _selectedProviderID = State(initialValue: saved)
        _page = State(initialValue: page)
    }

    private func setSelectedProviderID(_ providerID: String) {
        if selectedProviderID != providerID { onePasswordReferenceEdited = false }
        onePasswordRef = AIKeyReferencePolicy.referenceAfterProviderChange(
            onePasswordRef, from: selectedProviderID, to: providerID
        )
        selectedProviderID = providerID
    }

    /// Red only when a finite cap is actually reached; unlimited never is.
    private var usageIsAtLimit: Bool {
        if settings.effectiveAILimitMode == .cost {
            return settings.aiCostCapMicros > 0
                && settings.todayAICostMicros >= settings.aiCostCapMicros
        }
        guard let cap = settings.aiCountLimit else { return false }
        return settings.todayAIRequestCount >= cap
    }

    private var usageValueText: String {
        settings.effectiveAILimitMode == .cost
            ? settings.aiCostUsageText
            : settings.aiUsageText
    }

    private var usageFraction: Double? {
        if settings.effectiveAILimitMode == .cost {
            guard settings.aiCostCapMicros > 0 else { return nil }
            return min(1, Double(settings.todayAICostMicros) / Double(settings.aiCostCapMicros))
        }
        guard let cap = settings.aiCountLimit, cap > 0 else { return nil }
        return min(1, Double(settings.todayAIRequestCount) / Double(cap))
    }

    private static let costPresets: [Double] = [5, 10, 20, 50]

    /// OpenCode reports a different kind of number for each plan. Say which
    /// one the ledger is showing instead of presenting an allowance as a bill.
    private var openCodeCostNote: String? {
        switch settings.aiProvider {
        case AIProvider.opencodeGo.rawValue: return "ai.cost.footer.opencodeGo".localized
        case AIProvider.opencodeZen.rawValue: return "ai.cost.footer.opencodeZen".localized
        default: return nil
        }
    }

    /// The documented price list that applies to the provider being edited.
    /// Only OpenCode publishes per-model prices; every other provider keeps its
    /// short prose note instead.
    private var openCodePricingPlan: OpenCodePricingPlan? {
        switch selectedProviderID {
        case AIProvider.opencodeGo.rawValue: return .go
        case AIProvider.opencodeZen.rawValue: return .zen
        default: return nil
        }
    }

    private static func costText(_ micros: Int64) -> String {
        String(format: "%.2f", Double(max(0, micros)) / 1_000_000)
    }

    private func commitCostInput() {
        let normalized = costInput.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value >= 0 else {
            costInput = Self.costText(settings.aiCostCapMicros)
            return
        }
        settings.aiCostCapMicros = Int64((value * 1_000_000).rounded())
        costInput = Self.costText(settings.aiCostCapMicros)
    }

    private func setCostCap(_ yuan: Double) {
        settings.aiCostCapMicros = Int64((yuan * 1_000_000).rounded())
        costInput = Self.costText(settings.aiCostCapMicros)
    }

    var body: some View {
        VStack(spacing: 0) {
            pagePicker

            Form {
                switch page {
                case .connection: connectionSections
                case .usage: usageSections
                case .research: researchSections
                }
            }
            .formStyle(.grouped)
            .disabled(isDeletingCustomProvider)
            .scrollContentBackground(.hidden)
            .onAppear {
                costInput = Self.costText(settings.aiCostCapMicros)
                settings.refreshAIUsageMirror()
            }
            .onChange(of: settings.aiCostCapMicros) { _, value in
                let text = Self.costText(value)
                if text != costInput { costInput = text }
            }
            .onChange(of: costFieldFocused) { _, focused in
                if !focused { commitCostInput() }
            }
            .onChange(of: settings.aiProvider) { _, _ in
                if settings.aiLimitMode == .cost, !settings.aiCostEstimateAvailable {
                    settings.aiLimitMode = .count
                }
            }
            .onChange(of: settings.aiKeyContext.inputContext) { _, _ in
                apiKeyInput = ""
                keyInputContext = nil
                onePasswordRef = ""
                onePasswordReferenceEdited = false
                referenceInputContext = nil
                testResult = nil
                onePasswordFeedback = nil
            }
            .onChange(of: settings.aiModel) { _, _ in
                if settings.aiLimitMode == .cost, !settings.aiCostEstimateAvailable {
                    settings.aiLimitMode = .count
                }
            }
            .task(id: settings.modelCatalogRevision) {
                setSelectedProviderID(settings.aiProvider)
                await settings.refreshModelCatalog()
            }
            .sheet(isPresented: $showCustomEditor) {
                CustomAIProviderEditor(provider: editingCustom) { saved in
                    let previous = editingCustom
                    editingCustom = nil
                    showCustomEditor = false
                    if let saved, !saved.id.isEmpty {
                        let customID = "custom:\(saved.id)"
                        let credentialsReset = previous.map {
                            AICustomProviderConnectionPolicy.requiresCredentialReset(from: $0, to: saved)
                        } ?? false
                        setSelectedProviderID(customID)
                        settings.aiProvider = customID
                        settings.cachedAPIKey = nil
                        apiKeyInput = ""
                        testResult = nil
                        if credentialsReset {
                            keyDeletionRetryAccounts.remove(customID)
                            keySaveSyncAccounts.remove(customID)
                            pendingOnePasswordReferences.removeValue(forKey: customID)
                            onePasswordRef = ""
                            onePasswordReferenceEdited = false
                            keyStatus = .missing
                        }
                        keyFeedback = credentialsReset ? .customProviderCredentialsReset : nil
                        onePasswordFeedback = nil
                    } else {
                        // A failed, unconfirmed reset may already have removed
                        // the old entries even though the configuration stayed.
                        Task {
                            await refreshKeyStatus()
                            await loadScopedOnePasswordRef()
                        }
                    }
                }
                .environment(settings)
                .frame(minWidth: 460, minHeight: 460)
            }
            .sheet(isPresented: $showPricingSheet) {
                OpenCodePricingView(
                    currentModel: settings.aiModel,
                    initialPlan: openCodePricingPlan ?? .go
                )
                .environment(settings)
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
            .task(id: settings.aiKeyContext) {
                await refreshKeyStatus()
                await loadScopedOnePasswordRef()
            }
        }
    }

    /// A sticky page switch above the form, so the page name stays visible
    /// while the form scrolls — the sidebar only says "AI". Chips rather than a
    /// segmented control: on the paper surface the native one loses its labels.
    private var pagePicker: some View {
        HStack(spacing: 0) {
            EditorialChips(
                values: Page.allCases,
                title: { L10n.string($0.titleKey) },
                groupLabel: "settings.ai.page".localized,
                selection: $page
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var legacyBindingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("ai.legacyBinding.title".localized, systemImage: "key.horizontal")
                    .font(.callout.weight(.semibold))
                Text("ai.legacyBinding.body".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    bindLegacyCustomCredentials()
                } label: {
                    Label("ai.legacyBinding.action".localized, systemImage: "link")
                }
                .disabled(isBindingLegacyCredentials || isSaving || isDeletingKey)
            }
            .padding(.vertical, 4)
        }
    }

    private func bindLegacyCustomCredentials() {
        guard let account = settings.usableAPIKeyAccount,
              let identity = settings.aiKeyContext.endpointIdentity else { return }
        isBindingLegacyCredentials = true
        let started = settings.aiCredentialUIContext
        Task {
            let result = await EncryptedKeyStore().bindLegacyCustomCredentialsResult(
                account: account, endpointIdentity: identity
            )
            await MainActor.run {
                isBindingLegacyCredentials = false
                guard settings.isCurrentAICredentialUIContext(started) else { return }
                switch result {
                case .durable:
                    settings.cachedAPIKey = nil
                    keyFeedback = .saved
                    Task {
                        await refreshKeyStatus()
                        await loadScopedOnePasswordRef()
                    }
                case .committedDurabilityUnknown:
                    keyFeedback = .saveDurabilityUnknown
                    Task { await refreshKeyStatus() }
                case .unverified:
                    keyFeedback = .saveUnverified
                case .notCommitted:
                    keyFeedback = .saveFailed
                }
            }
        }
    }

    @ViewBuilder
    private var connectionSections: some View {
        Section {
            Toggle("ai.enable".localized, isOn: Binding(
                get: { settings.aiSummaryEnabled },
                set: { settings.aiSummaryEnabled = $0 }
            ))
        } header: {
            Text("ai.feature".localized)
        }

        if settings.isUsingCustomProvider, keyStatus == .unbound,
           settings.aiKeyContext.endpointIdentity != nil {
            legacyBindingSection
        }

        Section {
            Picker("ai.provider".localized, selection: Binding(
                get: { selectedProviderID },
                set: { newProvider in
                    setSelectedProviderID(newProvider)
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
                .disabled(isSaving || isDeletingKey || isLoadingFrom1Password || isSavingOnePasswordReference)

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
                    .disabled(isSaving || isDeletingKey || isLoadingFrom1Password || isSavingOnePasswordReference)

                    Button {
                        pendingCustomDeletion = custom
                    } label: {
                        Text("ai.delete".localized)
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                    .controlSize(.small)
                    .disabled(isSaving || isDeletingKey || isLoadingFrom1Password || isSavingOnePasswordReference)
                }
            }
            if !settings.hasUsableProviderSelection {
                Text("ai.provider.unavailable".localized)
                    .font(.caption)
                    .foregroundStyle(.orange)
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

            SecureField(settings.providerApiKeyPlaceholder(forID: selectedProviderID), text: Binding(
                get: { apiKeyInput },
                set: {
                    apiKeyInput = $0
                    keyInputContext = settings.aiKeyContext.inputContext
                }
            ))
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
                .disabled(apiKeyInput.isEmpty || isSaving || isDeletingKey || isLoadingFrom1Password || isSavingOnePasswordReference)
                .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
                .controlSize(.small)

                Button {
                    testConnection()
                } label: {
                    Text(isTesting ? "ai.testing".localized : "ai.test".localized)
                }
                .disabled((apiKeyInput.isEmpty && (settings.usableCachedAPIKey?.isEmpty ?? true)) || isTesting)
                .buttonStyle(EditorialActionButtonStyle(compact: true))
                .controlSize(.small)

                Spacer()

                Button {
                    pendingKeyDeletion = true
                } label: {
                    Text("ai.deleteKey".localized)
                }
                .disabled((keyStatus == .missing && !keyDeletionRetryAccounts.contains(settings.activeAPIKeyAccount)) || isDeletingKey || isSaving || isLoadingFrom1Password || isSavingOnePasswordReference)
                .foregroundStyle(.red)
                .controlSize(.small)
            }

            if let feedback = keyFeedback {
                Text(feedback.text(language: settings.appLanguage))
                    .font(.caption)
                    .foregroundStyle(feedback.color)
                    .accessibilityLabel(feedback.text(language: settings.appLanguage))
            }

            if keySaveSyncAccounts.contains(settings.activeAPIKeyAccount), keyStatus != .unverified {
                Button(settings.appLanguage == .en ? "Retry key disk synchronization" : "重试密钥磁盘同步") {
                    retryKeySaveDurability()
                }
                .disabled(isSaving || isDeletingKey || isLoadingFrom1Password || isSavingOnePasswordReference)
                .buttonStyle(EditorialActionButtonStyle(compact: true))
                .controlSize(.small)
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
        .disabled(!settings.hasUsableProviderSelection)

        Section {
            VStack(alignment: .leading, spacing: 6) {
                TextField(settings.providerOnePasswordHint(forID: selectedProviderID), text: Binding(
                    get: { onePasswordRef },
                    set: {
                        onePasswordRef = $0
                        onePasswordReferenceEdited = true
                        referenceInputContext = settings.aiKeyContext.inputContext
                    }
                ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .disabled(isSaving || isDeletingKey || isLoadingFrom1Password || isSavingOnePasswordReference)
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
                    .disabled(onePasswordRef.isEmpty || isLoadingFrom1Password || isSaving || isDeletingKey || isSavingOnePasswordReference)
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
                    .controlSize(.small)
                }

                if let feedback = onePasswordFeedback {
                    Text(feedback.text(language: settings.appLanguage))
                        .font(.caption)
                        .foregroundStyle(feedback.color)
                }

                if onePasswordFeedback == .referenceReadFailed {
                    Button("ai.1p.retryReadReference".localized) {
                        Task { await loadScopedOnePasswordRef() }
                    }
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
                    .controlSize(.small)
                    .disabled(isSaving || isDeletingKey || isLoadingFrom1Password || isSavingOnePasswordReference)
                }

                if pendingOnePasswordReferences[settings.activeAPIKeyAccount] != nil {
                    Button("ai.1p.retryUpdateReference".localized) {
                        retryOnePasswordReference()
                    }
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
                    .controlSize(.small)
                    .disabled(isSaving || isDeletingKey || isLoadingFrom1Password || isSavingOnePasswordReference)
                }
            }
        } header: {
            Text("ai.1password".localized)
        } footer: {
            Text("ai.1password.footer".localized)
        }
        .disabled(!settings.hasUsableProviderSelection)

        Section {
            Picker("ai.model".localized, selection: Binding(
                get: { settings.aiModel },
                set: {
                    settings.aiModel = $0
                    settings.aiModelManuallyEntered = false
                }
            )) {
                if !settings.currentAIModels.contains(settings.aiModel) {
                    Text("ai.models.unselected".localized).tag(settings.aiModel)
                }
                ForEach(settings.providerModels(forID: selectedProviderID), id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .disabled((settings.currentAIModels.isEmpty && !settings.aiModelManuallyEntered) || settings.isLoadingModelCatalog)

            Toggle("ai.model.manual".localized, isOn: Binding(
                get: { settings.aiModelManuallyEntered },
                set: { settings.aiModelManuallyEntered = $0 }
            ))

            if settings.aiModelManuallyEntered {
                HStack(spacing: 6) {
                    TextField("ai.model.manualPlaceholder".localized, text: Binding(
                        get: { settings.aiModel },
                        set: { settings.aiModel = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .accessibilityLabel("ai.model.manual".localized)
                    Text(settings.isAIModelCatalogValidated ? "ai.model.verified".localized : "ai.model.unverified".localized)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(settings.isAIModelCatalogValidated ? .green : .orange)
                        .accessibilityLabel(settings.isAIModelCatalogValidated
                            ? "ai.model.verified".localized
                            : "ai.model.unverified".localized)
                }
            }

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
                if settings.currentAIModels.isEmpty && !settings.aiModelManuallyEntered {
                    Button {
                        settings.aiModelManuallyEntered = true
                    } label: {
                        Label("ai.models.manualFallback".localized, systemImage: "square.and.pencil")
                    }
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
                    .controlSize(.small)
                }
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
            Text(settings.aiModelManuallyEntered ? "ai.model.manual.footer".localized : "ai.model.footer".localized)
        }

        Section {
            // The legacy switch is only meaningful for a connection that
            // actually exposes a DeepSeek-style binary toggle. Other
            // providers get a capability note instead of a misleading knob.
            if settings.resolvedAIConnection.thinkingStyle == .deepseekToggle {
                Toggle("ai.disableThinking".localized, isOn: Binding(
                    get: { settings.aiDisableDeepSeekThinking },
                    set: { settings.aiDisableDeepSeekThinking = $0 }
                ))
            }
            if let note = settings.resolvedAIConnection.thinkingStyle.capabilityNote(settings.appLanguage) {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            if settings.resolvedAIConnection.thinkingStyle == .deepseekToggle {
                Text("ai.disableThinking.footer".localized)
            }
        }
    }

    @ViewBuilder
    private var usageSections: some View {
        Section {
            if let plan = openCodePricingPlan {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string(
                        "ai.pricing.summary",
                        L10n.string(plan.titleKey),
                        OpenCodePriceSheet.listedCount(for: plan)
                    ))
                    .font(.caption)

                    if let note = openCodeCostNote {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        showPricingSheet = true
                    } label: {
                        Label("ai.pricing.open".localized, systemImage: "tablecells")
                    }
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(settings.providerPricingInfo(forID: selectedProviderID), id: \.title) { item in
                        Text("\(item.title): \(item.detail)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
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
                    Text(usageValueText)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(usageIsAtLimit ? .red : .primary)
                }
                if let fraction = usageFraction {
                    ProgressView(value: fraction)
                        .tint(usageIsAtLimit ? .red : .blue)
                } else {
                    Text("ai.usage.unlimitedHint".localized)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if settings.effectiveAILimitMode == .cost {
                    if settings.todayAIInputTokens > 0 || settings.todayAIOutputTokens > 0 {
                        Text(L10n.string(
                            "ai.cost.tokens",
                            settings.todayAIInputTokens,
                            settings.todayAIOutputTokens
                        ))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                    Text("ai.cost.footer".localized)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if settings.todayAIUnpricedCalls > 0 {
                        Text(L10n.string("ai.cost.unpriced", settings.todayAIUnpricedCalls))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

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
            if settings.aiCostEstimateAvailable {
                Picker("ai.limitMode".localized, selection: Binding(
                    get: { settings.effectiveAILimitMode },
                    set: { settings.aiLimitMode = $0 }
                )) {
                    Text("ai.limitMode.count".localized).tag(AILimitMode.count)
                    Text("ai.limitMode.cost".localized).tag(AILimitMode.cost)
                }
                .pickerStyle(.segmented)
            }

            if settings.effectiveAILimitMode == .cost {
                HStack {
                    Text("ai.costCap".localized)
                    Spacer()
                    Text("¥")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    TextField("5.00", text: $costInput)
                        .frame(width: 72)
                        .multilineTextAlignment(.trailing)
                        .focused($costFieldFocused)
                        .onSubmit(commitCostInput)
                }
                HStack(spacing: 6) {
                    ForEach(Self.costPresets, id: \.self) { value in
                        Button("¥\(Int(value))") { setCostCap(value) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                if let perCall = settings.estimatedAICostPerCallMicros {
                    Text(L10n.string(
                        "ai.cost.perCall",
                        AICostFormat.yuan(perCall),
                        AICostFormat.yuan(perCall * 200),
                        AICostFormat.yuan(perCall * 500)
                    ))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            } else {
                HStack {
                    Text("ai.dailyCap".localized)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { settings.aiDailyCap },
                        set: { settings.aiDailyCap = $0 }
                    )) {
                        ForEach(Array(AppSettings.validAICaps).sorted(), id: \.self) { cap in
                            Text(cap < 0 ? "ai.cap.unlimited".localized : L10n.string("ai.capTimes", cap))
                                .tag(cap)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
                if !settings.aiCostEstimateAvailable {
                    Text("ai.cost.unavailable".localized)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let perCall = settings.estimatedAICostPerCallMicros {
                    Text(L10n.string(
                        "ai.cost.perCall",
                        AICostFormat.yuan(perCall),
                        AICostFormat.yuan(perCall * 200),
                        AICostFormat.yuan(perCall * 500)
                    ))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("ai.limit".localized)
        } footer: {
            Text("ai.limit.footer".localized)
        }
    }

    @ViewBuilder
    private var researchSections: some View {
        Section {
            Toggle("ai.search.enabled".localized, isOn: Binding(
                get: { settings.aiSearchEnabled },
                set: { settings.aiSearchEnabled = $0 }
            ))
            if settings.aiSearchEnabled {
                Toggle("ai.search.web".localized, isOn: Binding(
                    get: { settings.aiSearchUseWeb },
                    set: { settings.aiSearchUseWeb = $0 }
                ))
                Picker("ai.search.pages".localized, selection: Binding(
                    get: { settings.aiSearchPageCount },
                    set: { settings.aiSearchPageCount = $0 }
                )) {
                    ForEach(Array(AppSettings.validAISearchPageCounts).sorted(), id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                Picker("ai.search.model".localized, selection: Binding(
                    get: { settings.aiSearchModel },
                    set: { settings.aiSearchModel = $0 }
                )) {
                    Text(L10n.string(
                        "ai.search.inherit",
                        settings.effectiveAISearchModel.isEmpty ? "—" : settings.effectiveAISearchModel
                    )).tag("")
                    if !settings.aiSearchModel.isEmpty,
                       !settings.currentAIModels.contains(settings.aiSearchModel) {
                        Text(settings.aiSearchModel).tag(settings.aiSearchModel)
                    }
                    ForEach(settings.currentAIModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .disabled(settings.isLoadingModelCatalog)
                if settings.resolvedAIConnection.thinkingStyle != .none {
                    Picker("ai.search.thinking".localized, selection: Binding(
                        get: { settings.aiSearchThinking },
                        set: { settings.aiSearchThinking = $0 }
                    )) {
                        Text(AIThinkingLevel.off.title(settings.appLanguage)).tag(AIThinkingLevel.off)
                        Text(AIThinkingLevel.low.title(settings.appLanguage)).tag(AIThinkingLevel.low)
                        Text(AIThinkingLevel.medium.title(settings.appLanguage)).tag(AIThinkingLevel.medium)
                        Text(AIThinkingLevel.high.title(settings.appLanguage)).tag(AIThinkingLevel.high)
                    }
                }
            }
        } header: {
            Text("ai.search.section".localized)
        } footer: {
            Text("ai.search.footer".localized)
        }

        Section {
            Picker("settings.selectionWeb".localized, selection: Binding(
                get: { settings.selectionWebMode },
                set: { settings.selectionWebMode = $0 }
            )) {
                ForEach(SelectionWebMode.allCases) { mode in
                    Text(mode.title(settings.appLanguage)).tag(mode)
                }
            }
            Text(settings.selectionWebMode.detail(settings.appLanguage))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("settings.selectionWeb.section".localized)
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

    private func deleteCustomProvider(_ custom: CustomAIProviderConfig) {
        guard !isDeletingCustomProvider, !isSaving, !isDeletingKey,
              !isLoadingFrom1Password, !isSavingOnePasswordReference else { return }
        pendingCustomDeletion = nil
        isDeletingCustomProvider = true
        let account = "custom:\(custom.id)"
        let mutation = settings.beginAICredentialMutation(account: account)
        Task {
            let store = EncryptedKeyStore()
            let result: EncryptedKeyStore.MutationResult
            switch await store.customProviderCredentialStateResult(account: account) {
            case .legacy:
                result = await store.deleteCustomProviderCredentialsResult(account: account, expectedState: nil)
            case let .state(state):
                result = await store.deleteCustomProviderCredentialsResult(account: account, expectedState: state)
            case .failed:
                result = .unverified
            }
            let decision = AICustomProviderDeletionPolicy.decision(for: result)
            await MainActor.run {
                _ = settings.finishAICredentialMutation(account: account, token: mutation)
                isDeletingCustomProvider = false
                if decision.clearCachedKey, settings.activeAPIKeyAccount == account {
                    settings.cachedAPIKey = nil
                }
                guard decision.removeProvider else {
                    if settings.aiProvider == account {
                        if decision.clearCachedKey { keyStatus = .unverified }
                        keyFeedback = decision.feedback
                    }
                    return
                }
                if let current = settings.customAIProviders.first(where: { $0.id == custom.id }), current != custom {
                    if settings.aiProvider == account {
                        keyStatus = .unverified
                        keyFeedback = .customProviderDeleteUnverified
                    }
                    return
                }
                settings.customAIProviders.removeAll { $0.id == custom.id }
                keyDeletionRetryAccounts.remove(account)
                keySaveSyncAccounts.remove(account)
                pendingOnePasswordReferences.removeValue(forKey: account)
                if settings.aiProvider == account {
                    settings.aiProvider = AIProvider.deepseek.rawValue
                    setSelectedProviderID(AIProvider.deepseek.rawValue)
                    settings.aiModel = settings.providerDefaultModel(forID: selectedProviderID)
                    settings.cachedAPIKey = nil
                    keyFeedback = decision.feedback
                }
            }
        }
    }

    private func saveAPIKey() {
        guard let account = settings.usableAPIKeyAccount else { return }
        guard keyInputContext == settings.aiKeyContext.inputContext else {
            keyFeedback = .saveFailed
            return
        }
        guard !onePasswordReferenceEdited || referenceInputContext == settings.aiKeyContext.inputContext else {
            onePasswordFeedback = .referenceBindingRequired
            return
        }
        isSaving = true
        keyFeedback = nil
        let sanitized = SecurityPolicies.sanitizeUserInput(apiKeyInput)
        let providerID = settings.aiProvider
        let mutation = settings.beginAICredentialMutation(account: account)
        let revision = settings.modelCatalogRevision
        let endpointIdentity = settings.aiKeyContext.endpointIdentity
        let reference = AIKeyReferencePolicy.manualKeySaveReference(
            onePasswordRef, userEdited: onePasswordReferenceEdited
        )
        let capturedState = credentialStateSnapshot
        Task {
            let store = EncryptedKeyStore()
            let generation: String?
            let savedCustomState: EncryptedKeyStore.CustomProviderCredentialState?
            let result: EncryptedKeyStore.MutationResult
            let preparationFailed: Bool
            do {
                let saved = try await AICustomProviderCredentialAccess.save(
                    sanitized, account: account, store: store, capturedState: capturedState,
                    endpointIdentity: endpointIdentity
                )
                generation = saved.generation
                savedCustomState = saved.state
                result = saved.result
                preparationFailed = false
            } catch let error as AICustomProviderCredentialError {
                generation = nil
                savedCustomState = nil
                result = error.result == .notCommitted ? .notCommitted : .unverified
                preparationFailed = true
            } catch {
                generation = nil
                savedCustomState = nil
                result = .unverified
                preparationFailed = true
            }
            let decision = AIKeySavePolicy.decision(for: result)
            await MainActor.run {
                let sameConfiguration = providerID == settings.aiProvider
                    && account == settings.activeAPIKeyAccount
                    && revision == settings.modelCatalogRevision
                let mayActivate = settings.finishAICredentialMutation(account: account, token: mutation)
                if decision.retrySyncAllowed { keySaveSyncAccounts.insert(account) }
                else if result == .durable { keySaveSyncAccounts.remove(account) }
                guard account == settings.activeAPIKeyAccount, providerID == settings.aiProvider else {
                    isSaving = false
                    return
                }
                guard mayActivate, sameConfiguration else {
                    if result != .notCommitted {
                        settings.cachedAPIKey = nil
                        keyStatus = .unverified
                        keyFeedback = .saveUnverified
                    }
                    isSaving = false
                    return
                }
                if preparationFailed {
                    settings.cachedAPIKey = nil
                    keyStatus = .unverified
                }
                if decision.clearCachedKey { settings.cachedAPIKey = nil }
                if decision.activateKey {
                    guard settings.activateAPIKey(
                        sanitized, providerID: providerID, revision: settings.modelCatalogRevision
                    ) else {
                        settings.cachedAPIKey = nil
                        keyStatus = .unverified
                        keyFeedback = .saveUnverified
                        isSaving = false
                        return
                    }
                    keyDeletionRetryAccounts.remove(account)
                    TestIsolation.defaults.set(true, forKey: "hasAIKey-\(account)")
                    NotificationCenter.default.post(name: .apiKeyConfigured, object: nil)
                    if let reference {
                        isSavingOnePasswordReference = true
                        let referenceContext = settings.aiCredentialUIContext
                        Task {
                            await persistOnePasswordReference(
                                reference, for: account, customProviderGeneration: generation,
                                customProviderState: savedCustomState,
                                started: referenceContext
                            )
                        }
                    }
                }
                if decision.clearInput { apiKeyInput = "" }
                if let status = decision.status { keyStatus = status }
                keyFeedback = decision.feedback
                isSaving = false
            }
        }
    }

    private func retryKeySaveDurability() {
        guard let account = settings.usableAPIKeyAccount else { return }
        let started = settings.aiKeyContext
        isSaving = true
        Task {
            let store = EncryptedKeyStore()
            let synced = await store.confirmWriteDurability()
            let status: AIKeyStatus
            if !synced {
                status = .unverified
            } else if account.hasPrefix("custom:"), let identity = started.endpointIdentity {
                let result = await store.readBoundCustomKeyResult(account: account, endpointIdentity: identity)
                status = AIKeyStatus.resolve(bound: result, hasFlag: false)
            } else if account.hasPrefix("custom:") {
                status = .unverified
            } else {
                switch await store.readAPIKeyResult(account: account) {
                case .found: status = .saved
                case .missing: status = .missing
                case .failed: status = .unverified
                }
            }
            await MainActor.run {
                isSaving = false
                if synced { keySaveSyncAccounts.remove(account) }
                guard started == settings.aiKeyContext else { return }
                guard synced else {
                    keyFeedback = .saveDurabilityUnknown
                    return
                }
                keyStatus = status
                switch status {
                case .saved:
                    keyFeedback = .saved
                case .missing, .flagWithoutSecret, .unbound, .endpointMismatch:
                    keyFeedback = .saveFailed
                case .unverified:
                    keyFeedback = .saveUnverified
                }
            }
        }
    }

    /// Removes the encrypted copy on this Mac. The 1Password item and the
    /// provider-side key are deliberately left untouched.
    private func deleteAPIKey() {
        guard let account = settings.usableAPIKeyAccount else { return }
        isDeletingKey = true
        keyFeedback = nil
        let mutation = settings.beginAICredentialMutation(account: account)
        let capturedGeneration = credentialStateSnapshot?.generation
        let capturedState = credentialStateSnapshot
        Task {
            let store = EncryptedKeyStore()
            let result: EncryptedKeyStore.MutationResult
            let preparationFailed: Bool
            do {
                let generation = try await AICustomProviderCredentialAccess.generation(
                    account: account, store: store, allowRecovery: false
                )
                if account.hasPrefix("custom:"), generation != capturedGeneration {
                    result = .notCommitted
                    preparationFailed = true
                } else {
                    result = await store.deleteAPIKeyResult(account: account, customProviderGeneration: generation)
                    preparationFailed = false
                }
            } catch let error as AICustomProviderCredentialError {
                result = error.result == .notCommitted ? .notCommitted : .unverified
                preparationFailed = true
            } catch {
                result = .unverified
                preparationFailed = true
            }
            _ = capturedState
            let decision = AIKeyDeletionPolicy.decision(for: result)
            await MainActor.run {
                let mayPresent = settings.finishAICredentialMutation(account: account, token: mutation)
                isDeletingKey = false
                if decision.retryAllowed {
                    keyDeletionRetryAccounts.insert(account)
                } else {
                    keyDeletionRetryAccounts.remove(account)
                }
                guard account == settings.activeAPIKeyAccount else { return }
                guard mayPresent else {
                    if result != .notCommitted {
                        settings.cachedAPIKey = nil
                        keyStatus = .unverified
                        keyFeedback = .deleteUnverified
                    }
                    return
                }
                if preparationFailed {
                    settings.cachedAPIKey = nil
                    keyStatus = .unverified
                }
                if decision.clearCachedKey {
                    settings.cachedAPIKey = nil
                    NotificationCenter.default.post(name: .apiKeyConfigured, object: nil)
                }
                if let status = decision.status { keyStatus = status }
                keyFeedback = decision.feedback
            }
        }
    }

    @MainActor
    private func refreshKeyStatus() async {
        guard let account = settings.usableAPIKeyAccount else {
            keyStatus = .missing
            return
        }
        let started = settings.aiCredentialUIContext
        guard let status = await AIKeyAccess.readForPresentation(
            isCurrent: { settings.isCurrentAICredentialUIContext(started) },
            read: {
                let store = EncryptedKeyStore()
                let hasFlag = TestIsolation.defaults.bool(forKey: "hasAIKey-\(account)")
                if account.hasPrefix("custom:") {
                    guard let identity = started.keyContext.endpointIdentity else { return AIKeyStatus.unverified }
                    let result = await store.readBoundCustomKeyResult(account: account, endpointIdentity: identity)
                    return AIKeyStatus.resolve(bound: result, hasFlag: hasFlag)
                }
                let stored = await store.readAPIKey(account: account)
                return AIKeyStatus.resolve(stored: stored, hasFlag: hasFlag)
            }
        ) else { return }
        keyStatus = status
        if account.hasPrefix("custom:") {
            switch await EncryptedKeyStore().customProviderCredentialStateResult(account: account) {
            case let .state(state): credentialStateSnapshot = state
            case .legacy, .failed: credentialStateSnapshot = nil
            }
        } else {
            credentialStateSnapshot = nil
        }
    }

    @MainActor
    private func loadScopedOnePasswordRef() async {
        guard let account = settings.usableAPIKeyAccount else {
            onePasswordRef = ""
            onePasswordReferenceEdited = false
            return
        }
        let started = settings.aiCredentialUIContext
        let initialReference = onePasswordRef
        let initialEditState = onePasswordReferenceEdited
        guard !initialEditState else { return }
        guard let loaded = await AIKeyAccess.readForPresentation(
            isCurrent: { settings.isCurrentAICredentialUIContext(started) && !isSavingOnePasswordReference },
            read: {
                let store = EncryptedKeyStore()
                if account.hasPrefix("custom:") {
                    guard let identity = started.keyContext.endpointIdentity else {
                        return AIKeyReferencePolicy.boundReadDecision(for: .failed)
                    }
                    let result = await store.readBoundCustomReferenceResult(account: account, endpointIdentity: identity)
                    return AIKeyReferencePolicy.boundReadDecision(for: result)
                }
                return AIKeyReferencePolicy.readDecision(for: await store.readOnePasswordRefResult(account: account))
            }
        ) else { return }
        guard onePasswordRef == initialReference,
              onePasswordReferenceEdited == initialEditState else { return }
        let pending = AIKeyReferencePolicy.pendingForEndpoint(
            pendingOnePasswordReferences[account], endpointIdentity: started.keyContext.endpointIdentity
        )
        let decision: AIKeyReferencePolicy.ReadDecision
        if let pending {
            decision = AIKeyReferencePolicy.ReadDecision(
                reference: pending.reference,
                feedback: loaded.feedback == .referenceReadFailed ? .referenceReadFailed : pending.feedback
            )
        } else {
            decision = loaded
        }
        onePasswordRef = decision.reference
        // A pending value is shown for retry, not a fresh user edit: treating
        // it as edited would let an import skip binding checks and re-apply a
        // stale secret over another instance's newer reference.
        onePasswordReferenceEdited = false
        referenceInputContext = nil
        onePasswordFeedback = decision.feedback
    }

    @MainActor
    private func persistOnePasswordReference(
        _ reference: String, for account: String, customProviderGeneration: String?,
        customProviderState: EncryptedKeyStore.CustomProviderCredentialState?,
        operationRevision: String? = nil,
        started: AICredentialUIContext
    ) async {
        guard started.keyContext.account == account, settings.isCurrentAICredentialUIContext(started) else {
            isSavingOnePasswordReference = false
            return
        }
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let referenceRevision = operationRevision ?? UUID().uuidString
        let store = EncryptedKeyStore()
        let result: EncryptedKeyStore.MutationResult
        if account.hasPrefix("custom:") {
            if let identity = started.keyContext.endpointIdentity,
               let state = customProviderState,
               state.generation == customProviderGeneration {
                result = await store.applyBoundCustomReferenceResult(
                    trimmed, account: account, expectedState: state, endpointIdentity: identity,
                    operationRevision: referenceRevision
                )
            } else {
                result = .notCommitted
            }
        } else if trimmed.isEmpty {
            result = await store.deleteOnePasswordRefResult(
                account: account, customProviderGeneration: customProviderGeneration
            )
        } else {
            result = await store.saveOnePasswordRefResult(
                trimmed, account: account, customProviderGeneration: customProviderGeneration
            )
        }
        let decision = AIKeyReferencePolicy.mutationDecision(for: result, deleting: trimmed.isEmpty)
        // A successful reference write advances referenceRevision. Refresh the
        // snapshot the next save/delete compares against, otherwise the next
        // action fails once with a stale expected state.
        if account.hasPrefix("custom:"), result != .notCommitted,
           case let .state(freshState) = await store.customProviderCredentialStateResult(account: account) {
            credentialStateSnapshot = freshState
        }
        isSavingOnePasswordReference = false
        guard settings.isCurrentAICredentialUIContext(started) else { return }
        let previous = pendingOnePasswordReferences[account]
        if decision.retryAllowed, let feedback = decision.feedback {
            pendingOnePasswordReferences[account] = .init(
                reference: reference, feedback: feedback, customProviderGeneration: customProviderGeneration,
                endpointIdentity: started.keyContext.endpointIdentity, customProviderState: customProviderState,
                operationRevision: account.hasPrefix("custom:") ? referenceRevision : nil
            )
        } else {
            pendingOnePasswordReferences.removeValue(forKey: account)
        }
        guard onePasswordRef.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
        onePasswordReferenceEdited = decision.retryAllowed
        if let feedback = decision.feedback {
            onePasswordFeedback = feedback
        } else if onePasswordFeedback == previous?.feedback || onePasswordFeedback == .referenceReadFailed {
            onePasswordFeedback = nil
        }
    }

    private func retryOnePasswordReference() {
        guard !isSaving, !isDeletingKey, !isLoadingFrom1Password, !isSavingOnePasswordReference else { return }
        guard let account = settings.usableAPIKeyAccount else { return }
        guard let pending = AIKeyReferencePolicy.pendingForEndpoint(
            pendingOnePasswordReferences[account], endpointIdentity: settings.aiKeyContext.endpointIdentity
        ) else { return }
        guard !onePasswordReferenceEdited || referenceInputContext == settings.aiKeyContext.inputContext else {
            onePasswordFeedback = .referenceBindingRequired
            return
        }
        if account.hasPrefix("custom:"),
           onePasswordRef.trimmingCharacters(in: .whitespacesAndNewlines)
            != pending.reference.trimmingCharacters(in: .whitespacesAndNewlines) {
            onePasswordFeedback = .referenceChangedDuringRetry
            return
        }
        settings.noteAICredentialIntent()
        let started = settings.aiCredentialUIContext
        let reference = onePasswordRef
        isSavingOnePasswordReference = true
        Task {
            await persistOnePasswordReference(
                reference, for: account, customProviderGeneration: pending.customProviderGeneration,
                customProviderState: pending.customProviderState, operationRevision: pending.operationRevision,
                started: started
            )
        }
    }

    private func currentOnePasswordContext() -> AIOnePasswordCompletionPolicy.Context {
        .init(
            providerID: settings.aiProvider,
            account: settings.activeAPIKeyAccount,
            revision: settings.modelCatalogRevision
        )
    }

    private func finishOnePasswordFailure(
        _ feedback: AIKeyFeedback, started: AIOnePasswordCompletionPolicy.Context, mutation: UUID
    ) async {
        await MainActor.run {
            let current = currentOnePasswordContext()
            let mayPresent = settings.finishAICredentialMutation(account: started.account, token: mutation)
            isLoadingFrom1Password = false
            guard mayPresent, AIOnePasswordCompletionPolicy.mayPresent(
                started: started, current: current
            ) else { return }
            onePasswordFeedback = feedback
        }
    }

    private func loadFrom1Password() {
        guard !onePasswordRef.isEmpty, !isLoadingFrom1Password, !isSaving,
              !isDeletingKey, !isSavingOnePasswordReference else { return }
        guard let account = settings.usableAPIKeyAccount else { return }
        guard !onePasswordReferenceEdited || referenceInputContext == settings.aiKeyContext.inputContext else {
            onePasswordFeedback = .referenceBindingRequired
            return
        }
        guard OnePasswordService.isValidReference(onePasswordRef) else {
            onePasswordFeedback = .invalidReference
            return
        }

        isLoadingFrom1Password = true
        onePasswordFeedback = nil
        let mutation = settings.beginAICredentialMutation(account: account)
        let started = currentOnePasswordContext()
        let endpointIdentity = settings.aiKeyContext.endpointIdentity
        let reference = onePasswordRef
        let referenceWasEdited = onePasswordReferenceEdited

        Task {
            do {
                let outcome = try await AIOnePasswordKeyImport.run(
                    reference: reference, account: account, store: EncryptedKeyStore(),
                    endpointIdentity: endpointIdentity, referenceWasEdited: referenceWasEdited
                ) { reference in
                    try await OnePasswordService.readSecretAsync(reference: reference)
                }
                let decision = outcome.saveDecision
                let referenceContext = await MainActor.run { () -> AICredentialUIContext? in
                    let current = currentOnePasswordContext()
                    let mayActivate = settings.finishAICredentialMutation(account: account, token: mutation)
                    isLoadingFrom1Password = false
                    if decision.retrySyncAllowed { keySaveSyncAccounts.insert(account) }
                    else if outcome.result == .durable { keySaveSyncAccounts.remove(account) }
                    guard mayActivate, AIOnePasswordCompletionPolicy.mayPresent(started: started, current: current) else {
                        if account == current.account, started.providerID == current.providerID,
                           outcome.result != .notCommitted {
                            settings.cachedAPIKey = nil
                            keyStatus = .unverified
                            keyFeedback = .saveUnverified
                        }
                        return nil
                    }
                    if decision.clearCachedKey { settings.cachedAPIKey = nil }
                    if decision.activateKey {
                        guard settings.activateAPIKey(
                            outcome.key, providerID: started.providerID, revision: settings.modelCatalogRevision
                        ) else { return nil }
                        // The secret stays in the encrypted store; never echo it
                        // back into a field the user could re-save or screenshot.
                        keyDeletionRetryAccounts.remove(account)
                        NotificationCenter.default.post(name: .apiKeyConfigured, object: nil)
                    }
                    if let status = decision.status { keyStatus = status }
                    keyFeedback = decision.feedback
                    onePasswordFeedback = outcome.feedback
                    let persist = AIOnePasswordCompletionPolicy.mayPersistReference(
                        result: outcome.result, started: started, current: current
                    )
                    guard persist else { return nil }
                    isSavingOnePasswordReference = true
                    return settings.aiCredentialUIContext
                }
                if let referenceContext {
                    await persistOnePasswordReference(
                        reference, for: account, customProviderGeneration: outcome.customProviderGeneration,
                        customProviderState: outcome.customProviderState,
                        started: referenceContext
                    )
                }
            } catch let error as AICustomProviderCredentialError {
                if error.result != .notCommitted, account == settings.activeAPIKeyAccount {
                    settings.cachedAPIKey = nil
                    keyStatus = .unverified
                }
                let feedback: AIKeyFeedback = error.result == .notCommitted ? .saveFailed : .saveUnverified
                await finishOnePasswordFailure(feedback, started: started, mutation: mutation)
            } catch OnePasswordError.notInstalled {
                await finishOnePasswordFailure(.notInstalled, started: started, mutation: mutation)
            } catch OnePasswordError.timeout {
                await finishOnePasswordFailure(.timedOut, started: started, mutation: mutation)
            } catch OnePasswordError.readFailed {
                await finishOnePasswordFailure(.readFailed, started: started, mutation: mutation)
            } catch OnePasswordError.invalidReference {
                await finishOnePasswordFailure(.invalidReference, started: started, mutation: mutation)
            } catch {
                NSLog("[AITab] loadFrom1Password failed: %@", error.localizedDescription)
                await finishOnePasswordFailure(.unknown, started: started, mutation: mutation)
            }
        }
    }

    private func testConnection() {
        guard settings.usableAPIKeyAccount != nil else {
            testResult = "ai.provider.unavailable".localized
            return
        }
        guard apiKeyInput.isEmpty || keyInputContext == settings.aiKeyContext.inputContext else {
            testResult = "ai.provider.unavailable".localized
            return
        }
        isTesting = true
        testResult = nil
        testSucceeded = false
        let expected = settings.aiKeyContext
        let key = SecurityPolicies.sanitizeUserInput(apiKeyInput.isEmpty ? (settings.usableCachedAPIKey ?? "") : apiKeyInput)

        Task {
            defer { isTesting = false }
            do {
                guard !key.isEmpty else {
                    testResult = "ai.test.emptyKey".localized
                    return
                }
                let result = try await settings.checkModelConnection(apiKey: key, expected: expected)
                guard expected == settings.aiKeyContext else { return }
                if result.source == .live {
                    testSucceeded = true
                    testResult = "ai.models.connectionSuccess".localized
                } else {
                    testResult = "ai.models.connectionStale".localized
                }
            } catch is CancellationError {
                return
            } catch AISearchError.configurationChanged {
                guard expected == settings.aiKeyContext else { return }
                testResult = AISearchError.configurationChanged.message(settings.appLanguage)
            } catch {
                guard expected == settings.aiKeyContext else { return }
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
    @State private var thinkingStyle: AIThinkingStyle
    @State private var pricingNote: String
    @State private var inputPrice: String
    @State private var outputPrice: String
    @State private var cacheReadPrice: String
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var pendingConnectionChange: CustomAIProviderConfig?

    init(provider: CustomAIProviderConfig?, onSaved: @escaping (CustomAIProviderConfig?) -> Void) {
        self.provider = provider
        self.onSaved = onSaved
        _name = State(initialValue: provider?.name ?? "")
        _baseURL = State(initialValue: provider?.baseURL ?? "")
        _isAnthropicFormat = State(initialValue: provider?.responseFormat == .anthropic)
        _authHeaderName = State(initialValue: provider?.authHeaderName ?? "Authorization")
        _authHeaderPrefix = State(initialValue: provider?.authHeaderPrefix ?? "Bearer ")
        _apiVersion = State(initialValue: provider?.apiVersion ?? "")
        _thinkingStyle = State(initialValue: provider?.thinkingStyle ?? .none)
        _pricingNote = State(initialValue: provider?.pricingNote ?? "")
        _inputPrice = State(initialValue: Self.priceText(provider?.inputPricePerMTok))
        _outputPrice = State(initialValue: Self.priceText(provider?.outputPricePerMTok))
        _cacheReadPrice = State(initialValue: Self.priceText(provider?.cacheReadPricePerMTok))
    }

    private static func priceText(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%g", value)
    }

    private static func priceValue(_ text: String) -> Double? {
        let normalized = text
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, let value = Double(normalized), value >= 0 else { return nil }
        return value
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

            VStack(alignment: .leading, spacing: 4) {
                Picker("ai.custom.thinking".localized, selection: $thinkingStyle) {
                    ForEach(AIThinkingStyle.allCases) { style in
                        Text(style.title(settings.appLanguage)).tag(style)
                    }
                }
                Text("ai.custom.thinking.footer".localized)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("ai.custom.pricing".localized, text: $pricingNote)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                Text("ai.custom.unitPrices".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("ai.custom.inputPrice".localized, text: $inputPrice)
                        .textFieldStyle(.roundedBorder)
                    TextField("ai.custom.outputPrice".localized, text: $outputPrice)
                        .textFieldStyle(.roundedBorder)
                    TextField("ai.custom.cachePrice".localized, text: $cacheReadPrice)
                        .textFieldStyle(.roundedBorder)
                }
                Text("ai.custom.unitPrices.footer".localized)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

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
                .disabled(isSaving)

                Spacer()

                Button("ai.custom.save".localized) {
                    save()
                }
                .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
                .disabled(name.isEmpty || baseURL.isEmpty || isSaving)
            }
        }
        .padding(20)
        .adaptiveColorScheme()
        .appThemeSurface()
        .interactiveDismissDisabled(isSaving)
        .confirmationDialog(
            "ai.custom.credentialsResetTitle".localized,
            isPresented: Binding(
                get: { pendingConnectionChange != nil },
                set: { if !$0 { pendingConnectionChange = nil } }
            ),
            presenting: pendingConnectionChange
        ) { proposed in
            Button("ai.custom.credentialsResetConfirm".localized, role: .destructive) {
                pendingConnectionChange = nil
                applyConnectionChange(proposed)
            }
            Button("ai.cancel".localized, role: .cancel) { pendingConnectionChange = nil }
        } message: { _ in
            Text("ai.custom.credentialsResetMessage".localized)
        }
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
            thinkingStyle: thinkingStyle,
            pricingNote: pricingNote.trimmingCharacters(in: .whitespacesAndNewlines),
            inputPricePerMTok: Self.priceValue(inputPrice),
            outputPricePerMTok: Self.priceValue(outputPrice),
            cacheReadPricePerMTok: Self.priceValue(cacheReadPrice)
        )

        if let existing = provider {
            guard settings.customAIProviders.first(where: { $0.id == existing.id }) == existing else {
                errorMessage = "ai.custom.configChanged".localized
                return
            }
            if AICustomProviderConnectionPolicy.requiresCredentialReset(from: existing, to: config) {
                pendingConnectionChange = config
                return
            }
        }
        commit(config)
    }

    private func commit(_ config: CustomAIProviderConfig) {
        if let existing = provider {
            guard let idx = settings.customAIProviders.firstIndex(where: { $0.id == existing.id }),
                  settings.customAIProviders[idx] == existing else {
                errorMessage = "ai.custom.configChanged".localized
                return
            }
            settings.customAIProviders[idx] = config
        } else {
            guard !settings.customAIProviders.contains(where: { $0.id == config.id }) else {
                errorMessage = "ai.custom.configChanged".localized
                return
            }
            settings.customAIProviders.append(config)
        }
        onSaved(config)
    }

    private func applyConnectionChange(_ config: CustomAIProviderConfig) {
        guard !isSaving, let existing = provider,
              settings.customAIProviders.first(where: { $0.id == existing.id }) == existing else {
            errorMessage = "ai.custom.configChanged".localized
            return
        }
        isSaving = true
        errorMessage = nil
        let account = "custom:\(existing.id)"
        let mutation = settings.beginAICredentialMutation(account: account)
        if settings.activeAPIKeyAccount == account { settings.cachedAPIKey = nil }
        Task {
            let store = EncryptedKeyStore()
            let result: EncryptedKeyStore.MutationResult
            switch await store.customProviderCredentialStateResult(account: account) {
            case .legacy:
                result = await store.resetCustomProviderCredentialsForConnectionChange(
                    account: account, expectedState: nil
                )
            case let .state(state):
                result = await store.resetCustomProviderCredentialsForConnectionChange(
                    account: account, expectedState: state
                )
            case .failed:
                result = .unverified
            }
            await MainActor.run {
                defer {
                    _ = settings.finishAICredentialMutation(account: account, token: mutation)
                    isSaving = false
                }
                guard result == .durable else {
                    errorMessage = "ai.custom.credentialsResetFailed".localized
                    return
                }
                commit(config)
            }
        }
    }
}
