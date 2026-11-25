import Foundation

enum DiagnosticInterestMatch: String, Codable, Sendable, CaseIterable {
    case untagged, taggedNoMatch = "tagged_no_match", matched

    init(_ affinity: Double?) {
        if let affinity { self = affinity > 0 ? .matched : .taggedNoMatch }
        else { self = .untagged }
    }
}

enum DiagnosticConfidence: String, Codable, Sendable, CaseIterable {
    case zero, low, high, unknown

    init(_ value: Double) {
        switch value {
        case 0: self = .zero
        case 0..<0.5: self = .low
        case 0.5...1: self = .high
        default: self = .unknown
        }
    }
}

struct RecommendationDiagnosticEvent: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case exposure = "qualified_exposure", click = "click_intent", result = "first_open_result"
        case milestone = "read_milestone", feedback = "explicit_feedback"
    }
    enum Variant: String, Codable, Sendable { case v4, taggedNoMatchNeutral = "tagged_no_match_neutral" }
    enum Attribution: String, Codable, Sendable {
        case sameSnapshot = "same_snapshot", afterRerank = "after_rerank", unattributed
    }
    enum Result: String, Codable, Sendable, CaseIterable {
        case opened, failed, blocked, abandoned = "abandoned_before_load"
    }
    enum Milestone: String, Codable, Sendable, Hashable { case engaged, qualified, deep }
    enum Feedback: String, Codable, Sendable {
        case bookmark, moreLikeThis, notInterested, muteSource, reduceTopic, followTopic, hideEvent
        case lessLikeContent, lessLikeSource, undo

        var isNegative: Bool {
            switch self {
            case .notInterested, .muteSource, .reduceTopic, .hideEvent, .lessLikeContent, .lessLikeSource: true
            default: false
            }
        }
    }

    var schemaVersion = 1
    let kind: Kind
    let occurredAt: Date
    let diagnosticSessionID: UUID
    var snapshotID: UUID?
    let contentKey: UUID
    var exposureID: UUID?
    var attemptID: UUID?
    var attributionKind: Attribution?
    var algorithmRank: Int?
    var confidenceBand: DiagnosticConfidence?
    var interestMatch: DiagnosticInterestMatch?
    let rankingVariant: Variant
    var result: Result?
    var milestone: Milestone?
    var articleAdapted: Bool?
    var feedbackKind: Feedback?
}

/// Association state is process-local. The stored content keys are random per
/// session; raw content identity never makes it into the encoded dictionary.
struct RecommendationDiagnosticCapture {
    typealias Event = RecommendationDiagnosticEvent
    static let window: TimeInterval = 30 * 60
    private struct Session {
        let id = UUID()
        let day: Date
        let zone: String
    }
    private struct Attempt {
        let click: Event
        var result: Event.Result?
        var milestones: Set<Event.Milestone> = []
    }
    private var session: Session?
    private var keys: [String: UUID] = [:]
    private var exposures: [UUID: Event] = [:]
    private var attempts: [UUID: Attempt] = [:]
    private var feedbackIDs: Set<UUID> = []

    mutating func endSession() {
        session = nil
        keys.removeAll(keepingCapacity: true)
        exposures.removeAll(keepingCapacity: true)
        feedbackIDs.removeAll(keepingCapacity: true)
    }

    mutating func invalidate() { self = Self() }

    private mutating func current(at date: Date, calendar: Calendar) -> Session {
        let day = calendar.startOfDay(for: date)
        let zone = calendar.timeZone.identifier
        if let session, session.day == day, session.zone == zone { return session }
        endSession()
        let value = Session(day: day, zone: zone)
        session = value
        return value
    }

    private mutating func key(_ identity: String) -> UUID? {
        if let key = keys[identity] { return key }
        // Do not evict and then accidentally count another first exposure.
        guard keys.count < 10_000 else { return nil }
        let key = UUID()
        keys[identity] = key
        return key
    }

    mutating func expose(_ identity: String, snapshot: UUID, rank: Int, confidence: DiagnosticConfidence,
                         match: DiagnosticInterestMatch, variant: Event.Variant = .v4,
                         at date: Date, calendar: Calendar = .autoupdatingCurrent) -> Event? {
        let session = current(at: date, calendar: calendar)
        guard rank > 0, let key = key(identity), exposures[key] == nil else { return nil }
        let event = Event(kind: .exposure, occurredAt: date, diagnosticSessionID: session.id,
                          snapshotID: snapshot, contentKey: key, exposureID: UUID(), algorithmRank: rank,
                          confidenceBand: confidence, interestMatch: match, rankingVariant: variant)
        exposures[key] = event
        return event
    }

    mutating func click(_ identity: String, snapshot: UUID?, rank: Int?, id: UUID, variant: Event.Variant = .v4,
                        at date: Date, calendar: Calendar = .autoupdatingCurrent) -> Event? {
        let session = current(at: date, calendar: calendar)
        let rank = rank.flatMap { $0 > 0 ? $0 : nil }
        if attempts.count >= 512 {
            attempts = attempts.filter { date.timeIntervalSince($0.value.click.occurredAt) <= Self.window }
        }
        guard attempts.count < 10_000, attempts[id] == nil, let key = key(identity) else { return nil }
        let exposure = exposures[key].flatMap { event -> Event? in
            let ago = date.timeIntervalSince(event.occurredAt)
            guard snapshot != nil, rank != nil, event.rankingVariant == variant, ago > 0, ago <= Self.window else { return nil }
            return event
        }
        let attribution: Event.Attribution = exposure.map { $0.snapshotID == snapshot ? .sameSnapshot : .afterRerank } ?? .unattributed
        let event = Event(kind: .click, occurredAt: date, diagnosticSessionID: session.id, snapshotID: snapshot,
                          contentKey: key, exposureID: exposure?.exposureID, attemptID: id,
                          attributionKind: attribution, algorithmRank: rank, rankingVariant: variant)
        attempts[id] = Attempt(click: event)
        return event
    }

    private func active(_ id: UUID, at date: Date) -> Attempt? {
        guard let attempt = attempts[id] else { return nil }
        let elapsed = date.timeIntervalSince(attempt.click.occurredAt)
        return (0...Self.window).contains(elapsed) ? attempt : nil
    }

    private func event(_ kind: Event.Kind, from click: Event, at date: Date) -> Event {
        Event(kind: kind, occurredAt: date, diagnosticSessionID: click.diagnosticSessionID,
              snapshotID: click.snapshotID, contentKey: click.contentKey, exposureID: click.exposureID,
              attemptID: click.attemptID, rankingVariant: click.rankingVariant)
    }

    mutating func finish(_ id: UUID, result: Event.Result, at date: Date) -> Event? {
        guard var attempt = active(id, at: date), attempt.result == nil else { return nil }
        attempt.result = result
        attempts[id] = attempt
        var event = event(.result, from: attempt.click, at: date)
        event.result = result
        return event
    }

    mutating func read(_ id: UUID, activeSeconds: Double, adapted: Bool, level: Event.Milestone? = nil, at date: Date) -> [Event] {
        guard activeSeconds.isFinite, activeSeconds >= 15, var attempt = active(id, at: date),
              attempt.result == .opened else { return [] }
        let levels: [Event.Milestone] = [.engaged] + (adapted ? level.map { [$0] } ?? [] : [])
        let events = levels.compactMap { level -> Event? in
            guard attempt.milestones.insert(level).inserted else { return nil }
            var event = event(.milestone, from: attempt.click, at: date)
            event.milestone = level
            event.articleAdapted = adapted
            return event
        }
        attempts[id] = attempt
        return events
    }

    mutating func feedback(_ identity: String, id: UUID, kind: Event.Feedback, snapshot: UUID?, rank: Int?,
                           at date: Date, calendar: Calendar = .autoupdatingCurrent) -> Event? {
        let session = current(at: date, calendar: calendar)
        guard feedbackIDs.count < 10_000, feedbackIDs.insert(id).inserted, let key = key(identity) else { return nil }
        let exact = exposures[key].flatMap { event -> UUID? in
            let ago = date.timeIntervalSince(event.occurredAt)
            guard event.snapshotID == snapshot, event.algorithmRank == rank,
                  ago >= 0, ago <= Self.window else { return nil }
            return event.exposureID
        }
        return Event(kind: .feedback, occurredAt: date, diagnosticSessionID: session.id,
                     snapshotID: snapshot, contentKey: key, exposureID: exact, algorithmRank: rank,
                     rankingVariant: .v4, feedbackKind: kind)
    }
}
