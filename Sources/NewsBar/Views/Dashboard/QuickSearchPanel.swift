import AppKit
import SwiftUI

enum QuickSearchSurface: String, CaseIterable, Identifiable {
    case local
    case web
    case ai
    case archive

    var id: String { rawValue }

    static func transferDraft(
        from oldSurface: QuickSearchSurface,
        to newSurface: QuickSearchSurface,
        quickQuery: inout String,
        aiQuestion: inout String
    ) {
        if oldSurface == .ai {
            quickQuery = aiQuestion
        }
        if newSurface == .ai {
            aiQuestion = quickQuery
        }
    }
}

enum QuickSearchAccessibilityLabels {
    static func surface(_ surface: QuickSearchSurface, language: AppLanguage) -> String {
        L10n.string("reader.quickSearch.\(surface.rawValue)", language: language)
    }

    static func close(language: AppLanguage) -> String {
        L10n.string("reader.quickSearch.close", language: language)
    }

    static func copy(language: AppLanguage) -> String {
        L10n.string("reader.quickSearch.copy", language: language)
    }

    static func openSource(_ title: String, language: AppLanguage) -> String {
        L10n.string("reader.quickSearch.openSource", language: language, title)
    }

    static func remove(language: AppLanguage) -> String {
        L10n.string("reader.quickSearch.remove", language: language)
    }

    static func returnToSearch(language: AppLanguage) -> String {
        L10n.string("reader.quickSearch.backToSearch", language: language)
    }

    static func backToArchive(language: AppLanguage) -> String {
        L10n.string("reader.quickSearch.backToArchive", language: language)
    }

    static func openArchive(language: AppLanguage) -> String {
        L10n.string("reader.quickSearch.openArchive", language: language)
    }

    static func archiveRow(_ entry: AISearchArchiveEntry, language: AppLanguage) -> String {
        [entry.query, entry.pageTitle, entry.answer.oneLine]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

struct QuickSearchArchiveReplayCloseButton: View {
    let language: AppLanguage
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.escape, modifiers: [])
        .accessibilityLabel(QuickSearchAccessibilityLabels.close(language: language))
    }
}

struct QuickSearchPanel: View {
    @Bindable var model: QuickSearchModel
    @Bindable var aiModel: AISearchPanelModel
    @Bindable var archiveController: AISearchArchiveController
    let activeNewsItems: [NewsItem]
    let readingHistory: [ReaderHistoryEntry]
    @Bindable var settings: AppSettings
    let language: AppLanguage
    let onOpenResult: (URL) -> Void
    let onOpenSource: (URL) -> Void
    let onClose: () -> Void
    let onConfigureAI: () -> Void

    @State private var surface: QuickSearchSurface
    @State private var selectedArchiveEntry: AISearchArchiveEntry?
    @State private var webGateway = ManualSearchGateway()
    @FocusState private var queryFocused: Bool

    init(
        model: QuickSearchModel,
        aiModel: AISearchPanelModel,
        archiveController: AISearchArchiveController,
        activeNewsItems: [NewsItem],
        readingHistory: [ReaderHistoryEntry],
        settings: AppSettings,
        language: AppLanguage,
        initialSurface: QuickSearchSurface,
        onOpenResult: @escaping (URL) -> Void,
        onOpenSource: @escaping (URL) -> Void,
        onClose: @escaping () -> Void,
        onConfigureAI: @escaping () -> Void
    ) {
        self.model = model
        self.aiModel = aiModel
        self.archiveController = archiveController
        self.activeNewsItems = activeNewsItems
        self.readingHistory = readingHistory
        self.settings = settings
        self.language = language
        self.onOpenResult = onOpenResult
        self.onOpenSource = onOpenSource
        self.onClose = onClose
        self.onConfigureAI = onConfigureAI
        _surface = State(initialValue: initialSurface)
        _selectedArchiveEntry = State(initialValue: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            surfacePicker
            if surface == .ai, selectedArchiveEntry == nil {
                aiPanel
            } else {
                if let selectedArchiveEntry {
                    archiveReplay(selectedArchiveEntry)
                } else {
                    searchHeader
                    surfaceContent
                }
            }
        }
        .padding(12)
        .frame(width: 452, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 4)
        .accessibilityElement(children: .contain)
        .onAppear {
            if surface == .local { refreshLocalResults() }
            if surface == .ai { aiModel.present() }
            if surface != .ai { queryFocused = true }
        }
        .onChange(of: model.query) { _, _ in
            if surface == .local { refreshLocalResults() }
        }
        .onChange(of: archiveController.entries) { _, _ in
            if surface == .local { refreshLocalResults() }
        }
        .onChange(of: surface) { _, newSurface in
            if newSurface == .local { refreshLocalResults() }
            if newSurface != .ai { queryFocused = true }
        }
        .onChange(of: settings.aiSearchEnabled) { _, isEnabled in
            if !isEnabled, surface == .ai { selectSurface(.local) }
        }
    }

    private var surfacePicker: some View {
        HStack(spacing: 4) {
            ForEach(QuickSearchSurface.allCases) { candidate in
                if surface == candidate {
                    surfaceButton(candidate)
                        .buttonStyle(.borderedProminent)
                } else {
                    surfaceButton(candidate)
                        .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func surfaceButton(_ candidate: QuickSearchSurface) -> some View {
        Button {
            selectSurface(candidate)
        } label: {
            Text(QuickSearchAccessibilityLabels.surface(candidate, language: language))
                .lineLimit(1)
        }
        .controlSize(.small)
        .disabled(candidate == .ai && !settings.aiSearchEnabled)
        .accessibilityLabel(QuickSearchAccessibilityLabels.surface(candidate, language: language))
    }

    private var searchHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: surface == .archive ? "clock.arrow.circlepath" : "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(QuickSearchAccessibilityLabels.surface(surface, language: language))
                .font(.headline)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel(QuickSearchAccessibilityLabels.close(language: language))
        }
    }

    @ViewBuilder
    private var surfaceContent: some View {
        switch surface {
        case .local:
            localSearch
        case .web:
            webSearch
        case .ai:
            aiPanel
        case .archive:
            archiveBrowse
        }
    }

    private var localSearch: some View {
        VStack(alignment: .leading, spacing: 8) {
            queryField
            Text(L10n.string("reader.quickSearch.localHint", language: language))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    L10n.string("reader.quickSearch.localPrompt", language: language),
                    systemImage: "magnifyingglass"
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else if model.localResults.isEmpty {
                ContentUnavailableView(
                    L10n.string("reader.quickSearch.noResults", language: language),
                    systemImage: "doc.text.magnifyingglass"
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.localResults) { result in
                            localResultRow(result)
                        }
                    }
                }
                .frame(maxHeight: 470)
            }
        }
    }

    private var webSearch: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                queryField
                Button(action: submitWebSearch) {
                    if model.isSearching {
                        ProgressView().controlSize(.small).frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.isSearching || model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(L10n.string("reader.quickSearch.submit", language: language))
            }
            Text(L10n.string("reader.quickSearch.webHint", language: language))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.isSearching {
                ProgressView(L10n.string("reader.quickSearch.searching", language: language))
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if let error = model.error {
                VStack(spacing: 8) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(L10n.string("reader.quickSearch.retry", language: language), action: submitWebSearch)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else if !model.webHits.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.webHits, id: \.canonicalURL) { hit in
                            webResultRow(hit)
                        }
                    }
                }
                .frame(maxHeight: 470)
            } else {
                ContentUnavailableView(
                    L10n.string("reader.quickSearch.webPrompt", language: language),
                    systemImage: "globe"
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
    }

    private var archiveBrowse: some View {
        VStack(alignment: .leading, spacing: 8) {
            queryField
            if let storageError = archiveController.storageError {
                Text(L10n.string("settings.browser.aiSearchHistory.error", language: language, storageError))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            AISearchArchiveView(
                entries: archiveController.entries,
                query: model.query,
                language: language,
                onSelect: { selectedArchiveEntry = $0 },
                onCopy: { copy(AISearchArchiveView.restoredAnswer(for: $0).plainText(language)) },
                onOpenSource: openArchivedSource,
                onRemove: { entry in
                    Task { await archiveController.remove(id: entry.id) }
                }
            )
        }
    }

    private func archiveReplay(_ entry: AISearchArchiveEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    selectedArchiveEntry = nil
                } label: {
                    Label(
                        L10n.string("reader.quickSearch.archive.back", language: language),
                        systemImage: "chevron.left"
                    )
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(QuickSearchAccessibilityLabels.backToArchive(language: language))
                Spacer(minLength: 0)
                Button {
                    copy(AISearchArchiveView.restoredAnswer(for: entry).plainText(language))
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(QuickSearchAccessibilityLabels.copy(language: language))
                Button(role: .destructive) {
                    Task {
                        await archiveController.remove(id: entry.id)
                        selectedArchiveEntry = nil
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(QuickSearchAccessibilityLabels.remove(language: language))
                QuickSearchArchiveReplayCloseButton(language: language, action: onClose)
            }
            Text(entry.query)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let pageTitle = entry.pageTitle, !pageTitle.isEmpty {
                Text(pageTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            AnswerDocumentView(
                document: AISearchArchiveView.restoredAnswer(for: entry),
                language: language,
                maxHeight: 400,
                onOpenSource: { source in
                    guard let url = ReaderNavigationPolicy.allowedURL(source.url) else { return }
                    onOpenSource(url)
                }
            )
        }
    }

    private var aiPanel: some View {
        AISearchPanel(
            model: aiModel,
            language: language,
            providerName: settings.providerDisplayName(forID: settings.aiProvider),
            modelName: settings.effectiveAISearchModel,
            webEnabled: settings.aiSearchUseWeb,
            onSubmit: { aiModel.submit(settings: settings) },
            onRetry: { aiModel.retry(settings: settings) },
            onClose: onClose,
            onOpenCitation: { url in
                guard let allowedURL = ReaderNavigationPolicy.allowedURL(url.absoluteString) else { return }
                onOpenSource(allowedURL)
            },
            onCopy: copy,
            onOpenSettings: onConfigureAI,
            onReturnToSearch: { selectSurface(.local) },
            onOpenArchive: { selectSurface(.archive) }
        )
    }

    private var queryField: some View {
        TextField(
            L10n.string("reader.quickSearch.query", language: language),
            text: $model.query
        )
        .textFieldStyle(.roundedBorder)
        .focused($queryFocused)
        .onSubmit {
            if surface == .web { submitWebSearch() }
            if surface == .local { refreshLocalResults() }
        }
        .accessibilityLabel(L10n.string("reader.quickSearch.query", language: language))
    }

    private func localResultRow(_ result: QuickSearchResult) -> some View {
        let title = resultTitle(result)
        let subtitle = resultSubtitle(result)
        let canReplayArchive: Bool = {
            if case .archive = result { return true }
            return false
        }()
        return Button {
            if case .archive(let entry) = result {
                selectSurface(.archive)
                selectedArchiveEntry = entry
            } else if let url = Self.allowedReaderURL(for: result) {
                onOpenResult(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .contentShape(Rectangle())
            .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canReplayArchive && Self.allowedReaderURL(for: result) == nil)
        .accessibilityLabel(L10n.string("reader.quickSearch.result", language: language, title, subtitle))
    }

    private func webResultRow(_ hit: SearchHit) -> some View {
        let destination = Self.allowedReaderURL(for: hit)
        return Button {
            guard let destination else { return }
            onOpenResult(destination)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !hit.snippet.isEmpty {
                    Text(hit.snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                Text(hit.domain)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .contentShape(Rectangle())
            .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(destination == nil)
        .accessibilityLabel(L10n.string("reader.quickSearch.result", language: language, hit.title, hit.domain))
    }

    private func resultTitle(_ result: QuickSearchResult) -> String {
        switch result {
        case .news(let item): return item.title
        case .readerHistory(let entry): return entry.title
        case .archive(let entry): return entry.query
        }
    }

    private func resultSubtitle(_ result: QuickSearchResult) -> String {
        switch result {
        case .news(let item): return item.url
        case .readerHistory(let entry): return entry.host
        case .archive(let entry): return entry.pageTitle ?? entry.answer.oneLine
        }
    }

    private func selectSurface(_ nextSurface: QuickSearchSurface) {
        guard nextSurface != .ai || settings.aiSearchEnabled else { return }
        var quickQuery = model.query
        var aiQuestion = aiModel.question
        QuickSearchSurface.transferDraft(
            from: surface,
            to: nextSurface,
            quickQuery: &quickQuery,
            aiQuestion: &aiQuestion
        )
        model.query = quickQuery
        aiModel.question = aiQuestion
        surface = nextSurface
        selectedArchiveEntry = nil
        if nextSurface == .ai { aiModel.present() }
    }

    private func refreshLocalResults() {
        model.searchLocal(
            query: model.query,
            newsItems: activeNewsItems,
            readingHistory: readingHistory,
            archiveEntries: archiveController.entries
        )
    }

    private func submitWebSearch() {
        let query = model.query
        Task {
            let keys = await SearchKeyStore.loadAll()
            await model.searchWeb(
                query: query,
                language: language,
                enabledProviders: settings.enabledSearchProviders,
                keys: keys,
                gateway: webGateway
            )
        }
    }

    private func openArchivedSource(_ url: URL) {
        guard let allowedURL = ReaderNavigationPolicy.allowedURL(url.absoluteString) else { return }
        onOpenSource(allowedURL)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func allowedReaderURL(for result: QuickSearchResult) -> URL? {
        switch result {
        case .news(let item):
            return ReaderNavigationPolicy.allowedURL(item.readerURL ?? item.url)
        case .readerHistory(let entry):
            return ReaderNavigationPolicy.allowedURL(entry.url)
        case .archive:
            return nil
        }
    }

    static func allowedReaderURL(for hit: SearchHit) -> URL? {
        ReaderNavigationPolicy.allowedURL(hit.url)
    }
}
