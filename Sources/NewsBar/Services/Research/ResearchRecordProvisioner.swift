import Foundation

/// Creates or reuses the single record for an exact topic. Auto-detected
/// records merge by exact topic key inside a 7-day window; manual verification
/// reuses any exact-key record so a user can always re-run it. Fuzzy merging is
/// deliberately not used here.
enum ResearchRecordProvisioner {
    private static let inFlightLock = NSLock()
    nonisolated(unsafe) private static var inFlight: Set<String> = []

    static func ensureRecord(
        for item: NewsItem,
        origin: ResearchOrigin,
        store: any ResearchPersisting,
        now: Date = Date()
    ) async -> ResearchRecord? {
        let normalizedTitle = TopicFingerprint.normalized(item.title)
        guard !normalizedTitle.isEmpty else { return nil }

        let topicKey = TopicFingerprint.key(for: item.title)

        // Two callers (burst auto-detect and manual verify) can both see "no
        // record" before either writes one. Serialize per topic key.
        inFlightLock.lock()
        let inserted = inFlight.insert(topicKey).inserted
        inFlightLock.unlock()
        guard inserted else {
            try? await Task.sleep(nanoseconds: 50_000_000)
            return await store.latestRecord(topicKey: topicKey)
        }
        defer {
            inFlightLock.lock()
            inFlight.remove(topicKey)
            inFlightLock.unlock()
        }
        if let existing = await store.latestRecord(topicKey: topicKey),
           shouldReuse(existing, origin: origin, now: now) {
            let record = adopt(existing, for: item, topicKey: topicKey, now: now)
            do {
                try await store.save(record)
                return record
            } catch {
                return nil
            }
        }

        // Exact keys miss when a hot-search headline evolves. Reuse a recent
        // automatic record only when the title/alias similarity and source
        // domain pass TopicFingerprint's strict fuzzy policy; manual records
        // stay exact-only so the user's history is never merged implicitly.
        // Filter by the lightweight index first: decoding every full record on
        // each burst miss would be a needless I/O spike.
        if origin.isAutomatic {
            let recent = await store.index().filter {
                $0.origin.isAutomatic
                    && abs(now.timeIntervalSince($0.lastSeenAt)) <= TopicFingerprint.fuzzyMergeWindow
            }
            for entry in recent {
                guard let candidate = await store.record(id: entry.id),
                      TopicFingerprint.shouldFuzzyMerge(
                          title: item.title,
                          seedURL: item.url,
                          source: item.source,
                          origin: origin,
                          with: candidate,
                          now: now
                      ) else { continue }
                let record = adopt(candidate, for: item, topicKey: topicKey, now: now)
                do {
                    try await store.save(record)
                    return record
                } catch {
                    return nil
                }
            }
        }

        var run = ResearchRun()
        run.phase = .idle
        run.depth = .quick
        run.origin = origin

        let record = ResearchRecord(
            id: UUID().uuidString,
            topicKey: topicKey,
            origin: origin,
            topic: item.title,
            aliases: [],
            seed: ResearchSeed(
                itemID: item.id,
                title: item.title,
                url: item.url,
                source: item.source,
                publishedAt: item.publishedAt,
                initialSummary: ""
            ),
            createdAt: now,
            lastSeenAt: now,
            updatedAt: now,
            lastAccessedAt: now,
            isPinned: false,
            isRead: false,
            status: .queued,
            report: nil,
            run: run,
            reportVersion: 0
        )

        do {
            try await store.save(record)
            return record
        } catch {
            return nil
        }
    }

    private static func adopt(
        _ existing: ResearchRecord,
        for item: NewsItem,
        topicKey: String,
        now: Date
    ) -> ResearchRecord {
        var record = existing
        if record.topic != item.title {
            let previousTitle = record.topic
            record.topic = item.title
            record.addAlias(previousTitle)
            // Keep exact-topic lookup working after a title evolves; otherwise
            // the next notification opens a new record and starts a duplicate
            // research pass.
            record.topicKey = topicKey
        }
        record.lastSeenAt = now
        if record.seed.title.isEmpty { record.seed.title = item.title }
        if record.seed.url == nil { record.seed.url = item.url }
        if record.seed.publishedAt == nil { record.seed.publishedAt = item.publishedAt }
        return record
    }

    private static func shouldReuse(
        _ record: ResearchRecord,
        origin: ResearchOrigin,
        now: Date
    ) -> Bool {
        switch origin {
        case .manual:
            return true
        case .burst, .keyword, .interest:
            return now.timeIntervalSince(record.lastSeenAt) <= 7 * 86_400
        }
    }
}
