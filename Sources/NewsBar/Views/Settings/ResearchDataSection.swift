import SwiftUI

/// 关于 → 研究数据. History and temp-cache limits are enforced immediately; a
/// lower limit asks for confirmation with the exact deletion count first.
struct ResearchDataSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.cacheClearAction) private var cacheClearAction

    @State private var recordsBytes: Int64 = 0
    @State private var cacheBytes: Int64 = 0
    @State private var pendingLimit: PendingLimit?
    @State private var showsClearHistory = false
    @State private var showsClearCache = false
    @State private var showsClearAll = false
    @State private var message: String?

    private enum PendingLimit: Identifiable {
        case history(limit: Int, removals: Int)
        case retention(days: Int, removals: Int)
        case cache(megabytes: Int, files: Int)

        var id: String {
            switch self {
            case .history: return "history"
            case .retention: return "retention"
            case .cache: return "cache"
            }
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        Group {
            Section {
                storageRow("research.data.records", bytes: recordsBytes)
                storageRow("research.data.cache", bytes: cacheBytes)
            } header: {
                Text("research.data.storage".localized)
            }

            Section {
                Picker("research.data.historyLimit".localized, selection: historyLimitBinding) {
                    ForEach(Array(AppSettings.validResearchHistoryLimits).sorted(), id: \.self) { value in
                        Text(L10n.string("research.data.items", language: settings.appLanguage, value))
                            .tag(value)
                    }
                }
                Picker("research.data.retention".localized, selection: retentionBinding) {
                    ForEach(Array(AppSettings.validResearchRetentionDays).sorted(), id: \.self) { value in
                        Text(
                            value == 0
                                ? L10n.string("research.data.retentionForever", language: settings.appLanguage)
                                : L10n.string("research.data.days", language: settings.appLanguage, value)
                        )
                        .tag(value)
                    }
                }
            } header: {
                Text("research.data.history".localized)
            } footer: {
                Text("research.data.history.footer".localized)
            }

            Section {
                Picker("research.data.cacheSize".localized, selection: cacheSizeBinding) {
                    ForEach(Array(AppSettings.validResearchTempCacheMB).sorted(), id: \.self) { value in
                        Text(L10n.string("research.data.megabytes", language: settings.appLanguage, value))
                            .tag(value)
                    }
                }
                Picker("research.data.cacheTTL".localized, selection: cacheTTLBinding) {
                    ForEach(Array(AppSettings.validResearchTempCacheTTL).sorted(), id: \.self) { value in
                        Text(L10n.string("research.data.hours", language: settings.appLanguage, value))
                            .tag(value)
                    }
                }
            } header: {
                Text("research.data.cache".localized)
            } footer: {
                Text("research.data.cache.footer".localized)
            }

            Section {
                Button("research.data.clearHistory".localized, role: .destructive) {
                    showsClearHistory = true
                }
                Button("research.data.clearCache".localized, role: .destructive) {
                    showsClearCache = true
                }
                Button("research.data.clearAll".localized, role: .destructive) {
                    showsClearAll = true
                }
            } header: {
                Text("research.data.actions".localized)
            } footer: {
                Text("research.data.actions.footer".localized)
            }

            if let message {
                Section {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await refreshStorage() }
        .onReceive(NotificationCenter.default.publisher(for: .researchRecordsChanged)) { _ in
            Task { await refreshStorage() }
        }
        .confirmationDialog(
            "research.data.clearHistory.title".localized,
            isPresented: $showsClearHistory,
            titleVisibility: .visible
        ) {
            Button("research.data.clear".localized, role: .destructive) {
                clearHistory()
            }
            Button("research.data.cancel".localized, role: .cancel) {}
        } message: {
            Text("research.data.clearHistory.message".localized)
        }
        .confirmationDialog(
            "research.data.clearCache.title".localized,
            isPresented: $showsClearCache,
            titleVisibility: .visible
        ) {
            Button("research.data.clear".localized, role: .destructive) {
                clearCache()
            }
            Button("research.data.cancel".localized, role: .cancel) {}
        } message: {
            Text("research.data.clearCache.message".localized)
        }
        .confirmationDialog(
            "research.data.clearAll.title".localized,
            isPresented: $showsClearAll,
            titleVisibility: .visible
        ) {
            Button("research.data.clear".localized, role: .destructive) {
                clearAllCaches()
            }
            Button("research.data.cancel".localized, role: .cancel) {}
        } message: {
            Text("research.data.clearAll.message".localized)
        }
        .alert(item: $pendingLimit) { pending in
            Alert(
                title: Text("research.data.confirm.title".localized),
                message: Text(confirmationMessage(pending)),
                primaryButton: .destructive(Text("research.data.confirm.apply".localized)) {
                    apply(pending)
                },
                secondaryButton: .cancel(Text("research.data.cancel".localized))
            )
        }
    }

    // MARK: - Bindings

    private var historyLimitBinding: Binding<Int> {
        Binding(
            get: { settings.researchHistoryLimit },
            set: { newValue in
                guard newValue < settings.researchHistoryLimit else {
                    applyImmediately { settings.researchHistoryLimit = newValue }
                    return
                }
                Task { @MainActor in
                    let removals = await ResearchMaintenance.shared.previewHistoryRemoval(
                        settings: settings,
                        historyLimit: newValue,
                        retentionDays: settings.researchRetentionDays
                    )
                    if removals > 0 {
                        pendingLimit = .history(limit: newValue, removals: removals)
                    } else {
                        applyImmediately { settings.researchHistoryLimit = newValue }
                    }
                }
            }
        )
    }

    private var retentionBinding: Binding<Int> {
        Binding(
            get: { settings.researchRetentionDays },
            set: { newValue in
                guard newValue > 0,
                      settings.researchRetentionDays == 0 || newValue < settings.researchRetentionDays else {
                    applyImmediately { settings.researchRetentionDays = newValue }
                    return
                }
                Task { @MainActor in
                    let removals = await ResearchMaintenance.shared.previewHistoryRemoval(
                        settings: settings,
                        historyLimit: settings.researchHistoryLimit,
                        retentionDays: newValue
                    )
                    if removals > 0 {
                        pendingLimit = .retention(days: newValue, removals: removals)
                    } else {
                        applyImmediately { settings.researchRetentionDays = newValue }
                    }
                }
            }
        )
    }

    private var cacheSizeBinding: Binding<Int> {
        Binding(
            get: { settings.researchTempCacheMB },
            set: { newValue in
                guard newValue < settings.researchTempCacheMB else {
                    applyImmediately { settings.researchTempCacheMB = newValue }
                    return
                }
                Task { @MainActor in
                    let stats = await ResearchMaintenance.shared.previewCacheRemoval(
                        maxBytes: Int64(newValue) * 1024 * 1024
                    )
                    if stats.removedFiles > 0 {
                        pendingLimit = .cache(megabytes: newValue, files: stats.removedFiles)
                    } else {
                        applyImmediately { settings.researchTempCacheMB = newValue }
                    }
                }
            }
        )
    }

    private var cacheTTLBinding: Binding<Int> {
        Binding(
            get: { settings.researchTempCacheTTLHours },
            set: { newValue in
                settings.researchTempCacheTTLHours = newValue
                Task { @MainActor in
                    await ResearchCacheStore.shared.setPagesTTL(hours: newValue)
                }
            }
        )
    }

    // MARK: - Actions

    private func applyImmediately(_ change: () -> Void) {
        change()
        Task { @MainActor in
            await runMaintenance()
        }
    }

    private func apply(_ pending: PendingLimit) {
        switch pending {
        case .history(let limit, _):
            settings.researchHistoryLimit = limit
        case .retention(let days, _):
            settings.researchRetentionDays = days
        case .cache(let megabytes, _):
            settings.researchTempCacheMB = megabytes
        }
        pendingLimit = nil
        Task { @MainActor in
            await runMaintenance()
        }
    }

    private func runMaintenance() async {
        var excluding = ResearchCoordinator.shared.activeRecordIDs()
        if let selected = ResearchSelectionTracker.shared.selectedID {
            excluding.insert(selected)
        }
        await ResearchMaintenance.shared.runEnforcement(
            settings: settings,
            excluding: excluding
        )
        NotificationCenter.default.post(name: .researchRecordsChanged, object: nil)
        await refreshStorage()
    }

    private func clearHistory() {
        ResearchCoordinator.shared.cancelAll()
        Task { @MainActor in
            do {
                // Search snapshots contain the queries that produced the
                // records we are deleting; clear them too.
                await ResearchCacheStore.shared.clear(kind: .search)
                try await ResearchStore.shared.deleteAll()
                message = "research.data.clearedHistory".localized
            } catch {
                message = "research.data.clearFailed".localized
            }
            NotificationCenter.default.post(name: .researchRecordsChanged, object: nil)
            await refreshStorage()
        }
    }

    private func clearCache() {
        Task { @MainActor in
            await ResearchCacheStore.shared.clearAll()
            message = "research.data.clearedCache".localized
            await refreshStorage()
        }
    }

    private func clearAllCaches() {
        cacheClearAction?()
        Task { @MainActor in
            await ResearchCacheStore.shared.clearAll()
            message = "research.data.clearedAll".localized
            await refreshStorage()
        }
    }

    private func refreshStorage() async {
        let records = await ResearchStore.shared.storageFootprint()
        let cache = await ResearchCacheStore.shared.totalBytes()
        recordsBytes = records
        cacheBytes = cache
    }

    // MARK: - Helpers

    private func storageRow(_ title: String, bytes: Int64) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(Self.byteFormatter.string(fromByteCount: bytes))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func confirmationMessage(_ pending: PendingLimit) -> String {
        switch pending {
        case .history(_, let removals), .retention(_, let removals):
            return L10n.string(
                "research.data.confirm.records",
                language: settings.appLanguage,
                removals
            )
        case .cache(_, let files):
            return L10n.string(
                "research.data.confirm.cacheFiles",
                language: settings.appLanguage,
                files
            )
        }
    }
}
