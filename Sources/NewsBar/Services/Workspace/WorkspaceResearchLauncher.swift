import Foundation

/// The single start/update entry for the workspace, reader, popover and quick
/// search. It resolves the linked record, coalesces concurrent calls per
/// subject and hands the actual work to `ResearchCoordinator`.
@MainActor
final class WorkspaceResearchLauncher {
    private static var inFlight: [String: Task<WorkspaceResearchAction, Never>] = [:]

    private let settings: AppSettings
    private let store: any WorkspacePersisting
    private let researchStore: any ResearchPersisting
    private let eventStore: any NewsEventPersisting
    private let coordinator: ResearchCoordinator
    private let executor: WorkspaceResearchExecutor
    private let now: @Sendable () -> Date

    init(
        settings: AppSettings,
        store: any WorkspacePersisting = WorkspaceSubjectStore.shared,
        researchStore: any ResearchPersisting = ResearchStore.shared,
        eventStore: any NewsEventPersisting = NewsEventStore.shared,
        coordinator: ResearchCoordinator? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        executor: @escaping WorkspaceResearchExecutor
    ) {
        self.settings = settings
        self.store = store
        self.researchStore = researchStore
        self.eventStore = eventStore
        self.coordinator = coordinator ?? .shared
        self.now = now
        self.executor = executor
    }

    /// Production wiring for stage 3. The launcher writes the requested depth
    /// onto `record.run.depth`; this executor passes it explicitly so a
    /// workspace request never falls back to `settings.researchDepth`.
    static func productionExecutor(
        orchestrator: NewsOrchestrator,
        settings: AppSettings
    ) -> WorkspaceResearchExecutor {
        { record, progress in
            await orchestrator.executeResearch(
                record: record,
                settings: settings,
                depth: record.run.depth,
                progress: progress
            )
        }
    }

    func start(_ request: WorkspaceResearchRequest) async -> WorkspaceResearchAction {
        if let existing = Self.inFlight[request.subjectID] {
            return await existing.value
        }
        let task = Task { @MainActor [weak self] () -> WorkspaceResearchAction in
            guard let self else { return .failed(.unavailable) }
            defer { Self.inFlight.removeValue(forKey: request.subjectID) }
            return await self.perform(request)
        }
        Self.inFlight[request.subjectID] = task
        return await task.value
    }

    /// Entry for the legacy automatic/keyword paths. They already provisioned a
    /// record; this resolves or creates its subject (never followed) and then
    /// uses the same in-flight/schedule path as the workspace.
    func start(recordID: String, request template: WorkspaceResearchRequest) async -> WorkspaceResearchAction {
        let subjectID: String
        if let subject = await store.subject(containingResearchID: recordID) {
            subjectID = subject.id
        } else {
            guard let record = await researchStore.record(id: recordID),
                  record.loadIssue == nil,
                  record.status != .corrupt else { return .failed(.unavailable) }
            do {
                var subject = try await store.createSubject(
                    title: record.topic,
                    aliases: record.aliases,
                    isFollowed: false,
                    now: now()
                )
                subject.link(
                    researchID: record.id,
                    title: record.topic,
                    aliases: record.aliases
                )
                subject.markActivity(at: record.updatedAt)
                let createdID = subject.id
                _ = try await store.updateSubject(id: createdID) { latest in
                    latest.link(
                        researchID: record.id,
                        title: record.topic,
                        aliases: record.aliases
                    )
                    latest.markActivity(at: record.updatedAt)
                }
                subjectID = createdID
            } catch {
                return .failed(.persistenceFailed)
            }
        }
        var request = template
        request.subjectID = subjectID
        request.recordID = recordID
        return await start(request)
    }

    /// Same gate as `start`, without side effects. The UI shows the hint only
    /// when this returns a value.
    func reusePreview(
        subjectID: String,
        depth: ResearchDepth
    ) async -> WorkspaceReusePreview? {
        guard let subject = await store.subject(id: subjectID),
              let record = await resolveExistingRecord(for: subject),
              let report = record.report,
              let generatedAt = report.generatedAt,
              record.status == .ready else { return nil }
        let event = await latestLinkedEvent(for: subject)
        let updates = await store.updates(subjectID: subject.id)
        let state = await store.reportState(recordID: record.id)
        let signature = makeSignature(
            subjectID: subject.id,
            depth: depth,
            settings: settings
        )
        let currentFingerprint = WorkspaceEvidenceFingerprint.make(
            event: event,
            research: record,
            updates: updates
        )
        let analysisDate = state?.recordedAt
        let hasUnanalyzedUpdate = updates.contains { candidate in
            guard let analysisDate else { return true }
            return candidate.discoveredAt > analysisDate
                || (candidate.publishedAt ?? .distantPast) > analysisDate
        }
        let age = now().timeIntervalSince(generatedAt)
        guard state?.status == .analyzed,
              state?.analyzedFingerprint == currentFingerprint,
              state?.signature == signature,
              !hasUnanalyzedUpdate,
              age <= Self.reuseAgeLimit(for: settings) else { return nil }
        return WorkspaceReusePreview(
            recordID: record.id,
            generatedAt: generatedAt,
            age: age,
            reason: age < 24 * 3_600 ? .freshReport : .unchangedEvidence
        )
    }

    private func resolveExistingRecord(for subject: WorkspaceSubject) async -> ResearchRecord? {
        var linked: [ResearchRecord] = []
        for id in subject.researchRecordIDs {
            if let record = await researchStore.record(id: id),
               record.loadIssue == nil,
               record.status != .corrupt {
                linked.append(record)
            }
        }
        if let latest = linked.max(by: { $0.updatedAt < $1.updatedAt }) {
            return latest
        }
        return await researchStore.latestRecord(topicKey: TopicFingerprint.key(for: subject.title))
    }

    private func perform(_ request: WorkspaceResearchRequest) async -> WorkspaceResearchAction {        guard let subject = await store.subject(id: request.subjectID) else {
            return .failed(.subjectMissing)
        }
        let moment = now()

        guard let record = await resolveRecord(for: subject, request: request, now: moment) else {
            return .failed(.unavailable)
        }

        if coordinator.isRunning(recordID: record.id) {
            return .focusedRunning(recordID: record.id)
        }

        let event = await latestLinkedEvent(for: subject)
        let updates = await store.updates(subjectID: subject.id)
        let state = await store.reportState(recordID: record.id)
        let signature = makeSignature(
            subjectID: subject.id,
            depth: request.depth,
            settings: settings
        )
        let currentFingerprint = WorkspaceEvidenceFingerprint.make(
            event: event,
            research: record,
            updates: updates
        )
        let analysisDate = state?.recordedAt
        let hasUnanalyzedUpdate = updates.contains { candidate in
            guard let analysisDate else { return true }
            return candidate.discoveredAt > analysisDate
                || (candidate.publishedAt ?? .distantPast) > analysisDate
        }
        let reportAge = record.report
            .flatMap { $0.generatedAt }
            .map { moment.timeIntervalSince($0) }
            ?? moment.timeIntervalSince(record.updatedAt)
        let maxReuseAge = Self.reuseAgeLimit(for: settings)

        if request.allowReuse,
           !request.forceRefresh,
           record.report != nil,
           record.status == .ready,
           state?.status == .analyzed,
           state?.analyzedFingerprint == currentFingerprint,
           state?.signature == signature,
           !hasUnanalyzedUpdate,
           reportAge <= maxReuseAge {
            return .reused(
                recordID: record.id,
                reason: reportAge < 24 * 3_600 ? .freshReport : .unchangedEvidence
            )
        }

        // Lazy first version for a linked legacy record that predates the
        // version layer. It never rewrites the research record file.
        if record.report != nil {
            try? await store.ensureBaselineVersion(
                record: record,
                subjectID: subject.id,
                at: record.updatedAt
            )
        }

        // Record what this run is about to analyse. The fingerprint stays nil
        // until the observer archives the finished report; the reuse check
        // above only trusts `.analyzed` state.
        let pendingState = WorkspaceReportState(
            recordID: record.id,
            subjectID: subject.id,
            status: .pending,
            signature: signature,
            analyzedFingerprint: nil,
            versionID: nil,
            recordedAt: nil
        )
        do {
            try await store.saveReportState(pendingState)
        } catch {
            return .failed(.persistenceFailed)
        }

        var scheduled = record
        scheduled.run.depth = request.depth
        do {
            try await researchStore.save(scheduled)
        } catch {
            return .failed(.persistenceFailed)
        }

        let incremental = (request.forceRefresh || !request.allowsIncremental)
            ? nil
            : makeIncrementalContext(
                report: record.report,
                event: event,
                updates: updates,
                signature: signature
            )
        if let incremental {
            await ResearchIncrementalContextStore.shared.put(
                incremental,
                recordID: record.id
            )
        } else {
            await ResearchIncrementalContextStore.shared.discard(recordID: record.id)
        }
        await ResearchIncrementalContextStore.shared.putDepth(
            request.depth,
            recordID: record.id
        )
        await ResearchIncrementalContextStore.shared.putForceRefresh(
            request.forceRefresh,
            recordID: record.id
        )

        let outcome = await coordinator.schedule(
            recordID: record.id,
            notify: request.notify,
            trigger: request.trigger,
            executor: executor
        )
        switch outcome {
        case .accepted:
            return .started(recordID: record.id)
        case .alreadyActive:
            await ResearchIncrementalContextStore.shared.discard(recordID: record.id)
            return .focusedRunning(recordID: record.id)
        case .persistenceFailed:
            await ResearchIncrementalContextStore.shared.discard(recordID: record.id)
            return .failed(.persistenceFailed)
        case .admissionDenied, .queueFull, .unavailable:
            await ResearchIncrementalContextStore.shared.discard(recordID: record.id)
            return .failed(.unavailable)
        }
    }

    // MARK: - Record resolution

    private func resolveRecord(
        for subject: WorkspaceSubject,
        request: WorkspaceResearchRequest,
        now: Date
    ) async -> ResearchRecord? {
        if let recordID = request.recordID {
            guard let record = await researchStore.record(id: recordID),
                  record.loadIssue == nil,
                  record.status != .corrupt else { return nil }
            await link(record, to: subject)
            return record
        }

        var linked: [ResearchRecord] = []
        for id in subject.researchRecordIDs {
            if let record = await researchStore.record(id: id),
               record.loadIssue == nil,
               record.status != .corrupt {
                linked.append(record)
            }
        }
        if let latest = linked.max(by: { $0.updatedAt < $1.updatedAt }) {
            return latest
        }

        let topicKey = TopicFingerprint.key(for: subject.title)
        if let existing = await researchStore.latestRecord(topicKey: topicKey) {
            await link(existing, to: subject)
            return existing
        }

        let event = await latestLinkedEvent(for: subject)
        let recordSeed = makeSeed(subject: subject, event: event, seed: request.seed)
        guard let created = await ResearchRecordProvisioner.ensureTopicRecord(
            title: subject.title,
            seed: recordSeed,
            origin: request.trigger,
            store: researchStore,
            now: now
        ) else { return nil }
        await link(created, to: subject)
        return created
    }

    private func link(_ record: ResearchRecord, to subject: WorkspaceSubject) async {
        guard !subject.contains(recordID: record.id) else { return }
        _ = try? await store.updateSubject(id: subject.id) { latest in
            latest.link(
                researchID: record.id,
                title: record.topic,
                aliases: record.aliases
            )
            latest.markActivity(at: record.updatedAt)
        }
    }

    private func makeSeed(
        subject: WorkspaceSubject,
        event: NewsEvent?,
        seed: ResearchSeed?
    ) -> ResearchSeed? {
        if let seed { return seed }
        let title = subject.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        // A URL the user supplied on the topic is a real seed. It is not a
        // citation: the pipeline still has to read and verify the page.
        if let raw = subject.seedURL,
           let url = ReaderNavigationPolicy.allowedURL(raw) {
            let host = url.host ?? ""
            return ResearchSeed(
                itemID: nil,
                title: title,
                url: url.absoluteString,
                source: .rss(name: host.isEmpty ? title : host, url: url.absoluteString),
                publishedAt: nil,
                initialSummary: ""
            )
        }
        let candidates = (event?.evidence ?? []).sorted(by: {
            ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast)
        })
        guard let evidence = candidates.first else { return nil }
        return ResearchSeed(
            itemID: nil,
            title: title,
            url: evidence.url,
            source: .rss(
                name: evidence.sourceName,
                url: evidence.sourceID ?? ""
            ),
            publishedAt: evidence.publishedAt,
            initialSummary: evidence.excerpt
        )
    }

    private func latestLinkedEvent(for subject: WorkspaceSubject) async -> NewsEvent? {
        guard !subject.eventIDs.isEmpty else { return nil }
        let events = (try? await eventStore.events()) ?? []
        return events
            .filter { subject.eventIDs.contains($0.id) }
            .max { $0.lastEvidenceAt < $1.lastEvidenceAt }
    }

    // MARK: - Signatures and incremental materials

    /// A report may be reused only inside a conservative freshness window. The
    /// cap is derived from the configured recency and never exceeds 24 hours.
    static func reuseAgeLimit(for settings: AppSettings) -> TimeInterval {
        let day: TimeInterval = 24 * 3_600
        switch settings.researchDefaultRecency {
        case .auto:
            return 12 * 3_600
        case .all:
            return day
        case .week, .month, .quarter, .year:
            let days = settings.researchDefaultRecency.explicit?.days ?? 1
            return min(day, max(3_600, Double(days) * 3_600))
        }
    }

    private func makeSignature(
        subjectID: String,
        depth: ResearchDepth,
        settings: AppSettings
    ) -> ResearchReuseSignature {
        let endpointIdentity = settings.resolvedAIConnection.credentialEndpointIdentity
        return ResearchReuseSignature(
            subjectID: subjectID,
            depth: depth,
            provider: settings.aiProvider,
            model: settings.aiModel,
            promptVersion: ResearchPrompts.version,
            recency: settings.researchDefaultRecency.rawValue,
            endpointIdentity: endpointIdentity,
            providerIdentity: settings.aiProvider + "|" + endpointIdentity
        )
    }

    private func makeIncrementalContext(
        report: BurstResearch?,
        event: NewsEvent?,
        updates: [WorkspaceUpdateCandidate],
        signature: ResearchReuseSignature
    ) -> ResearchIncrementalContext? {
        guard let report else { return nil }
        let knownURLs = Set(report.evidence.map(\.canonicalURL))
        let reportDate = report.generatedAt ?? .distantPast
        var materials: [String: ResearchMaterial] = [:]

        for update in updates {
            let canonical = ContentIdentity.canonicalURL(update.url)
            guard !knownURLs.contains(canonical) else { continue }
            materials[canonical] = ResearchMaterial(
                url: update.url,
                title: update.title,
                snippet: "",
                publishedAt: update.publishedAt,
                sourceName: update.sourceName
            )
        }

        for evidence in event?.evidence ?? [] {
            let canonical = ContentIdentity.canonicalURL(evidence.url)
            guard !knownURLs.contains(canonical) else { continue }
            let isNew = evidence.fetchedAt > reportDate
                || (evidence.publishedAt ?? .distantPast) > reportDate
            guard isNew else { continue }
            if materials[canonical] == nil {
                materials[canonical] = ResearchMaterial(
                    url: evidence.url,
                    title: evidence.title,
                    snippet: evidence.excerpt,
                    publishedAt: evidence.publishedAt,
                    sourceName: evidence.sourceName
                )
            }
        }

        guard !materials.isEmpty else { return nil }
        return ResearchIncrementalContext(
            priorReport: report,
            newMaterials: materials.values.sorted { $0.canonicalURL < $1.canonicalURL },
            signature: signature
        )
    }
}
