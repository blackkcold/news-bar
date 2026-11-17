import Foundation

/// Stable finalize hook. Stage 4 adds notification/state observers with the same
/// two methods; it must not replace this protocol shape.
@MainActor
protocol ResearchResultObserving: AnyObject {
    /// Called before the coordinator replaces a previous report. Returning
    /// `false` aborts the replacement: the coordinator keeps the previous
    /// report, marks the run failed with a visible error, saves counts, and
    /// skips event ingestion/notifications. Never ignore this result.
    func researchWillOverwrite(
        _ previous: ResearchRecord,
        nextReport: BurstResearch
    ) async -> Bool

    /// Called only after a usable new report actually replaced the old one.
    /// A failed, cancelled, empty or archive-failed run never reaches this
    /// method, so an observer cannot archive a report that was not stored.
    func researchDidFinalize(_ record: ResearchRecord, previous: ResearchRecord) async
}

extension ResearchResultObserving {
    func researchWillOverwrite(
        _ previous: ResearchRecord,
        nextReport: BurstResearch
    ) async -> Bool { true }
}

/// Built-in observer: archives report versions and records the fingerprint the
/// analysis actually consumed. It is always retained by the coordinator, even
/// when stage 4 installs its own observers.
@MainActor
final class WorkspaceReportVersionObserver: ResearchResultObserving {
    static let shared = WorkspaceReportVersionObserver()

    private let store: any WorkspacePersisting
    private let eventStore: any NewsEventPersisting
    private let now: @Sendable () -> Date

    init(
        store: any WorkspacePersisting = WorkspaceSubjectStore.shared,
        eventStore: any NewsEventPersisting = NewsEventStore.shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.eventStore = eventStore
        self.now = now
    }

    func researchWillOverwrite(
        _ previous: ResearchRecord,
        nextReport: BurstResearch
    ) async -> Bool {
        guard let report = previous.report else { return true }
        guard let subject = await resolveSubject(for: previous, at: now()) else {
            return false
        }
        do {
            try await store.appendVersion(
                WorkspaceReportVersion(
                    id: "\(previous.id)#0",
                    recordID: previous.id,
                    subjectID: subject.id,
                    sequence: 0,
                    createdAt: report.generatedAt ?? previous.updatedAt,
                    trigger: previous.run.origin,
                    report: report,
                    digest: WorkspaceReportDigest.make(report)
                )
            )
            return true
        } catch {
            NSLog(
                "[WorkspaceReportVersionObserver] could not archive previous report %@: %@",
                previous.id,
                error.localizedDescription
            )
            return false
        }
    }

    func researchDidFinalize(_ record: ResearchRecord, previous: ResearchRecord) async {
        guard record.status == .ready || record.status == .partial else { return }
        guard let report = record.report else { return }
        guard let subject = await resolveSubject(for: record, at: now()) else { return }

        let finishedAt = record.run.finishedAt ?? record.updatedAt
        let startedAt = record.run.startedAt ?? previous.run.startedAt ?? finishedAt
        let event = await linkedEvent(for: subject)
        let updates = await store.updates(subjectID: subject.id)
        let fingerprint = WorkspaceEvidenceFingerprint.make(
            event: event,
            research: record,
            updates: updates,
            asOf: startedAt
        )

        let digest = WorkspaceReportDigest.make(report)
        do {
            try await store.appendVersion(
                WorkspaceReportVersion(
                    id: "\(record.id)#0",
                    recordID: record.id,
                    subjectID: subject.id,
                    sequence: 0,
                    createdAt: report.generatedAt ?? record.updatedAt,
                    trigger: record.run.origin,
                    report: report,
                    digest: digest,
                    evidenceFingerprint: fingerprint,
                    analysisSignature: await store.reportState(recordID: record.id)?.signature
                )
            )
        } catch {
            NSLog(
                "[WorkspaceReportVersionObserver] could not archive report %@: %@",
                record.id,
                error.localizedDescription
            )
        }

        let versions = await store.versions(recordID: record.id)
        let versionID = versions.last(where: { $0.digest == digest })?.id
        let state = WorkspaceReportState(
            recordID: record.id,
            subjectID: subject.id,
            status: .analyzed,
            signature: await store.reportState(recordID: record.id)?.signature,
            analyzedFingerprint: fingerprint,
            versionID: versionID,
            recordedAt: finishedAt
        )
        try? await store.saveReportState(state)

        let stale = Set(
            updates
                .filter { $0.discoveredAt <= startedAt }
                .map(\.id)
        )
        let newer = updates.filter { $0.discoveredAt > startedAt }
        _ = try? await store.updateSubject(id: subject.id) { latest in
            latest.pendingUpdateIDs.removeAll { stale.contains($0) }
            if !newer.isEmpty {
                latest.pendingUpdateIDs = Array(
                    Set(latest.pendingUpdateIDs + newer.map(\.id))
                ).sorted()
            }
            if record.status == .ready {
                if latest.pendingUpdateIDs.isEmpty {
                    latest.updateState = event?.hasConflict == true ? .needsReview : .current
                } else {
                    latest.updateState = .needsReview
                }
            } else if !latest.pendingUpdateIDs.isEmpty {
                latest.updateState = .needsReview
            }
            latest.markActivity(at: finishedAt)
        }
    }

    private func resolveSubject(
        for record: ResearchRecord,
        at date: Date
    ) async -> WorkspaceSubject? {
        if let existing = await store.subject(containingResearchID: record.id) {
            return existing
        }
        let title = record.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        do {
            var created = try await store.createSubject(
                title: title,
                aliases: record.aliases,
                isFollowed: false,
                now: date
            )
            created = try await store.updateSubject(id: created.id) { latest in
                latest.link(
                    researchID: record.id,
                    title: record.topic,
                    aliases: record.aliases
                )
            }
            return created
        } catch {
            return nil
        }
    }

    private func linkedEvent(for subject: WorkspaceSubject) async -> NewsEvent? {
        guard !subject.eventIDs.isEmpty else { return nil }
        let events = (try? await eventStore.events()) ?? []
        return events
            .filter { subject.eventIDs.contains($0.id) }
            .max { $0.lastEvidenceAt < $1.lastEvidenceAt }
    }
}
