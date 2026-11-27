import Foundation

/// Builds the real research hooks for the command bridge.
///
/// The bridge itself only knows the two closures it needs; this file is the one
/// place that connects them to the production path (record provisioning →
/// launcher → coordinator → `executeResearch`). Keeping it separate means a
/// test can drive the bridge with a stub, and the app has exactly one wiring.
@MainActor
enum ResearchAgentHooksFactory {
    static func production(
        settings: AppSettings,
        orchestrator: NewsOrchestrator,
        researchStore: any ResearchPersisting = ResearchStore.shared
    ) -> ResearchAgentHooks {
        ResearchAgentHooks(
            start: { topic, depth in
                await start(
                    topic: topic,
                    depth: depth,
                    settings: settings,
                    orchestrator: orchestrator,
                    researchStore: researchStore
                )
            },
            snapshot: { recordID, topic in
                await snapshot(
                    recordID: recordID,
                    topic: topic,
                    researchStore: researchStore
                )
            }
        )
    }

    /// Provisions or reuses the record for `topic`, then schedules it.
    ///
    /// `forceRefresh` and `allowsIncremental: false` are deliberate: a CLI run
    /// is a measurement of a full pass, and an incremental run against an older
    /// report would silently produce a different shape of result.
    private static func start(
        topic: String,
        depth: ResearchDepth,
        settings: AppSettings,
        orchestrator: NewsOrchestrator,
        researchStore: any ResearchPersisting
    ) async -> ResearchAgentStartResult {
        // An explicit request is not an unlimited one. The CLI can call this in
        // a loop, and each pass spends real search and AI budget, so the queue
        // is bounded the same way automatic runs are.
        guard ResearchAutomationPolicy.allowsManualAdmission(
            activeManualRuns: ResearchCoordinator.shared.activeManualRunCount()
        ) else {
            return .queueFull
        }

        // Manual origin: an agent-requested run is an explicit request, so it
        // keeps the manual provider route, the manual budget line and its own
        // daily task accounting rather than competing with automatic picks.
        guard let record = await ResearchRecordProvisioner.ensureTopicRecord(
            title: topic,
            seed: nil,
            origin: .manual,
            store: researchStore
        ) else { return .unavailable }

        if ResearchCoordinator.shared.isRunning(recordID: record.id) {
            return .alreadyActive(recordID: record.id)
        }

        let launcher = WorkspaceResearchLauncher(
            settings: settings,
            researchStore: researchStore,
            coordinator: .shared,
            executor: WorkspaceResearchLauncher.productionExecutor(
                orchestrator: orchestrator,
                settings: settings
            )
        )
        let request = WorkspaceResearchRequest(
            subjectID: "",
            depth: depth,
            trigger: .manual,
            forceRefresh: true,
            notify: false,
            recordID: record.id,
            allowReuse: false,
            allowsIncremental: false
        )
        switch await launcher.start(recordID: record.id, request: request) {
        case .started, .focusedRunning:
            return .started(recordID: record.id, topic: record.topic, depth: depth)
        case .reused:
            return .alreadyActive(recordID: record.id)
        case .failed(.alreadyActive):
            return .alreadyActive(recordID: record.id)
        case .failed(.persistenceFailed):
            return .persistenceFailed
        case .failed:
            return .unavailable
        }
    }

    private static func snapshot(
        recordID: String?,
        topic: String?,
        researchStore: any ResearchPersisting
    ) async -> ResearchAgentSnapshot? {
        let record: ResearchRecord?
        if let recordID, !recordID.isEmpty {
            record = await researchStore.record(id: recordID)
        } else if let topic, !topic.isEmpty {
            record = await researchStore.latestRecord(
                topicKey: TopicFingerprint.key(for: topic)
            )
        } else {
            record = nil
        }
        guard let record, record.loadIssue == nil else { return nil }

        let report = record.report
        return ResearchAgentSnapshot(
            recordID: record.id,
            topic: record.topic,
            depth: record.run.depth,
            status: record.status,
            phase: record.run.phase,
            summary: report?.summary ?? "",
            evidenceCount: report?.evidence.count ?? 0,
            timelineCount: report?.timeline.count ?? 0,
            commentaryCount: report?.commentary.count ?? 0,
            verdict: report?.verification?.verdict,
            verdictStrength: report?.verification?.strength,
            searchCalls: record.run.searchCalls,
            aiCalls: record.run.aiCalls,
            pagesRead: record.run.pagesRead,
            queries: report?.method?.queries ?? [],
            limitations: report?.limitations ?? "",
            lastError: record.run.lastError,
            isPartial: record.status == .partial,
            generatedAt: report?.generatedAt
        )
    }
}
