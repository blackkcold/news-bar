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
    let quota: AIQuotaStore
    let now: @Sendable () -> Date

    init(
        store: any ResearchPersisting = ResearchStore.shared,
        cache: ResearchCacheStore = ResearchCacheStore.shared,
        ledger: ResearchLedger = ResearchLedger.shared,
        quota: AIQuotaStore = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.cache = cache
        self.ledger = ledger
        self.quota = quota
        self.now = now
    }

    /// One-time carry-over of today's already-spent calls into the single quota
    /// ledger. The marker is written only after a successful seed, so a failed
    /// write retries on the next launch without double counting.
    static let aiQuotaMigrationKey = "aiQuotaMigrationVersion"

    @MainActor
    @discardableResult
    func migrateAIQuotaIfNeeded(settings: AppSettings) -> Bool {
        guard UserDefaults.standard.integer(forKey: Self.aiQuotaMigrationKey) < 1 else {
            return false
        }
        settings.resetDailyStatsIfNeeded()
        let summary = AISummaryService.legacySummaryUsage(settings: settings)
        let research = ledger.snapshot(at: now()).totalAI
        guard quota.seedLegacyUsage(
            summaryCount: summary,
            researchCount: research,
            at: now()
        ) else { return false }
        UserDefaults.standard.set(1, forKey: Self.aiQuotaMigrationKey)
        settings.refreshAIUsageMirror(at: now())
        return true
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

    /// Clears queued records that no coordinator slot owns. A crash or a
    /// history reset can leave `.queued` behind; those records would otherwise
    /// sit in the research center forever and look like work in progress.
    /// Records younger than `ResearchAutoAdmission.queueLifetime` are kept
    /// because their initial status write may still be in flight.
    @discardableResult
    func reclaimOrphanedQueuedRecords(
        activeIDs: Set<String>,
        now: Date? = nil
    ) async -> Int {
        let current = now ?? self.now()
        let stale = await store.index().filter { entry in
            entry.status == .queued
                && !activeIDs.contains(entry.id)
                && current.timeIntervalSince(entry.createdAt) > ResearchAutoAdmission.queueLifetime
        }
        guard !stale.isEmpty else { return 0 }

        var reclaimed = 0
        for entry in stale {
            guard var record = await store.record(id: entry.id),
                  record.status == .queued,
                  record.run.startedAt == nil else { continue }
            record.status = .interrupted
            record.run.phase = .done
            record.run.finishedAt = current
            record.run.lastError = nil
            do {
                try await store.save(record)
                reclaimed += 1
            } catch {
                continue
            }
        }
        return reclaimed
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
            // active-record set cannot map onto them. Protect everything a run
            // could still be reading: files touched in the last hour.
            protecting: [],
            protectingSince: now().addingTimeInterval(-3_600)
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
