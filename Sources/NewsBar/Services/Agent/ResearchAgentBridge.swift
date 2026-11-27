import Foundation

/// What `research.start` reports back.
enum ResearchAgentStartResult: Sendable {
    case started(recordID: String, topic: String, depth: ResearchDepth)
    case alreadyActive(recordID: String)
    /// Too many explicit research jobs are already running or waiting.
    case queueFull
    case unavailable
    case persistenceFailed

    var recordID: String? {
        switch self {
        case let .started(recordID, _, _): return recordID
        case let .alreadyActive(recordID): return recordID
        case .queueFull, .unavailable, .persistenceFailed: return nil
        }
    }
}

/// One record's run state, flattened for the CLI. Counts only: no prose bodies,
/// so a status poll stays small and never leaks source text into a log.
struct ResearchAgentSnapshot: Sendable {
    var recordID: String
    var topic: String
    var depth: ResearchDepth
    var status: ResearchStatus
    var phase: ResearchRun.Phase
    var summary: String
    var evidenceCount: Int
    var timelineCount: Int
    var commentaryCount: Int
    var verdict: VerificationReport.Verdict?
    var verdictStrength: Int?
    var searchCalls: Int
    var aiCalls: Int
    var pagesRead: Int
    var queries: [String]
    var limitations: String
    var lastError: String?
    var isPartial: Bool
    var generatedAt: Date?
}

/// The two research operations the command bridge needs, as closures.
///
/// Injected rather than reached for directly: `AgentCommandService` is a file
/// protocol bridge, and making it depend on `NewsOrchestrator` would drag the
/// whole network stack into every test that just wants to check a command
/// envelope. It also keeps the bridge testable without a pipeline.
struct ResearchAgentHooks: Sendable {
    /// Provisions or reuses a record for `topic`, then schedules it. Returns as
    /// soon as the job is queued: a deep pass takes minutes.
    var start: @MainActor @Sendable (_ topic: String, _ depth: ResearchDepth) async -> ResearchAgentStartResult
    /// Reads one record without touching it. `recordID` wins when both are
    /// given; `topic` resolves the newest record for that subject.
    var snapshot: @MainActor @Sendable (_ recordID: String?, _ topic: String?) async -> ResearchAgentSnapshot?
}
