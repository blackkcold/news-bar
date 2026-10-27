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
            var record = existing
            if record.topic != item.title {
                record.addAlias(record.topic)
                record.topic = item.title
            }
            record.lastSeenAt = now
            if record.seed.title.isEmpty { record.seed.title = item.title }
            if record.seed.url == nil { record.seed.url = item.url }
            if record.seed.publishedAt == nil { record.seed.publishedAt = item.publishedAt }
            do {
                try await store.save(record)
                return record
            } catch {
                return nil
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

    private static func shouldReuse(
        _ record: ResearchRecord,
        origin: ResearchOrigin,
        now: Date
    ) -> Bool {
        switch origin {
        case .manual:
            return true
        case .burst, .keyword:
            return now.timeIntervalSince(record.lastSeenAt) <= 7 * 86_400
        }
    }
}
