import AppKit
import SwiftUI

struct WorkspaceResearchPane: View {
    @Environment(AppSettings.self) private var settings
    @Bindable var model: ResearchWorkspaceModel
    let detail: WorkspaceDetail
    let onStart: (_ forceRefresh: Bool, _ depth: ResearchDepth) -> Void

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var record: ResearchRecord? { detail.research }
    private var versions: [WorkspaceReportVersion] { detail.versions }
    private var selectedVersionID: String? {
        model.presentation.selectedVersionID(for: detail.subject.id)
    }
    private var displayedVersion: WorkspaceReportVersion? {
        if let selectedVersionID,
           let selected = versions.first(where: { $0.id == selectedVersionID }) {
            return selected
        }
        return versions.first
    }
    private var displayedReport: BurstResearch? {
        displayedVersion?.report ?? record?.report
    }
    private var isHistorical: Bool {
        guard let displayedVersion else { return false }
        return displayedVersion.id != versions.first?.id
    }
    private var chosenDepth: ResearchDepth {
        model.presentation.depth(for: detail.subject.id) ?? model.defaultDepth
    }

    private var anchorBinding: Binding<String?> {
        Binding(
            get: { model.presentation.anchor(for: detail.subject.id, segment: .research) ?? "research.top" },
            set: { model.presentation.setAnchor($0, for: detail.subject.id, segment: .research) }
        )
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                Color.clear
                    .frame(height: 1)
                    .id("research.top")
                runSection
                    .id("research.run")
                if !versions.isEmpty {
                    versionSection
                        .id("research.versions")
                }
                if let report = displayedReport {
                    WorkspaceSectionHeader(
                        symbol: "doc.text",
                        title: displayedVersion.map { "V\($0.sequence)" }
                            ?? "workspace.report.legacy".localized,
                        trailing: displayedVersion?.createdAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                    WorkspaceReportBody(
                        report: report,
                        isHistorical: isHistorical,
                        onOpenURL: { url, title in
                            model.openEvidenceURL(url, title: title)
                        }
                    )
                    .id("research.report")
                } else {
                    Text("workspace.research.noReport".localized)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                footer
                    .id("research.footer")
            }
            .scrollTargetLayout()
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition(id: anchorBinding)
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

    private var versionSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                WorkspaceSectionHeader(
                    symbol: "clock.arrow.circlepath",
                    title: "workspace.research.versions".localized,
                    trailing: "\(versions.count)"
                )
                if isHistorical {
                    Button("workspace.research.viewLatest".localized) {
                        model.presentation.setSelectedVersionID(nil, for: detail.subject.id)
                        model.presentation.setAnchor("research.report", for: detail.subject.id, segment: .research)
                    }
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
                    .accessibilityLabel("workspace.research.viewLatest".localized)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(versions) { version in
                    versionRow(version)
                }
            }
        }
    }

    private func versionRow(_ version: WorkspaceReportVersion) -> some View {
        let selected = (displayedVersion?.id == version.id)
        return Button {
            model.presentation.setSelectedVersionID(version.id, for: detail.subject.id)
        } label: {
            HStack(spacing: 7) {
                Text("V\(version.sequence)")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(selected ? Color.accentColor : Color.secondary.opacity(0.12))
                    .editorialClipShape(cornerRadius: 4)

                Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)

                Text(triggerLabel(version.trigger))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)

                if let verdict = version.report.verification?.verdict {
                    Text(L10n.string(
                        "research.verdict.short.\(verdict.rawValue)",
                        language: settings.appLanguage
                    ))
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(verdictColor(verdict))
                }

                Text(L10n.string(
                    "workspace.research.evidenceCount",
                    language: settings.appLanguage,
                    version.report.evidence.count
                ))
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)

                Spacer(minLength: 0)

                if version.id == versions.first?.id {
                    Text("workspace.research.latest".localized)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                } else {
                    Text("workspace.research.readOnly".localized)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.10) : Color.clear)
            .editorialClipShape(cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("V\(version.sequence)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                .frame(height: 1)

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

    private func triggerLabel(_ origin: ResearchOrigin) -> String {
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

    private func verdictColor(_ verdict: VerificationReport.Verdict) -> Color {
        switch verdict {
        case .confirmed, .mostlyConfirmed: return .green
        case .mixed: return .orange
        case .unverified: return .secondary
        case .refuted: return .red
        }
    }
}
