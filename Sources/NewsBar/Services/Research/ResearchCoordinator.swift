import Foundation

/// Result of one research pass, independent of how it was produced. P1 uses
/// the existing single-pass `BurstResearchService`; P2 will swap the executor
/// without touching the coordinator or the record state machine.
struct ResearchExecution: Sendable {
    let research: BurstResearch
    let error: String?
    let pagesRead: Int
    let searchCalls: Int
    let aiCalls: Int
    let queries: [String]
    /// True when the pipeline stopped early (truncation, budget, search/page
    /// failure) but still produced a usable report.
    var isPartial: Bool = false

    static func failure(_ message: String) -> ResearchExecution {
        ResearchExecution(
            research: BurstResearch(),
            error: message,
            pagesRead: 0,
            searchCalls: 0,
            aiCalls: 0,
            queries: []
        )
    }
}

extension Notification.Name {
    /// Posted whenever a record file or its index projection changes.
    static let researchRecordsChanged = Notification.Name("researchRecordsChanged")
}

/// Serializes research tasks and owns their status transitions. The heavy
/// network work stays in the injected executor; this type only decides who
/// runs, when, and what gets persisted. MainActor keeps `AppSettings` and the
/// orchestrator access safe; a shared instance outlives any one window.
@MainActor
final class ResearchCoordinator {
    typealias Executor = @MainActor (
        ResearchRecord,
        @escaping @Sendable (ResearchRun) async -> Void
    ) async -> ResearchExecution

    static let shared = ResearchCoordinator()

    private struct Job {
        let token: UUID
        let recordID: String
        let notify: Bool
        let executor: Executor
    }

    private struct RunningJob {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let store: any ResearchPersisting
    private var maxConcurrent: Int
    private let notifier: @MainActor (ResearchRecord) -> Void
    private var running: [String: RunningJob] = [:]
    private var queue: [Job] = []
    /// Bumped by `cancelAll` so a task that is already past the executor
    /// cannot write a record back after a history reset.
    private var generation = 0

    init(
        store: any ResearchPersisting = ResearchStore.shared,
        maxConcurrent: Int = 1,
        notifier: @escaping @MainActor (ResearchRecord) -> Void = {
            NotificationService.sendResearchNotification(record: $0)
        }
    ) {
        self.store = store
        self.maxConcurrent = max(1, maxConcurrent)
        self.notifier = notifier
    }

    /// Applies the user's concurrency setting; queued jobs start immediately if
    /// the new ceiling allows it.
    func setMaxConcurrent(_ value: Int) {
        maxConcurrent = max(1, min(3, value))
        startNextIfPossible()
    }

    func schedule(recordID: String, notify: Bool = true, executor: @escaping Executor) async {
        guard running[recordID] == nil,
              !queue.contains(where: { $0.recordID == recordID }) else { return }
        guard let record = await store.record(id: recordID) else { return }
        guard record.status != .running else { return }

        // Re-check after the awaits: two callers can both pass the first guard
        // while waiting for the store, and the second must not enqueue a
        // duplicate job for the same record.
        guard running[recordID] == nil,
              !queue.contains(where: { $0.recordID == recordID }) else { return }

        let job = Job(token: UUID(), recordID: recordID, notify: notify, executor: executor)
        if running.count < maxConcurrent {
            start(job)
        } else {
            var queued = record
            queued.status = .queued
            queued.run.phase = .idle
            try? await store.save(queued)
            postChanged()
            queue.append(job)
        }
    }

    func cancel(recordID: String) {
        queue.removeAll { $0.recordID == recordID }
        // Keep the slot until `execute` returns; removing it here would let a
        // new job start while the cancelled task can still write.
        running[recordID]?.task.cancel()

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard var record = await self.store.record(id: recordID) else { return }
            guard record.status == .running || record.status == .queued else { return }
            record.status = .cancelled
            record.run.phase = .done
            record.run.finishedAt = Date()
            try? await self.store.save(record)
            self.postChanged()
        }
    }

    func cancelAll() {
        generation += 1
        queue.removeAll()
        let tasks = running.values.map(\.task)
        running.removeAll()
        for task in tasks { task.cancel() }
    }

    func isRunning(recordID: String) -> Bool {
        running[recordID] != nil || queue.contains { $0.recordID == recordID }
    }

    func activeRecordIDs() -> Set<String> {
        Set(running.keys).union(queue.map(\.recordID))
    }

    /// Test and shutdown helper. Production never blocks on this.
    func waitForAll() async {
        while !running.isEmpty || !queue.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func start(_ job: Job) {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.execute(job)
            if self.running[job.recordID]?.token == job.token {
                self.running.removeValue(forKey: job.recordID)
            }
            self.startNextIfPossible()
        }
        running[job.recordID] = RunningJob(token: job.token, task: task)
    }

    private func startNextIfPossible() {
        while running.count < maxConcurrent, !queue.isEmpty {
            start(queue.removeFirst())
        }
    }

    private func execute(_ job: Job) async {
        let executionGeneration = generation
        guard executionGeneration == generation else { return }
        ResearchActivity.begin()
        defer { ResearchActivity.end() }

        guard var record = await store.record(id: job.recordID) else { return }

        record.status = .running
        record.run.phase = .planning
        record.run.startedAt = Date()
        record.run.finishedAt = nil
        record.run.lastError = nil
        record.run.queriesPlanned = 0
        record.run.queriesCompleted = 0
        record.run.pagesRead = 0
        record.run.aiCalls = 0
        record.run.searchCalls = 0
        try? await store.save(record)

        guard executionGeneration == generation else {
            // A reset happened while the running state was being written.
            try? await store.delete(id: job.recordID)
            return
        }
        postChanged()

        let recordID = job.recordID
        let progress: @Sendable (ResearchRun) async -> Void = { [weak self, store] run in
            guard let self else { return }
            let isCurrent = await MainActor.run { [weak self] in
                self?.generation == executionGeneration
            }
            // A history reset bumps the generation; a late tick must not
            // recreate the record that was just deleted.
            guard isCurrent else { return }
            guard var latest = await store.record(id: recordID) else { return }
            guard latest.status == .running else { return }
            latest.run = run
            await store.saveProgress(latest)
            await MainActor.run { self.postChanged() }
        }

        let execution = await job.executor(record, progress)
        guard executionGeneration == generation else { return }

        guard var current = await store.record(id: job.recordID) else { return }
        let finishedAt = Date()

        func applyCounts() {
            current.run.pagesRead = max(current.run.pagesRead, execution.pagesRead)
            current.run.searchCalls = max(current.run.searchCalls, execution.searchCalls)
            current.run.aiCalls = max(current.run.aiCalls, execution.aiCalls)
            current.run.queriesCompleted = max(current.run.queriesCompleted, execution.queries.count)
        }

        if Task.isCancelled {
            current.status = .cancelled
            current.run.phase = .done
            current.run.finishedAt = finishedAt
            current.run.lastError = nil
            applyCounts()
        } else if let error = execution.error {
            // Consent revoked or the AI model changed mid-run: the task itself
            // was not cancelled, but the run was superseded. It must not be
            // recorded as a user-visible failure.
            // The message is produced by the pipeline in the run's language,
            // which may differ from the current UI language.
            let cancelledMessages = [
                L10n.string("research.error.cancelled", language: .zh),
                L10n.string("research.error.cancelled", language: .en),
            ]
            let superseded = cancelledMessages.contains(error) && !Task.isCancelled
            current.status = superseded ? .cancelled : .failed
            current.run.phase = .done
            current.run.finishedAt = finishedAt
            current.run.lastError = superseded ? nil : error
            applyCounts()
        } else if !BurstResearchParser.hasUsableContent(execution.research) {
            current.status = .failed
            current.run.phase = .done
            current.run.finishedAt = finishedAt
            current.run.lastError = L10n.string(
                "research.error.empty",
                language: L10n.currentLanguage
            )
            applyCounts()
        } else {
            current.report = execution.research
            current.updatedAt = finishedAt
            current.status = execution.isPartial || execution.research.searchStatus == .failed
                ? .partial
                : .ready
            current.reportVersion = max(
                current.reportVersion,
                execution.research.promptVersion > 0 ? 2 : 1
            )
            current.run.phase = .done
            current.run.finishedAt = finishedAt
            applyCounts()
        }

        try? await store.save(current)
        postChanged()

        if current.status == .ready, job.notify {
            notifier(current)
        }
    }

    private func postChanged() {
        NotificationCenter.default.post(name: .researchRecordsChanged, object: nil)
    }
}
