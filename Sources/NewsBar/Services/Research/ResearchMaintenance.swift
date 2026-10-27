import Foundation

struct ResearchMaintenanceResult: Sendable, Equatable {
    var removedRecords = 0
    var removedCacheFiles = 0
    var removedCacheBytes: Int64 = 0
    var ledgerMigrated = false
}

/// Central place for the once-per-launch ledger carry-over and the periodic
/// history/cache enforcement pass. Keeping it out of the views means the limits
/// apply even when the settings window was never opened.
struct ResearchMaintenance: Sendable {
    static let shared = ResearchMaintenance()

    let store: any ResearchPersisting
    let cache: ResearchCacheStore
    let ledger: ResearchLedger
    let now: @Sendable () -> Date

    init(
        store: any ResearchPersisting = ResearchStore.shared,
        cache: ResearchCacheStore = ResearchCacheStore.shared,
        ledger: ResearchLedger = ResearchLedger.shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.cache = cache
        self.ledger = ledger
        self.now = now
    }

    /// Moves the legacy `todayBurstResearchCount` counter into the shared ledger
    /// once. The marker is written only after a successful copy; a failed write
    /// keeps both the counter and the marker so the next launch retries.
    @MainActor
    @discardableResult
    func migrateLedgerIfNeeded(settings: AppSettings) async -> Bool {
        let meta = await store.meta()
        guard meta.ledgerMigrationVersion < 1 else { return false }

        settings.resetDailyStatsIfNeeded()
        let legacy = settings.todayBurstResearchCount
        if legacy > 0 {
            guard ledger.seedLegacyBurstCalls(legacy, at: now()) else { return false }
        }
        let updated = await store.updateMeta { $0.ledgerMigrationVersion = 1 }
        return updated
    }

    /// Applies the user's history/cache limits. Active research is protected by
    /// the caller through `excluding`; pinned records are protected by the store.
    @MainActor
    @discardableResult
    func runEnforcement(
        settings: AppSettings,
        excluding: Set<String> = []
    ) async -> ResearchMaintenanceResult {
        var result = ResearchMaintenanceResult()
        await cache.setPagesTTL(hours: settings.researchTempCacheTTLHours)

        let removed = await store.enforceLimits(
            now: now(),
            historyLimit: settings.researchHistoryLimit,
            retentionDays: settings.researchRetentionDays,
            excluding: excluding
        )
        result.removedRecords = removed.count

        let cacheStats = await cache.enforceLimits(
            now: now(),
            maxBytes: Int64(settings.researchTempCacheMB) * 1024 * 1024,
            // Cache files are keyed by content hashes, not record IDs, so the
            // active-record set cannot map onto them. A cache miss during a run
            // is safe: the pipeline re-fetches the page.
            protecting: []
        )
        result.removedCacheFiles = cacheStats.removedFiles
        result.removedCacheBytes = cacheStats.removedBytes
        return result
    }

    /// Dry run used by the settings page before a lower limit is committed.
    @MainActor
    func previewHistoryRemoval(
        settings: AppSettings,
        historyLimit: Int,
        retentionDays: Int
    ) async -> Int {
        await store.previewEnforcement(
            now: now(),
            historyLimit: historyLimit,
            retentionDays: retentionDays
        )
    }

    @MainActor
    func previewCacheRemoval(maxBytes: Int64) async -> ResearchCacheStats {
        await cache.previewEnforcement(now: now(), maxBytes: maxBytes)
    }
}
