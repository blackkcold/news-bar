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
    /// Optional shared ledger. When present, a quota block survives a relaunch;
    /// without it the router stays in-memory only, which keeps tests hermetic.
    private let ledger: ResearchLedger?
    /// Local per-provider request guards. `nil` in tests that do not care.
    private let quota: SearchQuotaStore?

    private var cooldownUntil: [SearchProviderID: Date] = [:]
    private var consecutiveQuotaFailures: [SearchProviderID: Int] = [:]
    /// Fingerprint of the key that failed with 401. A changed key clears it.
    /// A keyless 401 never enters this map, so it cannot disable the session.
    private var invalidKeyFingerprints: [SearchProviderID: String] = [:]
    private var statuses: [SearchProviderID: SearchProviderStatus] = [:]

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    init(
        providers: [any SearchProvider]? = nil,
        cache: ResearchCacheStore = ResearchCacheStore(),
        now: @escaping @Sendable () -> Date = { Date() },
        ledger: ResearchLedger? = nil,
        quota: SearchQuotaStore? = nil
    ) {
        self.providers = providers ?? [
            TavilySearchProvider(),
            FirecrawlSearchProvider(),
            TinyFishSearchProvider(),
            ExaSearchProvider(),
            ParallelSearchProvider(),
            BraveSearchProvider(),
        ]
        self.cache = cache
        self.now = now
        self.ledger = ledger
        self.quota = quota
    }

    func search(
        _ query: SearchQuery,
        configuration: SearchRouterConfiguration,
        maxAttempts: Int = DepthProfile.maxSearchHTTPCallsPerTask,
        maxProviderAttempts: Int = 3,
        useCache: Bool = true,
        ticket: SearchAttemptTicket? = nil
    ) async throws -> SearchBatch {
        let current = now()
        let cacheKey = Self.cacheKey(for: query, configuration: configuration)
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
        var providerAttempts = 0

        for provider in ordered {
            try Task.checkCancellation()
            guard configuration.enabled.contains(provider.id) else {
                record(.disabled, for: provider.id)
                continue
            }

            let key = configuration.key(for: provider.id)
            if provider.authMode.needsKeyToDispatch, key.isEmpty {
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
            // A quota block outlives this process; adopt it before dispatching.
            if let until = ledger?.providerCooldown(provider.id, at: current), until > current {
                cooldownUntil[provider.id] = until
                record(.cooling, for: provider.id, until: until)
                failures.append(
                    SearchProviderFailure(
                        provider: provider.id,
                        reason: .coolingDown(until: until)
                    )
                )
                continue
            }

            // A single query must not spend the whole task budget walking six
            // providers. Skips above are free; this cap counts real dispatches.
            guard providerAttempts < maxProviderAttempts else {
                failures.append(SearchProviderFailure(provider: nil, reason: .attemptLimit))
                break
            }

            let keyed = !key.isEmpty
            if let quota {
                let allowed = await quota.consume(for: provider.id, keyed: keyed)
                if !allowed {
                    record(.quotaExhausted, for: provider.id)
                    failures.append(
                        SearchProviderFailure(provider: provider.id, reason: .quotaExhausted)
                    )
                    continue
                }
            }
            providerAttempts += 1

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

                    if case .rateLimited(let retryAfter) = mapped {
                        let until = recordRateLimit(
                            for: provider.id,
                            at: now(),
                            retryAfter: retryAfter
                        )
                        record(.cooling, for: provider.id, until: until, failure: .rateLimited)
                        failures.append(
                            SearchProviderFailure(
                                provider: provider.id,
                                reason: .rateLimited
                            )
                        )
                        failovers += 1
                        break
                    }

                    if mapped == .quotaExhausted {
                        let until = recordQuotaExhaustion(
                            for: provider.id,
                            keyed: keyed,
                            at: now()
                        )
                        await quota?.exhaust(for: provider.id, keyed: keyed)
                        record(.quotaExhausted, for: provider.id, until: until)
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
        let current = date ?? now()
        let until = cooldownUntil[provider] ?? ledger?.providerCooldown(provider, at: current)
        guard let until else { return 0 }
        return max(0, until.timeIntervalSince(current))
    }

    /// Full settings snapshot. Reads configuration only; the current key never
    /// leaves this method.
    func statusSnapshot(
        configuration: SearchRouterConfiguration,
        at date: Date? = nil
    ) async -> [SearchProviderStatus] {
        let current = date ?? now()
        var result: [SearchProviderStatus] = []
        for id in SearchProviderID.failoverOrder {
            guard configuration.enabled.contains(id) else {
                result.append(SearchProviderStatus(provider: id, state: .disabled))
                continue
            }
            let key = configuration.key(for: id)
            let snapshot = await quota?.snapshot(for: id, keyed: !key.isEmpty, at: current)
            if id.authMode.needsKeyToDispatch, key.isEmpty {
                result.append(
                    SearchProviderStatus(provider: id, state: .missingKey, quota: snapshot)
                )
                continue
            }
            let persisted = ledger?.providerCooldown(id, at: current)
            if let until = cooldownUntil[id] ?? persisted, until > current {
                result.append(
                    SearchProviderStatus(
                        provider: id,
                        state: .cooling,
                        cooldownUntil: until,
                        lastFailure: .quotaExhausted,
                        quota: snapshot
                    )
                )
                continue
            }
            let fingerprint = Self.fingerprint(key)
            if invalidKeyFingerprints[id] == fingerprint {
                result.append(
                    SearchProviderStatus(
                        provider: id,
                        state: .authRejected,
                        lastFailure: .authRejected,
                        quota: snapshot
                    )
                )
                continue
            }
            let base = statuses[id] ?? SearchProviderStatus(provider: id, state: .unattempted)
            result.append(
                SearchProviderStatus(
                    provider: id,
                    state: base.state,
                    cooldownUntil: base.cooldownUntil,
                    lastFailure: base.lastFailure,
                    quota: snapshot
                )
            )
        }
        return result
    }

    /// The cache key includes the dispatchable provider set. Without it, a
    /// cached batch can be replayed after a provider is disabled and the report
    /// would still credit the closed provider.
    static func cacheKey(
        for query: SearchQuery,
        configuration: SearchRouterConfiguration? = nil
    ) -> String {
        let normalized = query.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var parts = [
            normalized,
            query.recency.rawValue,
            query.language ?? "",
            String(query.maxResults),
        ]
        if let configuration {
            let dispatchable = configuration.enabled
                .filter { provider in
                    !provider.authMode.needsKeyToDispatch || !configuration.key(for: provider).isEmpty
                }
                .map(\.rawValue)
                .sorted()
                .joined(separator: ",")
            parts.append("providers:\(dispatchable)")
        }
        return parts.joined(separator: "\u{001F}")
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
    private func recordRateLimit(
        for provider: SearchProviderID,
        at date: Date,
        retryAfter: TimeInterval?
    ) -> Date {
        let failures = (consecutiveQuotaFailures[provider] ?? 0) + 1
        consecutiveQuotaFailures[provider] = failures
        let ladder: [TimeInterval] = [60, 300, 900, 3600]
        let backoff = ladder[min(failures - 1, ladder.count - 1)]
        // Honour the provider's hint, but bound it: a bad header must not park
        // a provider for a day, and a zero must not hammer it.
        let delay = retryAfter.map { min(max($0, 60), 24 * 3600) } ?? backoff
        let until = date.addingTimeInterval(delay)
        cooldownUntil[provider] = until
        // Persist the block so a relaunch cannot immediately re-spend a limit
        // that the provider already refused.
        ledger?.recordProviderCooldown(provider, until: until, at: date)
        return until
    }

    /// `402` means the allowance is gone, not that we were too fast. Park the
    /// provider until its own window resets instead of retrying in 15 minutes.
    @discardableResult
    private func recordQuotaExhaustion(
        for provider: SearchProviderID,
        keyed: Bool,
        at date: Date
    ) -> Date {
        let limit = SearchRateLimits.limit(for: provider, keyed: keyed)
        let until = limit.resetDate(after: date, calendar: Self.utcCalendar)
        cooldownUntil[provider] = until
        ledger?.recordProviderCooldown(provider, until: until, at: date)
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
        case .rateLimited: return .rateLimited
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
