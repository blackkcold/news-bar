import SwiftUI

struct WorkspaceSubjectList: View {
    @Environment(AppSettings.self) private var settings
    @Bindable var model: ResearchWorkspaceModel
    let onNewTopic: () -> Void

    @FocusState private var searchFocused: Bool

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var accent: Color { isRetro ? RetroEditorialTokens.brick : .accentColor }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            listControls
            Divider()

            if model.isLoading && model.subjects.isEmpty {
                loadingState
            } else if model.isSearching {
                searchResults
            } else {
                subjectList
            }
        }
        .background(.background)
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onChange(of: model.searchText) { _, _ in
            model.scheduleSearch()
        }
        .onMoveCommand(perform: moveSelection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("workspace.list.label".localized)
    }

    // MARK: - Chrome

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("workspace.search.placeholder".localized, text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit {
                    Task { await model.searchAll() }
                }
                .accessibilityLabel("workspace.search.placeholder".localized)
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                    model.scheduleSearch()
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("workspace.search.clear".localized)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(Color(nsColor: .controlBackgroundColor))
        .editorialClipShape(cornerRadius: 8)
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    private var listControls: some View {
        HStack(spacing: 8) {
            Text(filterTitle)
                .font(.system(size: 10, weight: .semibold, design: isRetro ? .serif : .default))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Menu {
                Picker("workspace.sort.label".localized, selection: $model.sort) {
                    ForEach(WorkspaceSort.allCases) { sort in
                        Text(sort.titleKey.localized).tag(sort)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 20, height: 18)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("workspace.sort.label".localized)
            .accessibilityLabel("workspace.sort.label".localized)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
    }

    private var filterTitle: String {
        "\(model.filter.titleKey.localized) \(model.visibleSubjects.count)"
    }

    // MARK: - Subject list

    @ViewBuilder
    private var subjectList: some View {
        if model.subjects.isEmpty {
            emptyState(
                title: "workspace.empty.noSubjects".localized,
                body: "workspace.empty.noSubjects.body".localized,
                symbol: "square.stack.3d.up",
                showsNewTopic: true
            )
        } else if model.visibleSubjects.isEmpty {
            emptyState(
                title: "workspace.empty.filter".localized,
                body: "workspace.empty.filter.body".localized,
                symbol: model.filter.symbol,
                showsNewTopic: false
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 3) {
                        ForEach(model.visibleSubjects) { subject in
                            Button {
                                Task { await model.select(subject.id) }
                            } label: {
                                WorkspaceSubjectRow(
                                    subject: subject,
                                    isSelected: subject.id == model.selectedSubjectID,
                                    isResearchActive: model.activeSubjectIDs.contains(subject.id)
                                )
                            }
                            .buttonStyle(.plain)
                            .id(subject.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: model.selectedSubjectID) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Search results

    @ViewBuilder
    private var searchResults: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 10) {
                if groupedResults.isEmpty {
                    emptyState(
                        title: "workspace.empty.search".localized,
                        body: "workspace.empty.search.body".localized,
                        symbol: "text.magnifyingglass",
                        showsNewTopic: false
                    )
                    .frame(minHeight: 180)
                } else {
                    ForEach(groupedResults, id: \.kind) { group in
                        resultSection(group)
                    }
                }

                Divider()
                webSearchFooter
                if !model.webResults.isEmpty {
                    webResultsSection
                }
            }
            .padding(10)
        }
    }

    private struct ResultGroup {
        let kind: WorkspaceResultKind
        let results: [WorkspaceSearchResult]
    }

    private enum WorkspaceResultKind: String, CaseIterable, Identifiable {
        case subject, report, evidence, answer

        var id: String { rawValue }
        var titleKey: String { "workspace.result.\(rawValue)" }
        var symbol: String {
            switch self {
            case .subject: return "square.stack.3d.up"
            case .report: return "doc.text"
            case .evidence: return "quote.bubble"
            case .answer: return "bubble.left.and.text.bubble.right"
            }
        }
    }

    private var groupedResults: [ResultGroup] {
        let dict = Dictionary(grouping: model.searchResults) { result -> WorkspaceResultKind in
            switch result {
            case .subject: return .subject
            case .report: return .report
            case .evidence: return .evidence
            case .answer: return .answer
            }
        }
        return WorkspaceResultKind.allCases.compactMap { kind in
            guard let results = dict[kind], !results.isEmpty else { return nil }
            return ResultGroup(kind: kind, results: results)
        }
    }

    private func resultSection(_ group: ResultGroup) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionHeader(group.kind.titleKey.localized, count: group.results.count)
            ForEach(group.results) { result in
                searchResultRow(result)
            }
        }
    }

    private func searchResultRow(_ result: WorkspaceSearchResult) -> some View {
        Button {
            Task { await model.openSearchResult(result) }
        } label: {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: kindSymbol(result))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 13)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(resultTitle(result))
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    let snippet = resultSnippet(result)
                    if !snippet.isEmpty {
                        Text(snippet)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(.quaternary.opacity(0.18))
            .editorialClipShape(cornerRadius: 7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(resultTitle(result))
    }

    private var webSearchFooter: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.searchWeb() }
            } label: {
                HStack(spacing: 5) {
                    if model.isSearchingWeb {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "globe")
                            .font(.system(size: 10))
                    }
                    Text("workspace.search.web".localized)
                        .font(.system(size: 10, weight: .medium))
                }
            }
            .buttonStyle(EditorialActionButtonStyle(compact: true))
            .disabled(model.isSearchingWeb || model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("workspace.search.web".localized)

            if model.isSearchingWeb {
                Text("workspace.search.webRunning".localized)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            } else {
                Text("workspace.search.webHint".localized)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private var webResultsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionHeader("workspace.search.webResults".localized, count: model.webResults.count)
            ForEach(model.webResults, id: \.canonicalURL) { hit in
                webResultRow(hit)
            }
        }
    }

    private func webResultRow(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                model.openEvidenceURL(hit.url, title: hit.title)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !hit.snippet.isEmpty {
                        Text(hit.snippet)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Text(hit.domain)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 5) {
                EditorialTag(
                    text: "workspace.search.lead".localized,
                    fallbackTint: .orange
                )
                Spacer(minLength: 0)
                if model.selectedSubjectID != nil {
                    Button("workspace.search.addToSubject".localized) {
                        Task { await model.saveWebHit(hit, to: model.selectedSubjectID) }
                    }
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
                }
                Button("workspace.search.addAsTopic".localized) {
                    Task { await model.saveWebHit(hit, to: nil) }
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.18))
        .editorialClipShape(cornerRadius: 7)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .black, design: isRetro ? .serif : .default))
                .tracking(isRetro ? 0.7 : 0.2)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(.tertiary)
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.4))
                .frame(height: 1)
        }
        .padding(.top, 2)
    }

    private func emptyState(
        title: String,
        body: String,
        symbol: String,
        showsNewTopic: Bool
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 21))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Text(body)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if showsNewTopic {
                Button("workspace.action.newTopic".localized, action: onNewTopic)
                    .buttonStyle(EditorialActionButtonStyle(tone: .prominent, compact: true))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
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

    // MARK: - Helpers

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !searchFocused, !model.isSearching else { return }
        guard direction == .up || direction == .down else { return }
        let subjects = model.visibleSubjects
        guard !subjects.isEmpty else { return }
        let current = subjects.firstIndex { $0.id == model.selectedSubjectID }
        let next: Int
        if let current {
            next = min(max(current + (direction == .down ? 1 : -1), 0), subjects.count - 1)
        } else {
            next = direction == .down ? 0 : subjects.count - 1
        }
        let id = subjects[next].id
        Task { await model.select(id) }
    }

    private func kindSymbol(_ result: WorkspaceSearchResult) -> String {
        switch result {
        case .subject: return "square.stack.3d.up"
        case .report: return "doc.text"
        case .evidence: return "quote.bubble"
        case .answer: return "bubble.left.and.text.bubble.right"
        }
    }

    private func resultTitle(_ result: WorkspaceSearchResult) -> String {
        switch result {
        case let .subject(_, title, _, _): return title
        case let .report(_, _, title, _, _): return title
        case let .evidence(_, _, title, _, _): return title
        case let .answer(_, query, _, _): return query
        }
    }

    private func resultSnippet(_ result: WorkspaceSearchResult) -> String {
        switch result {
        case let .subject(_, _, snippet, _): return snippet
        case let .report(_, _, _, snippet, _): return snippet
        case let .evidence(_, _, _, snippet, _): return snippet
        case let .answer(_, _, snippet, _): return snippet
        }
    }
}
