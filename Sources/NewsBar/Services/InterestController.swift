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

/// Shared, assertable copy for controls that need active learning. Keeping it
/// in one place stops the feed, reader, settings and explanation page from
/// giving different reasons for the same disabled action.
enum InterestFeedbackCopy {
    static func softFeedbackUnavailable(_ language: AppLanguage) -> String {
        language == .en
            ? "Available after local learning is on; bookmarks, mutes and hides still work."
            : "开启本地学习后可用；收藏、屏蔽与隐藏仍可用。"
    }

    static func followRequiresLearning(_ language: AppLanguage) -> String {
        language == .en
            ? "Following needs local learning on (and not paused or private). Bookmarks, mutes and hides still work."
            : "关注需要学习开启（且未暂停、未处于隐私阅读）；收藏、屏蔽与隐藏仍可用。"
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
    let surface: String?
    let contextID: String?
    let position: Int?
    let readerSessionID: UUID?
    let policyVersion: String?
    /// Frozen when the signal is captured, not when the buffer is flushed.
    let profileVersion: Int
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
    /// True for the whole clear/recovery await. Consent changes, learning
    /// writes and a second reset are rejected while the reset is in flight.
    private(set) var isResetting = false
    var privateReading = false
    private(set) var recommendations: RecommendationSnapshot?
    private(set) var sessionFeedback: [InterestFeedback] = []
    /// Stable identity for the current feed/list session. Views can be rebuilt
    /// (tab switches, ranking refresh) without minting a new exposure session.
    private(set) var feedSessionID = UUID()
    private var candidates: [NewsItem] = []
    private var rankingGeneration = UUID()
    private let store: LocalInterestStore
    @ObservationIgnored private var pendingEvents: [PendingInterestEvent] = []
    @ObservationIgnored private var pendingFlush: Task<Void, Never>?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSnapshot: LocalInterestState?
    @ObservationIgnored private var pendingReset = false
    @ObservationIgnored private var lastPruneAt = Date.distantPast
    /// Highest revision confirmed written to disk. `flush(revision:)` reports
    /// success only when this covers the caller's target.
    @ObservationIgnored private var lastPersistedRevision = 0
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
                // A previous transient load failure must not keep `canLearn`
                // false after a successful retry.
                storageError = nil
            } catch {
                storageError = "本地兴趣数据不可用，已停止学习。 / Local interest storage unavailable; learning stopped."
            }
        }
        loading = task
        await task.value
        loading = nil
    }

    var canLearn: Bool {
        isReady && storageError == nil && !isResetting
            && state.learningEnabled && !state.learningPaused && !privateReading
    }

    var canManagePreferences: Bool { isReady && storageError == nil && !isResetting }

    /// Explicit reset remains available for an unreadable/damaged store, which
    /// is the only recovery path. Settings must use this instead of `isReady`.
    var canResetStorage: Bool { !isResetting }

    var learningStatus: InterestLearningStatus {
        guard isReady, storageError == nil, !isResetting else { return .unavailable }
        if privateReading { return .privateReading }
        if !state.learningEnabled { return .off }
        return state.learningPaused ? .paused : .active
    }

    func ingest(_ items: [NewsItem]) async {
        guard !isResetting else { return }
        await prepare()
        guard isReady, storageError == nil, !isResetting else { return }
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
        guard canManagePreferences else { return }
        flushPendingEvents()
        state.learningEnabled = enabled
        state.consentEpoch = UUID()
        state.profileVersion += 1
        // Session-only soft feedback belongs to the previous consent boundary.
        sessionFeedback = []
        persist(reset: true)
        rebuild()
    }

    func setPaused(_ paused: Bool) {
        guard canManagePreferences else { return }
        flushPendingEvents()
        state.learningPaused = paused
        state.consentEpoch = UUID()
        sessionFeedback = []
        persist(reset: true)
    }

    func record(
        _ item: NewsItem,
        kind: InterestEventKind,
        epoch: UUID,
        sessionID: UUID,
        surface: String? = nil,
        contextID: String? = nil,
        position: Int? = nil,
        readerSessionID: UUID? = nil,
        policyVersion: String? = nil,
        profileVersion: Int? = nil
    ) {
        guard canLearn else { return }
        // Freeze batch/profile provenance at capture time. The buffer may flush
        // after another article changes the profile; attribution must describe
        // the batch that produced this signal.
        let capturedProfileVersion = profileVersion ?? state.profileVersion
        if kind.strength > 0 {
            // Meaningful evidence is rare (one per article) and affects ranking
            // immediately; only the high-frequency impressions are buffered.
            flushPendingEvents()
            if applyRecord(
                item: item,
                kind: kind,
                epoch: epoch,
                sessionID: sessionID,
                now: Date(),
                surface: surface,
                contextID: contextID,
                position: position,
                readerSessionID: readerSessionID,
                policyVersion: policyVersion,
                profileVersionAtEvent: capturedProfileVersion
            ) {
                rebuild()
            }
            return
        }
        pendingEvents.append(PendingInterestEvent(
            item: item,
            kind: kind,
            epoch: epoch,
            sessionID: sessionID,
            occurredAt: Date(),
            surface: surface,
            contextID: contextID,
            position: position,
            readerSessionID: readerSessionID,
            policyVersion: policyVersion,
            profileVersion: capturedProfileVersion
        ))
        schedulePendingFlush()
    }

    /// Hard rules (bookmark / not interested / hide event / mute source) are
    /// independent of behavioral learning and persist while it is off or
    /// paused. Soft profile preferences (reduce topic / more like this) require
    /// active learning: saving them without consent would either train later
    /// without consent or never take effect, both misleading.
    @discardableResult
    func feedback(_ item: NewsItem, kind: InterestFeedbackKind, topic: String? = nil) -> UUID? {
        guard canManagePreferences else { return nil }
        switch kind {
        case .reduceTopic, .moreLikeThis, .followTopic:
            guard canLearn else { return nil }
        case .bookmark, .notInterested, .muteSource, .hideEvent:
            break
        }
        flushPendingEvents()
        if kind == .moreLikeThis {
            // Session scope: clicking "more like this" twice on the same
            // content must not double the +2 short-term weight. Replacing the
            // row is idempotent and undo still removes it by its new id.
            let feedback = InterestFeedback(item: item, kind: kind, occurredAt: Date())
            sessionFeedback.removeAll { $0.kind == .moreLikeThis && $0.scopeKey == feedback.scopeKey }
            sessionFeedback.append(feedback)
            rebuild()
            return feedback.id
        }
        let id = state.feedback(
            item: item,
            kind: kind,
            topic: topic,
            participatesInProfile: canLearn
        )
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
        guard canManagePreferences else { return nil }
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
        // During a reset the profile is in flux; ranking now would build a
        // snapshot from pre-reset candidates. The reset's own rebuild covers it.
        guard !isResetting else { return }
        candidates = items
        rebuild()
    }

    func endListSession() {
        // Closing the dashboard should not rebuild a ranking nobody is looking
        // at; the next load/refresh ranks with the cleared session feedback.
        // A new list session may legitimately see the same article again.
        flushPendingEvents()
        sessionFeedback = []
        feedSessionID = UUID()
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

    /// Explicit privacy reset. Returns `true` only after the reset document was
    /// persisted; corrupt/unknown stores are recovered through this same path,
    /// and a write failure is reported instead of claiming success.
    @discardableResult
    func clear(keepBookmarks: Bool) async -> Bool {
        guard !isResetting else { return false }
        isResetting = true
        defer { isResetting = false }
        // Invalidate ranked state before any await so nothing built from the
        // old profile can be selected or shown during the reset.
        rankingGeneration = UUID()
        recommendations = nil
        sessionFeedback = []
        pendingFlush?.cancel()
        pendingFlush = nil
        pendingEvents.removeAll(keepingCapacity: true)
        pendingSnapshot = nil
        pendingReset = false

        if !isReady, storageError == nil { await prepare() }
        await writeTask?.value

        var cleared = state
        cleared.clearPersonalData(keepBookmarks: keepBookmarks)
        cleared.revision = max(state.revision, cleared.revision) + 1
        do {
            try await store.recover(cleared)
        } catch {
            // Keep the old in-memory document; report the failure and retain
            // diagnostics. No success notification is posted.
            storageError = "清空失败，本地数据状态未确认。 / Clear failed; local data state is unconfirmed. (\(error))"
            return false
        }
        state = cleared
        isReady = true
        storageError = nil
        lastPruneAt = Date()
        privateReading = false
        NotificationCenter.default.post(name: .interestDataCleared, object: nil)
        rebuild()
        return true
    }

    func updateResearch(_ research: PersistedResearchState, epoch: UUID) {
        guard isReady, !isResetting, epoch == state.consentEpoch else { return }
        state.research = research
        persist()
    }

    @discardableResult
    func flush(revision: Int? = nil) async -> Bool {
        flushPendingEvents()
        await writeTask?.value
        if let revision {
            return storageError == nil && lastPersistedRevision >= revision
        }
        return storageError == nil && pendingSnapshot == nil
    }

    @discardableResult
    private func applyRecord(
        item: NewsItem,
        kind: InterestEventKind,
        epoch: UUID,
        sessionID: UUID,
        now: Date,
        surface: String? = nil,
        contextID: String? = nil,
        position: Int? = nil,
        readerSessionID: UUID? = nil,
        policyVersion: String? = nil,
        profileVersionAtEvent: Int? = nil
    ) -> Bool {
        let changed = state.record(
            item: item,
            kind: kind,
            epoch: epoch,
            sessionID: sessionID,
            now: now,
            pruneNow: false,
            surface: surface,
            contextID: contextID,
            position: position,
            readerSessionID: readerSessionID,
            policyVersion: policyVersion,
            profileVersionAtEvent: profileVersionAtEvent ?? state.profileVersion
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
                pruneNow: false,
                surface: event.surface,
                contextID: event.contextID,
                position: event.position,
                readerSessionID: event.readerSessionID,
                policyVersion: event.policyVersion,
                profileVersionAtEvent: event.profileVersion
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
                lastPersistedRevision = max(lastPersistedRevision, snapshot.revision)
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
