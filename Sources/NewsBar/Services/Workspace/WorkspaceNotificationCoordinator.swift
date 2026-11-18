import Foundation

/// Result of a notification coordination decision. A suppressed event is not
/// allowed to claim its semantic de-duplication key, so a later real progress
/// update is never lost because the workspace was archived or unreadable.
enum WorkspaceNotificationDecision: Equatable, Sendable {
    case allowed(subjectID: String?)
    case suppressed(reason: String)

    var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    var subjectID: String? {
        if case let .allowed(subjectID) = self { return subjectID }
        return nil
    }
}

/// Coordinates event-progress and research-completion notices for one subject.
///
/// It deliberately does not suppress every event of the same kind for six
/// hours. New, substantive progress must still notify. Only the same report
/// version, or an automatic research completion immediately after an event
/// notification for the same update, is suppressed.
@MainActor
final class WorkspaceNotificationCoordinator {
    static let shared = WorkspaceNotificationCoordinator()

    /// Coordination is by exact causal token, not by elapsed time. A later,
    /// unrelated update or a new report version is never suppressed.

    private let store: any WorkspacePersisting
    private let researchStore: any ResearchPersisting
    private let now: @Sendable () -> Date

    private struct Recent {
        var at: Date
        var kind: WorkspaceNotificationKind
        var reference: String?
    }

    /// Fallback when the index is read-only or a write fails. Notifications are
    /// not dropped just because coordination state cannot be persisted.
    private var recentBySubject: [String: Recent] = [:]
    private var isProcessing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        store: any WorkspacePersisting = WorkspaceSubjectStore.shared,
        researchStore: any ResearchPersisting = ResearchStore.shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.researchStore = researchStore
        self.now = now
    }

    // MARK: - Resolution

    func subjectID(forRecordID id: String) async -> String? {
        await store.subject(containingResearchID: id)?.id
    }

    func subjectID(forEventID id: String) async -> String? {
        await store.subject(containingEventID: id)?.id
    }

    // MARK: - Event progress

    /// Checks delivery without consuming the event's semantic key or writing
    /// coordination state. `causalToken` is set only when the triggering
    /// evidence came from a finalized research report.
    func authorizeEvent(
        eventID: String,
        at date: Date,
        causalToken: String? = nil
    ) async -> WorkspaceNotificationDecision {
        await serialized {
            guard let subject = await store.subject(containingEventID: eventID) else {
                return .allowed(subjectID: nil)
            }
            if subject.isArchived {
                return .suppressed(reason: L10n.string("workspace.notify.archived"))
            }
            if let causalToken, let state = effectiveState(for: subject),
               state.kind == .researchCompleted,
               state.reference == causalToken {
                return .suppressed(reason: L10n.string("workspace.notify.sameReport"))
            }
            // An event is new progress by definition. Do not apply a blanket
            // same-kind time window: that would hide major developments.
            return .allowed(subjectID: subject.id)
        }
    }

    /// Records a delivered event notice. Called after UserNotifications accepts
    /// the request, so a failed send does not make a later research completion
    /// look redundant. A research-derived event stores the exact report token.
    func recordEventNotified(
        eventID: String,
        at date: Date,
        causalToken: String? = nil
    ) async {
        await serialized {
            guard let subject = await store.subject(containingEventID: eventID) else {
                return
            }
            let reference = causalToken ?? "event:\(eventID)"
            do {
                try await store.updateSubject(id: subject.id) { latest in
                    if date >= (latest.lastNotifiedAt ?? .distantPast) {
                        latest.lastNotifiedAt = date
                        latest.lastNotificationKind = .eventProgress
                        latest.lastNotifiedReference = reference
                    }
                }
                recentBySubject[subject.id] = Recent(
                    at: date,
                    kind: .eventProgress,
                    reference: reference
                )
            } catch {
                NSLog(
                    "[WorkspaceNotificationCoordinator] event notice state not persisted: %@",
                    error.localizedDescription
                )
            }
        }
    }

    // MARK: - Research completion

    func claimResearch(recordID: String, at date: Date) async -> WorkspaceNotificationDecision {
        let decision = await authorizeResearch(recordID: recordID, at: date)
        guard decision.isAllowed else { return decision }
        await recordResearchNotified(recordID: recordID, at: date)
        return decision
    }

    func authorizeResearch(recordID: String, at date: Date) async -> WorkspaceNotificationDecision {
        let record = await researchStore.record(id: recordID)
        return await serialized {
            guard let subject = await store.subject(containingResearchID: recordID) else {
                // No subject means nothing to coordinate; the legacy payload
                // still opens the record by ID.
                return .allowed(subjectID: nil)
            }
            if subject.isArchived {
                return .suppressed(reason: L10n.string("workspace.notify.archived"))
            }

            let reference = record.flatMap { WorkspaceResearchCausalToken.make(record: $0) }
                ?? Self.fallbackReference(for: record)
            let state = effectiveState(for: subject)
            if let state, state.reference == reference {
                return .suppressed(reason: L10n.string("workspace.notify.sameReport"))
            }
            return .allowed(subjectID: subject.id)
        }
    }

    func recordResearchNotified(recordID: String, at date: Date) async {
        let record = await researchStore.record(id: recordID)
        let reference = record.flatMap { WorkspaceResearchCausalToken.make(record: $0) }
            ?? Self.fallbackReference(for: record)
        await serialized {
            guard let subject = await store.subject(containingResearchID: recordID) else { return }
            do {
                try await store.updateSubject(id: subject.id) { latest in
                    if date >= (latest.lastNotifiedAt ?? .distantPast) {
                        latest.lastNotifiedAt = date
                        latest.lastNotificationKind = .researchCompleted
                        latest.lastNotifiedReference = reference
                    }
                }
                recentBySubject[subject.id] = Recent(
                    at: date,
                    kind: .researchCompleted,
                    reference: reference
                )
            } catch {
                // Delivery has already been accepted by the system. Keep the
                // in-memory causal state so a later event ingest does not echo it.
                recentBySubject[subject.id] = Recent(
                    at: date,
                    kind: .researchCompleted,
                    reference: reference
                )
                NSLog(
                    "[WorkspaceNotificationCoordinator] research notice state not persisted: %@",
                    error.localizedDescription
                )
            }
        }
    }

    /// Frozen cross-stage entry point. Used by callers that already resolved a
    /// subject. Event progress is always allowed unless the subject is archived.
    func claim(
        subjectID: String,
        kind: WorkspaceNotificationKind,
        at date: Date
    ) async -> WorkspaceNotificationDecision {
        await serialized {
            guard let subject = await store.subject(id: subjectID) else {
                return .allowed(subjectID: subjectID)
            }
            if subject.isArchived {
                return .suppressed(reason: L10n.string("workspace.notify.archived"))
            }
            let reference = kind == .eventProgress ? "event:coordination" : nil
            do {
                try await store.updateSubject(id: subject.id) { latest in
                    if date >= (latest.lastNotifiedAt ?? .distantPast) {
                        latest.lastNotifiedAt = date
                        latest.lastNotificationKind = kind
                        latest.lastNotifiedReference = reference
                    }
                }
                recentBySubject[subject.id] = Recent(
                    at: date,
                    kind: kind,
                    reference: reference
                )
            } catch {
                NSLog(
                    "[WorkspaceNotificationCoordinator] claim state not persisted: %@",
                    error.localizedDescription
                )
            }
            return .allowed(subjectID: subject.id)
        }
    }

    func reset() {
        recentBySubject.removeAll()
    }

    // MARK: - Helpers

    private func effectiveState(for subject: WorkspaceSubject) -> (at: Date, kind: WorkspaceNotificationKind, reference: String?)? {
        let stored: (Date, WorkspaceNotificationKind, String?)? = {
            guard let at = subject.lastNotifiedAt,
                  let kind = subject.lastNotificationKind else { return nil }
            return (at, kind, subject.lastNotifiedReference)
        }()
        let memory = recentBySubject[subject.id].map { ($0.at, $0.kind, $0.reference) }
        switch (stored, memory) {
        case let (stored?, memory?):
            return stored.0 >= memory.0 ? stored : memory
        case let (stored?, nil):
            return stored
        case let (nil, memory?):
            return memory
        case (nil, nil):
            return nil
        }
    }

    private static func fallbackReference(for record: ResearchRecord?) -> String? {
        guard let record else { return nil }
        return "research:\(record.id):no-report"
    }

    private func serialized<Value>(_ operation: () async -> Value) async -> Value {
        await acquire()
        defer { release() }
        return await operation()
    }

    private func acquire() async {
        guard isProcessing else {
            isProcessing = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isProcessing = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
