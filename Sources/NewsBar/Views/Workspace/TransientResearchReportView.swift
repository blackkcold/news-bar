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
    private(set) var record: ResearchRecord?
    private(set) var event: NewsEvent?
    private(set) var isLoading = false
    private(set) var didLoad = false
    var showsProgress = UserDefaults.standard.bool(forKey: "reader.research.progressExpanded") {
        didSet { UserDefaults.standard.set(showsProgress, forKey: "reader.research.progressExpanded") }
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

    func open(recordID: String?, eventID: String?, markReadOnOpen: Bool = false) async {
        if self.recordID == recordID, self.eventID == eventID, didLoad {
            await reload()
            return
        }
        revision += 1
        let currentRevision = revision
        self.recordID = recordID
        self.eventID = eventID
        record = nil
        event = nil
        didLoad = false
        await reload(expectedRevision: currentRevision, markReadOnOpen: markReadOnOpen)
    }

    func reload() async {
        revision += 1
        await reload(expectedRevision: revision)
    }

    private func reload(expectedRevision: Int, markReadOnOpen: Bool = false) async {
        isLoading = true
        defer {
            if revision == expectedRevision {
                isLoading = false
                didLoad = true
            }
        }

        var resolvedRecord = recordID.flatMap { _ in record }
        if let recordID {
            resolvedRecord = await researchStore.record(id: recordID)
        } else if let eventID,
                  let subject = await workspaceStore.subject(containingEventID: eventID) {
            let index = await researchStore.index()
            let linked = index
                .filter { subject.contains(recordID: $0.id) && $0.issue == nil && $0.status != .corrupt }
                .sorted(by: Self.preferredRecord)
            if let entry = linked.first {
                resolvedRecord = await researchStore.record(id: entry.id)
                recordID = entry.id
            }
        }

        var resolvedEvent: NewsEvent?
        if let eventID {
            resolvedEvent = try? await eventStore.event(id: eventID)
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

        guard revision == expectedRevision, !Task.isCancelled else { return }
        if markReadOnOpen,
           let resolvedRecord,
           resolvedRecord.status.marksReadOnOpen {
            _ = await researchStore.markReadOnOpen(id: resolvedRecord.id, at: Date())
            guard revision == expectedRevision, !Task.isCancelled else { return }
        }
        record = resolvedRecord
        event = resolvedEvent
        if eventID == nil { self.eventID = resolvedEvent?.id }
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

struct TransientResearchReportView: View {
    @Environment(AppSettings.self) private var settings
    @Bindable var model: TransientResearchReportModel
    let onClose: () -> Void

    private var english: Bool { settings.appLanguage == .en }
    private var report: BurstResearch? { model.record?.report }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.didLoad {
                ProgressView(english ? "Loading research…" : "正在载入研究报告…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let record = model.record {
                reportContent(record)
            } else if let event = model.event {
                eventContent(event)
            } else {
                unavailable
            }
        }
        .frame(minWidth: 560, minHeight: 520)
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
                    HStack(spacing: 8) {
                        Text(ResearchStatusPresentation.label(record.status, language: settings.appLanguage))
                        if let report {
                            Text("\(english ? "Verified as of " : "核验截至 ")\((report.generatedAt ?? record.updatedAt).formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel(english ? "Close report" : "关闭报告")
        }
        .padding(18)
    }

    @ViewBuilder
    private func reportContent(_ record: ResearchRecord) -> some View {
        if let report = record.report {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(english ? "Current conclusion" : "当前结论")
                            .font(.headline)
                        Text(ResearchNotificationSummary.make(report: report, language: settings.appLanguage))
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                        if let missing = report.verification?.missing, !missing.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(english ? "Still to confirm" : "仍待确认")
                                    .font(.subheadline.weight(.semibold))
                                ForEach(Array(missing.enumerated()), id: \.offset) { item in
                                    Text("• \(item.element)")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.36), in: RoundedRectangle(cornerRadius: 12))

                    if record.status.isActive {
                        progressDisclosure(record)
                    }

                    WorkspaceReportBody(
                        report: report,
                        isHistorical: false,
                        onOpenURL: openEvidenceURL
                    )
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text(record.status.isActive
                     ? (english ? "Research is in progress. The previous verified report will appear here when available." : "研究仍在进行。上一份已核验报告（如有）会继续显示在这里。")
                     : (english ? "No readable report is available for this item." : "当前项目没有可读取的报告。"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                if record.status.isActive { progressDisclosure(record) }
                if let lastError = record.run.lastError, !lastError.isEmpty {
                    Text(lastError).font(.caption).foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
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
            }
            .padding(.top, 8)
        } label: {
            Text(english ? "Show research progress" : "显示研究进度")
                .font(.subheadline.weight(.semibold))
        }
        .padding(12)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
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
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(english ? "This report was removed or is unavailable." : "该报告已移除或暂时不可用。")
                .font(.headline)
            Text(english ? "The reading window and your search position are still available." : "关闭此窗口即可回到原来的阅读位置或搜索。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func openEvidenceURL(_ rawURL: String, title: String) {
        guard let url = ReaderNavigationPolicy.allowedURL(rawURL) else { return }
        NewsNavigationRouter.shared.open(url: url.absoluteString, title: title, surface: "researchReport")
    }
}
