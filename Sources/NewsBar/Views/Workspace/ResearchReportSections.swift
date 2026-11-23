import SwiftUI

// MARK: - Conclusion

/// The report's conclusion: the full summary, data-backed counts, the two most
/// pressing gaps, and the background folded away. No "key facts" are invented
/// from prose — every number here comes from `ResearchReportMetrics`.
struct ResearchReportConclusionSection: View {
    @Environment(AppSettings.self) private var settings

    let report: BurstResearch
    var isLegacy: Bool = false

    @State private var showsOverview: Bool

    init(report: BurstResearch, isLegacy: Bool = false) {
        self.report = report
        self.isLegacy = isLegacy
        // Background is only open by default when there is no summary to read.
        let summaryIsEmpty = report.summary
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        _showsOverview = State(initialValue: summaryIsEmpty)
    }

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var metrics: ResearchReportMetrics { ResearchReportMetrics(report: report) }
    private var hasSummary: Bool {
        !report.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var trimmedOverview: String {
        report.overview.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkspaceSectionHeader(
                symbol: "text.alignleft",
                title: "\(ResearchReportSection.conclusion.index) \(ResearchReportSection.conclusion.title)"
            )

            if hasSummary {
                Text(report.summary)
                    .font(.system(size: 14, weight: .regular, design: isRetro ? .serif : .default))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !metaText.isEmpty {
                metaStrip
            }

            if metrics.missingCount > 0, let missing = report.verification?.missing, !missing.isEmpty {
                missingStrip(missing)
            }

            if !trimmedOverview.isEmpty {
                overviewDisclosure
            }

            if isLegacy {
                note("info.circle", "research.report.legacy.note")
            }
            if report.searchStatus == .failed {
                note("wifi.exclamationmark", "research.report.searchFailed")
            }
        }
        .onChange(of: WorkspaceReportDigest.make(report)) {
            // A swapped report must not inherit the previous overview state.
            showsOverview = report.summary
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
        .accessibilityElement(children: .contain)
    }

    /// One honest count per line of the report. Pieces with nothing to count
    /// are omitted instead of rendered as zero.
    private var metaText: String {
        var parts: [String] = []
        if metrics.timelineNodeCount > 0 {
            if let span = metrics.timelineSpanDays {
                parts.append(L10n.string(
                    "research.report.meta.timeline",
                    language: settings.appLanguage,
                    metrics.timelineNodeCount,
                    span
                ))
            } else {
                parts.append(L10n.string(
                    "research.report.meta.timelineNoSpan",
                    language: settings.appLanguage,
                    metrics.timelineNodeCount
                ))
            }
        }
        if metrics.evidenceCount > 0 {
            parts.append(L10n.string(
                "research.report.meta.sources",
                language: settings.appLanguage,
                metrics.evidenceCount,
                metrics.domainCount
            ))
        }
        if metrics.verifiedQuoteCount > 0 {
            parts.append(L10n.string(
                "research.report.meta.quotes",
                language: settings.appLanguage,
                metrics.verifiedQuoteCount
            ))
        }
        if metrics.independentSourceCount > 0 {
            parts.append(L10n.string(
                "research.report.meta.independentSources",
                language: settings.appLanguage,
                metrics.independentSourceCount
            ))
        }
        return parts.joined(separator: " · ")
    }

    private var metaStrip: some View {
        Text(metaText)
            .font(.system(size: 10, weight: .medium, design: isRetro ? .serif : .default))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.22))
            .editorialClipShape(cornerRadius: 7)
            .accessibilityLabel(metaText)
    }

    private func missingStrip(_ missing: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
                Text(L10n.string(
                    "research.report.missing.summary",
                    language: settings.appLanguage,
                    metrics.missingCount
                ))
                .font(.system(size: 10.5, weight: .semibold))
                Spacer(minLength: 0)
                if missing.count > 2 {
                    Text(L10n.string(
                        "research.report.missing.more",
                        language: settings.appLanguage,
                        missing.count - 2
                    ))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(missing.prefix(2).enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 3.5, height: 3.5)
                        .padding(.top, 5)
                        .accessibilityHidden(true)
                    Text(item)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .editorialClipShape(cornerRadius: 8)
    }

    private var overviewDisclosure: some View {
        DisclosureGroup(isExpanded: $showsOverview) {
            Text(trimmedOverview)
                .font(.system(size: 12, weight: .regular, design: isRetro ? .serif : .default))
                .lineSpacing(2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 5)
        } label: {
            Text("research.report.overview".localized)
                .font(.system(size: 11, weight: .semibold, design: isRetro ? .serif : .default))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.14))
        .editorialClipShape(cornerRadius: 8)
    }

    private func note(_ symbol: String, _ key: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .accessibilityHidden(true)
            Text(key.localized)
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Timeline

/// The report's own timeline, not the workspace's event timeline. Node states
/// come from `ReportPresentation`, so an unsourced or unverified node can never
/// look verified.
struct ResearchReportTimelineSection: View {
    @Environment(AppSettings.self) private var settings

    let report: BurstResearch
    let contextID: String?
    var isLegacy: Bool = false
    var onOpenEventTimeline: (() -> Void)? = nil

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var accent: Color { isRetro ? RetroEditorialTokens.brick : .accentColor }

    var body: some View {
        let metrics = ResearchReportMetrics(report: report)
        let presentation = ReportPresentation(report: report, isLegacy: isLegacy)
        return VStack(alignment: .leading, spacing: 10) {
            WorkspaceSectionHeader(
                symbol: "clock",
                title: "\(ResearchReportSection.timeline.index) \(ResearchReportSection.timeline.title)",
                trailing: trailingCount(presentation: presentation, metrics: metrics)
            )

            if presentation.nodes.isEmpty {
                emptyState
            } else {
                coverageLine(presentation)
                VStack(alignment: .leading, spacing: 13) {
                    ForEach(presentation.nodes) { node in
                        nodeRow(node)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func trailingCount(
        presentation: ReportPresentation,
        metrics: ResearchReportMetrics
    ) -> String {
        let count = presentation.nodes.count
        if let span = metrics.timelineSpanDays {
            return L10n.string(
                "research.report.timeline.count",
                language: settings.appLanguage,
                count,
                span
            )
        }
        return L10n.string(
            "research.report.meta.timelineNoSpan",
            language: settings.appLanguage,
            count
        )
    }

    private func coverageLine(_ presentation: ReportPresentation) -> some View {
        HStack(spacing: 6) {
            Text(L10n.string(
                "research.report.timeline.coverage",
                language: settings.appLanguage,
                presentation.verifiedNodeCount,
                presentation.nodes.count
            ))
            if presentation.unsourcedNodeCount > 0 {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(L10n.string(
                    "research.report.timeline.unsourced",
                    language: settings.appLanguage,
                    presentation.unsourcedNodeCount
                ))
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func nodeRow(_ item: ReportPresentation.Node) -> some View {
        HStack(alignment: .top, spacing: 9) {
            stateDot(item.state)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if !item.node.date.isEmpty {
                        Text(item.node.date)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(item.node.title)
                        .font(.system(size: 12, weight: .semibold, design: isRetro ? .serif : .default))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }

                if !item.node.detail.isEmpty {
                    Text(item.node.detail)
                        .font(.system(size: 11.5, design: isRetro ? .serif : .default))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !item.evidence.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(item.evidence) { evidence in
                            ResearchEvidenceChip(
                                id: evidence.id,
                                evidence: evidence,
                                contextID: contextID
                            )
                        }
                    }
                    .padding(.top, 1)
                }
            }
        }
    }

    @ViewBuilder
    private func stateDot(_ state: ReportPresentation.NodeState) -> some View {
        switch state {
        case .verified:
            Circle()
                .fill(accent)
                .frame(width: 7, height: 7)
                .accessibilityLabel("research.node.verified".localized)
        case .citedUnverified:
            Circle()
                .strokeBorder(
                    Color.orange,
                    style: StrokeStyle(lineWidth: 1.2, dash: [2, 2])
                )
                .frame(width: 7, height: 7)
                .accessibilityLabel("research.node.unverified".localized)
        case .unsourced:
            Circle()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
                .accessibilityLabel("research.node.unsourced".localized)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("research.report.timeline.empty.title".localized)
                .font(.system(size: 12, weight: .semibold, design: isRetro ? .serif : .default))
            Text("research.report.timeline.empty.body".localized)
                .font(.system(size: 11, design: isRetro ? .serif : .default))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if let onOpenEventTimeline {
                Button("research.report.timeline.empty.action".localized, action: onOpenEventTimeline)
                    .buttonStyle(EditorialActionButtonStyle(tone: .secondary, compact: true))
                    .padding(.top, 1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .newsCardSurface(cornerRadius: 10)
    }
}
