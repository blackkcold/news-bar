import Foundation

/// One compressed fact about the report, drawn as a pill in the popup header.
/// Tags never carry an action: they answer "what carried this story, how deep
/// did the run go, how solid is the verdict" before the reader starts reading.
struct ResearchReportHeaderTag: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable { case source, depth, verdict }

    let kind: Kind
    let text: String

    var id: String { kind.rawValue }
}

enum ResearchReportHeaderTagBuilder {
    /// At most three tags, in the order the reader needs them. A missing fact
    /// drops its tag instead of rendering an empty pill: a report without a
    /// verification block must not reserve space for a verdict.
    ///
    /// The verdict uses the short table (`已证实`/`分歧`/`反驳`) rather than the
    /// full sentence table, which would push the other tags off the row.
    static func tags(
        source: NewsSource?,
        depth: ResearchDepth?,
        verdict: VerificationReport.Verdict?,
        language: AppLanguage
    ) -> [ResearchReportHeaderTag] {
        var tags: [ResearchReportHeaderTag] = []
        if let source {
            tags.append(ResearchReportHeaderTag(kind: .source, text: sourceName(source, language: language)))
        }
        if let depth {
            tags.append(ResearchReportHeaderTag(
                kind: .depth,
                text: L10n.string("workspace.research.depth.\(depth.rawValue)", language: language)
            ))
        }
        if let verdict {
            tags.append(ResearchReportHeaderTag(
                kind: .verdict,
                text: L10n.string("research.verdict.short.\(verdict.rawValue)", language: language)
            ))
        }
        return tags
    }

    /// `NewsSource.displayName` reads the global `L10n.currentLanguage`, which
    /// is set by the settings object. A tag row built for a specific language
    /// must not depend on that global: during a language switch the row would
    /// briefly mix Chinese and English. RSS sources carry their own name, and
    /// the two built-in sources resolve through the explicit language.
    static func sourceName(_ source: NewsSource, language: AppLanguage) -> String {
        switch source {
        case .weibo: return L10n.string("source.weibo", language: language)
        case .bilibili: return L10n.string("source.bilibili", language: language)
        case let .rss(name, _): return name
        }
    }

    /// The row is one VoiceOver stop rather than three silent pills: the
    /// verdict is the only first-screen signal about how much to trust the
    /// summary, so it must not be hidden from a reader who cannot see it.
    static func accessibilityLabel(_ tags: [ResearchReportHeaderTag]) -> String {
        tags.map(\.text).joined(separator: "，")
    }
}
