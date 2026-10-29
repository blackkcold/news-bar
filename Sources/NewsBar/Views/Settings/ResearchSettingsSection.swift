import SwiftUI

/// AI → 联网研究. Owns the research depth/budget/concurrency controls, the
/// search-provider switches, the encrypted search keys, and the shared ledger.
struct ResearchSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.searchProviderStatusAction) private var searchProviderStatusAction
    @Environment(\.searchAuthRetryAction) private var searchAuthRetryAction

    @State private var keyInputs: [SearchProviderID: String] = [:]
    @State private var configured: [SearchProviderID: Bool] = [:]
    @State private var keyMessage: String?
    @State private var keyMessageIsError = false
    @State private var isSavingKey = false
    @State private var statuses: [SearchProviderStatus] = []
    @State private var lastStatusRefresh = Date.distantPast

    var body: some View {
        Group {
            Section {
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
                        Text(
                            L10n.string(
                                "research.cap.concurrent",
                                language: settings.appLanguage,
                                value
                            )
                        )
                        .tag(value)
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
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 240), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(SearchProviderID.failoverOrder) { provider in
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

            Section {
                ResearchLedgerView()
            } header: {
                Text("research.ledger.title".localized)
            } footer: {
                Text("research.ledger.footer".localized)
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
            isSaving: isSavingKey,
            keyInput: keyBinding(provider),
            onToggle: { enabled in
                providerBinding(provider).wrappedValue = enabled
            },
            onSave: { Task { await saveKey(provider) } },
            onClear: { Task { await clearKey(provider) } },
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
                    .filter { next.contains($0) }
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
        let saved = await SearchKeyStore.save(key, for: provider)
        isSavingKey = false

        if saved {
            keyInputs[provider] = ""
            configured[provider] = true
            // A new key ends an auth block but deliberately keeps any quota
            // cooldown and never resets the ledger.
            await searchAuthRetryAction?(provider)
            await refreshStatuses()
            keyMessage = L10n.string(
                "research.settings.keySaveSuccess",
                language: settings.appLanguage,
                provider.displayName
            )
            keyMessageIsError = false
        } else {
            keyMessage = L10n.string(
                "research.settings.keySaveFailed",
                language: settings.appLanguage,
                provider.displayName
            )
            keyMessageIsError = true
        }
    }

    private func clearKey(_ provider: SearchProviderID) async {
        isSavingKey = true
        await SearchKeyStore.delete(for: provider)
        isSavingKey = false
        configured[provider] = false
        await searchAuthRetryAction?(provider)
        await refreshStatuses()
        keyMessage = L10n.string(
            "research.settings.keyCleared",
            language: settings.appLanguage,
            provider.displayName
        )
        keyMessageIsError = false
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
        case .notNeeded:
            break
        }
    }
}
