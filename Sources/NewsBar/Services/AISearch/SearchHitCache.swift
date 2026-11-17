import Foundation

/// In-memory search-hit layer.
///
/// AI search used to read and write this actor. It now reads the shared
/// `ResearchCacheStore` through `SearchRouter` with a bounded `maxAge`, so one
/// clear and one epoch cover the whole product. The actor is kept for callers
/// that explicitly want a process-local layer, and
/// `ResearchCacheCoordinator.clearAll()` still empties it so no stale layer can
/// survive a user-visible clear.
///
/// Keyed by query + recency + the enabled provider set: switching providers
/// must not serve results the user just disabled.
actor SearchHitCache {
    static let shared = SearchHitCache()

    /// The AI-search freshness window. This is the value the product used
    /// before the cache was shared; AI search passes it as `maxAge` so the
    /// 12-hour research TTL never makes an answer 12 hours old.
    static let aiSearchMaxAge: TimeInterval = 600

    private struct Entry {
        let hits: [SearchHit]
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let lifetime: TimeInterval = SearchHitCache.aiSearchMaxAge
    private let limit = 20

    func hits(for key: String, now: Date = Date()) -> [SearchHit]? {
        guard let entry = entries[key] else { return nil }
        guard now.timeIntervalSince(entry.storedAt) < lifetime else {
            entries[key] = nil
            order.removeAll { $0 == key }
            return nil
        }
        order.removeAll { $0 == key }
        order.append(key)
        return entry.hits
    }

    func store(_ hits: [SearchHit], for key: String) {
        entries[key] = Entry(hits: hits, storedAt: Date())
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit {
            entries[order.removeFirst()] = nil
        }
    }

    /// Full clear for the research cache coordinator. One call, no epoch: this
    /// layer holds process-local hits only, and the store epoch is what guards
    /// in-flight writes.
    func clearAll() {
        entries.removeAll()
        order.removeAll()
    }
}
