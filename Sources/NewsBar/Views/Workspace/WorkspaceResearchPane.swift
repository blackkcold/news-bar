import AppKit
import SwiftUI

struct WorkspaceResearchPane: View {
    @Environment(AppSettings.self) private var settings
    @Bindable var model: ResearchWorkspaceModel
    let detail: WorkspaceDetail
    let onStart: (_ forceRefresh: Bool, _ depth: ResearchDepth) -> Void
    let onRequestSegment: (WorkspaceSegment) -> Void

    private var record: ResearchRecord? { detail.research }
    private var versions: [WorkspaceReportVersion] { detail.versions }

    /// The explicitly selected version, if it still exists. Nil means "latest",
    /// which is also what the record's report holds.
    private var selectedVersion: WorkspaceReportVersion? {
        guard let selectedVersionID = model.presentation.selectedVersionID(for: detail.subject.id) else {
            return nil
        }
        return versions.first { $0.id == selectedVersionID }
    }

    private var displayedVersion: WorkspaceReportVersion? {
        selectedVersion ?? versions.first
    }

    private var displayedReport: BurstResearch? {
        ResearchReportDisplay.report(selectedVersion: selectedVersion, record: record)
    }

    private var isHistorical: Bool {
        ResearchReportDisplay.isHistorical(selectedVersion: selectedVersion, record: record)
    }

    private var chosenDepth: ResearchDepth {
        model.presentation.depth(for: detail.subject.id) ?? model.defaultDepth
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                runSection
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            Divider()

            if let report = displayedReport {
                // The reader owns the only scroll view in this pane; the run
                // strip and the action bar stay fixed around it.
                ResearchReportReader(
                    report: report,
                    contextID: record?.id,
                    isHistorical: isHistorical,
                    isLegacy: record?.reportVersion == 0,
                    onOpenURL: { url, title in
                        model.openEvidenceURL(url, title: title)
                    },
                    onOpenEventTimeline: { onRequestSegment(.timeline) }
                )
            } else {
                emptyReportState
            }

            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: chosenDepth) { _, depth in
            Task { await model.refreshReusePreview(depth: depth) }
        }
    }

    // MARK: - Current run

    private var runSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                statusDot
                Text(statusLine)
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
                if let record {
                    Text(originMeta(record))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
                if !versions.isEmpty {
                    versionMenu
                }
            }

            if let record {
                HStack(spacing: 10) {
                    Label(L10n.string(
                        "workspace.research.queries",
                        language: settings.appLanguage,
                        record.run.queriesCompleted,
                        record.run.queriesPlanned
                    ), systemImage: "magnifyingglass")
                    Label(L10n.string(
                        "workspace.research.pages",
                        language: settings.appLanguage,
                        record.run.pagesRead
                    ), systemImage: "doc.text")
                    Label(L10n.string(
                        "workspace.research.aiCalls",
                        language: settings.appLanguage,
                        record.run.aiCalls
                    ), systemImage: "sparkles")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

                if record.status.isActive {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text(phaseLabel(record.run.phase))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("workspace.research.cancel".localized) {
                            Task { await model.cancelActiveResearch() }
                        }
                        .buttonStyle(EditorialActionButtonStyle(tone: .destructive, compact: true))
                        .accessibilityLabel("workspace.research.cancel".localized)
                    }
                }

                if let error = record.run.lastError, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("workspace.research.notStarted".localized)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 2)
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }

    private var statusColor: Color {
        guard let record else { return .secondary }
        return ResearchStatusPresentation.tint(record.status)
    }

    private var statusLine: String {
        guard let record else {
            return "workspace.research.none".localized
        }
        return ResearchStatusPresentation.label(record.status, language: settings.appLanguage)
    }

    // MARK: - Versions

    /// The version list collapsed into the run strip. Selecting a version shows
    /// that report read-only; "view latest" returns to `selectedVersionID == nil`.
    private var versionMenu: some View {
        Menu {
            ForEach(versions) { version in
                Button {
                    model.presentation.setSelectedVersionID(version.id, for: detail.subject.id)
                } label: {
                    if displayedVersion?.id == version.id {
                        Label(versionTitle(version), systemImage: "checkmark")
                    } else {
                        Text(versionTitle(version))
                    }
                }
            }
            if isHistorical {
                Divider()
                Button("workspace.research.viewLatest".localized) {
                    model.presentation.setSelectedVersionID(nil, for: detail.subject.id)
                }
            }
        } label: {
            Label(
                displayedVersion.map { "V\($0.sequence)" }
                    ?? "workspace.report.legacy".localized,
                systemImage: "clock.arrow.circlepath"
            )
            .font(.system(size: 10))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("workspace.research.versions".localized)
        .accessibilityLabel("workspace.research.versions".localized)
    }

    private func versionTitle(_ version: WorkspaceReportVersion) -> String {
        "V\(version.sequence) · \(version.createdAt.formatted(date: .abbreviated, time: .shortened))"
    }

    // MARK: - Empty report

    private var emptyReportState: some View {
        VStack(spacing: 7) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("workspace.research.noReport".localized)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Footer

    /// Fixed action bar below the reader. It stays put while the report scrolls.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Button(primaryButtonTitle) {
                    onStart(false, chosenDepth)
                }
                .buttonStyle(EditorialActionButtonStyle(
                    tone: model.primaryAction == .update ? .prominent : .primary,
                    compact: true
                ))
                .disabled(!model.canStartResearch || model.primaryAction == .active)
                .accessibilityLabel(primaryButtonTitle)

                if displayedReport != nil {
                    Button("workspace.research.force".localized) {
                        onStart(true, chosenDepth)
                    }
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
                    .disabled(!model.canStartResearch || model.primaryAction == .active)
                    .help("workspace.research.forceHelp".localized)
                    .accessibilityLabel("workspace.research.force".localized)
                }

                depthMenu
                Spacer(minLength: 0)

                Button {
                    copyMarkdown()
                } label: {
                    Label("workspace.research.copy".localized, systemImage: "doc.on.doc")
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))
                .disabled(displayedReport == nil)
                .accessibilityLabel("workspace.research.copy".localized)
            }

            if let hint = model.reuseHint {
                Label(hint, systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            } else {
                Text("workspace.research.depthHint".localized)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var primaryButtonTitle: String {
        switch model.primaryAction {
        case .update: return "workspace.action.updateResearch".localized
        case .active: return "workspace.status.researching".localized
        case .view: return "workspace.action.updateResearch".localized
        case .start, .none: return "workspace.action.startResearch".localized
        }
    }

    private var depthMenu: some View {
        Menu {
            ForEach(ResearchDepth.allCases, id: \.self) { depth in
                Button {
                    model.presentation.setDepth(depth, for: detail.subject.id)
                } label: {
                    if depth == chosenDepth {
                        Label(depthLabel(depth), systemImage: "checkmark")
                    } else {
                        Text(depthLabel(depth))
                    }
                }
            }
        } label: {
            Label(depthLabel(chosenDepth), systemImage: "slider.horizontal.3")
                .font(.system(size: 10))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("workspace.research.depth".localized)
        .accessibilityLabel("workspace.research.depth".localized)
    }

    // MARK: - Helpers

    private func copyMarkdown() {
        guard let report = displayedReport else { return }
        let markdown = WorkspaceReportMarkdown.make(
            report: report,
            subjectTitle: detail.subject.title,
            versionLabel: displayedVersion.map { "V\($0.sequence)" }
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        model.presentNotice(
            L10n.string("workspace.research.copied", language: settings.appLanguage),
            tone: .info,
            subjectID: detail.subject.id
        )
    }

    private func originMeta(_ record: ResearchRecord) -> String {
        [
            originLabel(record.origin),
            L10n.string("workspace.report.depth", language: settings.appLanguage, depthLabel(record.run.depth)),
        ].joined(separator: " · ")
    }

    private func originLabel(_ origin: ResearchOrigin) -> String {
        switch origin {
        case .burst: return "workspace.origin.burst".localized
        case .keyword: return "workspace.origin.keyword".localized
        case .interest: return "workspace.origin.interest".localized
        case .manual: return "workspace.origin.manual".localized
        }
    }

    private func depthLabel(_ depth: ResearchDepth) -> String {
        L10n.string("workspace.research.depth.\(depth.rawValue)", language: settings.appLanguage)
    }

    private func phaseLabel(_ phase: ResearchRun.Phase) -> String {
        L10n.string("research.phase.\(phase.rawValue)", language: settings.appLanguage)
    }
}
