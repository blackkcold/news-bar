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

/// Search content for the reader auxiliary rail. It owns no outer chrome:
/// the rail supplies the width, material, padding and the close control, so
/// the AI surface cannot end up inside a second floating panel.
struct QuickSearchContent: View {
    @Bindable var model: QuickSearchModel
    @Bindable var aiModel: AISearchPanelModel
    @Bindable var archiveController: AISearchArchiveController
    let activeNewsItems: [NewsItem]
    let readingHistory: [ReaderHistoryEntry]
    @Bindable var settings: AppSettings
    let language: AppLanguage
    @Binding var surface: QuickSearchSurface
    @Binding var selectedArchiveEntry: AISearchArchiveEntry?
    /// The rail sets this false while the overview tab is showing. Only the
    /// visible tab may take first responder.
    var isActive = true
    /// The rail fills the free height under its header. The standalone preview
    /// keeps the historical fixed caps so its existing snapshot stays stable.
    var fillsAvailableHeight = true
    /// Free height inside the rail, used to cap the answer canvas and archive.
    var availableHeight: CGFloat = 520
    let onOpenResult: (URL) -> Void
    let onOpenSource: (URL) -> Void
    let onConfigureAI: () -> Void

    @State private var webGateway = ManualSearchGateway()
    @State private var webTask: Task<Void, Never>?
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            surfacePicker
            if let selectedArchiveEntry {
                archiveReplay(selectedArchiveEntry)
            } else {
                surfaceContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .onAppear { activateIfNeeded() }
        .onChange(of: isActive) { _, active in
            if active {
                activateIfNeeded()
            } else {
                queryFocused = false
                webTask?.cancel()
            }
        }
        .onChange(of: model.query) { _, _ in
            if surface == .local { refreshLocalResults() }
        }
        .onChange(of: archiveController.entries) { _, _ in
            if surface == .local { refreshLocalResults() }
        }
        .onChange(of: surface) { _, newSurface in
            if newSurface == .local { refreshLocalResults() }
            if newSurface == .ai { aiModel.present() }
            queryFocused = newSurface != .ai
        }
        .onChange(of: settings.aiSearchEnabled) { _, isEnabled in
            if !isEnabled, surface == .ai { selectSurface(.local) }
        }
        .onDisappear { webTask?.cancel() }
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
                .minimumScaleFactor(0.8)
        }
        .controlSize(.small)
        .disabled(candidate == .ai && !settings.aiSearchEnabled)
        .accessibilityLabel(QuickSearchAccessibilityLabels.surface(candidate, language: language))
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
                emptyState(
                    L10n.string("reader.quickSearch.localPrompt", language: language),
                    systemImage: "magnifyingglass",
                    minHeight: 180
                )
            } else if model.localResults.isEmpty {
                emptyState(
                    L10n.string("reader.quickSearch.noResults", language: language),
                    systemImage: "doc.text.magnifyingglass",
                    minHeight: 180
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.localResults) { result in
                            localResultRow(result)
                        }
                    }
                }
                .frame(maxHeight: resultsMaxHeight(470))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil, alignment: .topLeading)
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
                    .frame(
                        maxWidth: .infinity,
                        minHeight: fillsAvailableHeight ? nil : 120,
                        maxHeight: fillsAvailableHeight ? .infinity : nil
                    )
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
                .frame(
                    maxWidth: .infinity,
                    minHeight: fillsAvailableHeight ? nil : 120,
                    maxHeight: fillsAvailableHeight ? .infinity : nil
                )
            } else if !model.webHits.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.webHits, id: \.canonicalURL) { hit in
                            webResultRow(hit)
                        }
                    }
                }
                .frame(maxHeight: resultsMaxHeight(470))
            } else {
                emptyState(
                    L10n.string("reader.quickSearch.webPrompt", language: language),
                    systemImage: "globe",
                    minHeight: 160
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil, alignment: .topLeading)
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
                },
                maxHeight: archiveMaxHeight
            )
        }
        .frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil, alignment: .topLeading)
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
                maxHeight: replayMaxHeight,
                onOpenSource: { source in
                    guard let url = ReaderNavigationPolicy.allowedURL(source.url) else { return }
                    onOpenSource(url)
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil, alignment: .topLeading)
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
            onClose: {},
            onOpenCitation: { url in
                guard let allowedURL = ReaderNavigationPolicy.allowedURL(url.absoluteString) else { return }
                onOpenSource(allowedURL)
            },
            onCopy: copy,
            onOpenSettings: onConfigureAI,
            onReturnToSearch: { selectSurface(.local) },
            onOpenArchive: { selectSurface(.archive) },
            embedded: true,
            isActive: isActive && surface == .ai,
            answerMaxHeight: answerMaxHeight,
            thinking: searchThinkingCapability.normalized(settings.aiSearchThinking),
            thinkingOptions: searchThinkingCapability.options,
            onThinkingChange: { settings.aiSearchThinking = $0 }
        )
    }

    private var searchThinkingCapability: AIThinkingCapability {
        AIThinkingResolver.capability(
            connection: settings.resolvedAIConnection,
            model: settings.effectiveAISearchModel,
            language: language
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

    private func emptyState(_ title: String, systemImage: String, minHeight: CGFloat) -> some View {
        ContentUnavailableView(title, systemImage: systemImage)
            .frame(
                maxWidth: .infinity,
                minHeight: fillsAvailableHeight ? nil : minHeight,
                maxHeight: fillsAvailableHeight ? .infinity : nil
            )
    }

    private func resultsMaxHeight(_ fallback: CGFloat) -> CGFloat? {
        fillsAvailableHeight ? .infinity : fallback
    }

    private var answerMaxHeight: CGFloat {
        guard fillsAvailableHeight else { return 360 }
        let chrome: CGFloat = aiModel.hasAcknowledgedPrivacy ? 230 : 290
        return min(360, max(140, availableHeight - chrome))
    }

    private var archiveMaxHeight: CGFloat {
        fillsAvailableHeight ? max(160, availableHeight - 120) : 460
    }

    private var replayMaxHeight: CGFloat {
        fillsAvailableHeight ? max(160, availableHeight - 160) : 400
    }

    private func activateIfNeeded() {
        guard isActive else { return }
        if surface == .local { refreshLocalResults() }
        if surface == .ai { aiModel.present() }
        queryFocused = surface != .ai
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
        queryFocused = nextSurface != .ai
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
        webTask?.cancel()
        let query = model.query
        webTask = Task {
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
