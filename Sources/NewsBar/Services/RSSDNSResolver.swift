import Foundation

/// Bounded, single-flight DNS lookups for outbound feed refreshes.
///
/// The system resolver call itself cannot be cancelled, so the only safe
/// control is to stop creating new blocked lookups: one task per host, a small
/// concurrency ceiling, and a short positive cache. A lookup that exceeds the
/// caller's deadline keeps running, but it no longer adds a thread per source.
actor RSSDNSResolver {
    static let shared = RSSDNSResolver()

    private struct Entry {
        let addresses: [String]
        let resolvedAt: Date
    }

    private let maxConcurrent: Int
    private let ttl: TimeInterval
    private var cache: [String: Entry] = [:]
    private var inFlight: [String: Task<[String], Never>] = [:]
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int = 4, ttl: TimeInterval = 60) {
        self.maxConcurrent = maxConcurrent
        self.ttl = ttl
    }

    func resolve(host: String, now: Date = Date()) async -> [String] {
        let key = host.lowercased()
        if let entry = cache[key], now.timeIntervalSince(entry.resolvedAt) < ttl {
            return entry.addresses
        }
        if let existing = inFlight[key] {
            return await existing.value
        }
        await acquire()
        // Another caller may have installed a lookup while this one waited.
        if let existing = inFlight[key] {
            release()
            return await existing.value
        }
        let task = Task.detached(priority: .utility) {
            await ReaderNavigationPolicy.resolveAddresses(key)
        }
        inFlight[key] = task
        let addresses = await task.value
        inFlight[key] = nil
        if !addresses.isEmpty {
            cache[key] = Entry(addresses: addresses, resolvedAt: now)
        }
        release()
        return addresses
    }

    /// Discards cached answers after a network path change.
    func invalidate() {
        cache.removeAll()
    }

    private func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        running += 1
    }

    private func release() {
        running = max(0, running - 1)
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }
}
