import Foundation

/// Deterministic subject linking and lead collection. It never starts research,
/// never enables AI/search, never follows a subject and never creates a second
/// event from an RSS lead.
@MainActor
final class WorkspaceAutoDiscovery {
    static let shared = WorkspaceAutoDiscovery()

    private let store: any WorkspacePersisting
    private let researchStore: any ResearchPersisting
    private let eventStore: any NewsEventPersisting
    private let reconciler: WorkspaceReconciler
    private let matcher: WorkspaceLeadMatcher
    private let now: @Sendable () -> Date

    init(
        store: any WorkspacePersisting = WorkspaceSubjectStore.shared,
        researchStore: any ResearchPersisting = ResearchStore.shared,
        eventStore: any NewsEventPersisting = NewsEventStore.shared,
        reconciler: WorkspaceReconciler = WorkspaceReconciler(),
        matcher: WorkspaceLeadMatcher = WorkspaceLeadMatcher(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.researchStore = researchStore
        self.eventStore = eventStore
        self.reconciler = reconciler
        self.matcher = matcher
        self.now = now
    }

    // MARK: - Full reconcile

    @discardableResult
    func fullReconcile(now moment: Date) async -> WorkspaceReconcileResult {
        let bootstrap = await store.bootstrap()
        let research = await researchStore.index()
        let events = (try? await eventStore.events()) ?? []
        let existing = await store.subjects()

        let result = reconciler.reconcile(
            research: research,
            events: events,
            existing: existing,
            now: moment,
            evidenceURLsByRecordID: await evidenceURLsByRecordID(research)
        )

        if !bootstrap.readOnly {
            let changed = !result.changedIDs.isEmpty
                || !result.createdIDs.isEmpty
                || result.subjects.count != existing.count
            if changed {
                do {
                    try await store.saveAll(result.subjects)
                } catch {
                    NSLog(
                        "[WorkspaceAutoDiscovery] reconcile could not be saved: %@",
                        error.localizedDescription
                    )
                }
            }
        }
        return result
    }

    /// Strict joins need the report's evidence URLs; the index only carries the
    /// seed URL. Loading the record is read-only and never rewrites it.
    private func evidenceURLsByRecordID(
        _ research: [ResearchIndexEntry]
    ) async -> [String: Set<String>] {
        var urls: [String: Set<String>] = [:]
        for entry in research where entry.hasReport || entry.seedURL != nil {
            var recordURLs: Set<String> = []
            if let seed = entry.seedURL, !seed.isEmpty {
                recordURLs.insert(ContentIdentity.canonicalURL(seed))
            }
            if entry.hasReport,
               let record = await researchStore.record(id: entry.id),
               record.loadIssue == nil,
               record.status != .corrupt {
                for item in record.report?.evidence ?? [] {
                    recordURLs.insert(ContentIdentity.canonicalURL(item.canonicalURL))
                }
            }
            if !recordURLs.isEmpty {
                urls[entry.id] = recordURLs
            }
        }
        return urls
    }

    // MARK: - New research

    /// Links one finalized record to a subject. It does not follow the subject
    /// and does not mark anything read.
    @discardableResult
    func ingestResearch(recordID: String, now moment: Date) async -> String? {
        guard let record = await researchStore.record(id: recordID),
              record.loadIssue == nil,
              record.status != .corrupt else { return nil }

        let result = await fullReconcile(now: moment)
        if let subject = result.subjects.first(where: { $0.contains(recordID: record.id) }) {
            await touch(subject, at: record.updatedAt)
            return subject.id
        }

        // Reconciliation should have created this link from the index. If the
        // index is stale, create the link directly without changing follow state.
        let bootstrap = await store.bootstrap()
        guard !bootstrap.readOnly else { return nil }
        do {
            var subject = try await store.createSubject(
                title: record.topic,
                aliases: record.aliases,
                isFollowed: false,
                now: moment
            )
            subject = try await store.updateSubject(id: subject.id) { latest in
                latest.link(
                    researchID: record.id,
                    title: record.topic,
                    aliases: record.aliases
                )
                latest.markActivity(at: record.updatedAt)
            }
            return subject.id
        } catch {
            NSLog(
                "[WorkspaceAutoDiscovery] could not link research %@: %@",
                recordID,
                error.localizedDescription
            )
            return nil
        }
    }

    // MARK: - Events

    /// Links event deltas and marks a linked ready report for review when the
    /// new evidence is newer than that report. Never starts research.
    @discardableResult
    func ingestEvents(now moment: Date) async -> Set<String> {
        let result = await fullReconcile(now: moment)
        let events = (try? await eventStore.events()) ?? []
        let eventsByID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var linked: Set<String> = []

        for subject in result.subjects {
            let linkedEvents = subject.eventIDs.compactMap { eventsByID[$0] }
            guard !linkedEvents.isEmpty else { continue }
            linked.formUnion(linkedEvents.map(\.id))
            guard !subject.isArchived else { continue }
            guard let latestEvent = linkedEvents.max(by: {
                $0.lastEvidenceAt < $1.lastEvidenceAt
            }) else { continue }
            guard let record = await latestRecord(for: subject),
                  let report = record.report,
                  record.status == .ready || record.status == .partial else { continue }
            let reportDate = report.generatedAt ?? record.updatedAt
            let eventDate = latestEvent.lastEvidenceAt
            guard eventDate > reportDate else { continue }

            _ = try? await store.updateSubject(id: subject.id) { latest in
                latest.updateState = .needsReview
                latest.markActivity(at: eventDate)
            }
        }
        return linked
    }

    // MARK: - RSS leads during the normal refresh

    /// Matches already-fetched RSS items against followed, non-archived topics.
    /// This is called from the existing refresh pipeline: it performs no
    /// network request, starts no timer and creates no subject.
    func ingestRSSItems(_ items: [NewsItem], now moment: Date) async {
        guard !items.isEmpty else { return }
        let bootstrap = await store.bootstrap()
        guard !bootstrap.readOnly else { return }

        let subjects = await store.subjects().filter {
            $0.isFollowed && !$0.isArchived && $0.kind != .event
        }
        guard !subjects.isEmpty else { return }

        for subject in subjects {
            let existing = Set(await store.updates(subjectID: subject.id).map(\.id))
            let seed = subject.seedURL.map(ContentIdentity.canonicalURL)
            let aliases = [subject.title] + subject.aliases
            var seen = existing
            var candidates: [WorkspaceUpdateCandidate] = []

            for item in items {
                let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let url = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, !url.isEmpty else { continue }
                let canonical = ContentIdentity.canonicalURL(url)
                if let seed, canonical == seed { continue }
                guard matcher.matches(title: title, summary: "", aliases: aliases) else {
                    continue
                }
                let id = WorkspaceUpdateCandidate.identity(subjectID: subject.id, url: url)
                guard seen.insert(id).inserted else { continue }
                candidates.append(
                    WorkspaceUpdateCandidate(
                        id: id,
                        subjectID: subject.id,
                        title: title,
                        url: url,
                        sourceName: item.source.displayName,
                        publishedAt: item.publishedAt,
                        discoveredAt: moment,
                        origin: .rss
                    )
                )
            }

            guard !candidates.isEmpty else { continue }
            do {
                try await store.saveUpdates(candidates, for: subject.id)
                await markReviewIfNeeded(
                    subjectID: subject.id,
                    candidates: candidates,
                    now: moment
                )
            } catch {
                NSLog(
                    "[WorkspaceAutoDiscovery] could not save RSS leads for %@: %@",
                    subject.id,
                    error.localizedDescription
                )
            }
        }
    }

    // MARK: - Update candidates from event/research deltas

    func applyUpdateCandidates(
        _ candidates: [WorkspaceUpdateCandidate],
        subjectID: String,
        now moment: Date
    ) async {
        guard !candidates.isEmpty else { return }
        do {
            try await store.saveUpdates(candidates, for: subjectID)
        } catch {
            NSLog(
                "[WorkspaceAutoDiscovery] could not save update candidates for %@: %@",
                subjectID,
                error.localizedDescription
            )
        }
        guard let subject = await store.subject(id: subjectID), !subject.isArchived else {
            return
        }
        guard let record = await latestRecord(for: subject),
              let report = record.report,
              record.status == .ready || record.status == .partial else { return }
        let reportDate = report.generatedAt ?? record.updatedAt
        let analyzedURLs = Set(
            report.evidence.map { ContentIdentity.canonicalURL($0.canonicalURL) }
        )
        let newer = candidates.filter { candidate in
            let canonical = ContentIdentity.canonicalURL(candidate.url)
            guard !analyzedURLs.contains(canonical) else { return false }
            return (candidate.publishedAt ?? candidate.discoveredAt) > reportDate
        }
        guard !newer.isEmpty else { return }
        _ = try? await store.updateSubject(id: subjectID) { latest in
            latest.updateState = .needsReview
            latest.pendingUpdateIDs = Array(
                Set(latest.pendingUpdateIDs + newer.map(\.id))
            ).sorted()
            latest.markActivity(at: moment)
        }
    }

    // MARK: - Helpers

    private func markReviewIfNeeded(
        subjectID: String,
        candidates: [WorkspaceUpdateCandidate],
        now moment: Date
    ) async {
        guard !candidates.isEmpty,
              let subject = await store.subject(id: subjectID),
              !subject.isArchived,
              let record = await latestRecord(for: subject),
              let report = record.report,
              record.status == .ready || record.status == .partial else { return }
        let reportDate = report.generatedAt ?? record.updatedAt
        let analyzedURLs = Set(
            report.evidence.map { ContentIdentity.canonicalURL($0.canonicalURL) }
        )
        let newer = candidates.filter { candidate in
            let canonical = ContentIdentity.canonicalURL(candidate.url)
            guard !analyzedURLs.contains(canonical) else { return false }
            return (candidate.publishedAt ?? candidate.discoveredAt) > reportDate
        }
        guard !newer.isEmpty else { return }
        try? await store.updateSubject(id: subjectID) { latest in
            guard !latest.isArchived else { return }
            latest.updateState = .needsReview
            latest.pendingUpdateIDs = Array(
                Set(latest.pendingUpdateIDs + newer.map(\.id))
            ).sorted()
            latest.markActivity(at: moment)
        }
    }

    private func touch(_ subject: WorkspaceSubject, at date: Date) async {
        _ = try? await store.updateSubject(id: subject.id) { latest in
            latest.markActivity(at: date)
        }
    }

    private func latestRecord(for subject: WorkspaceSubject) async -> ResearchRecord? {
        var records: [ResearchRecord] = []
        for id in subject.researchRecordIDs {
            if let record = await researchStore.record(id: id),
               record.loadIssue == nil,
               record.status != .corrupt {
                records.append(record)
            }
        }
        return records.max { $0.updatedAt < $1.updatedAt }
    }
}
