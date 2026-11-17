import Foundation

/// Receipt for one research cache clear. `isComplete` is false when a file
/// survived deletion, so a caller must not report "cleared" without checking it.
struct ResearchCacheClearReceipt: Sendable, Equatable {
    let epoch: Int
    let removedBytes: Int64
    let isComplete: Bool
}

/// The single cleanup path for the research cache.
///
/// Every entry that deletes or trims cached search results/pages goes through
/// here: the settings privacy pane, the staged clear-history flow and the
/// periodic maintenance pass. One clear bumps the store's write generation once,
/// which makes an in-flight `store` from before the clear a no-op.
///
/// The in-memory `SearchHitCache` is cleared here as well. Production AI search
/// no longer writes it (it reads the shared store with a bounded `maxAge`), but
/// clearing it keeps older layers and any test double from serving pre-clear
/// hits.
enum ResearchCacheCoordinator {
    static func clearAll(
        cache: ResearchCacheStore = .shared
    ) async -> ResearchCacheClearReceipt {
        let before = await cache.totalBytes()
        // This bumps `writeGeneration` exactly once; do not bump it again here.
        await cache.clearAll()
        await SearchHitCache.shared.clearAll()

        let epoch = await cache.writeEpoch()
        let after = await cache.totalBytes()
        let empty = await cache.isEmpty()
        return ResearchCacheClearReceipt(
            epoch: epoch,
            removedBytes: max(0, before - after),
            isComplete: empty
        )
    }

    /// Thin wrapper over the store's expiry + size enforcement. `protecting`
    /// holds hashed file keys a running task is still reading; `protectingSince`
    /// protects everything touched too recently to map back to a record.
    @discardableResult
    static func enforceLimits(
        maxBytes: Int64,
        protecting: Set<String> = [],
        protectingSince: Date? = nil,
        now: Date = Date(),
        cache: ResearchCacheStore = .shared
    ) async -> ResearchCacheStats {
        await cache.enforceLimits(
            now: now,
            maxBytes: maxBytes,
            protecting: protecting,
            protectingSince: protectingSince
        )
    }
}
