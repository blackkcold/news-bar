import Foundation

/// Owns the long-lived automation edges: one initial reconcile, coalesced
/// linking after record/event writes, and the one research-completion notifier.
/// It starts no timer and performs no network request on launch.
@MainActor
final class WorkspaceAutomationService {
    static let shared = WorkspaceAutomationService()

    private let store: any WorkspacePersisting
    private let discovery: WorkspaceAutoDiscovery
    private let coordinator: ResearchCoordinator
    private let notificationCoordinator: WorkspaceNotificationCoordinator

    private var isRunning = false
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private weak var orchestrator: NewsOrchestrator?
    private var settings: AppSettings?

    private var pendingTask: Task<Void, Never>?
    private var isDraining = false
    private var needsFullReconcile = false
    private var needsEventReconcile = false
    private var pendingRecordIDs: [String] = []

    private let coalescingDelay: Duration = .seconds(2)

    init(
        store: any WorkspacePersisting = WorkspaceSubjectStore.shared,
        discovery: WorkspaceAutoDiscovery? = nil,
        coordinator: ResearchCoordinator? = nil,
        notificationCoordinator: WorkspaceNotificationCoordinator? = nil
    ) {
        self.store = store
        self.discovery = discovery ?? .shared
        self.coordinator = coordinator ?? .shared
        self.notificationCoordinator = notificationCoordinator ?? .shared
    }

    func start(orchestrator: NewsOrchestrator, settings: AppSettings) {
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        let runGeneration = generation
        self.orchestrator = orchestrator
        self.settings = settings

        let controller = NewsEventController.shared(settings: settings)
        _ = controller

        coordinator.setResultObservers([WorkspaceResearchObserver.shared])
        coordinator.setNotifier { [weak self] record in
            guard let self else { return }
            let expected = runGeneration
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.generation == expected else { return }
                let decision = await self.notificationCoordinator.claimResearch(
                    recordID: record.id,
                    at: Date()
                )
                guard case let .allowed(subjectID) = decision else { return }
                NotificationService.sendResearchNotification(
                    record: record,
                    subjectID: subjectID
                )
            }
        }

        installObservers(generation: runGeneration)

        // One reconcile, then refresh the popover badge. This reads local stores
        // only; it never starts research, AI or a network request.
        Task { @MainActor [weak self] in
            guard let self, self.isRunning, self.generation == runGeneration else { return }
            _ = await self.discovery.fullReconcile(now: Date())
            await self.orchestrator?.refreshResearchSummary()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        pendingTask?.cancel()
        pendingTask = nil
        needsFullReconcile = false
        needsEventReconcile = false
        pendingRecordIDs.removeAll()
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
        orchestrator = nil
        settings = nil
    }

    // MARK: - Coalesced work

    private func installObservers(generation runGeneration: Int) {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: .researchRecordsChanged,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let recordID = note.userInfo?[ResearchChangeKey.recordID] as? String
                Task { @MainActor [weak self] in
                    self?.schedule(recordID: recordID, generation: runGeneration)
                }
            }
        )
        observers.append(
            center.addObserver(
                forName: .newsEventsChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleEvents(generation: runGeneration)
                }
            }
        )
        // Workspace writes are results, not inputs. Scheduling another
        // reconcile here would feed saveAll -> notification -> saveAll forever.
        observers.append(
            center.addObserver(
                forName: .researchWorkspaceChanged,
                object: nil,
                queue: .main
            ) { _ in }
        )
    }

    private func schedule(recordID: String?, generation runGeneration: Int) {
        guard isRunning, generation == runGeneration else { return }
        if let recordID {
            if !pendingRecordIDs.contains(recordID) {
                pendingRecordIDs.append(recordID)
            }
        } else {
            needsFullReconcile = true
        }
        scheduleDrain(generation: runGeneration)
    }

    private func scheduleEvents(generation runGeneration: Int) {
        guard isRunning, generation == runGeneration else { return }
        needsEventReconcile = true
        scheduleDrain(generation: runGeneration)
    }

    private func scheduleDrain(generation runGeneration: Int) {
        guard !isDraining, pendingTask == nil else { return }
        pendingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: self?.coalescingDelay ?? .seconds(2))
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  self.isRunning, self.generation == runGeneration else { return }
            self.pendingTask = nil
            await self.drain(generation: runGeneration)
        }
    }

    private func drain(generation runGeneration: Int) async {
        guard isRunning, generation == runGeneration, !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        while isRunning, generation == runGeneration {
            let recordIDs = pendingRecordIDs
            let full = needsFullReconcile
            let events = needsEventReconcile
            pendingRecordIDs.removeAll()
            needsFullReconcile = false
            needsEventReconcile = false

            if full {
                _ = await discovery.fullReconcile(now: Date())
            } else {
                if !recordIDs.isEmpty {
                    for recordID in recordIDs {
                        guard isRunning, generation == runGeneration else { return }
                        _ = await discovery.ingestResearch(recordID: recordID, now: Date())
                    }
                }
                if events {
                    guard isRunning, generation == runGeneration else { return }
                    _ = await discovery.ingestEvents(now: Date())
                }
            }

            guard isRunning, generation == runGeneration else { return }
            if pendingRecordIDs.isEmpty, !needsFullReconcile, !needsEventReconcile {
                break
            }
        }

        await orchestrator?.refreshResearchSummary()
    }
}
