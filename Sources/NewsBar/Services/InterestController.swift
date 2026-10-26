import Foundation
import Observation

enum InterestLearningStatus: Equatable {
    case unavailable, off, active, paused, privateReading

    func title(language: AppLanguage) -> String {
        let english = language == .en
        switch self {
        case .unavailable: return english ? "Learning unavailable" : "学习暂不可用"
        case .off: return english ? "Public ranking" : "公共排序"
        case .active: return english ? "Local learning" : "本地学习"
        case .paused: return english ? "Learning paused" : "学习已暂停"
        case .privateReading: return english ? "Private reading" : "隐私阅读中"
        }
    }
}

/// A signal captured on the render path but merged into the observed document
/// later. Impressions arrive in bursts while scrolling; doing a full JSON encode
/// and SQLite write per impression is what made scrolling expensive.
private struct PendingInterestEvent: Sendable {
    let item: NewsItem
    let kind: InterestEventKind
    let epoch: UUID
    let sessionID: UUID
    let occurredAt: Date
}

/// Single consent boundary for UI, reader and ranking. All disk work is serialized
/// off the main actor; every callback carries the epoch captured at entry.
@MainActor
@Observable
final class InterestController {
    static let shared = InterestController()
    private(set) var state = LocalInterestState()
    private(set) var isReady = false
    private(set) var storageError: String?
    var privateReading = false
    private(set) var recommendations: RecommendationSnapshot?
    private(set) var sessionFeedback: [InterestFeedback] = []
    private var candidates: [NewsItem] = []
    private var rankingGeneration = UUID()
    private let store: LocalInterestStore
    @ObservationIgnored private var pendingEvents: [PendingInterestEvent] = []
    @ObservationIgnored private var pendingFlush: Task<Void, Never>?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSnapshot: LocalInterestState?
    @ObservationIgnored private var pendingReset = false
    @ObservationIgnored private var lastPruneAt = Date.distantPast
    private var loading: Task<Void, Never>?

    init(store: LocalInterestStore = LocalInterestStore()) { self.store = store }

    func prepare() async {
        if isReady { return }
        if let loading { await loading.value; return }
        let task = Task { @MainActor in
            do {
                state = try await store.load()
                state.prune()
                lastPruneAt = Date()
                isReady = true
            } catch {
                storageError = "本地兴趣数据不可用，已停止学习。 / Local interest storage unavailable; learning stopped."
            }
        }
        loading = task
        await task.value
        loading = nil
    }

    var canLearn: Bool {
        isReady && storageError == nil && state.learningEnabled && !state.learningPaused && !privateReading
    }

    var canManagePreferences: Bool { isReady && storageError == nil }

    var learningStatus: InterestLearningStatus {
        guard isReady, storageError == nil else { return .unavailable }
        if privateReading { return .privateReading }
        if !state.learningEnabled { return .off }
        return state.learningPaused ? .paused : .active
    }

    func ingest(_ items: [NewsItem]) async {
        await prepare()
        guard isReady, storageError == nil else { return }
        // Loading a cached item is not a new source observation.
        state.ingest(items, usingFetchTimestamps: true)
        persist()
    }

    func recordSession(_ session: ReadingSessionRecord) {
        guard canLearn else { return }
        flushPendingEvents()
        guard state.recordSession(session) else { return }
        persist()
    }

    func setLearningEnabled(_ enabled: Bool) {
        guard isReady else { return }
        flushPendingEvents()
        state.learningEnabled = enabled
        state.consentEpoch = UUID()
        state.profileVersion += 1
        persist(reset: true)
        rebuild()
    }

    func setPaused(_ paused: Bool) {
        guard isReady else { return }
        flushPendingEvents()
        state.learningPaused = paused
        state.consentEpoch = UUID()
        persist(reset: true)
    }

    func record(_ item: NewsItem, kind: InterestEventKind, epoch: UUID, sessionID: UUID) {
        guard canLearn else { return }
        if kind.strength > 0 {
            // Meaningful evidence is rare (one per article) and affects ranking
            // immediately; only the high-frequency impressions are buffered.
            flushPendingEvents()
            if applyRecord(item: item, kind: kind, epoch: epoch, sessionID: sessionID, now: Date()) {
                rebuild()
            }
            return
        }
        pendingEvents.append(PendingInterestEvent(
            item: item,
            kind: kind,
            epoch: epoch,
            sessionID: sessionID,
            occurredAt: Date()
        ))
        schedulePendingFlush()
    }

    @discardableResult
    func feedback(_ item: NewsItem, kind: InterestFeedbackKind, topic: String? = nil) -> UUID? {
        guard canLearn else { return nil }
        flushPendingEvents()
        if kind == .moreLikeThis {
            let feedback = InterestFeedback(item: item, kind: kind, occurredAt: Date())
            sessionFeedback.append(feedback)
            rebuild()
            return feedback.id
        }
        let id = state.feedback(item: item, kind: kind, topic: topic)
        persist()
        rebuild()
        return id
    }

    func undo(_ id: UUID) {
        guard canManagePreferences else { return }
        flushPendingEvents()
        state.undoFeedback(id)
        sessionFeedback.removeAll { $0.id == id }
        persist()
        rebuild()
    }

    func toggleBookmark(_ item: NewsItem) -> UUID? {
        guard canLearn else { return nil }
        if let existing = state.feedbacks.first(where: { $0.kind == .bookmark && ContentIdentity.id(for: $0.item.url) == ContentIdentity.id(for: item.url) }) {
            undo(existing.id)
            return nil
        }
        return feedback(item, kind: .bookmark)
    }

    @discardableResult
    func follow(_ raw: String) -> Bool {
        guard canLearn else { return false }
        let keyword = String(SecurityPolicies.sanitizeUserInput(raw).prefix(80))
        guard !keyword.isEmpty, state.followedTopics.count < 100,
              !state.followedTopics.contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }) else { return false }
        flushPendingEvents()
        state.followedTopics.append(keyword)
        state.profileVersion += 1
        persist()
        rebuild()
        return true
    }

    func unfollow(_ topic: String) {
        guard canManagePreferences else { return }
        flushPendingEvents()
        state.followedTopics.removeAll { $0 == topic }
        state.profileVersion += 1
        persist()
        rebuild()
    }

    func rankCandidates(_ items: [NewsItem]) {
        candidates = items
        rebuild()
    }

    func endListSession() {
        // Closing the dashboard should not rebuild a ranking nobody is looking
        // at; the next load/refresh ranks with the cleared session feedback.
        flushPendingEvents()
        sessionFeedback = []
    }

    private func rebuild() {
        let state = state
        let items = candidates
        let feedback = sessionFeedback
        let generation = UUID()
        rankingGeneration = generation
        Task { @MainActor in
            let snapshot = await Task.detached(priority: .userInitiated) {
                RecommendationEngine.rank(items: items, state: state, sessionFeedback: feedback)
            }.value
            guard generation == rankingGeneration else { return }
            recommendations = snapshot
        }
    }

    func clear(keepBookmarks: Bool) async {
        guard isReady else { return }
        // Clearing is a privacy reset: drop buffered signals instead of writing
        // them just before the tombstone.
        pendingFlush?.cancel()
        pendingFlush = nil
        pendingEvents.removeAll(keepingCapacity: true)
        state.clearPersonalData(keepBookmarks: keepBookmarks)
        sessionFeedback = []
        recommendations = nil
        rankingGeneration = UUID()
        privateReading = false
        persist(reset: true)
        await flush()
        NotificationCenter.default.post(name: .interestDataCleared, object: nil)
        rebuild()
    }

    func updateResearch(_ research: PersistedResearchState, epoch: UUID) {
        guard isReady, epoch == state.consentEpoch else { return }
        state.research = research
        persist()
    }

    func flush() async {
        flushPendingEvents()
        await writeTask?.value
    }

    @discardableResult
    private func applyRecord(item: NewsItem, kind: InterestEventKind, epoch: UUID, sessionID: UUID, now: Date) -> Bool {
        let changed = state.record(
            item: item,
            kind: kind,
            epoch: epoch,
            sessionID: sessionID,
            now: now,
            pruneNow: false
        )
        guard changed else { return false }
        pruneIfNeeded()
        persist()
        return true
    }

    @discardableResult
    private func flushPendingEvents() -> Bool {
        pendingFlush?.cancel()
        pendingFlush = nil
        guard !pendingEvents.isEmpty else { return false }
        let events = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        var changed = false
        for event in events {
            if state.record(
                item: event.item,
                kind: event.kind,
                epoch: event.epoch,
                sessionID: event.sessionID,
                now: event.occurredAt,
                pruneNow: false
            ) {
                changed = true
            }
        }
        guard changed else { return false }
        pruneIfNeeded()
        persist()
        return true
    }

    private func schedulePendingFlush() {
        guard pendingFlush == nil else { return }
        pendingFlush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            self?.flushPendingEvents()
        }
    }

    private func pruneIfNeeded(force: Bool = false) {
        let now = Date()
        guard force
                || state.events.count > 10_000
                || now.timeIntervalSince(lastPruneAt) >= 60 else { return }
        state.prune(now: now)
        lastPruneAt = now
    }

    private func persist(reset: Bool = false) {
        state.revision += 1
        pendingSnapshot = state
        pendingReset = pendingReset || reset
        guard writeTask == nil else { return }
        writeTask = Task { @MainActor [weak self] in
            await self?.drainWrites()
        }
    }

    private func drainWrites() async {
        while let snapshot = pendingSnapshot {
            let reset = pendingReset
            pendingSnapshot = nil
            pendingReset = false
            do {
                if reset { try await store.reset(snapshot) }
                else { try await store.save(snapshot) }
            } catch {
                pendingSnapshot = nil
                pendingReset = false
                storageError = "本地数据写入失败，已停止学习。 / Local write failed; learning stopped."
                break
            }
        }
        writeTask = nil
    }
}

extension Notification.Name {
    static let interestDataCleared = Notification.Name("interestDataCleared")
}
