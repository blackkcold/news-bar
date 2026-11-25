import SwiftUI

/// Shared reader defaults are the workbench's existing presentation.
struct ResearchReportPresentation: Sendable {
    var maximumBodyWidth: CGFloat? = nil
    var bodyFontSize: CGFloat? = nil
    var showsChapterNumbers = true
    var showsChapterCounts = true
    var usesReadableChapters = false
    var linksToVerification = false
    var showsSupplementarySources = false

    static let workspace = Self()
    static let popup = Self(
        maximumBodyWidth: 640, bodyFontSize: 15, showsChapterNumbers: false,
        showsChapterCounts: false, usesReadableChapters: true,
        linksToVerification: true, showsSupplementarySources: true
    )

    func title(_ section: ResearchReportSection) -> String {
        showsChapterNumbers ? "\(section.index) \(section.title)" : section.title
    }

    func bodyFont(_ fallback: CGFloat, weight: Font.Weight = .regular, isRetro: Bool) -> Font {
        .system(size: bodyFontSize ?? fallback, weight: weight, design: isRetro ? .serif : .default)
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
