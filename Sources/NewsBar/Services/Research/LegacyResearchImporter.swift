import Foundation

/// One-time import of `PersistedResearchState.artifacts` into `ResearchStore`.
///
/// Identity is derived from the legacy artifact's own dictionary key, never
/// from a timestamp or a random UUID, so a retry after a partial write cannot
/// create a second copy. Every artifact must end up persisted, provably
/// equivalent to an existing record, or explicitly reported as unconfirmed;
/// the version marker and the source artifacts survive any unconfirmed item.
enum LegacyResearchImporter {
    struct Outcome: Sendable, Equatable {
        var imported = 0
        var skipped = 0
        var failed = false
        var errorDescription: String?
        /// Artifacts that could not be attributed to exactly one record.
        var conflicts: [String] = []
        /// Artifacts whose persistence could not be verified after the write.
        var unconfirmed: [String] = []

        /// Only a complete pass may clear the source artifacts and write the
        /// one-time marker.
        var isComplete: Bool {
            !failed && conflicts.isEmpty && unconfirmed.isEmpty
        }
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
        if meta.legacyImportVersion >= 1 {
            outcome.skipped = artifacts.count
            return outcome
        }
        guard await store.metaAvailability().isWritable else {
            outcome.failed = true
            outcome.errorDescription = "Store metadata is not writable"
            return outcome
        }

        let epochAtStart = await store.dataEpoch()
        let existing = await store.records()
        let existingIndex = await store.index()
        // Normalized-title duplicates keep the old contract: any record with
        // the same topic key already represents this artifact.
        // Only legacy-shaped records (burst, pre-pipeline report) represent a
        // previous import. A user's manual record with the same title must not
        // be mistaken for one and silently swallow the artifact.
        var existingTopicKeys = Set(
            existingIndex
                .filter { $0.origin == .burst }
                .map(\.topicKey)
        )
        existingTopicKeys.formUnion(
            existing
                .filter { $0.origin == .burst }
                .map(\.topicKey)
        )
        var claimedLegacyIDs = Set<String>()

        // Equal timestamps must import in a deterministic key order.
        let orderedKeys = artifacts.keys.sorted { $0 < $1 }

        var records: [ResearchRecord] = []
        var pendingTitles: [String] = []

        for rawTitle in orderedKeys {
            guard let research = artifacts[rawTitle] else { continue }
            let normalized = TopicFingerprint.normalized(rawTitle)
            let topicKey = Self.topicKey(forLegacyTitle: rawTitle)
            let recordID = Self.recordID(forLegacyTitle: rawTitle)

            if normalized.isEmpty == false, existingTopicKeys.contains(topicKey) {
                outcome.skipped += 1
                continue
            }

            let candidates = Self.candidateRecords(for: rawTitle, in: existing)
            if candidates.count > 1 {
                // Ambiguous: never guess, never silently drop, never add a
                // third copy.
                outcome.conflicts.append(rawTitle)
                continue
            }
            if let candidate = candidates.first {
                guard claimedLegacyIDs.insert(candidate.id).inserted else {
                    outcome.conflicts.append(rawTitle)
                    continue
                }
                outcome.skipped += 1
                existingTopicKeys.insert(topicKey)
                continue
            }

            if existing.contains(where: { $0.id == recordID }) {
                outcome.skipped += 1
                existingTopicKeys.insert(topicKey)
                continue
            }

            let record = makeRecord(
                recordID: recordID,
                rawTitle: rawTitle,
                research: research,
                topicKey: topicKey,
                stateUpdatedAt: stateUpdatedAt,
                currentItems: currentItems
            )
            records.append(record)
            pendingTitles.append(rawTitle)
            existingTopicKeys.insert(topicKey)
        }

        if !records.isEmpty {
            do {
                try await store.saveAll(records)
            } catch {
                // Leave the version marker unwritten: a retry can resume. The
                // stable IDs make already-written records idempotent.
                outcome.failed = true
                outcome.errorDescription = String(describing: error)
                return outcome
            }

            guard await store.dataEpoch() == epochAtStart else {
                // A history clear ran while this import was in flight. Remove
                // what we wrote so the clear stays authoritative.
                for record in records { try? await store.delete(id: record.id) }
                outcome.failed = true
                outcome.errorDescription = "History was cleared during import"
                return outcome
            }

            // A write that returned without throwing is not proof of
            // persistence; re-read every record.
            for (record, rawTitle) in zip(records, pendingTitles) {
                guard let stored = await store.record(id: record.id),
                      stored.topicKey == record.topicKey,
                      stored.seed.title == record.seed.title else {
                    outcome.unconfirmed.append(rawTitle)
                    continue
                }
                outcome.imported += 1
            }
            if !outcome.unconfirmed.isEmpty {
                return outcome
            }
        }

        if outcome.conflicts.isEmpty, outcome.unconfirmed.isEmpty {
            guard await store.dataEpoch() == epochAtStart else {
                outcome.failed = true
                outcome.errorDescription = "History was cleared during import"
                return outcome
            }
            let marked = await store.updateMeta { $0.legacyImportVersion = 1 }
            if !marked {
                outcome.failed = true
                outcome.errorDescription = "Failed to write legacy import version"
            }
        }
        return outcome
    }

    // MARK: - Identity

    /// Normal titles keep `topicKey`. A title that normalizes to nothing (for
    /// example `!!!`, `🔥`, an empty key or a whitespace-only key) is hashed
    /// from the raw dictionary key, so those cases cannot collide with each
    /// other or with the empty string.
    static func topicKey(forLegacyTitle rawTitle: String) -> String {
        let normalized = TopicFingerprint.normalized(rawTitle)
        guard normalized.isEmpty else { return TopicFingerprint.key(for: rawTitle) }
        return ContentIdentity.digest("legacy-topic-v1\n" + rawTitle)
    }

    /// Deterministic record ID for one artifact key. Excludes timestamps and
    /// UUIDs so retries target the same file.
    static func recordID(forLegacyTitle rawTitle: String) -> String {
        "legacy-" + ContentIdentity.digest("legacy-import-v1\n" + rawTitle).prefix(32)
    }

    private static func candidateRecords(
        for rawTitle: String,
        in existing: [ResearchRecord]
    ) -> [ResearchRecord] {
        let normalized = TopicFingerprint.normalized(rawTitle)
        let topicKey = topicKey(forLegacyTitle: rawTitle)
        return existing.filter { record in
            guard record.origin == .burst, record.reportVersion == 0 else { return false }
            if record.topicKey == topicKey { return true }
            if normalized.isEmpty {
                // Empty-normalized identities can only be recovered from the
                // preserved raw title.
                return record.seed.title == rawTitle
            }
            return TopicFingerprint.normalized(record.seed.title) == normalized
        }
    }

    // MARK: - Record

    private static func makeRecord(
        recordID: String,
        rawTitle: String,
        research: BurstResearch,
        topicKey: String,
        stateUpdatedAt: Date,
        currentItems: [NewsItem]
    ) -> ResearchRecord {
        let matched = currentItems.first { $0.title == rawTitle }
            ?? currentItems.first {
                TopicFingerprint.normalized($0.title) == TopicFingerprint.normalized(rawTitle)
            }
        let seedURL = matched?.url
            ?? research.sources.first { SecurityPolicies.validateURL($0) != nil }

        let seed = ResearchSeed(
            itemID: matched?.id,
            // Keep the raw artifact key even when it renders as nothing.
            title: rawTitle,
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
            id: recordID,
            topicKey: topicKey,
            origin: .burst,
            topic: displayTitle(rawTitle: rawTitle, summary: research.summary),
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

    /// A title that normalizes to nothing still needs a readable row label.
    /// The stored seed keeps the original key so identity stays recoverable.
    static func displayTitle(rawTitle: String, summary: String) -> String {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !TopicFingerprint.normalized(trimmed).isEmpty { return rawTitle }
        let firstSentence = summary
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { "。！？.!?\n".contains($0) })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !firstSentence.isEmpty {
            return String(firstSentence.prefix(40))
        }
        return L10n.string("research.untitled")
    }
}
