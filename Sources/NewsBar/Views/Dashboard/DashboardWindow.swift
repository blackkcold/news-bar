import AppKit
import SwiftUI

struct DashboardWindow: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let orchestrator: NewsOrchestrator
    @State private var collapsedRSSSourceIDs: Set<NewsSource.ID> = []
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var sourceFilter: DashboardSourceFilter = .all
    @State private var browseScroll = ScrollPosition()
    @State private var forYou = true
    @State private var listWidth: CGFloat = 400
    @State private var phase: ReaderPresentationPhase = .idle
    @State private var displayedRequest: NewsReaderRequest?
    @State private var readerVisible = false
    @State private var hero: ReaderHeroState?

    var onOpenSettings: () -> Void = {}
    var onConfigureAI: (() -> Void)? = nil

    private let layoutBreakpoint: CGFloat = 960
    private let sidebarWidth: CGFloat = 336
    private let dividerWidth: CGFloat = 9
    private let listMinWidth: CGFloat = 320
    private let listMaxWidth: CGFloat = 480

    enum DashboardSourceFilter: String, CaseIterable, Identifiable {
        case all, weibo, bilibili, rss
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all: return "dash.filter.all".localized
            case .weibo: return "source.weibo".localized
            case .bilibili: return "source.bilibili".localized
            case .rss: return "dash.filter.rss".localized
            }
        }

        func matches(_ source: NewsSource) -> Bool {
            switch self {
            case .all: return true
            case .weibo: return source == .weibo
            case .bilibili: return source == .bilibili
            case .rss: return source != .weibo && source != .bilibili
            }
        }
    }

    private var normalizedSearchQuery: String? {
        DashboardSearch.normalized(debouncedSearchText)
    }

    private func matchesSearch(_ item: NewsItem, query: String? = nil) -> Bool {
        DashboardSearch.matches(item, query: query ?? normalizedSearchQuery)
    }

    private var hasAnyFilter: Bool {
        isSearchActive || sourceFilter != .all
    }

    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isRSSSourceExpanded(_ source: NewsSource) -> Bool {
        !collapsedRSSSourceIDs.contains(source.id)
    }

    private func toggleRSSSourceExpansion(_ source: NewsSource) {
        if collapsedRSSSourceIDs.contains(source.id) {
            collapsedRSSSourceIDs.remove(source.id)
        } else {
            collapsedRSSSourceIDs.insert(source.id)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let selection = NewsNavigationRouter.shared.selection
            let isWide = geometry.size.width >= 1100
            let readerFrame = self.readerFrame(for: geometry.size, isWide: isWide)
            // Keep the compact column while the reader fades out; expand only
            // after it is gone so the reflow is never visible under a fade.
            let listWidthForPhase: CGFloat = (phase == .presented || phase == .dismissing)
                ? clampedListWidth
                : geometry.size.width

            ZStack(alignment: .topLeading) {
                browsePane
                    // Compact reader covers the list; wide split keeps it visible.
                    .environment(\.dashboardListObscured, phase != .idle && !isWide)
                    .frame(width: listWidthForPhase, height: geometry.size.height, alignment: .topLeading)
                    .allowsHitTesting(!(phase == .presented && !isWide))
                    .zIndex(0)

                if let request = displayedRequest {
                    readerPane(request)
                        .frame(
                            width: readerFrame.width,
                            height: readerFrame.height,
                            alignment: .topLeading
                        )
                        .offset(x: readerFrame.minX, y: readerFrame.minY)
                        .opacity(readerVisible ? 1 : 0)
                        .allowsHitTesting(readerVisible)
                        .zIndex(2)
                }

                if isWide, phase == .presented, displayedRequest != nil {
                    DashboardSplitter(width: $listWidth)
                        .frame(width: dividerWidth, height: geometry.size.height)
                        .offset(x: clampedListWidth)
                        .zIndex(3)
                }

                if let hero {
                    ReaderHeroOverlay(state: hero) {
                        self.hero = nil
                    }
                    .zIndex(20)
                }
            }
            .coordinateSpace(name: "dashboardRoot")
            .onAppear {
                if let request = selection, displayedRequest == nil {
                    beginReaderTransition(request: request, size: geometry.size, isWide: isWide)
                }
            }
            .onChange(of: selection?.id) { _, _ in
                if let request = selection {
                    beginReaderTransition(request: request, size: geometry.size, isWide: isWide)
                } else if displayedRequest != nil {
                    beginReaderDismissal()
                }
            }
            .task(id: searchText) {
                let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    debouncedSearchText = ""
                    return
                }
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                debouncedSearchText = searchText
            }
        }
        .frame(minWidth: 960, minHeight: 720)
        .adaptiveColorScheme()
        .appThemeSurface()
        .toolbar {
            ToolbarItem(placement: .principal) { toolbarTitle }
            ToolbarItemGroup(placement: .primaryAction) {
                DashboardRefreshToolbarItem(orchestrator: orchestrator) {
                    Task { await orchestrator.manualRefresh(settings: settings) }
                }
                DashboardToolbarAction(title: settings.appLanguage == .en ? "Settings" : "设置", symbol: "gearshape", action: onOpenSettings)
            }
        }
    }

    private var clampedListWidth: CGFloat {
        min(listMaxWidth, max(listMinWidth, listWidth))
    }

    private func readerPane(_ request: NewsReaderRequest) -> some View {
        NewsReaderView(request: request, onOpenSettings: openInterestSettings)
            .id(request.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func readerFrame(for size: CGSize, isWide: Bool) -> CGRect {
        if isWide {
            let x = clampedListWidth + dividerWidth
            return CGRect(x: x, y: 0, width: max(0, size.width - x), height: size.height)
        }
        return CGRect(origin: .zero, size: size)
    }

    private func beginReaderTransition(request: NewsReaderRequest, size: CGSize, isWide: Bool) {
        let origin = ReaderTransitionCoordinator.shared.consume()

        // Already split open: swap the article without replaying the open
        // transition. The list stays compact and the reader keeps its frame.
        if phase == .presented, displayedRequest != nil {
            displayedRequest = request
            hero = nil
            return
        }

        // Commit the layout change outside any animation. The list reflows once
        // in a single frame; animating it would re-layout every frame of the
        // transition for no visual gain behind the reader.
        displayedRequest = request
        phase = .presented
        readerVisible = false

        if !reduceMotion, let origin, origin.frame.width > 2, origin.frame.height > 2 {
            hero = ReaderHeroState(
                origin: origin.frame,
                target: readerFrame(for: size, isWide: isWide),
                title: origin.title.isEmpty ? request.title : origin.title,
                host: URL(string: request.url)?.host ?? "",
                isRetro: settings.appTheme == .retroEditorial
            )
        } else {
            hero = nil
        }

        Task { @MainActor in
            await Task.yield()
            withAnimation(reduceMotion ? DashboardMotion.reduced : DashboardMotion.structural) {
                readerVisible = true
            }
        }
    }

    private func beginReaderDismissal() {
        guard phase == .presented else { return }
        hero = nil
        phase = .dismissing
        withAnimation(reduceMotion ? DashboardMotion.reduced : DashboardMotion.reveal) {
            readerVisible = false
        }

        let settleDelay = reduceMotion ? 80 : 180
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(settleDelay + 120))
            guard phase == .dismissing else { return }
            displayedRequest = nil
            phase = .idle
        }
    }

    private var browsePane: some View {
        GeometryReader { proxy in
            let isWideLayout = proxy.size.width >= layoutBreakpoint

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 22) {
                    DashboardMasthead(orchestrator: orchestrator)

                    DashboardFilterBar(
                        searchText: $searchText,
                        sourceFilter: $sourceFilter,
                        forYou: $forYou,
                        orchestrator: orchestrator,
                        debouncedQuery: normalizedSearchQuery
                    )

                    contentLayout(
                        isWideLayout: isWideLayout,
                        isReaderCompact: phase == .presented || phase == .dismissing
                    )
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollPosition($browseScroll)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .top) {
                // Floating status keeps the feed from shifting down 40pt every
                // time a refresh starts or a warning appears.
                DashboardStatusOverlay(orchestrator: orchestrator)
                    .padding(.top, 12)
                    .allowsHitTesting(false)
            }
            .adaptiveColorScheme()
            .task {
                await orchestrator.loadCached(settings: settings)
            }
        }
    }

    private func openInterestSettings() {
        NotificationCenter.default.post(name: .interestSettingsRequested, object: nil)
    }

    private func recommendationsView() -> some View {
        RecommendationFeedView(
            matches: { sourceFilter.matches($0.source) && matchesSearch($0) },
            hasFilter: hasAnyFilter,
            onOpenSettings: openInterestSettings,
            onResetFilters: { searchText = ""; sourceFilter = .all },
            onRefresh: { Task { await orchestrator.manualRefresh(settings: settings) } },
            onShowSources: { forYou = false }
        )
    }

    @ViewBuilder
    private func contentLayout(isWideLayout: Bool, isReaderCompact: Bool) -> some View {
        if forYou {
            if isWideLayout && !isReaderCompact {
                HStack(alignment: .top, spacing: 20) {
                    recommendationsView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    DashboardSidebarRegion(
                        orchestrator: orchestrator,
                        sourceFilter: sourceFilter,
                        searchQuery: normalizedSearchQuery,
                        isSearchActive: isSearchActive,
                        onConfigureAI: onConfigureAI ?? onOpenSettings
                    )
                    .frame(width: sidebarWidth, alignment: .leading)
                }
            } else {
                recommendationsView()
            }
        } else if isReaderCompact {
            rssMainRegion
        } else if isWideLayout {
            HStack(alignment: .top, spacing: 20) {
                rssMainRegion
                    .frame(maxWidth: .infinity, alignment: .leading)

                DashboardSidebarRegion(
                    orchestrator: orchestrator,
                    sourceFilter: sourceFilter,
                    searchQuery: normalizedSearchQuery,
                    isSearchActive: isSearchActive,
                    onConfigureAI: onConfigureAI ?? onOpenSettings
                )
                .frame(width: sidebarWidth, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 20) {
                DashboardSidebarRegion(
                    orchestrator: orchestrator,
                    sourceFilter: sourceFilter,
                    searchQuery: normalizedSearchQuery,
                    isSearchActive: isSearchActive,
                    onConfigureAI: onConfigureAI ?? onOpenSettings
                )
                rssMainRegion
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rssMainRegion: some View {
        DashboardRSSMainRegion(
            orchestrator: orchestrator,
            sourceFilter: sourceFilter,
            searchQuery: normalizedSearchQuery,
            hasAnyFilter: hasAnyFilter,
            collapsedSourceIDs: collapsedRSSSourceIDs,
            onToggleExpansion: toggleRSSSourceExpansion,
            onRefresh: { source in
                Task { await orchestrator.refreshRSSSource(source, settings: settings) }
            },
            onOpenSettings: onOpenSettings
        )
    }

    private var toolbarTitle: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 10, weight: settings.appTheme == .retroEditorial ? .black : .semibold))
                Text("DASHBOARD")
                    .font(.system(size: 11, weight: settings.appTheme == .retroEditorial ? .black : .semibold, design: settings.appTheme == .retroEditorial ? .monospaced : .default))
                    .tracking(settings.appTheme == .retroEditorial ? 0.7 : 0)
                Text("趋势 · RSS · AI")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Text("DASHBOARD")
                .font(.system(size: 10, weight: settings.appTheme == .retroEditorial ? .black : .semibold, design: settings.appTheme == .retroEditorial ? .monospaced : .default))

            Image(systemName: "rectangle.split.2x1")
                .accessibilityLabel("Dashboard")
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Dashboard")
    }
}

// MARK: - Search

enum DashboardSearch {
    static func normalized(_ text: String) -> String? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        return query.folding(options: [.caseInsensitive], locale: .current)
    }

    static func matches(_ item: NewsItem, query: String?) -> Bool {
        guard let query else { return true }
        return item.displayTitle.folding(options: [.caseInsensitive], locale: .current)
            .contains(query)
    }
}

// MARK: - Masthead

private struct DashboardMasthead: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let orchestrator: NewsOrchestrator

    private static let issueDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter
    }()

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    private var selectedRSSSources: [NewsSource] {
        settings.activeSources.filter { !$0.isBuiltIn }
    }

    private var totalRSSItemCount: Int {
        selectedRSSSources.reduce(0) { partial, source in
            partial + (orchestrator.rssItemsMap[source.id]?.count ?? 0)
        }
    }

    private var hotCount: Int {
        orchestrator.weiboItems.count + orchestrator.bilibiliItems.count
    }

    private var issueNumber: String {
        String(format: "%02d", Calendar.current.component(.day, from: Date()))
    }

    private var issueDate: String {
        Self.issueDateFormatter.string(from: Date())
    }

    private var mastheadInk: Color {
        isRetro ? RetroEditorialTokens.ink : .primary
    }

    private var mastheadAccent: Color {
        isRetro ? RetroEditorialTokens.brick : .accentColor
    }

    private var mastheadSecondary: Color {
        isRetro ? RetroEditorialTokens.fadedInk : .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("VOL. 06 · NO. \(issueNumber)")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.7)
                Rectangle()
                    .fill(mastheadInk)
                    .frame(height: 1)
                Text(issueDate)
                    .font(.system(size: 10, weight: .bold, design: .serif))
                EditorialTag(text: "上海版", fallbackTint: .secondary, filled: true)
            }
            .padding(.bottom, 9)

            Rectangle()
                .fill(RetroEditorialTokens.ink)
                .frame(height: 2)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("NEWS")
                        .font(.system(size: 46, weight: .black, design: isRetro ? .serif : .default))
                        .tracking(-1.5)
                    Text("BAR")
                        .font(.system(size: 46, weight: .black, design: isRetro ? .serif : .default))
                        .tracking(-1.5)
                        .foregroundStyle(mastheadAccent)
                    Text("新闻编辑台")
                        .font(.system(size: 17, weight: .bold, design: isRetro ? .serif : .default))
                        .foregroundStyle(mastheadSecondary)
                    Spacer(minLength: 12)
                    Text("TREND · RSS · AI")
                        .font(.system(size: 10, weight: .black, design: isRetro ? .monospaced : .default))
                        .tracking(1.1)
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("NEWSBAR")
                        .font(.system(size: 34, weight: .black, design: isRetro ? .serif : .default))
                    Text("新闻编辑台")
                        .font(.system(size: 14, weight: .bold, design: isRetro ? .serif : .default))
                        .foregroundStyle(mastheadAccent)
                }
            }
            .padding(.vertical, 6)

            HStack(spacing: 8) {
                Text("实时聚合 · 档案式阅读 · AI 每日简报")
                    .font(.system(size: 11, weight: .medium, design: isRetro ? .serif : .default))
                    .foregroundStyle(mastheadSecondary)
                Spacer(minLength: 8)
                EditorialTag(text: "热榜 \(hotCount)", fallbackTint: .secondary)
                EditorialTag(text: "RSS \(totalRSSItemCount)", fallbackTint: .secondary)
                EditorialTag(text: "来源 \(selectedRSSSources.count + 2)", fallbackTint: .secondary)
            }
            .padding(.bottom, 8)

            VStack(spacing: 2) {
                Rectangle().fill(mastheadAccent).frame(height: isRetro ? 4 : 2)
                Rectangle().fill(mastheadInk).frame(height: 1)
            }
        }
        .padding(16)
        .background {
            if isRetro {
                Rectangle().fill(RetroEditorialTokens.raisedPaper)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(EditorialSurfaceTokens.cardFill(
                        colorScheme: colorScheme,
                        reduceTransparency: reduceTransparency
                    ))
            }
        }
        .overlay {
            if isRetro {
                Rectangle().strokeBorder(RetroEditorialTokens.ink, lineWidth: 1.5)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.34), lineWidth: 1)
            }
        }
        .editorialClipShape(cornerRadius: 14)
        .background {
            if isRetro {
                Rectangle()
                    .fill(RetroEditorialTokens.ink.opacity(0.72))
                    .offset(x: 4, y: 4)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("NewsBar 新闻编辑台，\(issueDate)，RSS \(totalRSSItemCount) 条")
    }
}

// MARK: - Filter bar

private struct DashboardFilterBar: View {
    @Environment(AppSettings.self) private var settings
    @Binding var searchText: String
    @Binding var sourceFilter: DashboardWindow.DashboardSourceFilter
    @Binding var forYou: Bool
    let orchestrator: NewsOrchestrator
    let debouncedQuery: String?

    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasAnyFilter: Bool {
        isSearchActive || sourceFilter != .all
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(settings.appLanguage == .en ? "Browse mode" : "浏览模式", selection: $forYou) {
                Text(settings.appLanguage == .en ? "For you" : "为你推荐").tag(true)
                Text(settings.appLanguage == .en ? "By source" : "按源浏览").tag(false)
            }
            .pickerStyle(.segmented)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField("dash.searchPlaceholder".localized, text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))

                if isSearchActive {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("dash.searchClear".localized)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                if settings.appTheme == .retroEditorial {
                    Rectangle().fill(RetroEditorialTokens.raisedPaper)
                }
            }
            .glassSettingsSurface(cornerRadius: 12)
            .overlay {
                if settings.appTheme == .retroEditorial {
                    Rectangle().strokeBorder(RetroEditorialTokens.ink, lineWidth: 1.4)
                }
            }

            HStack(spacing: 6) {
                ForEach(DashboardWindow.DashboardSourceFilter.allCases) { filter in
                    filterChip(filter)
                }

                Spacer(minLength: 0)

                if hasAnyFilter {
                    DashboardFilterCountLabel(
                        orchestrator: orchestrator,
                        sourceFilter: sourceFilter,
                        query: debouncedQuery,
                        forYou: forYou
                    )
                }
            }
        }
    }

    private func filterChip(_ filter: DashboardWindow.DashboardSourceFilter) -> some View {
        let isSelected = sourceFilter == filter
        return Button {
            sourceFilter = filter
        } label: {
            Text(filter.displayName)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    if settings.appTheme == .retroEditorial {
                        Rectangle().fill(isSelected ? RetroEditorialTokens.brick : RetroEditorialTokens.raisedPaper)
                    }
                }
                .glassSettingsSurface(cornerRadius: 40, interactive: true)
                .overlay {
                    if settings.appTheme == .retroEditorial {
                        Rectangle().strokeBorder(RetroEditorialTokens.ink, lineWidth: 1)
                    }
                }
                .foregroundStyle(
                    isSelected
                        ? (settings.appTheme == .retroEditorial ? RetroEditorialTokens.raisedPaper : Color.accentColor)
                        : .primary
                )
        }
        .buttonStyle(.plain)
    }
}

private struct DashboardFilterCountLabel: View {
    @Environment(AppSettings.self) private var settings
    let orchestrator: NewsOrchestrator
    let sourceFilter: DashboardWindow.DashboardSourceFilter
    let query: String?
    let forYou: Bool

    private var count: Int {
        if forYou {
            return InterestController.shared.recommendations?.items.filter {
                sourceFilter.matches($0.item.source) && DashboardSearch.matches($0.item, query: query)
            }.count ?? 0
        }
        var result = 0
        if sourceFilter.matches(.weibo) {
            result += orchestrator.weiboItems.filter {
                DashboardSearch.matches($0, query: query)
            }.count
        }
        if sourceFilter.matches(.bilibili) {
            result += orchestrator.bilibiliItems.filter {
                DashboardSearch.matches($0, query: query)
            }.count
        }
        for source in settings.activeSources where !source.isBuiltIn {
            guard sourceFilter.matches(source) else { continue }
            result += (orchestrator.rssItemsMap[source.id] ?? []).filter {
                DashboardSearch.matches($0, query: query)
            }.count
        }
        return result
    }

    var body: some View {
        Text(L10n.string("dash.filterCount", count))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

// MARK: - Status overlay

private struct DashboardStatusOverlay: View {
    let orchestrator: NewsOrchestrator

    var body: some View {
        if orchestrator.manualRefreshWarning != nil || orchestrator.batchProgress.total > 0 {
            VStack(alignment: .leading, spacing: 8) {
                if let warning = orchestrator.manualRefreshWarning {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text(warning)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                }

                if orchestrator.batchProgress.total > 0 {
                    HStack(spacing: 10) {
                        ProgressView(
                            value: Double(orchestrator.batchProgress.completed),
                            total: Double(orchestrator.batchProgress.total)
                        )
                        .controlSize(.small)
                        .tint(.blue)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("dash.rssBatchRefreshing".localized)
                                .font(.system(size: 12, weight: .medium))
                            Text("\(orchestrator.batchProgress.completed)/\(orchestrator.batchProgress.total)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(12)
            .newsCardSurface(cornerRadius: 14)
            .padding(.horizontal, 20)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Sidebar

private struct DashboardSidebarRegion: View {
    let orchestrator: NewsOrchestrator
    let sourceFilter: DashboardWindow.DashboardSourceFilter
    let searchQuery: String?
    let isSearchActive: Bool
    let onConfigureAI: () -> Void

    private func filtered(_ source: NewsSource, _ items: [NewsItem]) -> [NewsItem] {
        guard sourceFilter.matches(source) else { return [] }
        return items.filter { DashboardSearch.matches($0, query: searchQuery) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            EditorialSectionHeading(
                index: "01",
                title: "每日简报",
                subtitle: "AI 编辑部整理的重要线索"
            )

            DashboardAIBriefingPanel(
                orchestrator: orchestrator,
                onConfigureAI: onConfigureAI
            )

            EditorialSectionHeading(
                index: "02",
                title: "实时热榜",
                subtitle: "社交平台正在发生"
            )

            if sourceFilter.matches(.weibo) || !isSearchActive {
                DashboardHotTrendCard(source: .weibo, items: filtered(.weibo, orchestrator.weiboItems))
            }
            if sourceFilter.matches(.bilibili) || !isSearchActive {
                DashboardHotTrendCard(source: .bilibili, items: filtered(.bilibili, orchestrator.bilibiliItems))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - RSS main region

private struct DashboardRSSMainRegion: View {
    @Environment(AppSettings.self) private var settings
    let orchestrator: NewsOrchestrator
    let sourceFilter: DashboardWindow.DashboardSourceFilter
    let searchQuery: String?
    let hasAnyFilter: Bool
    let collapsedSourceIDs: Set<NewsSource.ID>
    let onToggleExpansion: (NewsSource) -> Void
    let onRefresh: (NewsSource) -> Void
    let onOpenSettings: () -> Void

    private var selectedSources: [NewsSource] {
        settings.activeSources.filter { !$0.isBuiltIn }
    }

    private var totalItemCount: Int {
        selectedSources.reduce(0) { partial, source in
            partial + (orchestrator.rssItemsMap[source.id]?.count ?? 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            EditorialSectionHeading(
                index: "03",
                title: "RSS 主版",
                subtitle: selectedSources.isEmpty
                    ? "尚未启用 RSS 源"
                    : "\(selectedSources.count) 个已启用源 · \(totalItemCount) 条内容"
            )

            if selectedSources.isEmpty {
                emptyState
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(selectedSources) { source in
                        DashboardRSSSourceCard(
                            source: source,
                            orchestrator: orchestrator,
                            sourceFilter: sourceFilter,
                            searchQuery: searchQuery,
                            hasAnyFilter: hasAnyFilter,
                            isExpanded: !collapsedSourceIDs.contains(source.id),
                            onRefresh: { onRefresh(source) },
                            onToggleExpansion: { onToggleExpansion(source) }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("尚未启用任何 RSS 源")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            Text("在设置中启用 RSS 订阅后，每个来源会以独立卡片显示在这里。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("打开设置") {
                onOpenSettings()
            }
            .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
            .controlSize(.small)
        }
        .padding(14)
        .newsCardSurface()
    }
}

// MARK: - Toolbar

private struct DashboardRefreshToolbarItem: View {
    @Environment(AppSettings.self) private var settings
    let orchestrator: NewsOrchestrator
    let action: () -> Void

    var body: some View {
        DashboardToolbarAction(
            title: settings.appLanguage == .en ? "Refresh" : "刷新",
            symbol: "arrow.clockwise",
            isDisabled: orchestrator.isRefreshing,
            action: action
        )
    }
}

private struct DashboardToolbarAction: View {
    @Environment(AppSettings.self) private var settings

    let title: String
    let symbol: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Group {
            if settings.appTheme == .retroEditorial {
                Button(action: action) {
                    ViewThatFits(in: .horizontal) {
                        Label(title, systemImage: symbol)
                        Image(systemName: symbol)
                    }
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))
            } else {
                Button(action: action) {
                    Label(title, systemImage: symbol)
                }
            }
        }
        .disabled(isDisabled)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct DashboardSplitter: View {
    @Binding var width: CGFloat
    @State private var dragStart: CGFloat?
    @State private var proposedWidth: CGFloat?

    private let minWidth: CGFloat = 320
    private let maxWidth: CGFloat = 480

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)

            if let proposedWidth {
                // Show the target position while dragging; commit the real
                // width once on release so the list does not reflow per frame.
                Rectangle()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .offset(x: proposedWidth - width)
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .onDisappear { NSCursor.arrow.set() }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragStart == nil { dragStart = width }
                    let start = dragStart ?? width
                    proposedWidth = min(maxWidth, max(minWidth, start + value.translation.width))
                }
                .onEnded { _ in
                    if let proposedWidth {
                        width = proposedWidth
                    }
                    dragStart = nil
                    proposedWidth = nil
                }
        )
        .onTapGesture(count: 2) {
            dragStart = nil
            proposedWidth = nil
            width = 400
        }
        .accessibilityLabel("Resize news list")
    }
}
