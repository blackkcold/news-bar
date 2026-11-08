import Foundation

/// Priority is the only thing that decides polling cadence and the default
/// notification policy. It is deliberately small: P0 is "tell me every time",
/// P1 is "tell me when it matters", P2 is "keep it in the feed".
enum WeiboMonitorPriority: String, Codable, CaseIterable, Identifiable, Sendable {
    case p0
    case p1
    case p2

    var id: String { rawValue }

    var rank: Int {
        switch self {
        case .p0: return 0
        case .p1: return 1
        case .p2: return 2
        }
    }

    var defaultInterval: TimeInterval {
        switch self {
        case .p0: return 120
        case .p1: return 300
        case .p2: return 900
        }
    }

    var minimumInterval: TimeInterval {
        switch self {
        case .p0: return 90
        case .p1: return 180
        case .p2: return 600
        }
    }

    var titleKey: String { "weibo.priority.\(rawValue)" }
}

enum WeiboNotifyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case keywords
    case feedOnly

    var id: String { rawValue }
    var titleKey: String { "weibo.notifyMode.\(rawValue)" }

    static func defaultMode(for priority: WeiboMonitorPriority) -> WeiboNotifyMode {
        switch priority {
        case .p0: return .all
        case .p1: return .keywords
        case .p2: return .feedOnly
        }
    }
}

enum WeiboMonitorErrorKind: String, Codable, Sendable, Equatable {
    case network
    case rateLimited
    case authExpired
    case challenge
    case server
    case parseChanged
    case emptyList
    case disk
    case unknown

    var titleKey: String { "weibo.error.\(rawValue)" }

    /// Errors that should keep the account paused until the user acts or the
    /// app restarts. A transient timeout does not belong here.
    var requiresManualResume: Bool {
        switch self {
        case .rateLimited, .authExpired, .challenge, .parseChanged:
            return true
        case .network, .server, .emptyList, .disk, .unknown:
            return false
        }
    }

    var isWarning: Bool {
        switch self {
        case .network, .server, .emptyList, .unknown:
            return true
        case .rateLimited, .authExpired, .challenge, .parseChanged, .disk:
            return false
        }
    }
}

struct WeiboMonitorStats: Codable, Equatable, Sendable {
    var posts7d: Int = 0
    var lastPostAt: Date?
}

/// One monitored account. Every scheduling decision is derived from these
/// fields, and the whole struct is persisted so a restart never resets the
/// baseline or the backoff state.
struct WeiboMonitorUser: Codable, Identifiable, Equatable, Sendable {
    var uid: String
    var screenName: String
    var avatarURL: String?
    var priority: WeiboMonitorPriority
    var notifyMode: WeiboNotifyMode
    var enabled: Bool
    var addedAt: Date
    var lastSeenMid: String?
    var lastSeenAt: Date?
    var seenMids: [String]
    var nextDueAt: Date
    var lastCheckedAt: Date?
    var lastSuccessAt: Date?
    /// The last real HTTP attempt, used to enforce the one-minute floor on a
    /// manual "check now" without burning a request.
    var lastRequestAt: Date?
    var consecutiveFailures: Int
    var lastErrorKind: WeiboMonitorErrorKind?
    /// Technical pause: rate limit, challenge page, or a long backoff.
    var pausedUntil: Date?
    /// User-initiated mute. Kept separate from `pausedUntil` so the UI can say
    /// "静音" instead of "被限流".
    var mutedUntil: Date?
    var gapSuspected: Bool
    /// Set when a new post arrives; the planner tightens the interval for ten
    /// minutes. Internal, but persisted so a restart does not lose the window.
    var hotWindowUntil: Date?
    /// Five consecutive failures pause the account until restart or resume.
    var needsManualResume: Bool
    var stats: WeiboMonitorStats
    /// Per-account override. nil follows the global setting; `.off` is the
    /// "always show this account" escape hatch.
    var relevanceMode: WeiboRelevanceMode?
    /// Rolling decision history for the account baseline and the Settings page.
    var relevanceStats: WeiboRelevanceStats?

    var id: String { uid }

    var isBaselinePending: Bool { lastSuccessAt == nil }

    init(
        uid: String,
        screenName: String,
        avatarURL: String? = nil,
        priority: WeiboMonitorPriority,
        notifyMode: WeiboNotifyMode? = nil,
        enabled: Bool = true,
        addedAt: Date,
        lastSeenMid: String? = nil,
        lastSeenAt: Date? = nil,
        seenMids: [String] = [],
        nextDueAt: Date,
        lastCheckedAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        lastRequestAt: Date? = nil,
        consecutiveFailures: Int = 0,
        lastErrorKind: WeiboMonitorErrorKind? = nil,
        pausedUntil: Date? = nil,
        mutedUntil: Date? = nil,
        gapSuspected: Bool = false,
        hotWindowUntil: Date? = nil,
        needsManualResume: Bool = false,
        stats: WeiboMonitorStats = WeiboMonitorStats(),
        relevanceMode: WeiboRelevanceMode? = nil,
        relevanceStats: WeiboRelevanceStats? = nil
    ) {
        self.uid = uid
        self.screenName = screenName
        self.avatarURL = avatarURL
        self.priority = priority
        self.notifyMode = notifyMode ?? WeiboNotifyMode.defaultMode(for: priority)
        self.enabled = enabled
        self.addedAt = addedAt
        self.lastSeenMid = lastSeenMid
        self.lastSeenAt = lastSeenAt
        self.seenMids = seenMids
        self.nextDueAt = nextDueAt
        self.lastCheckedAt = lastCheckedAt
        self.lastSuccessAt = lastSuccessAt
        self.lastRequestAt = lastRequestAt
        self.consecutiveFailures = consecutiveFailures
        self.lastErrorKind = lastErrorKind
        self.pausedUntil = pausedUntil
        self.mutedUntil = mutedUntil
        self.gapSuspected = gapSuspected
        self.hotWindowUntil = hotWindowUntil
        self.needsManualResume = needsManualResume
        self.stats = stats
        self.relevanceMode = relevanceMode
        self.relevanceStats = relevanceStats
    }

    func isMuted(now: Date) -> Bool {
        guard let mutedUntil else { return false }
        return mutedUntil > now
    }

    func isPaused(now: Date) -> Bool {
        if needsManualResume { return true }
        guard let pausedUntil else { return false }
        return pausedUntil > now
    }

    func isAvailable(now: Date) -> Bool {
        enabled && !isMuted(now: now) && !isPaused(now: now)
    }
}
