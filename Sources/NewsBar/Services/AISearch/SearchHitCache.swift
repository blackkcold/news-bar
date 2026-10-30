import Foundation

/// Ten-minute cache for search hits, so repeating the same look-up (or
/// re-running the same question) does not pay the search provider twice.
///
/// Keyed by query + recency + the enabled provider set: switching providers
/// must not serve results the user just disabled.
actor SearchHitCache {
    static let shared = SearchHitCache()

    private struct Entry {
        let hits: [SearchHit]
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let lifetime: TimeInterval = 600
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
}
