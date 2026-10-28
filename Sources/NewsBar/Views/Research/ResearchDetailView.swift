import AppKit
import SwiftUI

struct ResearchDetailView: View {
    @Environment(AppSettings.self) private var settings
    @Bindable var model: ResearchCenterModel
    let record: ResearchRecord

    @State private var copied = false
    @State private var showDeleteConfirmation = false
    @State private var verificationExpanded = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var accent: Color { isRetro ? RetroEditorialTokens.brick : .accentColor }
    private var report: BurstResearch? { record.report }
    private var presentation: ReportPresentation? {
        report.map { ReportPresentation(report: $0, isLegacy: record.reportVersion == 0) }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                header

                if record.status.isActive {
                    ResearchProgressView(run: record.run) {
                        Task { await model.cancel(id: record.id) }
                    }
                }

                banners

                if let report, let presentation {
                    reportContent(report, presentation: presentation)
                } else if !record.status.isActive {
                    emptyReport
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 520)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.25))
        .confirmationDialog(
            "research.delete.title".localized,
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("research.delete.confirm".localized, role: .destructive) {
                Task { await model.delete(id: record.id) }
            }
            Button("research.delete.cancel".localized, role: .cancel) {}
        } message: {
            Text("research.delete.message".localized)
        }
        .onAppear {
            verificationExpanded = presentation?.expandsVerificationByDefault ?? false
        }
        .onChange(of: record.id) { _, _ in
            verificationExpanded = presentation?.expandsVerificationByDefault ?? false
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                EditorialSourceBadge(
                    mark: sourceMark,
                    fallbackTint: sourceTint,
                    size: 28,
                    rotation: -1
                )
                EditorialTag(text: statusLabel, fallbackTint: statusColor, filled: true)
                if record.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("research.action.pin".localized)
                }

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    if record.status.isActive {
                        actionButton(
                            symbol: "xmark.octagon",
                            helpKey: "research.action.cancel",
                            disabled: false
                        ) {
                            Task { await model.cancel(id: record.id) }
                        }
                    } else {
                        actionButton(
                            symbol: "arrow.clockwise",
                            helpKey: "research.action.retry",
                            disabled: record.status == .corrupt
                        ) {
                            Task { await model.retry(id: record.id) }
                        }
                        .keyboardShortcut("r", modifiers: .command)
                    }

                    actionButton(
                        symbol: record.isPinned ? "pin.slash" : "pin",
                        helpKey: record.isPinned ? "research.action.unpin" : "research.action.pin",
                        disabled: record.status == .corrupt
                    ) {
                        Task { await model.togglePin(id: record.id) }
                    }

                    actionButton(
                        symbol: record.isRead ? "envelope.badge" : "envelope.open",
                        helpKey: record.isRead ? "research.action.markUnread" : "research.action.markRead",
                        disabled: record.status == .corrupt
                    ) {
                        Task { await model.markRead(id: record.id, read: !record.isRead) }
                    }
                    .keyboardShortcut("m", modifiers: [.command, .shift])

                    actionButton(
                        symbol: copied ? "checkmark" : "doc.on.doc",
                        helpKey: copied ? "research.action.copied" : "research.action.copyMarkdown",
                        disabled: record.report == nil
                    ) {
                        copyMarkdown()
                    }

                    actionButton(
                        symbol: "trash",
                        helpKey: "research.action.delete",
                        disabled: false
                    ) {
                        showDeleteConfirmation = true
                    }
                }
            }

            Text(record.topic.isEmpty ? "research.status.corrupt".localized : record.topic)
                .editorialHeading(size: 22)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text(record.seed.source.displayName)
                Text("·")
                Text(
                    L10n.string(
                        "research.updatedAt",
                        language: settings.appLanguage,
                        Self.relativeFormatter.localizedString(for: record.updatedAt, relativeTo: Date())
                    )
                )
                Text("·")
                Text(L10n.string("research.origin.\(record.origin.rawValue)", language: settings.appLanguage))
                Spacer(minLength: 0)
                Text(L10n.string("research.aliasCount", language: settings.appLanguage, record.aliases.count))
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(16)
        .newsCardSurface(cornerRadius: 14, rotation: isRetro ? -0.2 : 0)
    }

    private func actionButton(
        symbol: String,
        helpKey: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 18)
        }
        .buttonStyle(EditorialActionButtonStyle(tone: .secondary, compact: true))
        .disabled(disabled)
        .help(helpKey.localized)
        .accessibilityLabel(helpKey.localized)
    }

    // MARK: - Banners

    @ViewBuilder
    private var banners: some View {
        if let issue = record.loadIssue {
            banner(
                symbol: "lock.doc",
                tint: .purple,
                text: issueBannerText(issue)
            )
        }
        if let report {
            if record.status == .failed || record.status == .cancelled || record.status == .interrupted {
                banner(
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange,
                    text: L10n.string(
                        "research.failedBanner",
                        language: settings.appLanguage,
                        record.run.lastError ?? statusLabel
                    )
                )
            }
            if report.searchStatus == .failed {
                banner(
                    symbol: "wifi.slash",
                    tint: .orange,
                    text: "burst.searchFailed".localized
                )
            }
            if record.reportVersion == 0 {
                banner(
                    symbol: "clock.arrow.circlepath",
                    tint: .blue,
                    text: "research.oldReport".localized
                )
            }
        }
    }

    private func issueBannerText(_ issue: ResearchEntryIssue) -> String {
        switch issue {
        case .unsupportedVersion:
            return "research.issue.unsupportedVersion".localized
        case .corrupt:
            return "research.issue.corrupt".localized
        case .ioUnavailable:
            return "research.issue.ioUnavailable".localized
        }
    }

    private func banner(symbol: String, tint: Color, text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .newsCardSurface(cornerRadius: 10)
    }

    private var emptyReport: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("research.empty.detail".localized)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(record.run.lastError ?? "research.empty.detail.body".localized)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    // MARK: - Report

    @ViewBuilder
    private func reportContent(_ report: BurstResearch, presentation: ReportPresentation) -> some View {
        if !report.summary.isEmpty {
            section(index: "01", titleKey: "burst.summary", subtitleKey: "burst.summary.subtitle") {
                Text(report.summary)
                    .font(.system(size: 14, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .newsCardSurface(cornerRadius: 12)
            }
        }

        section(index: "02", titleKey: "burst.timeline", subtitleKey: "burst.timeline.subtitle") {
            VStack(alignment: .leading, spacing: 0) {
                if presentation.isLegacy {
                    Text("research.timeline.legacy".localized)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                } else if presentation.nodes.isEmpty {
                    timelineEmptyState
                } else {
                    timelineCoverage(presentation)
                }

                if !presentation.nodes.isEmpty {
                    ForEach(Array(presentation.nodes.enumerated()), id: \.element.id) { index, item in
                        timelineNode(
                            item,
                            isLast: index == presentation.nodes.count - 1,
                            isLegacy: presentation.isLegacy
                        )
                    }
                }
            }
            .padding(14)
            .newsCardSurface(cornerRadius: 12)
        }

        if !report.overview.isEmpty {
            section(index: "03", titleKey: "burst.overview", subtitleKey: "burst.overview.subtitle") {
                Text(report.overview)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .newsCardSurface(cornerRadius: 12)
            }
        }

        if presentation.showsVerificationSection {
            section(
                index: "04",
                titleKey: "research.section.verificationEvidence",
                subtitleKey: "research.section.verificationEvidence.subtitle"
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            verificationExpanded.toggle()
                        }
                    } label: {
                        verificationHeader(report, presentation: presentation)
                    }
                    .buttonStyle(.plain)

                    if verificationExpanded {
                        Divider().padding(.vertical, 10)
                        verificationBody(report)
                    }
                }
                .padding(14)
                .newsCardSurface(cornerRadius: 12)
            }
        } else if presentation.isLegacy {
            section(
                index: "04",
                titleKey: "research.section.verificationEvidence",
                subtitleKey: "research.section.verificationEvidence.subtitle"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("research.legacy.noVerification".localized)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if !report.sources.isEmpty {
                        sourceLinks(report.sources)
                    }
                }
                .padding(14)
                .newsCardSurface(cornerRadius: 12)
            }
        } else {
            evidenceGap(report, presentation: presentation)
        }

        if !report.limitations.isEmpty {
            section(
                index: "05",
                titleKey: "research.section.limitations",
                subtitleKey: "research.section.limitations.subtitle"
            ) {
                Text(report.limitations)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .newsCardSurface(cornerRadius: 12)
            }
        }

        Text("research.disclaimer".localized)
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
    }

    /// Actionable empty state for runs that produced content but no evidence.
    /// It replaces the verification disclosure entirely: there is nothing to
    /// verify, and "0 claims · 0 evidence" is not a result.
    private func evidenceGap(_ report: BurstResearch, presentation: ReportPresentation) -> some View {
        let title: String
        let body: String
        switch presentation.outcome {
        case .searchUnavailable:
            title = "research.outcome.searchUnavailable.title".localized
            body = "research.outcome.searchUnavailable.body".localized
        case .insufficientEvidence, .legacy, .complete, .partialEvidence:
            title = "research.outcome.insufficient.title".localized
            body = "research.outcome.insufficient.body".localized
        }

        return section(
            index: "04",
            titleKey: "research.section.verificationEvidence",
            subtitleKey: "research.section.verificationEvidence.subtitle"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                        Text(body)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let error = record.run.lastError, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button {
                        Task { await model.retry(id: record.id) }
                    } label: {
                        Label("research.action.retry".localized, systemImage: "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(EditorialActionButtonStyle(tone: .secondary, compact: true))

                    if let url = record.seed.url, !url.isEmpty {
                        Button {
                            NewsNavigationRouter.shared.open(
                                url: url,
                                surface: "researchGap",
                                contextID: record.id
                            )
                        } label: {
                            Label("research.action.openTopic".localized, systemImage: "arrow.up.forward.square")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(EditorialActionButtonStyle(tone: .secondary, compact: true))
                    }
                }

                if !report.sources.isEmpty {
                    sourceLinks(report.sources)
                }
            }
            .padding(14)
            .newsCardSurface(cornerRadius: 12)
        }
    }

    private var timelineEmptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("research.timeline.empty.title".localized)
                .font(.system(size: 12, weight: .semibold))
            Text("research.timeline.empty.body".localized)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private func timelineCoverage(_ presentation: ReportPresentation) -> some View {
        var parts = [
            L10n.string(
                "research.timeline.coverage",
                language: settings.appLanguage,
                presentation.verifiedNodeCount,
                presentation.nodes.count
            ),
        ]
        if presentation.citedUnverifiedNodeCount > 0 {
            parts.append(
                L10n.string(
                    "research.timeline.coverage.unverified",
                    language: settings.appLanguage,
                    presentation.citedUnverifiedNodeCount
                )
            )
        }
        if presentation.unsourcedNodeCount > 0 {
            parts.append(
                L10n.string(
                    "research.timeline.coverage.unsourced",
                    language: settings.appLanguage,
                    presentation.unsourcedNodeCount
                )
            )
        }
        return Text(parts.joined(separator: " · "))
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
    }

    private func nodeBadge(_ state: ReportPresentation.NodeState) -> some View {
        let text: String
        let color: Color
        switch state {
        case .citedUnverified:
            text = "research.node.unverified".localized
            color = .orange
        case .unsourced:
            text = "research.node.unsourced".localized
            color = .secondary
        case .verified:
            return AnyView(EmptyView())
        }
        return AnyView(
            Text(text)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(color.opacity(0.1))
                .clipShape(Capsule())
        )
    }

    private func verificationHeader(
        _ report: BurstResearch,
        presentation: ReportPresentation
    ) -> some View {
        HStack(spacing: 7) {
            if let verdict = report.verification?.verdict {
                EditorialTag(
                    text: L10n.string("research.verdict.short.\(verdict.rawValue)", language: settings.appLanguage),
                    fallbackTint: verdictColor(verdict),
                    filled: true
                )
            }

            if presentation.hasVerification {
                strengthBar(presentation.strength)
            }

            Text(
                L10n.string(
                    "research.verification.summary",
                    language: settings.appLanguage,
                    presentation.claimCount,
                    presentation.evidenceCount
                )
            )
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if presentation.conflictCount > 0 {
                Text(
                    L10n.string(
                        "research.verification.conflictsBadge",
                        language: settings.appLanguage,
                        presentation.conflictCount
                    )
                )
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.orange)
            }

            if presentation.isUnverified {
                Text("research.verification.unverifiedBadge".localized)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(verificationExpanded ? 180 : 0))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("research.section.verificationEvidence".localized)
        .accessibilityValue(
            "\(L10n.string("research.timeline.coverage", language: settings.appLanguage, presentation.verifiedNodeCount, presentation.nodes.count))"
        )
    }

    private func strengthBar(_ strength: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(index < strength ? accent : Color.secondary.opacity(0.15))
                    .frame(width: 12, height: 4)
            }
        }
    }

    private func verdictColor(_ verdict: VerificationReport.Verdict) -> Color {
        switch verdict {
        case .confirmed, .mostlyConfirmed: return .green
        case .mixed: return .orange
        case .unverified: return .secondary
        case .refuted: return .red
        }
    }

    @ViewBuilder
    private func verificationBody(_ report: BurstResearch) -> some View {
        if let verification = report.verification {
            VerificationPanel(
                verification: verification,
                method: report.method,
                evidence: report.evidence,
                recordID: record.id
            )
        }

        if !report.evidence.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sourceTierLegend
                ForEach(report.evidence) { item in
                    ResearchEvidenceRow(item: item, contextID: record.id)
                }
            }
            .padding(.top, report.verification == nil ? 0 : 8)
        } else if !report.sources.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("research.evidence.sourcesOnly".localized)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                sourceLinks(report.sources)
            }
        }
    }

    private var sourceTierLegend: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("research.timeline.legend.title".localized)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("research.timeline.legend.note".localized)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            HStack(spacing: 5) {
                ForEach(SourceTier.allCases, id: \.rawValue) { tier in
                    Text(L10n.string("research.tier.\(tier.rawValue)", language: settings.appLanguage))
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(Capsule())
                }
            }
        }
    }

    private func sourceLinks(_ sources: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(sources, id: \.self) { source in
                Button {
                    NewsNavigationRouter.shared.open(
                        url: source,
                        surface: "researchSource",
                        contextID: record.id
                    )
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.system(size: 9))
                            .foregroundStyle(accent)
                        Text(source)
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .newsCardSurface(cornerRadius: 8)
    }

    private func section<Content: View>(
        index: String,
        titleKey: String,
        subtitleKey: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorialSectionHeading(
                index: index,
                title: titleKey.localized,
                subtitle: subtitleKey.localized
            )
            content()
        }
    }

    private func timelineNode(
        _ item: ReportPresentation.Node,
        isLast: Bool,
        isLegacy: Bool
    ) -> some View {
        let node = item.node
        let verified = item.state == .verified
        // Legacy nodes were never checked individually. Drawing them as dashed
        // "unverified" markers would claim a verification that never ran.
        let dotColor: Color = isLegacy
            ? .secondary
            : (verified ? accent : (item.state == .unsourced ? .secondary : .orange))

        return HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(isLegacy || verified ? dotColor : Color.clear)
                    .frame(width: 10, height: 10)
                    .overlay {
                        if isLegacy {
                            EmptyView()
                        } else if verified {
                            Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1)
                        } else {
                            Circle().strokeBorder(
                                dotColor,
                                style: StrokeStyle(lineWidth: 1.2, dash: [2, 2])
                            )
                        }
                    }
                    .padding(.top, 5)

                if !isLast {
                    Rectangle()
                        .fill(verified ? accent.opacity(0.3) : Color.secondary.opacity(0.18))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 10)

            VStack(alignment: .leading, spacing: 4) {
                if !node.date.isEmpty {
                    Text(node.date)
                        .font(.system(size: 10, weight: .bold, design: isRetro ? .monospaced : .default))
                        .foregroundStyle(verified ? accent : .secondary)
                }
                Text(node.title)
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !node.detail.isEmpty {
                    Text(node.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !isLegacy, !verified || !item.evidence.isEmpty {
                    HStack(spacing: 4) {
                        if !isLegacy, !verified {
                            nodeBadge(item.state)
                        }
                        ForEach(item.evidence) { evidence in
                            ResearchEvidenceChip(
                                id: evidence.id,
                                evidence: evidence,
                                contextID: record.id
                            )
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }

    // MARK: - Helpers

    private var statusLabel: String {
        L10n.string("research.status.\(record.status.rawValue)", language: settings.appLanguage)
    }

    private var statusColor: Color {
        switch record.status {
        case .queued, .running: return .blue
        case .ready: return .green
        case .partial: return .orange
        case .failed: return .red
        case .cancelled, .interrupted: return .secondary
        case .corrupt: return .purple
        }
    }

    private var sourceMark: EditorialSourceMark {
        switch record.seed.source {
        case .weibo: return .weibo
        case .bilibili: return .bilibili
        case .rss: return .rss
        }
    }

    private var sourceTint: Color {
        switch record.seed.source {
        case .weibo: return .orange
        case .bilibili: return .pink
        case .rss: return .blue
        }
    }





    private func copyMarkdown() {
        let markdown = model.markdown(for: record)
        guard !markdown.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

