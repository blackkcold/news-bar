import AppKit
import SwiftUI

struct ResearchWorkspaceView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: ResearchWorkspaceModel

    @State private var showsNewSubject = false

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebar(model: model) {
                showsNewSubject = true
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 230, max: 260)
        } content: {
            WorkspaceSubjectList(model: model) {
                showsNewSubject = true
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 320, max: 360)
        } detail: {
            WorkspaceDetailView(model: model) {
                showsNewSubject = true
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1040, minHeight: 680)
        .adaptiveColorScheme()
        .appThemeSurface()
        .task { await model.load() }
        .safeAreaInset(edge: .top, spacing: 0) {
            banners
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            noticeBar
        }
        .background { keyboardShortcuts }
        .sheet(isPresented: $showsNewSubject) {
            WorkspaceNewSubjectSheet(model: model)
                .environment(settings)
                .id(settings.appLanguage)
        }
        .sheet(item: $model.archiveReplay) { entry in
            answerReplay(entry)
                .environment(settings)
                .id(settings.appLanguage)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Banners

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 0) {
            if let readOnly = model.readOnlyMessage {
                banner(
                    message: readOnly,
                    symbol: "lock.doc",
                    tint: .orange,
                    actionTitle: nil,
                    action: nil
                )
            }
            if let error = model.errorMessage {
                banner(
                    message: error,
                    symbol: "exclamationmark.triangle.fill",
                    tint: .red,
                    actionTitle: "workspace.action.retry".localized
                ) {
                    model.errorMessage = nil
                    Task { await model.refresh() }
                } onDismiss: {
                    model.errorMessage = nil
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.errorMessage)
    }

    private func banner(
        message: String,
        symbol: String,
        tint: Color,
        actionTitle: String?,
        action: (() -> Void)?,
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 10.5))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("workspace.notice.dismiss".localized)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint.opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tint.opacity(0.30))
                .frame(height: 1)
        }
    }

    // MARK: - Notice

    @ViewBuilder
    private var noticeBar: some View {
        if let notice = model.actionNotice {
            WorkspaceActionNoticeBar(
                notice: notice,
                onDismiss: { model.dismissNotice() },
                onAction: { action in
                    Task { await model.performNoticeAction(action) }
                }
            )
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Archive replay

    private func answerReplay(_ entry: AISearchArchiveEntry) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.query)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                        if let title = entry.pageTitle, !title.isEmpty {
                            Text("·")
                            Text(title)
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    let document = entry.answerDocument()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        document.plainText(settings.appLanguage),
                        forType: .string
                    )
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("workspace.replay.copy".localized)
                .help("workspace.replay.copy".localized)
                Button {
                    model.archiveReplay = nil
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityLabel("workspace.replay.close".localized)
                .help("workspace.replay.close".localized)
            }
            .padding(14)
            Divider()
            AnswerDocumentView(
                document: entry.answerDocument(),
                language: settings.appLanguage,
                maxHeight: 620,
                onOpenSource: { source in
                    model.openEvidenceURL(source.url, title: source.title)
                }
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 620, minHeight: 520)
    }

    // MARK: - Keyboard

    private var keyboardShortcuts: some View {
        ZStack {
            ForEach(Array(WorkspaceFilter.allCases.enumerated()), id: \.offset) { index, filter in
                Button("") {
                    model.filter = filter
                }
                .keyboardShortcut(
                    KeyEquivalent(Character("\(index + 1)")),
                    modifiers: .command
                )
            }
            Button("") { showsNewSubject = true }
                .keyboardShortcut("n", modifiers: .command)
            Button("") {
                guard let id = model.selectedSubjectID else { return }
                model.archiveConfirmationSubjectID = id
            }
            .keyboardShortcut(.delete, modifiers: .command)
            Button("") {
                guard let id = model.selectedSubjectID else { return }
                Task { await model.checkUpdates(id: id) }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!model.canCheckUpdates)
            Button("") {
                guard let id = model.selectedSubjectID else { return }
                Task {
                    await model.startResearch(
                        id: id,
                        forceRefresh: false,
                        depth: model.depth(for: id)
                    )
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canStartResearch)
            Button("") {
                if model.archiveReplay != nil {
                    model.archiveReplay = nil
                } else if !model.searchText.isEmpty {
                    model.searchText = ""
                    model.scheduleSearch()
                } else if model.actionNotice != nil {
                    model.dismissNotice()
                }
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
