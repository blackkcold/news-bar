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

    /// A fallback at or above this point is main reading copy; anything below
    /// is secondary or meta copy. The workbench never resolves sizes, so this
    /// threshold only affects a presentation that pins `bodyFontSize`.
    static let primaryFallbackThreshold: CGFloat = 13.5

    static let workspace = Self()
    static let popup = Self(
        maximumBodyWidth: 640, bodyFontSize: 15, secondaryFontSize: 12.5,
        showsChapterNumbers: false, showsChapterCounts: false, usesReadableChapters: true,
        linksToVerification: true, showsSupplementarySources: true
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
