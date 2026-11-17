import SwiftUI

struct WorkspaceOverviewPane: View {
    @Environment(AppSettings.self) private var settings
    @Bindable var model: ResearchWorkspaceModel
    let detail: WorkspaceDetail
    let onStartResearch: (Bool) -> Void
    let onRequestSegment: (WorkspaceSegment) -> Void

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var metrics: WorkspaceSourceMetrics { detail.metrics }

    private var anchorBinding: Binding<String?> {
        Binding(
            get: { model.presentation.anchor(for: detail.subject.id, segment: .overview) ?? "overview.top" },
            set: { model.presentation.setAnchor($0, for: detail.subject.id, segment: .overview) }
        )
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                Color.clear
                    .frame(height: 1)
                    .id("overview.top")
                if let event = detail.event {
                    eventSection(event)
                        .id("overview.event")
                }

                latestReportSection
                    .id("overview.report")
                pendingUpdatesSection
                    .id("overview.updates")
                metricsSection
                    .id("overview.metrics")
                checkStatusSection
                    .id("overview.check")
                nextActionSection
                    .id("overview.next")
            }
            .scrollTargetLayout()
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition(id: anchorBinding)
    }

    // MARK: - Event

    private func eventSection(_ event: NewsEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            WorkspaceSectionHeader(
                symbol: "dot.radiowaves.left.and.right",
                title: "workspace.overview.event".localized,
                trailing: event.lifecycle.rawValue
            )

            if !event.eventDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(event.eventDescription)
                    .font(.system(size: 12, design: isRetro ? .serif : .default))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !event.claims.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(event.claims.enumerated()), id: \.offset) { _, claim in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: eventClaimSymbol(claim.status))
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(eventClaimColor(claim.status))
                                .accessibilityHidden(true)
                            Text(claim.text)
                                .font(.system(size: 11))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            let conflicts = event.coreConflictDetails + event.detailConflictDetails
            if !conflicts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("workspace.overview.eventConflicts".localized)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                    ForEach(Array(conflicts.enumerated()), id: \.offset) { _, text in
                        Text("· \(text)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: 10) {
                Label(L10n.string(
                    "workspace.overview.eventEvidence",
                    language: settings.appLanguage,
                    event.evidence.count
                ), systemImage: "quote.bubble")
                Label(L10n.string(
                    "workspace.overview.eventPublishers",
                    language: settings.appLanguage,
                    event.countablePublisherCount
                ), systemImage: "building.2")
                Button("workspace.overview.openTimeline".localized) {
                    onRequestSegment(.timeline)
                }
                .buttonStyle(.plain)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
                Spacer(minLength: 0)
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Latest report

    private var latestReportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            WorkspaceSectionHeader(
                symbol: "doc.text.magnifyingglass",
                title: "workspace.overview.latestReport".localized,
                trailing: detail.versions.first.map { "V\($0.sequence)" }
            )

            if let record = detail.research, let report = record.report {
                HStack(spacing: 6) {
                    if let verdict = report.verification?.verdict {
                        Text(L10n.string(
                            "research.verdict.\(verdict.rawValue)",
                            language: settings.appLanguage
                        ))
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(verdictColor(verdict))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(verdictColor(verdict).opacity(0.11))
                        .editorialClipShape(cornerRadius: 5)
                    }
                    if let date = report.generatedAt {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    if detail.versions.count > 1 {
                        Text(L10n.string(
                            "workspace.overview.versions",
                            language: settings.appLanguage,
                            detail.versions.count
                        ))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    }
                }

                let summary = report.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                Text(summary.isEmpty ? "workspace.report.noSummary".localized : summary)
                    .font(.system(size: 12, design: isRetro ? .serif : .default))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                HStack(spacing: 10) {
                    Button("workspace.overview.readReport".localized) {
                        onRequestSegment(.research)
                    }
                    .buttonStyle(EditorialActionButtonStyle(compact: true))

                    Text(L10n.string(
                        "workspace.overview.reportEvidence",
                        language: settings.appLanguage,
                        report.evidence.count
                    ))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
            } else {
                Text("workspace.overview.noReport".localized)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("workspace.action.startResearch".localized) {
                    onStartResearch(false)
                }
                .buttonStyle(EditorialActionButtonStyle(tone: .prominent, compact: true))
                .disabled(!model.canStartResearch)
            }
        }
    }

    // MARK: - Pending updates

    private var pendingUpdatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            WorkspaceSectionHeader(
                symbol: "tray.and.arrow.down",
                title: "workspace.overview.updates".localized,
                trailing: "\(detail.updates.count)"
            )

            if detail.updates.isEmpty {
                Text("workspace.overview.noUpdates".localized)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(detail.updates.prefix(6))) { update in
                        updateRow(update)
                    }
                }
                if detail.updates.count > 6 {
                    Text(L10n.string(
                        "workspace.overview.moreUpdates",
                        language: settings.appLanguage,
                        detail.updates.count - 6
                    ))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                }
                if model.hasUnreadUpdates || !detail.updates.isEmpty {
                    Button("workspace.overview.updateResearch".localized) {
                        onStartResearch(false)
                    }
                    .buttonStyle(EditorialActionButtonStyle(tone: .prominent, compact: true))
                    .disabled(!model.canStartResearch)
                    .help("workspace.review.hint".localized)
                }
            }
        }
    }

    private func updateRow(_ update: WorkspaceUpdateCandidate) -> some View {
        Button {
            model.openEvidenceURL(update.url, title: update.title)
        } label: {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: update.origin == .rss
                      ? "antenna.radiowaves.left.and.right"
                      : (update.origin == .event ? "dot.radiowaves.left.and.right" : "globe"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: 13)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(update.title)
                        .font(.system(size: 11))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        Text(update.sourceName)
                        Text("·")
                        Text(update.publishedAt.map {
                            $0.formatted(date: .abbreviated, time: .omitted)
                        } ?? update.discoveredAt.formatted(date: .abbreviated, time: .shortened))
                        if update.origin == .research {
                            Text("· \("workspace.search.lead".localized)")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(.quaternary.opacity(0.16))
            .editorialClipShape(cornerRadius: 7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(update.title)
    }

    // MARK: - Metrics and check status

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            WorkspaceSectionHeader(
                symbol: "chart.bar.doc.horizontal",
                title: "workspace.metrics.title".localized
            )
            HStack(spacing: 8) {
                metricChip(
                    title: "workspace.metrics.researchSources".localized,
                    value: "\(metrics.researchIndependentSourceCount)",
                    help: L10n.string(
                        "workspace.metrics.researchHelp",
                        language: settings.appLanguage,
                        metrics.researchUniqueDomainCount
                    )
                )
                metricChip(
                    title: "workspace.metrics.notificationSubjects".localized,
                    value: "\(metrics.notificationPublisherCount)",
                    help: L10n.string(
                        "workspace.metrics.notificationHelp",
                        language: settings.appLanguage
                    )
                )
                Spacer(minLength: 0)
            }
        }
    }

    private func metricChip(title: String, value: String, help: String) -> some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.25))
        .editorialClipShape(cornerRadius: 7)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(value)")
        .accessibilityHint(help)
    }

    private var checkStatusSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(checkStatusText)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text("workspace.check.rssOnly".localized)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
            if let coverage = model.lastCheckCoverage,
               model.lastCheckCoverageSubjectID == detail.subject.id {
                Text(coverageText(coverage))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            if detail.subject.isArchived {
                Text("workspace.archived.note".localized)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }

    private func coverageText(_ coverage: WorkspaceCheckCoverage) -> String {
        let budget: String
        if let used = coverage.budgetUsed, let limit = coverage.budgetLimit {
            budget = L10n.string(
                "workspace.check.budget",
                language: settings.appLanguage,
                used,
                limit
            )
        } else {
            budget = L10n.string(
                "workspace.check.budgetUnknown",
                language: settings.appLanguage
            )
        }
        if coverage.reusedSharedCheck {
            return L10n.string(
                "workspace.check.coverageReused",
                language: settings.appLanguage,
                budget
            )
        }
        let next = coverage.nextEligibleAt.map(model.timeText) ?? "—"
        let base = L10n.string(
            "workspace.check.coverageLine",
            language: settings.appLanguage,
            coverage.checkedSourceNames.count,
            max(coverage.eligibleSourceCount, coverage.checkedSourceNames.count),
            budget,
            next
        )
        guard coverage.deferredSourceCount > 0 else { return base }
        return base + " " + L10n.string(
            "workspace.check.deferred",
            language: settings.appLanguage,
            coverage.deferredSourceCount
        )
    }

    private var checkStatusText: String {
        switch model.updateCheckAvailability {
        case .noSources:
            return "workspace.check.noSources".localized
        case .pendingChecker:
            return "workspace.check.pending".localized
        case .ready:
            guard let date = detail.subject.lastCheckOutcome.checkedAt
                    ?? detail.subject.lastCheckedAt else {
                return "workspace.check.never".localized
            }
            switch detail.subject.lastCheckOutcome {
            case let .checked(added, _):
                return L10n.string(
                    "workspace.check.lastCheckedAdded",
                    language: settings.appLanguage,
                    model.timeText(date),
                    added
                )
            case let .failed(message, _):
                return L10n.string(
                    "workspace.check.lastFailed",
                    language: settings.appLanguage,
                    message
                )
            case let .throttled(until):
                return L10n.string(
                    "workspace.check.throttled",
                    language: settings.appLanguage,
                    model.timeText(until)
                )
            case .notConfigured:
                return "workspace.check.never".localized
            }
        }
    }

    // MARK: - Next action

    private var nextActionSection: some View {
        HStack(spacing: 9) {
            Image(systemName: nextActionSymbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(nextActionText)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if model.primaryAction == .view {
                Button("workspace.action.viewResearch".localized) {
                    onRequestSegment(.research)
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))
            }
        }
        .padding(.top, 2)
    }

    private var nextActionSymbol: String {
        switch model.primaryAction {
        case .start: return "play.circle"
        case .active: return "hourglass"
        case .update: return "arrow.triangle.2.circlepath"
        case .view: return "doc.text.magnifyingglass"
        case .none: return "square.stack.3d.up"
        }
    }

    private var nextActionText: String {
        switch model.primaryAction {
        case .start: return "workspace.next.start".localized
        case .active: return "workspace.next.active".localized
        case .update: return "workspace.next.update".localized
        case .view: return "workspace.next.view".localized
        case .none: return "workspace.next.none".localized
        }
    }

    // MARK: - Helpers

    private func eventClaimSymbol(_ status: NewsEventClaimStatus) -> String {
        switch status {
        case .supported: return "checkmark.circle.fill"
        case .contested: return "exclamationmark.triangle.fill"
        case .corrected: return "arrow.triangle.2.circlepath"
        case .unverified: return "questionmark.circle"
        }
    }

    private func eventClaimColor(_ status: NewsEventClaimStatus) -> Color {
        switch status {
        case .supported: return .green
        case .contested: return .orange
        case .corrected: return .blue
        case .unverified: return .secondary
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
}
