import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class TransientResearchReportModel {
    private let researchStore: any ResearchPersisting
    private let workspaceStore: any WorkspacePersisting
    private let eventStore: any NewsEventPersisting
    private var revision = 0

    private(set) var recordID: String?
    private(set) var eventID: String?
    private(set) var fallbackSourceURL: String?
    private(set) var fallbackTitle: String?
    private(set) var record: ResearchRecord?
    private(set) var event: NewsEvent?
    private(set) var selectedVersion: WorkspaceReportVersion?
    private(set) var previousVersion: WorkspaceReportVersion?
    private(set) var availableRecord: ResearchRecord?
    private(set) var availableVersion: WorkspaceReportVersion?
    private(set) var availablePreviousVersion: WorkspaceReportVersion?
    private(set) var isShowingChanges = false
    private(set) var isLoading = false
    private(set) var didLoad = false
    var showsProgress = TestIsolation.defaults.bool(forKey: "reader.research.progressExpanded") {
        didSet { TestIsolation.defaults.set(showsProgress, forKey: "reader.research.progressExpanded") }
    }

    init(
        researchStore: any ResearchPersisting = ResearchStore.shared,
        workspaceStore: any WorkspacePersisting = WorkspaceSubjectStore.shared,
        eventStore: any NewsEventPersisting = NewsEventStore.shared
    ) {
        self.researchStore = researchStore
        self.workspaceStore = workspaceStore
        self.eventStore = eventStore
    }

    func open(
        recordID: String?,
        eventID: String?,
        versionID: String? = nil,
        compareFromVersionID: String? = nil,
        fallbackSourceURL: String? = nil,
        fallbackTitle: String? = nil,
        markReadOnOpen: Bool = false
    ) async {
        if self.recordID == recordID,
           self.eventID == eventID,
           self.selectedVersion?.id == versionID,
           self.previousVersion?.id == compareFromVersionID,
           self.fallbackSourceURL == fallbackSourceURL,
           self.fallbackTitle == fallbackTitle,
           didLoad {
            await reload()
            return
        }
        revision += 1
        let currentRevision = revision
        self.recordID = recordID
        self.eventID = eventID
        self.fallbackSourceURL = fallbackSourceURL
        self.fallbackTitle = fallbackTitle
        record = nil
        event = nil
        selectedVersion = nil
        previousVersion = nil
        availableRecord = nil
        availableVersion = nil
        availablePreviousVersion = nil
        isShowingChanges = false
        didLoad = false
        await reload(
            expectedRevision: currentRevision,
            markReadOnOpen: markReadOnOpen,
            requestedVersionID: versionID,
            requestedComparisonVersionID: compareFromVersionID
        )
    }

    func reload() async {
        revision += 1
        await reload(expectedRevision: revision)
    }

    func showAvailableChanges() {
        guard let latest = availableRecord else { return }
        record = latest
        selectedVersion = availableVersion
        previousVersion = availablePreviousVersion
        availableRecord = nil
        availableVersion = nil
        availablePreviousVersion = nil
        isShowingChanges = previousVersion != nil && selectedVersion != nil
    }

    func closeChanges() {
        isShowingChanges = false
        previousVersion = nil
        selectedVersion = nil
    }

    private func reload(
        expectedRevision: Int,
        markReadOnOpen: Bool = false,
        requestedVersionID: String? = nil,
        requestedComparisonVersionID: String? = nil
    ) async {
        isLoading = true
        defer {
            if revision == expectedRevision {
                isLoading = false
                didLoad = true
            }
        }

        let requestedRecordID = recordID
        let requestedEventID = eventID
        var resolvedRecord: ResearchRecord?
        var resolvedRecordID = requestedRecordID
        if let requestedRecordID {
            resolvedRecord = await researchStore.record(id: requestedRecordID)
        } else if let requestedEventID,
                  let subject = await workspaceStore.subject(containingEventID: requestedEventID) {
            let index = await researchStore.index()
            let linked = index
                .filter { subject.contains(recordID: $0.id) && $0.issue == nil && $0.status != .corrupt }
                .sorted(by: Self.preferredRecord)
            if let entry = linked.first {
                resolvedRecord = await researchStore.record(id: entry.id)
                resolvedRecordID = entry.id
            }
        }

        var resolvedEvent: NewsEvent?
        if let requestedEventID {
            resolvedEvent = try? await eventStore.event(id: requestedEventID)
        }
        if resolvedEvent == nil,
           let record = resolvedRecord,
           let seedURL = record.seed.url {
            let canonical = ContentIdentity.canonicalURL(seedURL)
            if !canonical.isEmpty {
                resolvedEvent = (try? await eventStore.events())?.first { candidate in
                    candidate.evidence.contains { ContentIdentity.canonicalURL($0.url) == canonical }
                }
            }
        }

        let versions: [WorkspaceReportVersion]
        if let resolvedRecordID {
            versions = await workspaceStore.versions(recordID: resolvedRecordID)
        } else {
            versions = []
        }
        guard revision == expectedRevision, !Task.isCancelled else { return }
        if markReadOnOpen,
           let resolvedRecord,
           resolvedRecord.status.marksReadOnOpen {
            _ = await researchStore.markReadOnOpen(id: resolvedRecord.id, at: Date())
            guard revision == expectedRevision, !Task.isCancelled else { return }
        }

        // IDs resolved from stores are written only after every async lookup
        // has proved that this request is still current.
        recordID = resolvedRecordID
        if requestedEventID == nil { eventID = resolvedEvent?.id }
        event = resolvedEvent

        if let requestedVersionID {
            selectedVersion = versions.first { $0.id == requestedVersionID }
            if let requestedComparisonVersionID {
                previousVersion = versions.first { $0.id == requestedComparisonVersionID }
                isShowingChanges = selectedVersion != nil && previousVersion != nil
            }
            record = resolvedRecord
            availableRecord = nil
            availableVersion = nil
            availablePreviousVersion = nil
            return
        }

        if let existing = record,
           existing.id == resolvedRecord?.id,
           let resolvedRecord,
           Self.reportDigest(existing) != Self.reportDigest(resolvedRecord) {
            availableRecord = resolvedRecord
            availableVersion = versions.last(where: { $0.digest == Self.reportDigest(resolvedRecord) })
            let visibleDigest = Self.reportDigest(existing)
            availablePreviousVersion = versions.last(where: { $0.digest == visibleDigest })
            if availablePreviousVersion == nil,
               let newest = availableVersion,
               let index = versions.firstIndex(where: { $0.id == newest.id }),
               index > 0 {
                availablePreviousVersion = versions[index - 1]
            }
            var refreshedProgress = existing
            refreshedProgress.run = resolvedRecord.run
            refreshedProgress.status = resolvedRecord.status
            refreshedProgress.updatedAt = resolvedRecord.updatedAt
            record = refreshedProgress
        } else {
            record = resolvedRecord
            availableRecord = nil
            availableVersion = nil
            availablePreviousVersion = nil
            if selectedVersion == nil { isShowingChanges = false }
        }
    }

    func matches(eventID: String?, recordID: String?) -> Bool {
        if let eventID, self.eventID == eventID { return true }
        if let recordID, self.recordID == recordID { return true }
        return false
    }

    private static func preferredRecord(_ lhs: ResearchIndexEntry, _ rhs: ResearchIndexEntry) -> Bool {
        if lhs.hasReport != rhs.hasReport { return lhs.hasReport }
        if lhs.status.isActive != rhs.status.isActive { return lhs.status.isActive }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }

    private static func reportDigest(_ record: ResearchRecord) -> String? {
        record.report.map(WorkspaceReportDigest.make)
    }
}

struct TransientResearchReportView: View {
    @Environment(AppSettings.self) private var settings
    @Bindable var model: TransientResearchReportModel
    let onClose: () -> Void
    let onOpenWorkspace: () -> Void
    let onOpenEventTimeline: () -> Void

    private var english: Bool { settings.appLanguage == .en }
    /// The report on screen. A selected version wins over the record's latest
    /// report, which is what makes a historical version readable here.
    private var displayedReport: BurstResearch? {
        ResearchReportDisplay.report(selectedVersion: model.selectedVersion, record: model.record)
    }
    private var isHistoricalReport: Bool {
        ResearchReportDisplay.isHistorical(selectedVersion: model.selectedVersion, record: model.record)
    }
    /// The label of the version actually on screen, if the model loaded one.
    /// The popup never invents a version when none was selected.
    private var copyVersionLabel: String? {
        model.selectedVersion.map { "V\($0.sequence)" }
    }
    private var fallbackSourceURL: String? { model.fallbackSourceURL }
    private var fallbackTitle: String? { model.fallbackTitle }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.availableRecord != nil {
                updateAvailableBanner
                Divider()
            }
            if let record = model.record, record.status.isActive {
                progressDisclosure(record)
                Divider()
            }
            if !model.didLoad {
                ProgressView(english ? "Loading research…" : "正在载入研究报告…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let record = model.record, let report = displayedReport {
                let changes: AnyView? = {
                    guard model.isShowingChanges,
                          let previous = model.previousVersion,
                          let current = model.selectedVersion else { return nil }
                    return AnyView(versionComparison(previous: previous, current: current))
                }()
                ResearchReportReader(
                    report: report,
                    contextID: record.id,
                    isHistorical: isHistoricalReport,
                    isLegacy: record.reportVersion == 0,
                    onOpenURL: openEvidenceURL,
                    onOpenEventTimeline: onOpenEventTimeline,
                    topContent: changes
                )
            } else if let event = model.event {
                eventContent(event)
            } else {
                unavailable
            }
        }
        .frame(minWidth: 620, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .researchRecordsChanged)) { notification in
            let changedID = notification.userInfo?[ResearchChangeKey.recordID] as? String
            guard changedID == nil || changedID == model.recordID else { return }
            Task { await model.reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .researchWorkspaceChanged)) { _ in
            Task { await model.reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newsEventsChanged)) { _ in
            Task { await model.reload() }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.event?.title ?? model.record?.topic ?? (english ? "Research report" : "研究报告"))
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let record = model.record {
                    Text(headerMeta(record))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Button(L10n.string("research.report.openWorkspace", language: settings.appLanguage)) {
                    onOpenWorkspace()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.recordID == nil)

                Menu {
                    Button(L10n.string("research.report.copy", language: settings.appLanguage)) {
                        copyMarkdown()
                    }
                    .disabled(displayedReport == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(L10n.string("research.report.actions.a11y", language: settings.appLanguage))

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityLabel(english ? "Close report" : "关闭报告")
            }
        }
        .padding(18)
    }

    /// Status plus the report's timestamp. The date is always "更新于" (updated):
    /// a generated date does not mean every quote was verified, so "核验于"
    /// claimed more than the report can back.
    private func headerMeta(_ record: ResearchRecord) -> String {
        let status = ResearchStatusPresentation.label(record.status, language: settings.appLanguage)
        guard let report = displayedReport else { return status }
        let date = (report.generatedAt ?? record.updatedAt)
            .formatted(date: .abbreviated, time: .shortened)
        let time = L10n.string(
            "research.report.meta.updated",
            language: settings.appLanguage,
            date
        )
        return "\(status) · \(time)"
    }

    private func copyMarkdown() {
        guard let report = displayedReport else { return }
        let title = model.event?.title ?? model.record?.topic ?? (english ? "Research report" : "研究报告")
        let markdown = WorkspaceReportMarkdown.make(
            report: report,
            subjectTitle: title,
            versionLabel: copyVersionLabel
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    private func progressDisclosure(_ record: ResearchRecord) -> some View {
        DisclosureGroup(isExpanded: $model.showsProgress) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(record.run.phase == .idle || record.run.phase == .done
                         ? ResearchStatusPresentation.label(record.status, language: settings.appLanguage)
                         : L10n.string("research.phase.\(record.run.phase.rawValue)", language: settings.appLanguage))
                        .font(.callout)
                }
                Text(english
                     ? "\(record.run.queriesCompleted)/\(record.run.queriesPlanned) searches · \(record.run.pagesRead) sources read"
                     : "已完成 \(record.run.queriesCompleted)/\(record.run.queriesPlanned) 次检索 · 已读 \(record.run.pagesRead) 个来源")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let facts = record.run.progressFacts, !facts.isEmpty {
                    ForEach(facts) { fact in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: fact.kind == .claimSupported ? "checkmark.seal" : "quote.bubble")
                                .font(.caption)
                                .foregroundStyle(fact.kind == .claimSupported ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(fact.claim ?? fact.title)
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let quote = fact.quote, !quote.isEmpty {
                                    Text("“\(quote)”")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Button(fact.title.isEmpty ? (english ? "Open source" : "打开来源") : fact.title) {
                                    openEvidenceURL(fact.url, title: fact.title)
                                }
                                .font(.caption2)
                                .buttonStyle(.link)
                            }
                        }
                        .padding(.top, 5)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Text(english ? "Show research progress" : "显示研究进度")
                .font(.subheadline.weight(.semibold))
        }
        .padding(12)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
    }

    private var updateAvailableBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(english ? "A newer report is ready" : "新版报告已就绪")
                    .font(.subheadline.weight(.semibold))
                Text(english ? "Your current version stays open until you switch." : "当前版本会保持打开，直到你选择查看新版。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button(english ? "View changes" : "查看变化") {
                model.showAvailableChanges()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.08))
    }

    private func versionComparison(
        previous: WorkspaceReportVersion,
        current: WorkspaceReportVersion
    ) -> some View {
        let oldEvidence = Set(previous.report.evidence.map(\.canonicalURL))
        let addedEvidence = current.report.evidence.filter { !oldEvidence.contains($0.canonicalURL) }
        let refutedClaims = current.report.verification?.claims.filter { $0.status == .refutes } ?? []
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(english ? "What changed" : "本次变化", systemImage: "arrow.left.arrow.right")
                    .font(.headline)
                Spacer()
                Button(english ? "Hide" : "收起") { model.closeChanges() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 10) {
                comparisonColumn(
                    title: english ? "Previous version" : "此前结论",
                    value: previous.report.summary
                )
                comparisonColumn(
                    title: english ? "Current version" : "当前结论",
                    value: current.report.summary
                )
            }
            if !refutedClaims.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(english ? "Claims now refuted" : "本版已驳斥的主张")
                        .font(.subheadline.weight(.semibold))
                    ForEach(refutedClaims) { claim in
                        Text("• \(claim.claim)")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !addedEvidence.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(english ? "New evidence" : "新增依据")
                        .font(.subheadline.weight(.semibold))
                    ForEach(addedEvidence, id: \.canonicalURL) { evidence in
                        Button(evidence.title.isEmpty ? evidence.url : evidence.title) {
                            openEvidenceURL(evidence.url, title: evidence.title)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }
            Text(english
                 ? "Version \(previous.sequence) → \(current.sequence)"
                 : "版本 \(previous.sequence) → \(current.sequence)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func comparisonColumn(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value.isEmpty ? (english ? "No summary." : "暂无摘要。") : value)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func eventContent(_ event: NewsEvent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(event.eventDescription)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                if !event.claims.isEmpty {
                    ForEach(event.claims) { claim in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(claim.text).font(.subheadline.weight(.medium))
                            Text(claim.status.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
                Text(english ? "No research report is available yet." : "该事件暂时还没有研究报告。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // An event with a failed active run stays diagnosable from here;
                // `unavailable` is a different branch, so this cannot duplicate it.
                if let lastError = model.record?.run.lastError, !lastError.isEmpty {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let fallbackSourceURL {
                    sourceFallbackButton(fallbackSourceURL, title: fallbackTitle)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(unavailableHeadline)
                .font(.headline)
            Text(english ? "The reading window and your search position are still available." : "关闭此窗口即可回到原来的阅读位置或搜索。")
                .font(.callout)
                .foregroundStyle(.secondary)
            // The popup no longer renders a "no report yet" branch of its own,
            // so a failed run's message stays visible here instead of vanishing.
            if let lastError = model.record?.run.lastError, !lastError.isEmpty {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let fallbackSourceURL {
                sourceFallbackButton(fallbackSourceURL, title: fallbackTitle)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A record that exists but has no report is a different state from a
    /// record that disappeared, so the headline must not claim removal.
    private var unavailableHeadline: String {
        if model.record != nil {
            return english ? "No readable report is available for this item." : "当前项目还没有可读取的报告。"
        }
        return english ? "This report was removed or is unavailable." : "该报告已移除或暂时不可用。"
    }

    private func openEvidenceURL(_ rawURL: String, title: String) {
        guard let url = ReaderNavigationPolicy.allowedURL(rawURL) else { return }
        NewsNavigationRouter.shared.open(url: url.absoluteString, title: title, surface: "researchReport")
    }

    private func sourceFallbackButton(_ rawURL: String, title: String?) -> some View {
        Button(english ? "Open original source" : "打开原文来源") {
            openEvidenceURL(rawURL, title: title ?? (english ? "Original source" : "原文来源"))
        }
        .buttonStyle(.link)
    }
}
