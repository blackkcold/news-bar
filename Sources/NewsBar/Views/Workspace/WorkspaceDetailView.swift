import SwiftUI

struct WorkspaceDetailView: View {
    @Environment(AppSettings.self) private var settings
    @Bindable var model: ResearchWorkspaceModel
    let onNewTopic: () -> Void

    @State private var handledSegmentRequestID: UUID?

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var accent: Color { isRetro ? RetroEditorialTokens.brick : .accentColor }
    private var subjectID: String { model.detail?.subject.id ?? "" }
    private var segment: WorkspaceSegment {
        model.presentation.segment(for: subjectID)
    }
    private var segmentBinding: Binding<WorkspaceSegment> {
        Binding(
            get: { model.presentation.segment(for: subjectID) },
            set: { model.presentation.setSegment($0, for: subjectID) }
        )
    }

    var body: some View {
        Group {
            if let detail = model.detail {
                VStack(spacing: 0) {
                    header(detail)
                    Divider()
                    segmentPicker
                    Divider()
                    panes(detail)
                }
            } else if model.isLoadingDetail {
                loadingState
            } else {
                emptyState
            }
        }
        .background(.background)
        .onChange(of: model.segmentRequest?.id, initial: true) { _, _ in
            applySegmentRequestIfPossible()
        }
        .onChange(of: model.detail?.subject.id) { _, _ in
            applySegmentRequestIfPossible()
        }
        .alert(archiveAlertTitle, isPresented: archiveAlertBinding) {
            Button("workspace.action.archive".localized, role: .destructive) {
                guard let id = model.archiveConfirmationSubjectID else { return }
                model.archiveConfirmationSubjectID = nil
                Task { await model.setArchived(id: id, archived: true) }
            }
            Button("workspace.action.cancel".localized, role: .cancel) {
                model.archiveConfirmationSubjectID = nil
            }
        } message: {
            Text("workspace.archive.message".localized)
        }
        .accessibilityElement(children: .contain)
    }

    private func applySegmentRequestIfPossible() {
        guard let request = model.segmentRequest,
              !subjectID.isEmpty,
              handledSegmentRequestID != request.id else { return }
        handledSegmentRequestID = request.id
        model.presentation.setSegment(request.segment, for: subjectID)
    }

    // MARK: - Header

    private func header(_ detail: WorkspaceDetail) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                titleBlock(detail)
                    .frame(minWidth: 250, idealWidth: 300, maxWidth: 310, alignment: .leading)
                actions(detail)
                    .fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 8) {
                titleBlock(detail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    actions(detail)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func titleBlock(_ detail: WorkspaceDetail) -> some View {
        let subject = detail.subject
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(subject.title)
                    .font(.system(size: 18, weight: isRetro ? .black : .semibold,
                                  design: isRetro ? .serif : .default))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .textSelection(.enabled)
                kindBadge(subject.kind)
                updateBadge(subject.updateState)
                Spacer(minLength: 0)
            }

            if !subject.normalizedAliases.isEmpty {
                aliasRow(subject.normalizedAliases)
            }

            HStack(spacing: 6) {
                if subject.isFollowed {
                    Label("workspace.sidebar.following".localized, systemImage: "pin.fill")
                        .lineLimit(1)
                }
                Text(L10n.string(
                    "workspace.header.lastActivity",
                    language: settings.appLanguage,
                    model.relativeTime(subject.lastActivityAt)
                ))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(subject.lastActivityAt.formatted(date: .abbreviated, time: .shortened))
                if model.isReadOnly {
                    Label("workspace.readOnly.short".localized, systemImage: "lock.doc")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
        }
    }

    private func aliasRow(_ aliases: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(aliases.prefix(2)), id: \.self) { alias in
                Text(alias)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 110, alignment: .leading)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.30))
                    .editorialClipShape(cornerRadius: 4)
                    .help(alias)
            }
            if aliases.count > 2 {
                Text("+\(aliases.count - 2)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func actions(_ detail: WorkspaceDetail) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                followButton(detail)
                checkUpdatesButton(detail, compact: false)
                primaryButton(detail)
                overflowMenu(detail)
            }
            HStack(spacing: 5) {
                followButton(detail)
                checkUpdatesButton(detail, compact: true)
                primaryButton(detail)
                overflowMenu(detail)
            }
            HStack(spacing: 5) {
                followButton(detail)
                primaryButton(detail)
                overflowMenu(detail, includesCheck: true)
            }
        }
    }

    private func followButton(_ detail: WorkspaceDetail) -> some View {
        Button {
            Task { await model.toggleFollow(id: detail.subject.id) }
        } label: {
            Image(systemName: detail.subject.isFollowed ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 24)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(detail.subject.isFollowed
              ? "workspace.action.unfollow".localized
              : "workspace.action.follow".localized + " · " + "workspace.follow.help".localized)
        .accessibilityLabel(detail.subject.isFollowed
                            ? "workspace.action.unfollow".localized
                            : "workspace.action.follow".localized)
        .accessibilityHint("workspace.follow.help".localized)
        .disabled(model.isReadOnly)
    }

    private func checkUpdatesButton(_ detail: WorkspaceDetail, compact: Bool) -> some View {
        Button {
            Task { await model.checkUpdates(id: detail.subject.id) }
        } label: {
            if model.isCheckingUpdates {
                ProgressView().controlSize(.mini).frame(width: compact ? 26 : nil, height: 24)
            } else if compact {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                    .frame(width: 26, height: 24)
            } else {
                Label("workspace.action.checkUpdates".localized,
                      systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!model.canCheckUpdates)
        .help(model.checkUpdatesHelp)
        .accessibilityLabel(model.checkUpdatesHelp)
    }

    private func primaryButton(_ detail: WorkspaceDetail) -> some View {
        Button {
            switch model.primaryAction {
            case .start, .update:
                Task {
                    await model.startResearch(
                        id: detail.subject.id,
                        forceRefresh: false,
                        depth: model.depth(for: detail.subject.id)
                    )
                }
            case .view:
                model.presentation.setSegment(.research, for: detail.subject.id)
            case .active:
                model.presentation.setSegment(.research, for: detail.subject.id)
            case .none:
                break
            }
        } label: {
            HStack(spacing: 4) {
                if model.isStartingResearch || model.primaryAction == .active {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: primarySymbol)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(primaryTitle)
                    .lineLimit(1)
            }
        }
        .buttonStyle(EditorialActionButtonStyle(
            tone: model.primaryAction == .view ? .secondary : .prominent,
            compact: true
        ))
        .disabled(model.primaryAction == .active
                  || (model.primaryAction != .view && !model.canStartResearch))
        .help(primaryTitle)
        .accessibilityLabel(primaryTitle)
    }

    private var primaryTitle: String {
        switch model.primaryAction {
        case .start: return "workspace.action.startResearch".localized
        case .update: return "workspace.action.updateResearch".localized
        case .view: return "workspace.action.viewResearch".localized
        case .active: return "workspace.status.researching".localized
        case .none: return "workspace.action.startResearch".localized
        }
    }

    private var primarySymbol: String {
        switch model.primaryAction {
        case .start: return "play.fill"
        case .update: return "arrow.triangle.2.circlepath"
        case .view: return "doc.text.magnifyingglass"
        case .active: return "hourglass"
        case .none: return "play.fill"
        }
    }

    private func overflowMenu(_ detail: WorkspaceDetail, includesCheck: Bool = false) -> some View {
        Menu {
            if includesCheck {
                Button(model.checkUpdatesHelp) {
                    Task { await model.checkUpdates(id: detail.subject.id) }
                }
                .disabled(!model.canCheckUpdates)
                Divider()
            }
            Button("workspace.action.openInReader".localized) {
                model.openInReader()
            }
            .disabled(model.readerURL == nil)
            Divider()
            if detail.subject.isArchived {
                Button("workspace.action.unarchive".localized) {
                    Task { await model.setArchived(id: detail.subject.id, archived: false) }
                }
            } else {
                Button("workspace.action.archive".localized, role: .destructive) {
                    model.archiveConfirmationSubjectID = detail.subject.id
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("workspace.action.more".localized)
        .accessibilityLabel("workspace.action.more".localized)
    }

    private func kindBadge(_ kind: WorkspaceSubjectKind) -> some View {
        Text(kindLabel(kind))
            .font(.system(size: 8, weight: .black))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.30))
            .editorialClipShape(cornerRadius: 4)
    }

    @ViewBuilder
    private func updateBadge(_ state: WorkspaceUpdateState) -> some View {
        switch state {
        case .needsReview:
            Text("workspace.status.review".localized)
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(.orange)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.12))
                .editorialClipShape(cornerRadius: 4)
        case .hasUpdates:
            Text("workspace.status.updated".localized)
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(.blue)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.12))
                .editorialClipShape(cornerRadius: 4)
        case .current:
            EmptyView()
        }
    }

    private func kindLabel(_ kind: WorkspaceSubjectKind) -> String {
        switch kind {
        case .topic: return "workspace.kind.topic".localized
        case .event: return "workspace.kind.event".localized
        case .mixed: return "workspace.kind.mixed".localized
        }
    }

    // MARK: - Segments and panes

    private var segmentPicker: some View {
        HStack {
            Picker("workspace.detail.segments".localized, selection: segmentBinding) {
                ForEach(WorkspaceSegment.allCases) { item in
                    Label(item.titleKey.localized, systemImage: item.symbol)
                        .tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("workspace.detail.segments".localized)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private func panes(_ detail: WorkspaceDetail) -> some View {
        ZStack {
            WorkspaceOverviewPane(
                model: model,
                detail: detail,
                onStartResearch: { force in
                    Task {
                        await model.startResearch(
                            id: detail.subject.id,
                            forceRefresh: force,
                            depth: model.depth(for: detail.subject.id)
                        )
                    }
                },
                onRequestSegment: { model.presentation.setSegment($0, for: detail.subject.id) }
            )
            .opacity(segment == .overview ? 1 : 0)
            .allowsHitTesting(segment == .overview)
            .accessibilityHidden(segment != .overview)

            WorkspaceTimelinePane(
                model: model,
                detail: detail,
                onRequestSegment: { model.presentation.setSegment($0, for: detail.subject.id) }
            )
            .opacity(segment == .timeline ? 1 : 0)
            .allowsHitTesting(segment == .timeline)
            .accessibilityHidden(segment != .timeline)

            WorkspaceEvidencePane(
                model: model,
                detail: detail,
                onRequestSegment: { model.presentation.setSegment($0, for: detail.subject.id) }
            )
            .opacity(segment == .evidence ? 1 : 0)
            .allowsHitTesting(segment == .evidence)
            .accessibilityHidden(segment != .evidence)

            WorkspaceResearchPane(
                model: model,
                detail: detail,
                onStart: { force, depth in
                    Task {
                        await model.startResearch(
                            id: detail.subject.id,
                            forceRefresh: force,
                            depth: depth
                        )
                    }
                }
            )
            .opacity(segment == .research ? 1 : 0)
            .allowsHitTesting(segment == .research)
            .accessibilityHidden(segment != .research)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(model.subjects.isEmpty
                 ? "workspace.empty.noSubjects".localized
                 : "workspace.empty.detail".localized)
                .font(.system(size: 13, weight: .medium))
            Text(model.subjects.isEmpty
                 ? "workspace.empty.noSubjects.body".localized
                 : "workspace.empty.detail.body".localized)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if model.subjects.isEmpty {
                Button("workspace.action.newTopic".localized, action: onNewTopic)
                    .buttonStyle(EditorialActionButtonStyle(tone: .prominent, compact: true))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("workspace.loading".localized)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var archiveAlertBinding: Binding<Bool> {
        Binding(
            get: { model.archiveConfirmationSubjectID != nil },
            set: { presented in
                if !presented { model.archiveConfirmationSubjectID = nil }
            }
        )
    }

    private var archiveAlertTitle: String {
        let title = model.selectedSubject?.title ?? ""
        return L10n.string("workspace.archive.title", language: settings.appLanguage, title)
    }
}
