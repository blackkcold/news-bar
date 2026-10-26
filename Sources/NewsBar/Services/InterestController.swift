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
    private var pendingWrite: Task<Void, Never>?
    private var loading: Task<Void, Never>?

    init(store: LocalInterestStore = LocalInterestStore()) { self.store = store }

    func prepare() async {
        if isReady { return }
        if let loading { await loading.value; return }
        let task = Task { @MainActor in
            do {
                state = try await store.load()
                state.prune()
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
        guard canLearn, state.recordSession(session) else { return }
        persist()
    }

    func setLearningEnabled(_ enabled: Bool) {
        guard isReady else { return }
        state.learningEnabled = enabled
        state.consentEpoch = UUID()
        state.profileVersion += 1
        persist(reset: true)
        rebuild()
    }

    func setPaused(_ paused: Bool) {
        guard isReady else { return }
        state.learningPaused = paused
        state.consentEpoch = UUID()
        persist(reset: true)
    }

    func record(_ item: NewsItem, kind: InterestEventKind, epoch: UUID, sessionID: UUID) {
        guard canLearn else { return }
        if state.record(item: item, kind: kind, epoch: epoch, sessionID: sessionID) {
            persist()
            if kind.strength > 0 { rebuild() }
        }
    }

    @discardableResult
    func feedback(_ item: NewsItem, kind: InterestFeedbackKind, topic: String? = nil) -> UUID? {
        guard canLearn else { return nil }
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
        state.followedTopics.append(keyword)
        state.profileVersion += 1
        persist()
        rebuild()
        return true
    }

    func unfollow(_ topic: String) {
        guard canManagePreferences else { return }
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
        sessionFeedback = []
        rebuild()
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

    func flush() async { await pendingWrite?.value }

    private func persist(reset: Bool = false) {
        state.revision += 1
        let snapshot = state
        let previous = pendingWrite
        pendingWrite = Task { @MainActor [store] in
            await previous?.value
            do {
                if reset { try await store.reset(snapshot) }
                else { try await store.save(snapshot) }
            } catch {
                storageError = "本地数据写入失败，已停止学习。 / Local write failed; learning stopped."
            }
        }
    }
}

extension Notification.Name {
    static let interestDataCleared = Notification.Name("interestDataCleared")
}
