import Foundation

/// Executes the staged "clear research history" flow. Split from the
/// orchestrator so every failure point can be exercised without a live app.
///
/// Order is part of the contract:
/// 1. durable intent
/// 2. stop research
/// 3. cache (search + pages)
/// 4. authoritative records
/// 5. legacy artifacts (notification de-duplication and interest data stay)
/// 6. verify, then remove the intent last
@MainActor
struct ResearchHistoryClearer {
    let store: any ResearchPersisting
    let cache: ResearchCacheStore
    let intentStore: ResearchClearIntentStore
    var cancelResearch: () -> Void
    /// Returns `true` only when the cleared artifact set was durably written.
    var clearArtifacts: () async -> Bool
    var verifyArtifactsCleared: () -> Bool

    func run(existing: ResearchClearIntent?, generation: Int) async -> ResearchClearResult {
        var intent = existing ?? ResearchClearIntent.make(generation: generation, at: Date())
        intent.generation = generation
        intent.stage = .prepared
        do {
            try intentStore.save(intent)
        } catch {
            return ResearchClearResult(error: "clear intent could not be written")
        }

        cancelResearch()

        var result = ResearchClearResult()

        // Persist the one-time import marker before anything is deleted. If
        // this write fails, the flow stops here: artifacts are still intact
        // and the next launch may retry normally.
        guard await store.updateMeta({ $0.legacyImportVersion = 1 }) else {
            result.error = "legacy import marker could not be written"
            return result
        }

        await cache.clearAll()
        guard await cache.isEmpty() else {
            result.error = "search/pages cache still has files"
            return result
        }
        result.cacheCleared = true
        advance(&intent, to: .cacheCleared)

        do {
            try await store.deleteAll()
        } catch {
            result.error = "record deletion failed"
            return result
        }
        guard await store.index().isEmpty else {
            result.error = "records remain after deletion"
            return result
        }
        advance(&intent, to: .recordsDeleted)

        guard await clearArtifacts() else {
            result.error = "legacy artifacts were not persisted as cleared"
            return result
        }
        guard verifyArtifactsCleared() else {
            result.error = "legacy artifacts remain"
            return result
        }
        result.artifactsCleared = true
        advance(&intent, to: .artifactsCleared)

        let finalRecords = await store.index()
        guard finalRecords.isEmpty, verifyArtifactsCleared() else {
            result.error = "clear verification failed"
            return result
        }
        intent.stage = .verified
        do {
            try intentStore.save(intent)
            try intentStore.clear()
        } catch {
            result.error = "clear intent could not be removed"
            return result
        }

        result.isComplete = true
        return result
    }

    private func advance(_ intent: inout ResearchClearIntent, to stage: ResearchClearIntent.Stage) {
        intent.stage = stage
        // A failed stage write is not fatal: the next launch replays the
        // idempotent stages from `prepared`. The final removal is strict.
        try? intentStore.save(intent)
    }
}
