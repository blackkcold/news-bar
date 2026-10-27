import SwiftUI

/// AI → 联网研究. Owns the research depth/budget/concurrency controls, the
/// search-provider switches, the encrypted search keys, and the shared ledger.
struct ResearchSettingsSection: View {
    @Environment(AppSettings.self) private var settings

    @State private var keyInputs: [SearchProviderID: String] = [:]
    @State private var configured: [SearchProviderID: Bool] = [:]
    @State private var keyMessage: String?
    @State private var keyMessageIsError = false
    @State private var isSavingKey = false

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

                Picker("research.settings.aiCap".localized, selection: Binding(
                    get: { settings.researchDailyAICap },
                    set: { settings.researchDailyAICap = $0 }
                )) {
                    ForEach(Array(AppSettings.validResearchDailyAICaps).sorted(), id: \.self) { cap in
                        Text(L10n.string("research.cap.times", language: settings.appLanguage, cap)).tag(cap)
                    }
                }

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
                ForEach(SearchProviderID.failoverOrder) { provider in
                    Toggle(isOn: providerBinding(provider)) {
                        HStack(spacing: 6) {
                            Text(provider.displayName)
                            if !provider.requiresAPIKey {
                                Text("research.settings.keyless".localized)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("research.settings.providers".localized)
            } footer: {
                Text("research.settings.providers.footer".localized)
            }

            Section {
                ForEach(SearchProviderID.failoverOrder) { provider in
                    providerKeyRow(provider)
                }
                if let keyMessage {
                    Text(keyMessage)
                        .font(.caption)
                        .foregroundStyle(keyMessageIsError ? .red : .green)
                }
            } header: {
                Text("research.settings.keys".localized)
            } footer: {
                Text("research.settings.keys.footer".localized)
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
        }
    }

    private func providerKeyRow(_ provider: SearchProviderID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(provider.displayName)
                    .font(.system(size: 12, weight: .medium))
                if !provider.requiresAPIKey {
                    Text("research.settings.keyOptional".localized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if configured[provider] == true {
                    Label("research.settings.keySaved".localized, systemImage: "checkmark.seal.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else {
                    Text("research.settings.keyMissing".localized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                SecureField(
                    L10n.string(
                        "research.settings.keyPlaceholder",
                        language: settings.appLanguage,
                        provider.displayName
                    ),
                    text: keyBinding(provider)
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))

                Button {
                    Task { await saveKey(provider) }
                } label: {
                    Text("research.settings.keySave".localized)
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))
                .controlSize(.small)
                .disabled(isSavingKey || (keyInputs[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if configured[provider] == true {
                    Button {
                        Task { await clearKey(provider) }
                    } label: {
                        Text("research.settings.keyClear".localized)
                    }
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
                    .controlSize(.small)
                    .foregroundStyle(.red)
                    .disabled(isSavingKey)
                }
            }
        }
        .padding(.vertical, 2)
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
