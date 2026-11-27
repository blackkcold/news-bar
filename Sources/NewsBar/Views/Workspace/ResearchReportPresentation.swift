import SwiftUI

/// Shared reader defaults are the workbench's existing presentation.
struct ResearchReportPresentation: Sendable {
    var maximumBodyWidth: CGFloat? = nil
    var bodyFontSize: CGFloat? = nil
    /// The size for dense, secondary copy (timeline detail, claim rows,
    /// verification notes, supplementary links). Kept separate from
    /// `bodyFontSize` so the popup does not flatten every fallback into one
    /// size: a 10.5pt note and a 14pt summary stay two levels apart.
    var secondaryFontSize: CGFloat? = nil
    var showsChapterNumbers = true
    var showsChapterCounts = true
    var usesReadableChapters = false
    var linksToVerification = false
    var showsSupplementarySources = false
    /// Whether the fixed chapter tab bar sits above the reading scroll view.
    /// Only the popup turns it off: its chapters live behind one disclosure
    /// strip instead, so a 40pt bar is no longer spending the first screen.
    var showsChapterNavigator = true
    /// Whether the chapters after the conclusion are folded away by default
    /// and reached through one strip. The workbench keeps every chapter
    /// visible because it is a management surface, not a reading surface.
    var foldsDetailChapters = false
    /// Whether the conclusion repeats the missing-item summary. The popup does
    /// not: with the fold strip in place that summary was a third entrance to
    /// the same chapter, and the verification chapter lists the items once.
    var showsMissingSummaryInConclusion = true
    /// Whether the count line sits as plain secondary text instead of a filled
    /// strip. The popup goes plain: the counts are context, not a badge.
    var usesPlainCountLine = false
    /// Whether every text run in the reading column can be selected. The popup
    /// turns this on because it drops the chapter tabs: with no navigation
    /// affordance in the chrome, quoting a heading or a date by hand is how a
    /// reader carries a fact out of the report.
    var enablesTextSelection = false
    /// Whether the conclusion draws the background/overview disclosure inline.
    /// The popup turns this off and renders the overview as plain copy at the
    /// top of its detail area: two disclosures on the first screen compete for
    /// the same action, and only one of them can win.
    var showsOverviewInConclusion = true
    /// Whether the conclusion's body copy is the overview rather than the
    /// one-sentence summary. The popup turns this on: a reader opens a deep
    /// research report to get material the article did not have, and a single
    /// sentence of restatement is the opposite of that. The summary stays in
    /// the data layer because the notification and the Markdown export use it.
    var usesOverviewAsBody = false
    /// Whether the body copy is laid out paragraph by paragraph.
    ///
    /// The popup's body is the overview, which the model writes as 2–4
    /// paragraphs separated by a blank line; handing that to a single `Text`
    /// makes the paragraph gap identical to the line gap, so the body reads as
    /// one undifferentiated block. The workbench keeps its own single `Text` and
    /// its own line spacing: it shares this view, and turning this on there
    /// would restyle a host that was not part of this work.
    var splitsBodyIntoParagraphs = false
    /// Which parts of the conclusion's count line this host wants. The popup
    /// asks for the evidence-only line: two of the five parts of the full line
    /// were measured to be constant or duplicated across every report on this
    /// machine, and a count that never varies teaches the reader to skip the
    /// whole line. The workbench keeps everything.
    var countLineScope: MetaScope = .all

    /// The two shapes of the conclusion count line. Declared here rather than
    /// in the section view because it is a presentation decision: both hosts
    /// read the same report and ask for different parts of it.
    enum MetaScope {
        case all
        case evidence
    }

    /// Whether the conclusion chapter still draws its own heading. The popup
    /// turns this off because its body is the overview — what happened, why and
    /// what changed — and a heading that says "Conclusion" over that copy names
    /// something the paragraph is not. The workbench keeps it: its chapter tab
    /// carries the same word and the heading anchors the scroll spy.
    var hidesConclusionHeading = false
    /// The report title's point size. The workbench draws its own title, so
    /// only a presentation that owns the title sets this.
    var titlePointSize: CGFloat? = nil

    /// A fallback at or above this point is main reading copy; anything below
    /// is secondary or meta copy. The workbench never resolves sizes, so this
    /// threshold only affects a presentation that pins `bodyFontSize`.
    static let primaryFallbackThreshold: CGFloat = 13.5

    static let workspace = Self()
    static let popup = Self(
        maximumBodyWidth: 640, bodyFontSize: 16, secondaryFontSize: 12.5,
        showsChapterNumbers: false, showsChapterCounts: false, usesReadableChapters: true,
        // The chapter tab bar is replaced by the detail strip, so the
        // conclusion no longer needs a second "view verification" link: the
        // strip is the single entrance and the verification chapter keeps the
        // missing items that the conclusion used to duplicate.
        linksToVerification: false, showsSupplementarySources: true,
        showsChapterNavigator: false, foldsDetailChapters: true,
        showsMissingSummaryInConclusion: false, usesPlainCountLine: true,
        enablesTextSelection: true, showsOverviewInConclusion: false,
        usesOverviewAsBody: true, splitsBodyIntoParagraphs: true,
        countLineScope: .evidence,
        hidesConclusionHeading: true, titlePointSize: 22
    )

    /// A reader that pins its own body size stops following the system's text
    /// size, so the host scales that size itself. The workbench keeps `nil` and
    /// therefore keeps its existing fixed sizes. Both tiers scale by the same
    /// factor so the hierarchy survives enlarged text.
    func scalingBodyFont(by scale: CGFloat) -> Self {
        var scaled = self
        if let bodyFontSize { scaled.bodyFontSize = bodyFontSize * scale }
        if let secondaryFontSize { scaled.secondaryFontSize = secondaryFontSize * scale }
        return scaled
    }

    func title(_ section: ResearchReportSection) -> String {
        showsChapterNumbers ? "\(section.index) \(section.title)" : section.title
    }

    /// Whether a chapter's own heading is drawn above its content.
    func showsHeading(_ section: ResearchReportSection) -> Bool {
        !(section == .conclusion && hidesConclusionHeading)
    }

    /// The resolved point size for a fallback. Exposed so the hierarchy and its
    /// scaling can be asserted without reading a `Font` back apart.
    func fontSize(_ fallback: CGFloat) -> CGFloat {
        guard let bodyFontSize else { return fallback }
        return fallback >= Self.primaryFallbackThreshold
            ? bodyFontSize
            : (secondaryFontSize ?? bodyFontSize)
    }

    func bodyFont(_ fallback: CGFloat, weight: Font.Weight = .regular, isRetro: Bool) -> Font {
        .system(size: fontSize(fallback), weight: weight, design: isRetro ? .serif : .default)
    }

    func timelineReport(_ report: BurstResearch) -> BurstResearch {
        guard usesReadableChapters else { return report }
        var visible = report
        visible.timeline = report.timeline.filter { node in
            [node.title, node.detail].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                || node.evidenceIDs.contains { id in report.evidence.contains { $0.id == id } }
        }
        return visible
    }

    func visibleLimitations(in report: BurstResearch) -> String? {
        let text = report.limitations.trimmingCharacters(in: .whitespacesAndNewlines)
        guard usesReadableChapters || report.verification != nil, !text.isEmpty else { return nil }
        return text
    }

    func verificationAnchor(in report: BurstResearch) -> ResearchReportSection? {
        guard linksToVerification,
              visibleLimitations(in: report) != nil || report.verification?.missing.isEmpty == false else { return nil }
        return .verification
    }

    func supplementaryLinks(in report: BurstResearch, isLegacy: Bool) -> [SupplementaryReportLink] {
        guard showsSupplementarySources else { return [] }
        var seen = Set(report.evidence.map { ContentIdentity.canonicalURL($0.url) })
        return report.sources.compactMap { raw in
            guard let url = ReaderNavigationPolicy.allowedURL(raw),
                  let host = url.host else { return nil }
            let key = ContentIdentity.canonicalURL(raw)
            guard seen.insert(key).inserted else { return nil }
            return SupplementaryReportLink(id: key, rawURL: raw, host: host, kind: isLegacy ? .legacy : .other)
        }
    }
}

struct SupplementaryReportLink: Identifiable {
    enum Kind { case legacy, other }
    let id: String
    let rawURL: String
    let host: String
    let kind: Kind

    func label(language: AppLanguage) -> String {
        let label = kind == .legacy
            ? L10n.string("research.report.sources.legacyLink", language: language)
            : L10n.string("research.report.sources.otherLink", language: language)
        return "\(label) · \(L10n.string("research.report.claims.noEvidence", language: language))"
    }
}

extension EnvironmentValues {
    @Entry var researchReportPresentation = ResearchReportPresentation.workspace
}

extension DynamicTypeSize {
    /// Multiplier for text whose point size is pinned by a presentation.
    /// Semantic text styles already scale on their own; only the pinned body
    /// size needs this, and `.large` is the platform default.
    var readerTextScale: CGFloat {
        switch self {
        case .xSmall: return 0.82
        case .small: return 0.88
        case .medium: return 0.94
        case .large: return 1
        case .xLarge: return 1.12
        case .xxLarge: return 1.23
        case .xxxLarge: return 1.35
        case .accessibility1: return 1.55
        case .accessibility2: return 1.75
        case .accessibility3: return 2
        case .accessibility4: return 2.25
        case .accessibility5: return 2.5
        default: return 1
        }
    }
}
