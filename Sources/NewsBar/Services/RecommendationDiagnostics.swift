import Foundation
import Observation

@MainActor
@Observable
final class RecommendationDiagnostics {
    enum SummaryState {
        case disabled, unavailable, insufficient(RecommendationDiagnosticSummary?), ready(RecommendationDiagnosticSummary)
    }

    private static let defaultsKey = "recommendationDiagnosticsEnabled"
    private let store: RecommendationDiagnosticStore
    private let defaults: UserDefaults?
    private let permit = RecommendationDiagnosticPermit()
    private(set) var enabled: Bool
    private(set) var isClearing = false
    private(set) var unavailable = false
    private(set) var permissionGeneration = UUID()
    private var learningAllowed = false
    private var learningEpoch: UUID?
    @ObservationIgnored private var capture = RecommendationDiagnosticCapture()
    @ObservationIgnored private var pending: [RecommendationDiagnosticEvent] = []
    @ObservationIgnored private var pendingShadow: [RecommendationShadowSample] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var coverageSince: Date?
    @ObservationIgnored private var pruningTask: Task<Void, Never>?
    @ObservationIgnored private var snapshots: [(UUID, [String])] = []
    @ObservationIgnored private var diagnosticFeedbackItems: [UUID: String] = [:]

    init(store: RecommendationDiagnosticStore = RecommendationDiagnosticStore(), defaults: UserDefaults? = nil) {
        self.store = store
        self.defaults = defaults
        enabled = defaults?.bool(forKey: Self.defaultsKey) ?? false
    }

    var canCapture: Bool { enabled && learningAllowed && !isClearing && !unavailable }

    struct ExposureBoundary: Equatable {
        let generation: UUID
        let day: Date
        let timeZone: String
    }

    func exposureBoundary(at now: Date) -> ExposureBoundary? {
        guard canCapture else { return nil }
        let calendar = Calendar.autoupdatingCurrent
        return ExposureBoundary(generation: permissionGeneration, day: calendar.startOfDay(for: now),
                                timeZone: calendar.timeZone.identifier)
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        defaults?.set(value, forKey: Self.defaultsKey)
        unavailable = false
        invalidate()
    }

    func setLearningAllowed(_ value: Bool, epoch: UUID? = nil) {
        guard learningAllowed != value || learningEpoch != epoch else { return }
        learningAllowed = value
        learningEpoch = epoch
        invalidate()
    }

    func endSession() {
        capture.endSession()
        snapshots.removeAll(keepingCapacity: true)
    }

    private func invalidate() {
        permit.invalidate()
        permissionGeneration = permit.generation.withLock { $0 }
        capture.invalidate()
        snapshots.removeAll(keepingCapacity: true)
        diagnosticFeedbackItems.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        pendingShadow.removeAll(keepingCapacity: true)
        flushTask?.cancel()
        flushTask = nil
        coverageSince = canCapture ? Date() : nil
        if canCapture { scheduleFlush() }
    }

    /// Retention runs even with capture off, but does not create an empty store.
    func maintainRetention() {
        guard pruningTask == nil else { return }
        pruningTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await store.load(now: Date())
            pruningTask = nil
        }
    }

    func expose(row: ScoredRecommendation, snapshot: UUID, rank: Int, confidence: Double, now: Date) {
        guard canCapture, let event = capture.expose(row.contentID, snapshot: snapshot, rank: rank,
                confidence: DiagnosticConfidence(confidence), match: DiagnosticInterestMatch(row.components["interest"]), at: now)
        else { return }
        enqueue([event])
    }

    func noteSnapshot(_ snapshot: RecommendationSnapshot) {
        guard canCapture else { return }
        snapshots.append((snapshot.id, snapshot.items.map(\.contentID)))
        if snapshots.count > 8 { snapshots.removeFirst(snapshots.count - 8) }
    }

    func click(_ request: NewsReaderRequest, current: RecommendationSnapshot?) {
        guard canCapture, !request.privateSession, request.surface == "recommendation", let item = request.item else { return }
        let identity = ContentIdentity.id(for: item.url)
        let snapshotID = request.contextID.flatMap(UUID.init(uuidString:))
        let position = request.position.flatMap { (0..<Int.max).contains($0) ? $0 : nil }
        let verified = position.flatMap { index in
            if let current, current.id == snapshotID {
                return current.items.indices.contains(index) && current.items[index].contentID == identity ? snapshotID : nil
            }
            guard let (_, identities) = snapshots.last(where: { $0.0 == snapshotID }) else { return nil }
            return identities.indices.contains(index) && identities[index] == identity ? snapshotID : nil
        }
        guard let event = capture.click(identity, snapshot: verified, rank: position.map { $0 + 1 },
                                        id: request.id, at: Date()) else { return }
        enqueue([event])
    }

    func readSessionEnded(_ session: ReadingSessionRecord) {
        guard canCapture else { return }
        // This is accumulated on the reader's attributed, active-time path.
        // The terminal state does not tell us whether the original load finished.
        enqueue(capture.read(session.id, activeSeconds: session.activeSeconds,
                             adapted: session.articleAdapted, at: session.endedAt))
    }

    func readSignal(_ kind: InterestEventKind, id: UUID, now: Date) {
        guard canCapture else { return }
        switch kind {
        case .opened, .failed, .blocked:
            let result: RecommendationDiagnosticEvent.Result = kind == .opened ? .opened : kind == .failed ? .failed : .blocked
            if let event = capture.finish(id, result: result, at: now) { enqueue([event]) }
        case .browsed, .qualifiedRead, .deepRead:
            // The existing producer only emits these after >=15s active and
            // while attribution is intact. No change to learning evidence.
            let level: RecommendationDiagnosticEvent.Milestone? = kind == .deepRead ? .deep : kind == .qualifiedRead ? .qualified : nil
            enqueue(capture.read(id, activeSeconds: 15, adapted: kind != .browsed, level: level, at: now))
        default: break
        }
    }

    func feedback(_ item: NewsItem, id: UUID, kind: RecommendationDiagnosticEvent.Feedback, snapshot: UUID? = nil, rank: Int? = nil) {
        guard canCapture else { return }
        let identity = ContentIdentity.id(for: item.url)
        guard let event = capture.feedback(identity, id: id, kind: kind,
                                                       snapshot: snapshot, rank: rank, at: Date()) else { return }
        if diagnosticFeedbackItems.count < 10_000 { diagnosticFeedbackItems[id] = identity }
        enqueue([event])
    }

    func undoFeedback(_ id: UUID) {
        guard canCapture, let identity = diagnosticFeedbackItems.removeValue(forKey: id),
              let event = capture.feedback(identity, id: UUID(), kind: .undo, snapshot: nil, rank: nil, at: Date())
        else { return }
        enqueue([event])
    }

    private func enqueue(_ events: [RecommendationDiagnosticEvent]) {
        guard !events.isEmpty else { return }
        guard pending.count + events.count <= 10_000 else {
            unavailable = true
            invalidate()
            return
        }
        pending.append(contentsOf: events)
        scheduleFlush()
    }

    func recordShadow(_ sample: RecommendationShadowSample, generation: UUID) {
        guard canCapture, permissionGeneration == generation, pendingShadow.count < 32 else { return }
        pendingShadow.append(sample)
        scheduleFlush()
    }

    private var hasPendingData: Bool { !pending.isEmpty || !pendingShadow.isEmpty || coverageSince != nil }

    private func scheduleFlush() {
        guard flushTask == nil, writeTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            flushTask = nil
            await flush()
        }
    }

    func flush() async {
        flushTask?.cancel()
        flushTask = nil
        if let writeTask { await writeTask.value }
        guard canCapture, hasPendingData, writeTask == nil else { return }
        let batch = pending, shadow = pendingShadow, start = coverageSince, generation = permissionGeneration
        pending.removeAll(keepingCapacity: true)
        pendingShadow.removeAll(keepingCapacity: true)
        coverageSince = nil
        let task = Task { @MainActor [self] in
            do {
                try await store.append(batch, now: Date(), coverageSince: start, gate: permit, generation: generation, shadow: shadow)
            } catch {
                if permissionGeneration == generation {
                    unavailable = true
                    invalidate()
                }
            }
            writeTask = nil
            if canCapture && hasPendingData { scheduleFlush() }
        }
        writeTask = task
        await task.value
    }

    @discardableResult
    func clear() async -> Bool {
        guard !isClearing else { return false }
        isClearing = true
        invalidate()
        await writeTask?.value
        do {
            try await store.clear()
            unavailable = false
        } catch {
            unavailable = true
        }
        isClearing = false
        invalidate()
        return !unavailable
    }

    func summary(_ window: RecommendationDiagnosticWindow, now: Date = Date()) async -> SummaryState {
        if unavailable { return .unavailable }
        guard canCapture else { return .disabled }
        let generation = permissionGeneration
        await flush()
        do {
            let document = try await store.load(now: now)
            guard canCapture, generation == permissionGeneration else { return unavailable ? .unavailable : .disabled }
            let value = RecommendationDiagnosticSummary.make(document: document, window: window, now: now)
            if let value, value.hasExposureSample || value.clicks > 0 { return .ready(value) }
            return .insufficient(value)
        } catch {
            if generation == permissionGeneration {
                unavailable = true
                invalidate()
            }
            return .unavailable
        }
    }
}
