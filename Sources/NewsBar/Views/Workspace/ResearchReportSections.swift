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

// MARK: - Verification

/// Chapter 03 keeps two questions apart on purpose: whether each quote was
/// found in the fetched page (evidence) and whether each claim has at least one
/// verified quote behind it (claim support). A claim that cites nothing is not
/// shown as supported; a quote that failed the check is not shown as verified.
struct ResearchReportVerificationSection: View {
    @Environment(AppSettings.self) private var settings

    let report: BurstResearch
    var isLegacy: Bool = false
    var contextID: String? = nil

    @State private var expandedClaims: Set<String> = []
    @State private var showsConflicts = false
    @State private var showsMissing = false

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var evidenceByID: [String: EvidenceItem] {
        Dictionary(report.evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    private var trimmedLimitations: String {
        report.limitations.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if let verification = report.verification {
                verificationBody(verification)
            } else if isLegacy {
                VStack(alignment: .leading, spacing: 9) {
                    header
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 9, weight: .semibold))
                            .accessibilityHidden(true)
                        Text("research.report.legacy.note".localized)
                            .font(.system(size: 10.5, design: isRetro ? .serif : .default))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .contain)
            }
        }
        // Attached outside the branches so a version swap still resets the
        // expansion state when the new report has a verification block.
        .onChange(of: WorkspaceReportDigest.make(report)) {
            expandedClaims = []
            showsConflicts = false
            showsMissing = false
        }
    }

    private var header: some View {
        WorkspaceSectionHeader(
            symbol: "checklist",
            title: "\(ResearchReportSection.verification.index) \(ResearchReportSection.verification.title)"
        )
    }

    private func verificationBody(_ verification: VerificationReport) -> some View {
        let metrics = ResearchReportMetrics(report: report)
        return VStack(alignment: .leading, spacing: 11) {
            header
            verdictRow(verification, metrics: metrics)

            if !verification.claims.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(verification.claims.enumerated()), id: \.offset) { _, claim in
                        claimDisclosure(claim)
                    }
                }
            }

            if !verification.conflicts.isEmpty {
                conflictsDisclosure(verification.conflicts)
            }

            if !verification.missing.isEmpty {
                missingDisclosure(verification.missing)
            }

            if !trimmedLimitations.isEmpty {
                limitationsBlock
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func verdictRow(
        _ verification: VerificationReport,
        metrics: ResearchReportMetrics
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            EditorialTag(
                text: L10n.string(
                    "research.verdict.\(verification.verdict.rawValue)",
                    language: settings.appLanguage
                ),
                fallbackTint: verdictTint(verification.verdict)
            )

            if metrics.claimCount > 0 {
                Text(L10n.string(
                    "research.report.claimsSummary",
                    language: settings.appLanguage,
                    metrics.claimCount,
                    metrics.claimsWithVerifiedEvidenceCount,
                    metrics.claimsNeedingEvidenceCount
                ))
                .font(.system(size: 10.5, weight: .medium, design: isRetro ? .serif : .default))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if verification.verdict == .unverified {
                Image(systemName: "info.circle")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help("research.report.verdict.unverifiedHelp".localized)
                    .accessibilityLabel("research.report.verdict.unverifiedHelp".localized)
            }

            Spacer(minLength: 0)
        }
    }

    private func claimDisclosure(_ claim: ClaimCheck) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(for: claim)) {
            VStack(alignment: .leading, spacing: 6) {
                if !claim.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(claim.note)
                        .font(.system(size: 10.5, design: isRetro ? .serif : .default))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !claim.evidenceIDs.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(claim.evidenceIDs.enumerated()), id: \.offset) { _, id in
                            ResearchEvidenceChip(
                                id: id,
                                evidence: evidenceByID[id],
                                contextID: contextID
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: claimSymbol(claim.status))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(claimTint(claim.status))
                    .accessibilityHidden(true)
                Text(claim.claim)
                    .font(.system(size: 11.5, weight: .medium, design: isRetro ? .serif : .default))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Text(claimCountText(claim))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .padding(9)
        .background(.quaternary.opacity(0.16))
        .editorialClipShape(cornerRadius: 7)
    }

    private func expansionBinding(for claim: ClaimCheck) -> Binding<Bool> {
        Binding(
            get: { expandedClaims.contains(claim.id) },
            set: { isExpanded in
                if isExpanded {
                    expandedClaims.insert(claim.id)
                } else {
                    expandedClaims.remove(claim.id)
                }
            }
        )
    }

    private func claimCountText(_ claim: ClaimCheck) -> String {
        claim.evidenceIDs.isEmpty
            ? "research.report.claims.noEvidence".localized
            : L10n.string(
                "research.report.claims.count",
                language: settings.appLanguage,
                claim.evidenceIDs.count
            )
    }

    private func conflictsDisclosure(_ conflicts: [String]) -> some View {
        DisclosureGroup(isExpanded: $showsConflicts) {
            bulletList(conflicts, tint: .orange)
                .padding(.top, 6)
        } label: {
            disclosureLabel(
                "research.report.conflicts".localized,
                symbol: "arrow.triangle.branch",
                count: conflicts.count,
                tint: .orange
            )
        }
        .padding(9)
        .background(Color.orange.opacity(0.08))
        .editorialClipShape(cornerRadius: 7)
    }

    private func missingDisclosure(_ missing: [String]) -> some View {
        DisclosureGroup(isExpanded: $showsMissing) {
            bulletList(missing, tint: .secondary)
                .padding(.top, 6)
        } label: {
            disclosureLabel(
                "research.report.missing.title".localized,
                symbol: "questionmark.circle",
                count: missing.count,
                tint: .secondary
            )
        }
        .padding(9)
        .background(.quaternary.opacity(0.14))
        .editorialClipShape(cornerRadius: 7)
    }

    private func disclosureLabel(
        _ title: String,
        symbol: String,
        count: Int,
        tint: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: isRetro ? .serif : .default))
            Spacer(minLength: 6)
            Text("\(count)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
    }

    private func bulletList(_ items: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, text in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(tint)
                        .frame(width: 4, height: 4)
                        .padding(.top, 4)
                        .accessibilityHidden(true)
                    Text(text)
                        .font(.system(size: 10.5, design: isRetro ? .serif : .default))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var limitationsBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("research.report.limitations".localized.uppercased())
                .font(.system(size: 9, weight: .bold, design: isRetro ? .serif : .default))
                .tracking(isRetro ? 0.6 : 0)
                .foregroundStyle(.tertiary)
            Text(trimmedLimitations)
                .font(.system(size: 10.5, design: isRetro ? .serif : .default))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func claimSymbol(_ status: EvidenceStance?) -> String {
        switch status {
        case .supports: return "checkmark.circle.fill"
        case .refutes: return "xmark.octagon.fill"
        case .unclear, nil: return "questionmark.circle"
        }
    }

    private func claimTint(_ status: EvidenceStance?) -> Color {
        switch status {
        case .supports: return .green
        case .refutes: return .red
        case .unclear: return .orange
        case nil: return .secondary
        }
    }

    private func verdictTint(_ verdict: VerificationReport.Verdict) -> Color {
        switch verdict {
        case .confirmed, .mostlyConfirmed: return .green
        case .mixed: return .orange
        case .unverified: return .secondary
        case .refuted: return .red
        }
    }
}

// MARK: - Sources

/// Chapter 04 is an index, not a wall of cards: collapsed by default, grouped
/// by domain in the metrics' own order, and every row opens its own source.
struct ResearchReportSourceSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let report: BurstResearch
    let onOpenURL: (String, String) -> Void

    @State private var isExpanded = false
    @State private var expandedSources: Set<String> = []

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var groups: [ResearchSourceGroup] {
        ResearchSourceGrouping.groups(for: report.evidence)
    }

    var body: some View {
        let metrics = ResearchReportMetrics(report: report)
        return VStack(alignment: .leading, spacing: 10) {
            WorkspaceSectionHeader(
                symbol: "quote.bubble",
                title: "\(ResearchReportSection.sources.index) \(ResearchReportSection.sources.title)",
                trailing: "\(metrics.evidenceCount)"
            )
            summaryButton(metrics: metrics)
            if isExpanded {
                sourceIndex
            }
        }
        .onChange(of: WorkspaceReportDigest.make(report)) {
            isExpanded = false
            expandedSources = []
        }
        .accessibilityElement(children: .contain)
    }

    private func summaryButton(metrics: ResearchReportMetrics) -> some View {
        let summary = L10n.string(
            "research.report.sources.summary",
            language: settings.appLanguage,
            metrics.evidenceCount,
            metrics.domainCount,
            metrics.verifiedQuoteCount
        )
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
                Text(summary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(EditorialActionButtonStyle(tone: .secondary, compact: true))
        .accessibilityLabel(summary)
        .accessibilityValue(
            isExpanded
                ? "research.report.sources.expand".localized
                : "research.report.sources.collapse".localized
        )
    }

    /// Evidence without a domain cannot form a group, so it is listed flat
    /// instead of disappearing behind an empty index.
    @ViewBuilder
    private var sourceIndex: some View {
        if groups.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(report.evidence) { item in
                    sourceRow(item)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(group.domain)
                                .font(.system(size: 10, weight: .semibold, design: isRetro ? .serif : .default))
                            Text("\(group.items.count)")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(group.items) { item in
                                sourceRow(item)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sourceRow(_ item: EvidenceItem) -> some View {
        ResearchSourceRow(
            item: item,
            isExpanded: sourceBinding(item.id),
            onOpenURL: onOpenURL
        )
    }

    private func sourceBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedSources.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedSources.insert(id)
                } else {
                    expandedSources.remove(id)
                }
            }
        )
    }
}

/// One source in the index. The label stays a plain row so the whole width
/// toggles; the open action lives in the content, never inside the label.
struct ResearchSourceRow: View {
    @Environment(AppSettings.self) private var settings

    let item: EvidenceItem
    @Binding var isExpanded: Bool
    let onOpenURL: (String, String) -> Void

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var displayTitle: String { item.title.isEmpty ? item.domain : item.title }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                if !item.quote.isEmpty {
                    Text("“\(item.quote)”")
                        .font(.system(size: 10.5, design: isRetro ? .serif : .default))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                HStack(spacing: 5) {
                    Text(item.domain)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(L10n.string(
                        "research.stance.\(item.stance.rawValue)",
                        language: settings.appLanguage
                    ))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("T\(item.tier.rawValue)")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(.tertiary)

                HStack {
                    Spacer(minLength: 0)
                    Button("research.report.source.open".localized) {
                        onOpenURL(item.url, displayTitle)
                    }
                    .buttonStyle(EditorialActionButtonStyle(tone: .secondary, compact: true))
                    .accessibilityLabel(L10n.string(
                        "workspace.evidence.openLabel",
                        language: settings.appLanguage,
                        item.domain
                    ))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.id)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(displayTitle)
                    .font(.system(size: 11.5, weight: .medium, design: isRetro ? .serif : .default))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                WorkspaceVerificationBadge(
                    verification: item.quoteVerified ? .verifiedQuote : .unverifiedQuote
                )
            }
        }
        .padding(9)
        .background(.quaternary.opacity(0.16))
        .editorialClipShape(cornerRadius: 7)
    }
}
