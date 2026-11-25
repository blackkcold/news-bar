import Foundation
import NewsBarAgentProtocol
import Observation

/// Short-lived, in-memory permission to read one fixed recommendation summary.
///
/// The grant is bound to a diagnostics generation and an app-run epoch, so a
/// consent change or a restart makes every outstanding ticket unusable. Nothing
/// here is persisted: quitting the app loses the grant.
@MainActor
@Observable
final class RecommendationAgentAccess {
    struct Scope: Equatable, Sendable {
        let diagnostics: UUID
        let agent: UUID

        init(diagnostics: UUID, agent: UUID) {
            self.diagnostics = diagnostics
            self.agent = agent
        }
    }

    struct Ticket: Equatable, Sendable {
        let id: UUID
        let window: RecommendationSummaryWindow
        let scope: Scope
    }

    struct Admission: Equatable, Sendable {
        let status: RecommendationSummaryReply.Status
        let ticket: Ticket?
    }

    struct Grant: Identifiable {
        let id = UUID()
        let window: RecommendationSummaryWindow
        let response: RecommendationSummaryReply
        let grantedAt: TimeInterval
        let expiresAt: TimeInterval
        let scope: Scope
    }

    static let duration: TimeInterval = 15 * 60
    static let rateLimit = 10
    static let rateWindow: TimeInterval = 60

    /// A fresh value per app run. A response granted before launch cannot be
    /// replayed after launch even though the diagnostics generation is stable.
    let epoch = UUID()

    private(set) var grant: Grant?
    private var inFlight: Set<UUID> = []
    private var admissions: [TimeInterval] = []

    func grant(
        _ response: RecommendationSummaryReply,
        scope: Scope,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard let window = response.window else { return }
        grant = Grant(
            window: window,
            response: response,
            grantedAt: now,
            expiresAt: now + Self.duration,
            scope: scope
        )
        inFlight.removeAll(keepingCapacity: true)
        admissions.removeAll(keepingCapacity: true)
    }

    func revoke() {
        grant = nil
        inFlight.removeAll(keepingCapacity: true)
        admissions.removeAll(keepingCapacity: true)
    }

    func activeGrant(
        scope: Scope,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Grant? {
        guard let grant, grant.scope == scope, now < grant.expiresAt else { return nil }
        return grant
    }

    /// Checks authorization, window and rate limit. Only an admitted request
    /// consumes a rate-limit slot, so a rejected window cannot exhaust it.
    func begin(
        _ window: RecommendationSummaryWindow,
        scope: Scope,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Admission {
        guard let grant, grant.scope == scope, grant.window == window, now < grant.expiresAt else {
            return Admission(status: .notAuthorized, ticket: nil)
        }
        admissions.removeAll { now - $0 >= Self.rateWindow }
        guard admissions.count < Self.rateLimit else {
            return Admission(status: .rateLimited, ticket: nil)
        }
        admissions.append(now)
        let ticket = Ticket(id: UUID(), window: window, scope: scope)
        inFlight.insert(ticket.id)
        return Admission(status: .ok, ticket: ticket)
    }

    /// Rechecks the scope immediately before bytes leave the process. A revoke
    /// between `begin` and this call therefore wins.
    func deliver(
        _ ticket: Ticket,
        scope: Scope,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> RecommendationSummaryReply {
        guard let grant, grant.scope == scope, grant.window == ticket.window,
              now < grant.expiresAt, inFlight.remove(ticket.id) != nil else {
            return RecommendationSummaryReply(status: .notAuthorized, window: ticket.window)
        }
        return grant.response
    }
}
