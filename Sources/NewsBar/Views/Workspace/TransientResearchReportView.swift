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
    private var target: Target?
    private var requestedEventID: String?

    private struct Target: Equatable {
        enum Item: Equatable {
            case record(String), event(String), url(String)
        }
        let item: Item?
        let versionID: String?
        let comparisonID: String?
    }

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
    private(set) var didLoad = false
    private(set) var readingID = UUID()
    /// The target pinned a version that is no longer stored. The record may
    /// still have a current report, but it is a different identity.
    private(set) var pinnedVersionUnavailable = false
    private var displayedVersion: WorkspaceReportVersion?
    private var currentVersion: WorkspaceReportVersion?
    private var unversionedDate: Date?

    var displayedReport: BurstResearch? { selectedVersion?.report ?? record?.report }
    var displayedDate: Date? {
        guard let displayedReport else { return nil }
        return displayedVersion?.createdAt ?? displayedReport.generatedAt ?? unversionedDate
    }
    var displayedVersionLabel: String? {
        guard let sequence = displayedVersion?.sequence, sequence > 0 else { return nil }
        return "V\(sequence)"
    }
    var copyVersionLabel: String? { selectedVersion.map { "V\($0.sequence)" } }
    /// A notification can pin the version that is still current; only a
    /// version older than the record's current one is a historical read, and
    /// an unreadable pin must not borrow the latest report's identity.
    var isHistorical: Bool {
        guard target?.versionID != nil else { return false }
        guard let selectedVersion, let currentVersion else { return true }
        return selectedVersion.id != currentVersion.id
    }
    var currentTaskStatus: ResearchStatus? { isHistorical ? nil : record?.status }
    /// A vanished pinned version is its own state: the task may have reports
    /// and may even be running, but neither fact explains the missing version.
    var emptyState: TransientReportEmptyState {
        pinnedVersionUnavailable ? .unavailableVersion : TransientReportEmptyState(status: currentTaskStatus)
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
        let item = recordID.map(Target.Item.record)
            ?? eventID.map(Target.Item.event)
            ?? fallbackSourceURL.map { .url(ContentIdentity.canonicalURL($0)) }
        let request = Target(item: item, versionID: versionID, comparisonID: compareFromVersionID)
        self.fallbackSourceURL = fallbackSourceURL
        self.fallbackTitle = fallbackTitle
        if let target,
           target.versionID == request.versionID,
           target.comparisonID == request.comparisonID,
           (target == request || recordID.map { $0 == self.recordID } == true
                || (recordID == nil && self.recordID != nil && eventID.map { $0 == self.eventID } == true)) {
            if didLoad { await reload() }
            return
        }
        revision += 1
        let currentRevision = revision
        target = request
        requestedEventID = eventID
        self.recordID = recordID
        self.eventID = eventID
        record = nil
        event = nil
        selectedVersion = nil
        previousVersion = nil
        displayedVersion = nil
        currentVersion = nil
        unversionedDate = nil
        pinnedVersionUnavailable = false
        clearAvailable()
        isShowingChanges = false
        didLoad = false
        readingID = UUID()
        await reload(expectedRevision: currentRevision, markReadOnOpen: markReadOnOpen)
    }

    func reload() async {
        // A change notification from markReadOnOpen must not replace the
        // in-flight initial request (including its pinned version).
        guard didLoad else { return }
        revision += 1
        await reload(expectedRevision: revision)
    }

    func showAvailableChanges() {
        guard let latest = availableRecord else { return }
        revision += 1
        record = latest
        selectedVersion = availableVersion
        displayedVersion = availableVersion
        currentVersion = availableVersion
        unversionedDate = latest.updatedAt
        previousVersion = availablePreviousVersion
        clearAvailable()
        isShowingChanges = previousVersion != nil && selectedVersion != nil
        readingID = UUID()
    }

    func closeChanges() {
        isShowingChanges = false
        if !isHistorical {
            previousVersion = nil
            selectedVersion = nil
        }
    }

    private func reload(
        expectedRevision: Int,
        markReadOnOpen: Bool = false
    ) async {
        let requestedRecordID = recordID
        let requestedEventID = self.requestedEventID
        let requestedVersionID = target?.versionID
        let requestedComparisonVersionID = target?.comparisonID
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
        eventID = requestedEventID ?? resolvedEvent?.id
        event = resolvedEvent

        let latestVersion = resolvedRecord?.report.flatMap { report in
            versions.last { $0.report == report }
        }
        currentVersion = latestVersion

        defer { didLoad = true }
        if let requestedVersionID {
            if let pinned = selectedVersion ?? versions.first(where: { $0.id == requestedVersionID }) {
                if selectedVersion == nil {
                    // A version can become readable after the record first opened.
                    if didLoad { readingID = UUID() }
                    selectedVersion = pinned
                    previousVersion = versions.first { $0.id == requestedComparisonVersionID }
                    isShowingChanges = previousVersion != nil
                }
                displayedVersion = pinned
                record = resolvedRecord
                pinnedVersionUnavailable = false
                clearAvailable()
                return
            }
            // The pin is gone (deleted history, or a stale notification). The
            // latest report is a different identity and must not stand in for
            // it, and neither may the current task's progress: the reader says
            // the version itself is unavailable.
            var unreadable = resolvedRecord
            unreadable?.report = nil
            record = unreadable
            selectedVersion = nil
            displayedVersion = nil
            unversionedDate = nil
            pinnedVersionUnavailable = true
            clearAvailable()
            return
        }

        if let existing = record, let visibleReport = displayedReport {
            let newerVersion = latestVersion.flatMap { latest in
                displayedVersion.map { latest.sequence > $0.sequence }
            } == true
            if let resolvedRecord, resolvedRecord.report != nil,
               resolvedRecord.report != visibleReport || newerVersion {
                availableRecord = resolvedRecord
                availableVersion = latestVersion
                availablePreviousVersion = displayedVersion ?? versions.last { $0.report == visibleReport }
            } else {
                clearAvailable()
                if resolvedRecord?.report == visibleReport, displayedVersion == nil {
                    displayedVersion = latestVersion
                }
            }
            var refreshedProgress = existing
            if let resolvedRecord {
                refreshedProgress.run = resolvedRecord.run
                refreshedProgress.status = resolvedRecord.status
            }
            record = refreshedProgress
        } else {
            record = resolvedRecord
            displayedVersion = latestVersion
            unversionedDate = resolvedRecord?.updatedAt
            clearAvailable()
        }
    }

    private func clearAvailable() {
        availableRecord = nil
        availableVersion = nil
        availablePreviousVersion = nil
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

}

/// Why the popup has no readable report. A running task, a finished failure
/// and a vanished pinned version each get their own state; a record that is
/// merely missing a report must not be shown as completed. Kept out of the
/// view so the copy is testable.
enum TransientReportEmptyState: Equatable {
    case researching
    case ended(ResearchStatus)
    case unavailable
    /// The notification pinned a version that is no longer stored. It is not
    /// "no report yet" and not the current task's failure.
    case unavailableVersion

    init(status: ResearchStatus?) {
        guard let status else {
            self = .unavailable
            return
        }
        if status.isActive {
            self = .researching
        } else if [.failed, .cancelled, .interrupted, .corrupt].contains(status) {
            self = .ended(status)
        } else {
            // ready/partial without a report is a gap, not a completed read.
            self = .unavailable
        }
    }

    func headline(language: AppLanguage) -> String {
        switch self {
        case .researching:
            return language == .en
                ? "Research in progress · No readable report yet"
                : "研究中 · 尚无可读报告"
        case .ended(.failed):
            return language == .en ? "Research failed · No readable report yet" : "研究失败 · 尚无可读报告"
        case .ended(.cancelled):
            return language == .en ? "Research cancelled · No readable report yet" : "研究已取消 · 尚无可读报告"
        case .ended(.interrupted):
            return language == .en ? "Research interrupted · No readable report yet" : "研究已中断 · 尚无可读报告"
        case .ended(.corrupt):
            return language == .en ? "Report file is unreadable" : "报告文件无法读取"
        case .ended:
            return language == .en ? "No readable report yet" : "尚无可读报告"
        case .unavailable:
            return language == .en ? "No readable report yet" : "尚无可读报告"
        case .unavailableVersion:
            return language == .en
                ? "This historical version is no longer available"
                : "该历史版本已不可用"
        }
    }

    /// The one sentence that explains the state without offering an action.
    /// History is read-only here; recovery belongs to the research center.
    func detail(language: AppLanguage) -> String? {
        guard self == .unavailableVersion else { return nil }
        return language == .en
            ? "The version this notification points to is not stored on this Mac. The current report is available in the research center."
            : "这条通知指向的版本已不在本机历史中。当前报告可在研究中心查看。"
    }
}

struct TransientResearchReportView: View {
    @Environment(AppSettings.self) private var settings
    @State private var citations = ResearchReportCitationPresentation()
    let model: TransientResearchReportModel
    let onClose: () -> Void
    let onOpenWorkspace: () -> Void
    let onOpenEventTimeline: () -> Void

    private var english: Bool { settings.appLanguage == .en }
    private var reportTitle: String {
        model.event?.title ?? model.record?.topic ?? (english ? "Research report" : "研究报告")
    }
    private var fallbackSourceURL: String? { model.fallbackSourceURL }
    private var fallbackTitle: String? { model.fallbackTitle }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.didLoad {
                ProgressView(english ? "Loading research…" : "正在载入研究报告…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let report = model.displayedReport {
                if model.availableRecord != nil {
                    updateAvailableBanner
                    Divider()
                } else if let status = model.currentTaskStatus, status.isActive || status == .failed {
                    Label(
                        taskLabel(status),
                        systemImage: status.isActive ? "clock" : "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    Divider()
                }
                let changes: AnyView? = {
                    guard model.isShowingChanges,
                          let previous = model.previousVersion,
                          let current = model.selectedVersion else { return nil }
                    return AnyView(versionComparison(previous: previous, current: current))
                }()
                ResearchReportReader(
                    report: report,
                    contextID: model.recordID,
                    isLegacy: model.isHistorical ? report.promptVersion == 0 : model.record?.reportVersion == 0,
                    onOpenURL: openEvidenceURL,
                    onOpenEventTimeline: onOpenEventTimeline,
                    topContent: changes,
                    presentation: .popup
                )
                .environment(\.researchReportCitations, citations)
                .id(model.readingID)
            } else {
                noReport
            }
        }
        .frame(minWidth: 620, minHeight: 560)
        .appThemeSurface()
        .background(Color(nsColor: .windowBackgroundColor))
        .adaptiveColorScheme()
        .onExitCommand {
            if !citations.dismiss() { onClose() }
        }
        .onChange(of: model.readingID) { citations.dismiss() }
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
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                headerControls(includesWorkspaceButton: true)
                headerControls(includesWorkspaceButton: false)
            }
            Text(model.event?.title ?? model.record?.topic ?? fallbackTitle ?? reportTitle)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func headerControls(includesWorkspaceButton: Bool) -> some View {
        HStack(spacing: 8) {
            if let meta = headerMeta {
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if includesWorkspaceButton {
                Button(workspaceTitle, action: onOpenWorkspace)
                    .buttonStyle(.bordered)
                    .disabled(!canOpenWorkspace)
            }
            Menu {
                if !includesWorkspaceButton {
                    Button(workspaceTitle, action: onOpenWorkspace)
                        .disabled(!canOpenWorkspace)
                }
                Button(L10n.string("research.report.copy", language: settings.appLanguage), action: copyMarkdown)
                    .disabled(model.displayedReport == nil)
            } label: {
                Text(english ? "More" : "更多")
            }
            .fixedSize()
            .accessibilityLabel(L10n.string("research.report.actions.a11y", language: settings.appLanguage))
        }
        .controlSize(.small)
    }

    private var workspaceTitle: String { english ? "Research Center" : "研究中心" }
    private var canOpenWorkspace: Bool { model.recordID != nil || model.eventID != nil }

    private var headerMeta: String? {
        let components = [
            model.isHistorical ? (english ? "Historical version" : "历史版") : nil,
            model.displayedVersionLabel,
            model.displayedDate?.formatted(Date.FormatStyle(
                date: .abbreviated, time: .omitted, locale: Locale(identifier: settings.appLanguage.bcp47)
            )),
        ].compactMap { $0 }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    private func taskLabel(_ status: ResearchStatus) -> String {
        let label = ResearchStatusPresentation.label(status, language: settings.appLanguage)
        return english ? "Current research: \(label)" : "当前研究：\(label)"
    }

    private func copyMarkdown() {
        guard let report = model.displayedReport else { return }
        let markdown = WorkspaceReportMarkdown.make(
            report: report,
            subjectTitle: reportTitle,
            versionLabel: model.copyVersionLabel
        )
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(markdown, forType: .string) {
            AccessibilityNotification.Announcement(english ? "Markdown copied" : "已复制 Markdown").post()
        }
    }

    @ViewBuilder
    private func progress(_ record: ResearchRecord) -> some View {
        if record.run.queriesPlanned > 0 && record.run.queriesCompleted < record.run.queriesPlanned,
           [.searching, .reading].contains(record.run.phase) {
            ProgressView(
                value: Double(record.run.queriesCompleted), total: Double(record.run.queriesPlanned)
            ) {
                Text(L10n.string("research.phase.\(record.run.phase.rawValue)", language: settings.appLanguage))
            }
        } else {
            ProgressView(record.run.phase == .idle || record.run.phase == .done
                         ? ResearchStatusPresentation.label(record.status, language: settings.appLanguage)
                         : L10n.string("research.phase.\(record.run.phase.rawValue)", language: settings.appLanguage))
        }
        Text(english ? "Closing this window does not cancel research." : "关闭此窗口不会取消研究。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var updateAvailableBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            Text(english ? "A newer report is ready" : "新版报告已就绪")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 6)
            Button(english ? "View new version" : "查看新版") {
                model.showAvailableChanges()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
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

    private var noReport: some View {
        let state = model.emptyState
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(state.headline(language: settings.appLanguage))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let detail = state.detail(language: settings.appLanguage) {
                    // A vanished pinned version is a read-only dead end here:
                    // no retry, no recovery, and no current task status that
                    // could pass for an explanation of the missing version.
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if state == .researching, let record = model.record {
                        progress(record)
                    }
                    if let event = model.event {
                        Text(english ? "Event information, not a research report" : "事件信息，非研究报告")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(event.eventDescription)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(event.claims) { claim in
                            Text(claim.text)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let fallbackSourceURL, ReaderNavigationPolicy.allowedURL(fallbackSourceURL) != nil {
                        sourceFallbackButton(fallbackSourceURL, title: fallbackTitle)
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(18)
            .frame(maxWidth: .infinity)
        }
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
