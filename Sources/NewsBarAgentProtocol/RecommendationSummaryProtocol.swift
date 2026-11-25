import Foundation

public enum RecommendationSummaryWindow: String, Codable, Sendable {
    case week = "7d", month = "30d"

    public var days: Int { self == .week ? 7 : 30 }
}

public enum RecommendationSummaryRequest {
    public static func parse(_ data: Data) -> RecommendationSummaryWindow? {
        switch data {
        case Data("7d\n".utf8): .week
        case Data("30d\n".utf8): .month
        default: nil
        }
    }
}

/// No dictionary or arbitrary string fields for metrics or group labels.
public struct RecommendationSummaryReply: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ok, insufficientData = "insufficient_data", notAuthorized = "not_authorized"
        case appUnavailable = "app_unavailable", storageUnavailable = "storage_unavailable"
        case invalidRequest = "invalid_request", rateLimited = "rate_limited", requestTimedOut = "request_timed_out"

        public var exitCode: Int32 {
            switch self {
            case .ok, .insufficientData: 0
            case .invalidRequest: 2
            case .appUnavailable: 3
            case .notAuthorized, .rateLimited: 4
            case .storageUnavailable, .requestTimedOut: 5
            }
        }
    }
    public enum Coverage: String, Codable, Sendable { case complete, partial }
    public struct Counts: Codable, Equatable, Sendable {
        public let qualifiedExposures: Int
        public let exposuresWithEngagedRead: Int
        public let clickedExposures: Int
        public let clickAttempts: Int
        public let attributedClickAttempts: Int
        public let opens: Int

        public init(qualifiedExposures: Int, exposuresWithEngagedRead: Int, clickedExposures: Int,
                    clickAttempts: Int, attributedClickAttempts: Int, opens: Int) {
            self.qualifiedExposures = qualifiedExposures
            self.exposuresWithEngagedRead = exposuresWithEngagedRead
            self.clickedExposures = clickedExposures
            self.clickAttempts = clickAttempts
            self.attributedClickAttempts = attributedClickAttempts
            self.opens = opens
        }
    }

    public var schemaVersion = 1
    public var metricDefinitionVersion = 1
    public var view = "overview"
    public let status: Status
    public let window: RecommendationSummaryWindow?
    public let availableFromDay: String?
    public let completeThroughDay: String?
    public let coverage: Coverage?
    public let counts: Counts?

    public init(status: Status, window: RecommendationSummaryWindow? = nil, availableFromDay: String? = nil,
                completeThroughDay: String? = nil, coverage: Coverage? = nil, counts: Counts? = nil) {
        self.status = status
        self.window = window
        self.availableFromDay = availableFromDay
        self.completeThroughDay = completeThroughDay
        self.coverage = coverage
        self.counts = counts
    }
}

/// CLI-facing rendering. Kept dependency-free so the exit-code and
/// field-whitelist contract is testable without launching the executable.
public enum RecommendationSummaryCommand {
    /// One disclosure group needs this many qualified exposures. The app uses
    /// the same value; the CLI never receives a smaller view.
    public static let minimumExposures = 20

    public struct Rendering: Sendable, Equatable {
        public let exitCode: Int32
        public let output: String
        public let error: String?

        public init(exitCode: Int32, output: String, error: String?) {
            self.exitCode = exitCode
            self.output = output
            self.error = error
        }
    }

    public static func render(_ reply: RecommendationSummaryReply, json: Bool) -> Rendering {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let text = (try? encoder.encode(reply)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return Rendering(exitCode: reply.status.exitCode, output: text, error: nil)
        }

        switch reply.status {
        case .ok:
            return Rendering(exitCode: 0, output: summaryText(reply), error: nil)
        case .insufficientData:
            return Rendering(exitCode: 0, output: insufficientText(reply), error: nil)
        default:
            return Rendering(
                exitCode: reply.status.exitCode,
                output: "",
                error: "error: \(reply.status.rawValue): \(message(reply.status))\n"
            )
        }
    }

    private static func summaryText(_ reply: RecommendationSummaryReply) -> String {
        var lines = [header(reply), rangeLine(reply)]
        if let counts = reply.counts {
            lines.append("Qualified exposures: \(counts.qualifiedExposures)")
            lines.append("Engaged-read exposures: \(counts.exposuresWithEngagedRead)")
            lines.append("Clicked exposures: \(counts.clickedExposures)")
            lines.append("Click attempts: \(counts.clickAttempts) · attributed \(counts.attributedClickAttempts)")
            lines.append("Opens: \(counts.opens)")
        }
        return lines.joined(separator: "\n")
    }

    private static func insufficientText(_ reply: RecommendationSummaryReply) -> String {
        [header(reply), rangeLine(reply),
         "Not enough data (fewer than \(minimumExposures) qualified exposures)."].joined(separator: "\n")
    }

    private static func header(_ reply: RecommendationSummaryReply) -> String {
        "Recommendation summary · \(reply.window?.days ?? 0) days"
    }

    private static func rangeLine(_ reply: RecommendationSummaryReply) -> String {
        guard let from = reply.availableFromDay, let through = reply.completeThroughDay else {
            return "No complete day yet."
        }
        let coverage = reply.coverage == .partial ? "partial" : "complete"
        return "\(from) – \(through) · \(coverage)"
    }

    private static func message(_ status: RecommendationSummaryReply.Status) -> String {
        switch status {
        case .ok, .insufficientData: ""
        case .notAuthorized: "no active authorization; grant agent read access in NewsBar settings"
        case .appUnavailable: "NewsBar is not running"
        case .storageUnavailable: "recommendation diagnostics storage is unavailable"
        case .invalidRequest: "invalid request"
        case .rateLimited: "rate limit reached for this authorization"
        case .requestTimedOut: "NewsBar did not answer in time"
        }
    }
}
