import Foundation

/// Result of one research pass, independent of how it was produced. The
/// coordinator owns queueing and the record state machine; executors only
/// produce this value.
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

/// User-info keys for `.researchRecordsChanged`. A present `recordID` lets the
/// research center refresh one record instead of rescanning storage; absent
/// means a bulk change (delete all, import, maintenance) and a full refresh.
enum ResearchChangeKey {
    static let recordID = "recordID"
}

/// Why a schedule request was not accepted. Callers must surface this to the
/// user; `schedule` no longer returns a bare Bool that can be discarded.
enum ResearchScheduleOutcome: Equatable, Sendable {
    /// The job is queued and will run.
    case accepted
    /// The same record already has a running or queued job.
    case alreadyActive
    /// The record disappeared, is corrupt, or cannot be written by this build.
    case unavailable
    /// Automatic admission policy declined this attempt.
    case admissionDenied
    /// The automatic queue is full and nothing was evictable.
    case queueFull
    /// Writing the queued state failed.
    case persistenceFailed
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
        let trigger: ResearchOrigin
        let enqueuedAt: Date
        let previousStatus: ResearchStatus
        let executor: Executor
        var ready = false
    }

    private struct RunningJob {
        let token: UUID
        let trigger: ResearchOrigin
        let task: Task<Void, Never>
    }

    private let store: any ResearchPersisting
    private var maxConcurrent: Int
    private let automaticStartInterval: TimeInterval
    private let automaticQueueLifetime: TimeInterval
    private let automaticQueueLimit = ResearchAutomationPolicy.maxActiveAutomaticRuns
    private let notifier: @MainActor (ResearchRecord) -> Void
    private var running: [String: RunningJob] = [:]
    private var queue: [Job] = []
    private var admitting: Set<String> = []
    private var lastAutomaticStart: Date?
    private var automaticWake: Task<Void, Never>?
    /// Bumped by `cancelAll` so a task that is already past the executor
    /// cannot write a record back after a history reset.
    private var generation = 0

    init(
        store: any ResearchPersisting = ResearchStore.shared,
        maxConcurrent: Int = 1,
        automaticStartInterval: TimeInterval = 120,
        automaticQueueLifetime: TimeInterval = ResearchAutoAdmission.queueLifetime,
        notifier: @escaping @MainActor (ResearchRecord) -> Void = {
            NotificationService.sendResearchNotification(record: $0)
        }
    ) {
        self.store = store
        self.maxConcurrent = max(1, maxConcurrent)
        self.automaticStartInterval = max(0, automaticStartInterval)
        self.automaticQueueLifetime = max(0, automaticQueueLifetime)
        self.notifier = notifier
    }

    /// Applies the user's concurrency setting; queued jobs start immediately if
    /// the new ceiling allows it.
    func setMaxConcurrent(_ value: Int) {
        maxConcurrent = max(1, min(3, value))
        startNextIfPossible()
    }

    func schedule(
        recordID: String,
        notify: Bool = true,
        trigger: ResearchOrigin = .manual,
        executor: @escaping Executor
    ) async -> ResearchScheduleOutcome {
        guard running[recordID] == nil,
              !queue.contains(where: { $0.recordID == recordID }),
              admitting.insert(recordID).inserted else { return .alreadyActive }
        defer { admitting.remove(recordID) }
        let admissionGeneration = generation
        guard let record = await store.record(id: recordID),
              admissionGeneration == generation,
              record.status != .running,
              record.loadIssue == nil,
              record.status != .corrupt else { return .unavailable }
        guard !trigger.isAutomatic || ResearchAutoAdmission.allows(record, now: Date()) else { return .admissionDenied }
        guard running[recordID] == nil,
              !queue.contains(where: { $0.recordID == recordID }) else { return .alreadyActive }

        if trigger.isAutomatic,
           queue.filter({ $0.trigger.isAutomatic }).count >= automaticQueueLimit {
            // Do not evict a job whose initial status write is still pending.
            guard let oldest = queue.firstIndex(where: { $0.trigger.isAutomatic && $0.ready }) else { return .queueFull }
            let evicted = queue.remove(at: oldest)
            markDiscarded(evicted, generation: admissionGeneration)
        }
        let job = Job(token: UUID(), recordID: recordID, notify: notify, trigger: trigger, enqueuedAt: Date(), previousStatus: record.status, executor: executor)
        queue.append(job)
        var queued = record
        queued.status = .queued
        queued.run.phase = .idle
        do {
            try await store.save(queued)
        } catch {
            queue.removeAll { $0.token == job.token }
            return .persistenceFailed
        }
        guard admissionGeneration == generation,
              let index = queue.firstIndex(where: { $0.token == job.token }) else { return .unavailable }
        queue[index].ready = true
        postChanged(recordID: recordID)
        startNextIfPossible()
        return .accepted
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
            self.postChanged(recordID: recordID)
        }
    }

    func cancelAll() {
        generation += 1
        queue.removeAll()
        automaticWake?.cancel()
        automaticWake = nil
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

    /// Number of feed-triggered jobs that are running or waiting. The
    /// orchestrator consults this before creating a candidate record so a
    /// refresh cannot pile work onto the queue.
    func activeAutomaticRunCount() -> Int {
        running.values.filter(\.trigger.isAutomatic).count
            + queue.filter { $0.trigger.isAutomatic }.count
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
        if job.trigger.isAutomatic { lastAutomaticStart = Date() }
        running[job.recordID] = RunningJob(token: job.token, trigger: job.trigger, task: task)
    }

    private func startNextIfPossible() {
        let now = Date()
        let expired = queue.filter {
            $0.ready && $0.trigger.isAutomatic && now.timeIntervalSince($0.enqueuedAt) > automaticQueueLifetime
        }
        let expiredTokens = Set(expired.map(\.token))
        queue.removeAll { expiredTokens.contains($0.token) }
        for job in expired { markDiscarded(job, generation: generation) }

        while running.count < maxConcurrent {
            let autoRunning = running.values.contains { $0.trigger.isAutomatic }
            let elapsed = lastAutomaticStart.map { Date().timeIntervalSince($0) } ?? automaticStartInterval
            guard let index = queue.firstIndex(where: { job in
                job.ready && (!job.trigger.isAutomatic || (!autoRunning && elapsed >= automaticStartInterval))
            }) else {
                if !autoRunning, queue.contains(where: { $0.ready && $0.trigger.isAutomatic }), elapsed < automaticStartInterval {
                    scheduleAutomaticWake(after: automaticStartInterval - elapsed)
                }
                return
            }
            start(queue.remove(at: index))
        }
    }

    private func scheduleAutomaticWake(after delay: TimeInterval) {
        guard automaticWake == nil else { return }
        automaticWake = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.automaticWake = nil
            self.startNextIfPossible()
        }
    }

    private func markDiscarded(_ job: Job, generation expectedGeneration: Int) {
        Task { @MainActor [weak self] in
            guard let self, self.generation == expectedGeneration,
                  self.running[job.recordID] == nil,
                  !self.queue.contains(where: { $0.recordID == job.recordID }),
                  var record = await self.store.record(id: job.recordID),
                  self.generation == expectedGeneration,
                  self.running[job.recordID] == nil,
                  !self.queue.contains(where: { $0.recordID == job.recordID }),
                  record.status == .queued else { return }
            record.status = .interrupted
            record.run.phase = .done
            record.run.finishedAt = Date()
            do {
                try await self.store.save(record)
                self.postChanged(recordID: job.recordID)
            } catch { return }
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
        record.run.origin = job.trigger
        record.run.finishedAt = nil
        record.run.lastError = nil
        record.run.queriesPlanned = 0
        record.run.queriesCompleted = 0
        record.run.pagesRead = 0
        record.run.aiCalls = 0
        record.run.searchCalls = 0
        if job.trigger.isAutomatic {
            let isLegacyFailure = job.previousStatus == .failed && record.lastAutomaticAttemptAt == nil
            let previousAttempts = isLegacyFailure ? max(1, record.automaticAttempts) : record.automaticAttempts
            record.automaticAttempts = previousAttempts + 1
            record.lastAutomaticAttemptAt = record.run.startedAt
        }
        do {
            try await store.save(record)
        } catch {
            // Never issue requests when retry accounting could not be persisted.
            return
        }

        guard executionGeneration == generation else {
            // A reset happened while the running state was being written.
            try? await store.delete(id: job.recordID)
            return
        }
        postChanged(recordID: job.recordID)

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
            latest.run.origin = job.trigger
            await store.saveProgress(latest)
            await MainActor.run { self.postChanged(recordID: recordID) }
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
            current.automaticAttempts = 0
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
        postChanged(recordID: job.recordID)

        if current.status == .ready, job.notify {
            notifier(current)
        }
    }

    private func postChanged(recordID: String? = nil) {
        let info = recordID.map { [ResearchChangeKey.recordID: $0] }
        NotificationCenter.default.post(name: .researchRecordsChanged, object: nil, userInfo: info)
    }
}
