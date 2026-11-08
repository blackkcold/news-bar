import Foundation

/// How hard the feed filters. `off` keeps every post visible and never
/// collapses anything; the three active modes only move the two thresholds,
/// they never change the shape of the decision.
enum WeiboRelevanceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case loose
    case balanced
    case strict

    var id: String { rawValue }

    var titleKey: String { "weibo.relevance.mode.\(rawValue)" }
    var hintKey: String { "weibo.relevance.modeHint.\(rawValue)" }

    /// At or above this ad score the post is a definite ad.
    var adFilterThreshold: Double {
        switch self {
        case .off: return 1.01
        case .loose: return 0.80
        case .balanced: return 0.60
        case .strict: return 0.40
        }
    }

    /// Between `adReviewThreshold` and `adFilterThreshold` the post is
    /// uncertain: collapsed, never notified.
    var adReviewThreshold: Double {
        switch self {
        case .off: return 1.01
        case .loose: return 0.55
        case .balanced: return 0.35
        case .strict: return 0.20
        }
    }

    /// At or above this interest score the post may be notified.
    var relevantThreshold: Double {
        switch self {
        case .off: return 0
        case .loose: return 0.30
        case .balanced: return 0.45
        case .strict: return 0.60
        }
    }

    /// The floor below which an on-topic post is treated as off-topic.
    var offTopicThreshold: Double { 0.25 }
}

enum WeiboRelevanceVerdict: String, Codable, CaseIterable, Sendable {
    /// Visible in the feed, counts as unread, eligible for a notification.
    case relevant
    /// Collapsed into the "filtered" section, never notified.
    case lowConfidence
    /// Collapsed: the post has nothing to do with the account's beat.
    case offTopic
    /// Collapsed: an ad or a commercial promotion.
    case filtered

    var titleKey: String { "weibo.relevance.verdict.\(rawValue)" }

    var isCollapsed: Bool { self != .relevant }

    var countsAsUnread: Bool { self == .relevant }

    var allowsNotification: Bool { self == .relevant }
}

/// The persisted decision for one post. Every field is small and Codable so a
/// reload can redraw the collapsed state without running the model again.
struct WeiboPostRelevance: Codable, Equatable, Sendable {
    var adScore: Double
    var interestScore: Double
    var verdict: WeiboRelevanceVerdict
    /// Stable codes, localized by the UI. The first item is the strongest
    /// evidence; the list is capped so a feed row stays one line.
    var reasons: [String]
    /// "rules", "rules+opencode" or "rules+ollama".
    var decider: String
    var decidedAt: Date
    /// Present only when the decision model actually answered.
    var modelConfidence: Double?

    init(
        adScore: Double,
        interestScore: Double,
        verdict: WeiboRelevanceVerdict,
        reasons: [String],
        decider: String = "rules",
        decidedAt: Date,
        modelConfidence: Double? = nil
    ) {
        self.adScore = adScore
        self.interestScore = interestScore
        self.verdict = verdict
        self.reasons = reasons
        self.decider = decider
        self.decidedAt = decidedAt
        self.modelConfidence = modelConfidence
    }

    var isCollapsed: Bool { verdict.isCollapsed }
}

/// Per-account history. Only the ratio is used by the model; the counters keep
/// the Settings page honest and make "why is this account always collapsed"
/// answerable.
struct WeiboRelevanceStats: Codable, Equatable, Sendable {
    var decided: Int = 0
    var relevant: Int = 0
    var filtered: Int = 0
    var lowConfidence: Int = 0
    var offTopic: Int = 0
    var aiCorrected: Int = 0
    var disagreement: Int = 0

    /// Cold start is deliberately neutral, not optimistic. A weak prior keeps
    /// one unrepresentative old post from resetting the account to zero.
    var onTopicRatio: Double {
        Double(relevant + 2) / Double(decided + 4)
    }

    mutating func record(_ relevance: WeiboPostRelevance) {
        decided += 1
        switch relevance.verdict {
        case .relevant: relevant += 1
        case .filtered: filtered += 1
        case .lowConfidence: lowConfidence += 1
        case .offTopic: offTopic += 1
        }
        if relevance.decider != "rules" {
            aiCorrected += 1
        }
    }
}

/// One candidate for the cross-account repost check. Only the text and the
/// account matter; the mid is not needed for the decision.
struct WeiboCrossPostReference: Equatable, Sendable {
    var uid: String
    var text: String
    var createdAt: Date
}
