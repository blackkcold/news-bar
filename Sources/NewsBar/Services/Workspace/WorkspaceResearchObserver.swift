import Foundation

/// Stage-4 state observer. The report version and pending-update state are
/// already owned by `WorkspaceReportVersionObserver`; this observer only links
/// the finalized record to a subject and refreshes activity.
@MainActor
final class WorkspaceResearchObserver: ResearchResultObserving {
    static let shared = WorkspaceResearchObserver()

    private let discovery: WorkspaceAutoDiscovery
    private let store: any WorkspacePersisting
    private let now: @Sendable () -> Date

    init(
        discovery: WorkspaceAutoDiscovery? = nil,
        store: any WorkspacePersisting = WorkspaceSubjectStore.shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.discovery = discovery ?? .shared
        self.store = store
        self.now = now
    }

    func researchWillOverwrite(
        _ previous: ResearchRecord,
        nextReport: BurstResearch
    ) async -> Bool {
        // Archiving is the built-in version observer's job. Never append a
        // second version here and never block a report this observer cannot
        // archive itself.
        true
    }

    func researchDidFinalize(_ record: ResearchRecord, previous: ResearchRecord) async {
        guard let subjectID = await discovery.ingestResearch(
            recordID: record.id,
            now: now()
        ) else { return }
        _ = try? await store.updateSubject(id: subjectID) { latest in
            latest.markActivity(at: record.run.finishedAt ?? record.updatedAt)
        }
    }
}
