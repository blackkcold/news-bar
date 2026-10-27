import Foundation

/// One-time import of `PersistedResearchState.artifacts` into `ResearchStore`.
///
/// P0 is deliberately copy-only: the legacy burst window still reads its
/// in-memory `BurstResearch` cache, so clearing `artifacts` here would make old
/// history disappear before the research center ships. P1 flips the final step
/// (clear `artifacts`, keep the notified sets) once the center reads the store.
enum LegacyResearchImporter {
    struct Outcome: Sendable, Equatable {
        var imported = 0
        var skipped = 0
        var failed = false
        var errorDescription: String?
    }

    static func importArtifacts(
        _ artifacts: [String: BurstResearch],
        stateUpdatedAt: Date,
        currentItems: [NewsItem],
        store: any ResearchPersisting
    ) async -> Outcome {
        var outcome = Outcome()
        guard !artifacts.isEmpty else { return outcome }

        let meta = await store.meta()
        guard meta.legacyImportVersion < 1 else {
            outcome.skipped = artifacts.count
            return outcome
        }

        let existing = await store.index()
        var seen = Set(existing.map { dedupeKey(topicKey: $0.topicKey, createdAt: $0.createdAt) })

        // Equal timestamps must import in a deterministic title order.
        let orderedTitles = artifacts.keys.sorted { $0 < $1 }

        var records: [ResearchRecord] = []
        for title in orderedTitles {
            guard let research = artifacts[title] else { continue }
            let topicKey = TopicFingerprint.key(for: title)
            let key = dedupeKey(topicKey: topicKey, createdAt: stateUpdatedAt)
            if seen.contains(key) {
                outcome.skipped += 1
                continue
            }

            let record = makeRecord(
                title: title,
                research: research,
                topicKey: topicKey,
                stateUpdatedAt: stateUpdatedAt,
                currentItems: currentItems
            )
            records.append(record)
            seen.insert(key)
        }

        if !records.isEmpty {
            do {
                try await store.saveAll(records)
                outcome.imported = records.count
            } catch {
                // Leave the version marker unwritten: the next launch retries,
                // and already-written records are deduplicated by key+timestamp.
                outcome.failed = true
                outcome.errorDescription = String(describing: error)
                return outcome
            }
        }

        let marked = await store.updateMeta { $0.legacyImportVersion = 1 }
        if !marked {
            outcome.failed = true
            outcome.errorDescription = "Failed to write legacy import version"
        }
        return outcome
    }

    private static func makeRecord(
        title: String,
        research: BurstResearch,
        topicKey: String,
        stateUpdatedAt: Date,
        currentItems: [NewsItem]
    ) -> ResearchRecord {
        let matched = currentItems.first { $0.title == title }
            ?? currentItems.first {
                TopicFingerprint.normalized($0.title) == TopicFingerprint.normalized(title)
            }
        let seedURL = matched?.url
            ?? research.sources.first { SecurityPolicies.validateURL($0) != nil }

        let seed = ResearchSeed(
            itemID: matched?.id,
            title: title,
            url: seedURL,
            source: matched?.source ?? .weibo,
            publishedAt: matched?.publishedAt,
            initialSummary: research.summary
        )

        var run = ResearchRun()
        run.phase = .done
        run.depth = .standard
        run.origin = .burst
        run.startedAt = stateUpdatedAt
        run.finishedAt = stateUpdatedAt

        return ResearchRecord(
            id: UUID().uuidString,
            topicKey: topicKey,
            origin: .burst,
            topic: title,
            aliases: [],
            seed: seed,
            createdAt: stateUpdatedAt,
            lastSeenAt: stateUpdatedAt,
            updatedAt: stateUpdatedAt,
            lastAccessedAt: stateUpdatedAt,
            isPinned: false,
            isRead: true,
            status: .ready,
            report: research,
            run: run,
            reportVersion: 0
        )
    }

    private static func dedupeKey(topicKey: String, createdAt: Date) -> String {
        let millis = Int64((createdAt.timeIntervalSince1970 * 1000).rounded())
        return "\(topicKey)|\(millis)"
    }
}
