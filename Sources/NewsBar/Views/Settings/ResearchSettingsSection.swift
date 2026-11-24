import SwiftUI

/// AI → 联网研究. Owns the research depth/budget/concurrency controls, the
/// search-provider switches, the encrypted search keys, and the shared ledger.
struct ResearchSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.searchProviderStatusAction) private var searchProviderStatusAction
    @Environment(\.searchAuthRetryAction) private var searchAuthRetryAction

    @State private var keyInputs: [SearchProviderID: String] = [:]
    @State private var configured: [SearchProviderID: Bool] = [:]
    @State private var unverifiedKeyStatuses: Set<SearchProviderID> = []
    @State private var pendingKeyDeleteRetries: Set<SearchProviderID> = []
    @State private var pendingKeySaveSyncs: Set<SearchProviderID> = []
    @State private var keyMessage: String?
    @State private var keyMessageIsError = false
    @State private var isSavingKey = false
    @State private var statuses: [SearchProviderStatus] = []
    @State private var lastStatusRefresh = Date.distantPast

    private var parallelMCPEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.researchParallelMCPEnabled },
            set: { settings.researchParallelMCPEnabled = $0 }
        )
    }

    private func concurrencyCapLabel(_ value: Int) -> String {
        L10n.string(
            "research.cap.concurrent",
            language: settings.appLanguage,
            value
        )
    }

    var body: some View {
        Group {
            Section {
                Toggle(
                    settings.appLanguage == .en
                        ? "Show research with articles"
                        : "阅读时显示研究提示与报告",
                    isOn: Binding(
                        get: { settings.researchReadingEnabled },
                        set: { settings.researchReadingEnabled = $0 }
                    )
                )
                .help(settings.appLanguage == .en
                      ? "Show trusted research matches in article reading and local search."
                      : "在文章阅读和本地搜索中显示可信关联的研究。")

                Picker(
                    settings.appLanguage == .en
                        ? "Automatic search requests per day"
                        : "自动搜索请求上限／日",
                    selection: Binding(
                        get: { settings.researchAutoSearchDailyLimit },
                        set: { settings.researchAutoSearchDailyLimit = $0 }
                    )
                ) {
                    ForEach([8, 20, 40], id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                Text(settings.appLanguage == .en
                     ? "Request count only, not a spending cap. Automatic search uses keyless routes; keyed providers remain manual."
                     : "这是请求次数，不是金额上限。自动搜索只走免 Key 通道；需 Key 的服务仅供手动研究。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("research.settings.depth".localized, selection: Binding(
                    get: { settings.researchDepth },
                    set: { settings.researchDepth = $0 }
                )) {
                    ForEach(ResearchDepth.allCases, id: \.self) { depth in
                        Text(
                            L10n.string(
                                "research.depth.\(depth.rawValue)",
                                language: settings.appLanguage
                            )
                        )
                        .tag(depth)
                    }
                }

                Picker("research.settings.recency".localized, selection: Binding(
                    get: { settings.researchDefaultRecency },
                    set: { settings.researchDefaultRecency = $0 }
                )) {
                    ForEach(ResearchDefaultRecency.allCases, id: \.self) { recency in
                        Text(
                            L10n.string(
                                "research.recency.\(recency.rawValue)",
                                language: settings.appLanguage
                            )
                        )
                        .tag(recency)
                    }
                }

                Text("research.settings.aiShared".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("research.settings.taskCap".localized, selection: Binding(
                    get: { settings.researchDailyTaskCap },
                    set: { settings.researchDailyTaskCap = $0 }
                )) {
                    ForEach(Array(AppSettings.validResearchDailyTaskCaps).sorted(), id: \.self) { cap in
                        Text(L10n.string("research.cap.tasks", language: settings.appLanguage, cap)).tag(cap)
                    }
                }

                Picker("research.settings.concurrency".localized, selection: Binding(
                    get: { settings.researchMaxConcurrent },
                    set: { settings.researchMaxConcurrent = $0 }
                )) {
                    ForEach(Array(AppSettings.validResearchConcurrency).sorted(), id: \.self) { value in
                        Text(concurrencyCapLabel(value)).tag(value)
                    }
                }
            } header: {
                Text("research.settings.title".localized)
            } footer: {
                Text("research.settings.footer".localized)
            }
            .onChange(of: settings.researchMaxConcurrent) { _, value in
                ResearchCoordinator.shared.setMaxConcurrent(value)
            }

            Section {
                Toggle(
                    settings.appLanguage == .en
                        ? "Allow Parallel MCP fallback"
                        : "允许 Parallel MCP 免 Key 备援",
                    isOn: parallelMCPEnabledBinding
                )
                .help(settings.appLanguage == .en
                      ? "Sends the current public research question to Parallel only when enabled providers return no usable results. Uses read-only web_search and web_fetch."
                      : "仅在启用的搜索服务没有可用结果时，将当前公开研究问题发送给 Parallel；只调用只读搜索与取页。")

                Text(settings.appLanguage == .en
                     ? "Off by default. Search results must be exhausted first; every MCP search or fetch uses its own local request allowance."
                     : "默认关闭。先用完已启用来源；每次 MCP 搜索或取页分别占用本地请求额度。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 240), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(SearchProviderID.failoverOrder.filter { !$0.isStandaloneOptIn }) { provider in
                        providerCard(provider)
                    }
                }
                if let keyMessage {
                    Text(keyMessage)
                        .font(.caption)
                        .foregroundStyle(keyMessageIsError ? .red : .green)
                }
            } header: {
                Text("research.settings.providers".localized)
            } footer: {
                Text("research.settings.providers.footer".localized)
            }
        }
        .task {
            await migrateLegacyKeyIfNeeded()
            await refreshKeyStatus()
            await refreshStatuses()
        }
        .onChange(of: settings.researchSearchProviders) { _, _ in
            Task { await refreshStatuses() }
        }
        .onChange(of: settings.researchParallelMCPEnabled) { _, _ in
            Task { await refreshStatuses() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .researchRecordsChanged)) { _ in
            let now = Date()
            guard now.timeIntervalSince(lastStatusRefresh) > 2 else { return }
            lastStatusRefresh = now
            Task { await refreshStatuses() }
        }
    }

    private func providerCard(_ provider: SearchProviderID) -> some View {
        SearchProviderCard(
            provider: provider,
            language: settings.appLanguage,
            status: statuses.first { $0.provider == provider },
            isEnabled: settings.enabledSearchProviders.contains(provider),
            isConfigured: configured[provider] == true,
            isKeyUnverified: unverifiedKeyStatuses.contains(provider),
            canRetryKeyRemoval: pendingKeyDeleteRetries.contains(provider),
            canRetryKeySync: pendingKeySaveSyncs.contains(provider),
            isSaving: isSavingKey,
            keyInput: keyBinding(provider),
            onToggle: { enabled in
                providerBinding(provider).wrappedValue = enabled
            },
            onSave: { Task { await saveKey(provider) } },
            onClear: { Task { await clearKey(provider) } },
            onRetryKeySync: { Task { await retryKeySync(provider) } },
            onRetryAuth: {
                Task {
                    await searchAuthRetryAction?(provider)
                    await refreshStatuses()
                }
            }
        )
    }

    private func keyBinding(_ provider: SearchProviderID) -> Binding<String> {
        Binding(
            get: { keyInputs[provider] ?? "" },
            set: { keyInputs[provider] = $0 }
        )
    }

    private func providerBinding(_ provider: SearchProviderID) -> Binding<Bool> {
        Binding(
            get: { settings.enabledSearchProviders.contains(provider) },
            set: { enabled in
                var next = settings.enabledSearchProviders
                if enabled {
                    next.insert(provider)
                } else {
                    next.remove(provider)
                }
                // An empty set is a valid AI-only configuration.
                settings.researchSearchProviders = SearchProviderID.failoverOrder
                    .filter { next.contains($0) && !$0.isStandaloneOptIn }
                    .map(\.rawValue)
            }
        )
    }

    private func refreshStatuses() async {
        guard let action = searchProviderStatusAction else {
            return
        }
        statuses = await action(settings)
        lastStatusRefresh = Date()
    }

    private func saveKey(_ provider: SearchProviderID) async {
        let raw = keyInputs[provider] ?? ""
        let key = SecurityPolicies.sanitizeUserInput(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        isSavingKey = true
        let result = await SearchKeyStore.saveResult(key, for: provider)
        isSavingKey = false
        let decision = SearchKeySavePolicy.decision(for: result)
        if decision.clearInput { keyInputs[provider] = "" }
        if let value = decision.configured { configured[provider] = value }
        if let unverified = decision.unverified {
            if unverified { unverifiedKeyStatuses.insert(provider) }
            else { unverifiedKeyStatuses.remove(provider) }
        }
        if decision.retrySyncAllowed { pendingKeySaveSyncs.insert(provider) }
        else if result == .durable { pendingKeySaveSyncs.remove(provider) }
        if decision.configured == true {
            pendingKeyDeleteRetries.remove(provider)
            // A new key ends an auth block but deliberately keeps any quota
            // cooldown and never resets the ledger.
            await searchAuthRetryAction?(provider)
            await refreshStatuses()
        }
        keyMessage = L10n.string(decision.messageKey, language: settings.appLanguage, provider.displayName)
        keyMessageIsError = decision.isError
    }

    private func clearKey(_ provider: SearchProviderID) async {
        isSavingKey = true
        let result = await SearchKeyStore.deleteResult(for: provider)
        isSavingKey = false
        let decision = SearchKeyDeletionPolicy.decision(for: result)
        if let value = decision.configured { configured[provider] = value }
        if let unverified = decision.unverified {
            if unverified { unverifiedKeyStatuses.insert(provider) }
            else { unverifiedKeyStatuses.remove(provider) }
        }
        if decision.retryAllowed { pendingKeyDeleteRetries.insert(provider) }
        else { pendingKeyDeleteRetries.remove(provider) }
        if decision.configured == false {
            pendingKeySaveSyncs.remove(provider)
            await searchAuthRetryAction?(provider)
            await refreshStatuses()
        }
        keyMessage = L10n.string(
            decision.messageKey,
            language: settings.appLanguage,
            provider.displayName
        )
        keyMessageIsError = decision.isError
    }

    private func retryKeySync(_ provider: SearchProviderID) async {
        isSavingKey = true
        let store = EncryptedKeyStore()
        let synced = await store.confirmWriteDurability()
        let actual = synced ? await store.readAPIKeyResult(account: SearchKeyStore.account(for: provider)) : .failed
        isSavingKey = false
        guard synced else {
            keyMessage = L10n.string("research.settings.keySaveDurabilityUnknown", language: settings.appLanguage, provider.displayName)
            keyMessageIsError = true
            return
        }
        pendingKeySaveSyncs.remove(provider)
        switch actual {
        case .found:
            configured[provider] = true
            unverifiedKeyStatuses.remove(provider)
            await searchAuthRetryAction?(provider)
            await refreshStatuses()
            keyMessage = L10n.string("research.settings.keySaveSuccess", language: settings.appLanguage, provider.displayName)
            keyMessageIsError = false
        case .missing:
            configured[provider] = false
            unverifiedKeyStatuses.remove(provider)
            keyMessage = L10n.string("research.settings.keySaveFailed", language: settings.appLanguage, provider.displayName)
            keyMessageIsError = true
        case .failed:
            unverifiedKeyStatuses.insert(provider)
            keyMessage = L10n.string("research.settings.keySaveUnverified", language: settings.appLanguage, provider.displayName)
            keyMessageIsError = true
        }
    }

    private func refreshKeyStatus() async {
        var next: [SearchProviderID: Bool] = [:]
        for provider in SearchProviderID.allCases {
            next[provider] = await SearchKeyStore.hasKey(for: provider)
        }
        configured = next
    }

    private func migrateLegacyKeyIfNeeded() async {
        let result = await SearchKeyStore.migrateLegacyFirecrawlKey(settings: settings)
        switch result {
        case .migrated:
            await searchAuthRetryAction?(.firecrawl)
            keyMessage = "research.settings.keyMigrated".localized
            keyMessageIsError = false
        case .failed:
            keyMessage = "research.settings.keyMigrationFailed".localized
            keyMessageIsError = true
        case .durabilityUnknown:
            keyMessage = "research.settings.keyMigrationDurabilityUnknown".localized
            keyMessageIsError = true
        case .unverified:
            keyMessage = "research.settings.keyMigrationUnverified".localized
            keyMessageIsError = true
        case .notNeeded:
            break
        }
    }
}
