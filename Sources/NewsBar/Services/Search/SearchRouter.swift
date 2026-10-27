import Foundation

/// Fixed-order search with quota/limit failover. The router owns only routing
/// state (cooldowns, invalid keys) and the disposable result cache; HTTP budget
/// accounting stays with the caller via `maxAttempts` and the returned count.
actor SearchRouter {
    private struct CachedSearchResult: Codable {
        let hits: [SearchHit]
        let providers: [SearchProviderID]
        let fetchedAt: Date
    }

    private let providers: [any SearchProvider]
    private let cache: ResearchCacheStore
    private let now: @Sendable () -> Date

    private var cooldownUntil: [SearchProviderID: Date] = [:]
    private var consecutiveQuotaFailures: [SearchProviderID: Int] = [:]
    /// Fingerprint of the key that failed with 401/403. A changed key clears it.
    private var invalidKeyFingerprints: [SearchProviderID: String] = [:]

    init(
        providers: [any SearchProvider]? = nil,
        cache: ResearchCacheStore = ResearchCacheStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.providers = providers ?? [
            TavilySearchProvider(),
            FirecrawlSearchProvider(),
            BraveSearchProvider(),
        ]
        self.cache = cache
        self.now = now
    }

    func search(
        _ query: SearchQuery,
        configuration: SearchRouterConfiguration,
        maxAttempts: Int = DepthProfile.maxSearchHTTPCallsPerTask,
        useCache: Bool = true
    ) async throws -> SearchBatch {
        let current = now()
        let cacheKey = Self.cacheKey(for: query)

        if useCache,
           let data = await cache.load(kind: .search, key: cacheKey, now: current),
           let cached = try? JSONDecoder().decode(CachedSearchResult.self, from: data) {
            return SearchBatch(
                hits: Array(cached.hits.prefix(query.maxResults)),
                providers: cached.providers,
                attempts: 0,
                failovers: 0,
                fetchedAt: cached.fetchedAt
            )
        }

        let ordered = SearchProviderID.failoverOrder.compactMap { id in
            providers.first { $0.id == id }
        }
        guard !ordered.isEmpty else {
            throw SearchUnavailableError(reasons: ["no search providers configured"])
        }

        var reasons: [String] = []
        var attempts = 0
        var failovers = 0

        for provider in ordered {
            try Task.checkCancellation()
            guard configuration.enabled.contains(provider.id) else { continue }

            let key = configuration.key(for: provider.id)
            if provider.requiresKey, key.isEmpty {
                reasons.append("\(provider.id.rawValue): missing key")
                continue
            }

            let fingerprint = Self.fingerprint(key)
            if invalidKeyFingerprints[provider.id] == fingerprint {
                reasons.append("\(provider.id.rawValue): invalid key")
                continue
            }
            if invalidKeyFingerprints[provider.id] != nil {
                invalidKeyFingerprints.removeValue(forKey: provider.id)
            }

            if let until = cooldownUntil[provider.id], until > current {
                reasons.append("\(provider.id.rawValue): cooling down")
                continue
            }

            var retried = false
            while true {
                guard attempts < maxAttempts else {
                    throw SearchUnavailableError(reasons: reasons + ["HTTP budget exhausted"])
                }
                attempts += 1

                do {
                    let hits = try await provider.search(query, key: key)
                    consecutiveQuotaFailures[provider.id] = nil
                    cooldownUntil[provider.id] = nil

                    let limited = Array(
                        SearchResultRanking.deduplicated(hits).prefix(query.maxResults)
                    )
                    let batch = SearchBatch(
                        hits: limited,
                        providers: [provider.id],
                        attempts: attempts,
                        failovers: failovers,
                        fetchedAt: current
                    )
                    await store(batch, cacheKey: cacheKey)
                    return batch
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A provider maps URLSession cancellation to a transport
                    // error; do not fail over to the next provider after a
                    // user cancel.
                    if Task.isCancelled { throw CancellationError() }
                    let mapped = SearchHTTPMapping.map(error)

                    if mapped == .unauthorized {
                        invalidKeyFingerprints[provider.id] = fingerprint
                        reasons.append("\(provider.id.rawValue): unauthorized")
                        failovers += 1
                        break
                    }

                    if mapped == .quotaExhausted {
                        recordQuotaFailure(for: provider.id, at: current)
                        reasons.append("\(provider.id.rawValue): quota exhausted")
                        failovers += 1
                        break
                    }

                    if (mapped.isServerError || mapped == .timeout), !retried {
                        retried = true
                        continue
                    }

                    reasons.append("\(provider.id.rawValue): \(mapped.errorDescription ?? "failed")")
                    failovers += 1
                    break
                }
            }
        }

        throw SearchUnavailableError(reasons: reasons.isEmpty ? ["all providers disabled"] : reasons)
    }

    /// Called when search settings change so an old 401 does not outlive its key.
    func resetKeyState() {
        invalidKeyFingerprints.removeAll()
    }

    func invalidProviders() -> Set<SearchProviderID> {
        Set(invalidKeyFingerprints.keys)
    }

    func cooldownRemaining(for provider: SearchProviderID, at date: Date? = nil) -> TimeInterval {
        guard let until = cooldownUntil[provider] else { return 0 }
        return max(0, until.timeIntervalSince(date ?? now()))
    }

    static func cacheKey(for query: SearchQuery) -> String {
        let normalized = query.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        return [
            normalized,
            query.recency.rawValue,
            query.language ?? "",
            String(query.maxResults),
        ].joined(separator: "\u{001F}")
    }

    private func store(_ batch: SearchBatch, cacheKey: String) async {
        let payload = CachedSearchResult(
            hits: batch.hits,
            providers: batch.providers,
            fetchedAt: batch.fetchedAt
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        await cache.store(data, kind: .search, key: cacheKey, now: batch.fetchedAt)
    }

    private func recordQuotaFailure(for provider: SearchProviderID, at date: Date) {
        let failures = (consecutiveQuotaFailures[provider] ?? 0) + 1
        consecutiveQuotaFailures[provider] = failures
        cooldownUntil[provider] = date.addingTimeInterval(failures >= 2 ? 30 * 60 : 15 * 60)
    }

    private static func fingerprint(_ key: String) -> String {
        ContentIdentity.digest("search-key\n" + key)
    }
}

extension SearchProviderError {
    var isServerError: Bool {
        if case .server = self { return true }
        return false
    }
}
