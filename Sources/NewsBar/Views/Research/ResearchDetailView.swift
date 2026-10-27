import AppKit
import SwiftUI

struct ResearchDetailView: View {
    @Environment(AppSettings.self) private var settings
    @Bindable var model: ResearchCenterModel
    let record: ResearchRecord

    @State private var copied = false
    @State private var showDeleteConfirmation = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var accent: Color { isRetro ? RetroEditorialTokens.brick : .accentColor }
    private var report: BurstResearch? { record.report }

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

                if let report {
                    reportContent(report)
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
    private func reportContent(_ report: BurstResearch) -> some View {
        if !report.summary.isEmpty {
            section(index: "01", titleKey: "burst.summary", subtitleKey: "burst.summary.subtitle") {
                Text(report.summary)
                    .font(.system(size: 14, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .newsCardSurface(cornerRadius: 12)
            }
        }

        if !report.overview.isEmpty {
            section(index: "02", titleKey: "burst.overview", subtitleKey: "burst.overview.subtitle") {
                Text(report.overview)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .newsCardSurface(cornerRadius: 12)
            }
        }

        if !report.timeline.isEmpty {
            section(index: "03", titleKey: "burst.timeline", subtitleKey: "burst.timeline.subtitle") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(report.timeline.enumerated()), id: \.element.id) { index, node in
                        timelineNode(node, isLast: index == report.timeline.count - 1, evidence: report.evidence)
                    }
                }
                .padding(14)
                .newsCardSurface(cornerRadius: 12)
            }
        }

        if let verification = report.verification {
            section(
                index: "04",
                titleKey: "research.section.verification",
                subtitleKey: "research.section.verification.subtitle"
            ) {
                VerificationPanel(
                    verification: verification,
                    method: report.method,
                    evidence: report.evidence,
                    recordID: record.id
                )
                .padding(14)
                .newsCardSurface(cornerRadius: 12)
            }
        }

        if !report.evidence.isEmpty {
            section(
                index: "05",
                titleKey: "research.section.evidence",
                subtitleKey: "research.section.evidence.subtitle"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(report.evidence) { item in
                        ResearchEvidenceRow(item: item, contextID: record.id)
                    }
                }
            }
        }

        if !report.limitations.isEmpty {
            section(
                index: "06",
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

        if report.evidence.isEmpty, !report.sources.isEmpty {
            section(index: "05", titleKey: "burst.sources", subtitleKey: "burst.sources.subtitle") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(report.sources, id: \.self) { source in
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
                .padding(14)
                .newsCardSurface(cornerRadius: 12)
            }
        }

        Text("research.disclaimer".localized)
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
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
        _ node: TimelineNode,
        isLast: Bool,
        evidence: [EvidenceItem]
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(accent)
                    .frame(width: 10, height: 10)
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1)
                    }
                    .padding(.top, 5)

                if !isLast {
                    Rectangle()
                        .fill(accent.opacity(0.3))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 10)

            VStack(alignment: .leading, spacing: 4) {
                if !node.date.isEmpty {
                    Text(node.date)
                        .font(.system(size: 10, weight: .bold, design: isRetro ? .monospaced : .default))
                        .foregroundStyle(accent)
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
                if !node.evidenceIDs.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(node.evidenceIDs, id: \.self) { id in
                            ResearchEvidenceChip(
                                id: id,
                                evidence: evidence.first { $0.id == id },
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

