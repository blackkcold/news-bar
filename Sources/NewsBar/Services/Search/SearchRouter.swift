import Foundation

/// Fixed-order search with quota/limit failover. The router owns only routing
/// state (cooldowns, rejected keys) and the disposable result cache. HTTP
/// budget accounting is delegated to a `SearchAttemptTicket` supplied by the
/// caller, so every dispatched request is charged exactly once even when the
/// call throws or is cancelled.
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
    /// Fingerprint of the key that failed with 401. A changed key clears it.
    /// A keyless 401 never enters this map, so it cannot disable the session.
    private var invalidKeyFingerprints: [SearchProviderID: String] = [:]
    private var statuses: [SearchProviderID: SearchProviderStatus] = [:]

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
        useCache: Bool = true,
        ticket: SearchAttemptTicket? = nil
    ) async throws -> SearchBatch {
        let current = now()
        let cacheKey = Self.cacheKey(for: query)
        let attempts = ticket ?? SearchAttemptTicket(limit: maxAttempts)
        let cacheEpoch = await cache.writeEpoch()

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
            throw SearchUnavailableError(failures: [
                SearchProviderFailure(provider: nil, reason: .disabled),
            ])
        }

        var failures: [SearchProviderFailure] = []
        var failovers = 0

        for provider in ordered {
            try Task.checkCancellation()
            guard configuration.enabled.contains(provider.id) else {
                record(.disabled, for: provider.id)
                continue
            }

            let key = configuration.key(for: provider.id)
            if provider.requiresKey, key.isEmpty {
                record(.missingKey, for: provider.id)
                failures.append(SearchProviderFailure(provider: provider.id, reason: .missingKey))
                continue
            }

            let fingerprint = Self.fingerprint(key)
            if invalidKeyFingerprints[provider.id] == fingerprint {
                record(.authRejected, for: provider.id)
                failures.append(
                    SearchProviderFailure(provider: provider.id, reason: .authRejected)
                )
                continue
            }
            if invalidKeyFingerprints[provider.id] != nil {
                invalidKeyFingerprints.removeValue(forKey: provider.id)
            }

            if let until = cooldownUntil[provider.id], until > current {
                record(.cooling, for: provider.id, until: until)
                failures.append(
                    SearchProviderFailure(
                        provider: provider.id,
                        reason: .coolingDown(until: until)
                    )
                )
                continue
            }

            var retried = false
            while true {
                try Task.checkCancellation()
                guard attempts.consume() else {
                    failures.append(
                        SearchProviderFailure(provider: nil, reason: .budgetExhausted)
                    )
                    throw SearchUnavailableError(failures: failures)
                }

                do {
                    let hits = try await provider.search(query, key: key)
                    consecutiveQuotaFailures[provider.id] = nil
                    cooldownUntil[provider.id] = nil
                    record(.succeeded, for: provider.id)

                    let limited = Array(
                        SearchResultRanking.deduplicated(hits).prefix(query.maxResults)
                    )
                    let batch = SearchBatch(
                        hits: limited,
                        providers: [provider.id],
                        attempts: attempts.used,
                        failovers: failovers,
                        fetchedAt: current,
                        failures: failures
                    )
                    await store(batch, cacheKey: cacheKey, epoch: cacheEpoch)
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
                        // Only a key that was actually supplied can be marked
                        // rejected. Firecrawl's keyless tier returning 401 must
                        // not turn into a permanent session-wide block.
                        if !key.isEmpty {
                            invalidKeyFingerprints[provider.id] = fingerprint
                        }
                        record(.authRejected, for: provider.id)
                        failures.append(
                            SearchProviderFailure(provider: provider.id, reason: .authRejected)
                        )
                        failovers += 1
                        break
                    }

                    if mapped == .forbidden {
                        // 403 is not proof of a bad key. Do not retry inside
                        // this research pass, but leave the next pass free to
                        // try again.
                        record(.forbidden, for: provider.id)
                        failures.append(
                            SearchProviderFailure(provider: provider.id, reason: .forbidden)
                        )
                        failovers += 1
                        break
                    }

                    if mapped == .quotaExhausted {
                        let until = recordQuotaFailure(for: provider.id, at: now())
                        record(.cooling, for: provider.id, until: until)
                        failures.append(
                            SearchProviderFailure(
                                provider: provider.id,
                                reason: .quotaExhausted
                            )
                        )
                        failovers += 1
                        break
                    }

                    if (mapped.isServerError || mapped == .timeout), !retried {
                        retried = true
                        continue
                    }

                    switch mapped {
                    case .server(let status):
                        record(.transientFailure, for: provider.id, failure: .server(status))
                    case .timeout:
                        record(.transientFailure, for: provider.id, failure: .timeout)
                    case .malformedResponse:
                        record(
                            .transientFailure,
                            for: provider.id,
                            failure: .malformedResponse
                        )
                    case .emptyQuery:
                        record(.transientFailure, for: provider.id, failure: .emptyQuery)
                    default:
                        record(.transientFailure, for: provider.id, failure: .transport)
                    }
                    failures.append(
                        SearchProviderFailure(
                            provider: provider.id,
                            reason: Self.reason(for: mapped)
                        )
                    )
                    failovers += 1
                    break
                }
            }
        }

        if failures.isEmpty {
            failures.append(SearchProviderFailure(provider: nil, reason: .disabled))
        }
        throw SearchUnavailableError(failures: failures)
    }

    /// Called when a provider key is saved, cleared or migrated so an old 401
    /// does not outlive the credential it described. It never sends a request
    /// and never clears a quota cooldown.
    func clearAuthBlock(for provider: SearchProviderID) {
        invalidKeyFingerprints.removeValue(forKey: provider)
        if statuses[provider]?.state == .authRejected {
            statuses[provider] = SearchProviderStatus(provider: provider, state: .unattempted)
        }
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

    /// Full settings snapshot. Reads configuration only; the current key never
    /// leaves this method.
    func statusSnapshot(
        configuration: SearchRouterConfiguration,
        at date: Date? = nil
    ) -> [SearchProviderStatus] {
        let current = date ?? now()
        return SearchProviderID.failoverOrder.map { id in
            guard configuration.enabled.contains(id) else {
                return SearchProviderStatus(provider: id, state: .disabled)
            }
            let requiresKey = providers.first { $0.id == id }?.requiresKey ?? id.requiresAPIKey
            let key = configuration.key(for: id)
            if requiresKey, key.isEmpty {
                return SearchProviderStatus(provider: id, state: .missingKey)
            }
            if let until = cooldownUntil[id], until > current {
                return SearchProviderStatus(
                    provider: id,
                    state: .cooling,
                    cooldownUntil: until,
                    lastFailure: .quotaExhausted
                )
            }
            let fingerprint = Self.fingerprint(key)
            if invalidKeyFingerprints[id] == fingerprint {
                return SearchProviderStatus(
                    provider: id,
                    state: .authRejected,
                    lastFailure: .authRejected
                )
            }
            return statuses[id] ?? SearchProviderStatus(provider: id, state: .unattempted)
        }
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

    private func store(_ batch: SearchBatch, cacheKey: String, epoch: Int) async {
        let payload = CachedSearchResult(
            hits: batch.hits,
            providers: batch.providers,
            fetchedAt: batch.fetchedAt
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        await cache.store(
            data,
            kind: .search,
            key: cacheKey,
            now: batch.fetchedAt,
            epoch: epoch
        )
    }

    @discardableResult
    private func recordQuotaFailure(for provider: SearchProviderID, at date: Date) -> Date {
        let failures = (consecutiveQuotaFailures[provider] ?? 0) + 1
        consecutiveQuotaFailures[provider] = failures
        let until = date.addingTimeInterval(failures >= 2 ? 30 * 60 : 15 * 60)
        cooldownUntil[provider] = until
        return until
    }

    private func record(
        _ state: SearchProviderState,
        for provider: SearchProviderID,
        until: Date? = nil,
        failure: SearchFailureReason? = nil
    ) {
        statuses[provider] = SearchProviderStatus(
            provider: provider,
            state: state,
            cooldownUntil: until,
            lastFailure: failure
        )
    }

    private static func reason(for error: SearchProviderError) -> SearchFailureReason {
        switch error {
        case .missingKey: return .missingKey
        case .unauthorized: return .authRejected
        case .forbidden: return .forbidden
        case .quotaExhausted: return .quotaExhausted
        case .server(let status): return .server(status)
        case .timeout: return .timeout
        case .malformedResponse: return .malformedResponse
        case .emptyQuery: return .emptyQuery
        case .transport: return .transport
        }
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
