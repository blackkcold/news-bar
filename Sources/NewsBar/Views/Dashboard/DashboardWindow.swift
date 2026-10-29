import AppKit
import SwiftUI

struct DashboardWindow: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let orchestrator: NewsOrchestrator
    @State private var actionToasts = ActionToastCenter.shared
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
    var onOpenResearchCenter: (String?) -> Void = { _ in }

    private let layoutBreakpoint: CGFloat = 960
    private let sidebarWidth: CGFloat = 336
    private let dividerWidth: CGFloat = 9
    private let listMinWidth: CGFloat = 320
    private let listMaxWidth: CGFloat = 480

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
        @Bindable var router = NewsNavigationRouter.shared
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
                DashboardToolbarAction(
                    title: L10n.string("research.center.title", language: settings.appLanguage),
                    symbol: "sparkles",
                    action: { onOpenResearchCenter(nil) }
                )
                DashboardToolbarAction(title: settings.appLanguage == .en ? "Settings" : "设置", symbol: "gearshape", action: onOpenSettings)
            }
        }
        .sheet(item: $router.digest) { request in
            NewsDigestSheet(request: request)
                .environment(settings)
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
            .onChange(of: phase) { _, newPhase in
                // The list narrows and gains the compact 02 block when the
                // reader opens; a preserved offset would point past the
                // reflowed content.
                if newPhase == .presented {
                    browseScroll.scrollTo(edge: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .top) {
                // Floating status keeps the feed from shifting down 40pt every
                // time a refresh starts or a warning appears.
                DashboardStatusOverlay(orchestrator: orchestrator)
                    .padding(.top, 12)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                if let toast = actionToasts.toast {
                    ActionToastView(toast: toast)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: actionToasts.toast?.id)
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

    private var browseGroups: [DashboardBrowseGroup] {
        DashboardBrowseCatalog.groups(
            sources: settings.activeSources,
            weiboItems: orchestrator.weiboItems,
            bilibiliItems: orchestrator.bilibiliItems,
            rssItems: orchestrator.rssItemsMap,
            filter: sourceFilter,
            query: normalizedSearchQuery
        )
    }

    @ViewBuilder
    private func contentLayout(isWideLayout: Bool, isReaderCompact: Bool) -> some View {
        let groups = browseGroups
        let hotGroups = groups.filter { $0.source.isBuiltIn }
        let rssGroups = groups.filter { !$0.source.isBuiltIn }
        let matchedHotGroups = hotGroups.filter { $0.matchCount > 0 }
        let hotMatchCount = hotGroups.reduce(0) { $0 + $1.matchCount }

        if forYou {
            if isWideLayout && !isReaderCompact {
                HStack(alignment: .top, spacing: 20) {
                    recommendationsView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    DashboardSidebarRegion(
                        orchestrator: orchestrator,
                        hotGroups: hotGroups,
                        searchQuery: normalizedSearchQuery,
                        onConfigureAI: onConfigureAI ?? onOpenSettings,
                        onOpenResearch: onOpenResearchCenter
                    )
                    .frame(width: sidebarWidth, alignment: .leading)
                }
            } else {
                recommendationsView()
            }
        } else if isReaderCompact {
            // The reader squeezes the list to 320–480pt. Keep 02 reachable
            // without two full trend cards pushing 03 out of the first screen.
            VStack(alignment: .leading, spacing: 20) {
                if !matchedHotGroups.isEmpty {
                    DashboardCompactHotTrends(
                        groups: matchedHotGroups,
                        orchestrator: orchestrator,
                        searchQuery: normalizedSearchQuery
                    )
                }
                sourceBrowserRegion(groups: rssGroups, hotMatchCount: hotMatchCount)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if isWideLayout {
            HStack(alignment: .top, spacing: 20) {
                sourceBrowserRegion(groups: rssGroups, hotMatchCount: hotMatchCount)
                    .frame(maxWidth: .infinity, alignment: .leading)

                DashboardSidebarRegion(
                    orchestrator: orchestrator,
                    hotGroups: hotGroups,
                    searchQuery: normalizedSearchQuery,
                    onConfigureAI: onConfigureAI ?? onOpenSettings,
                    onOpenResearch: onOpenResearchCenter
                )
                .frame(width: sidebarWidth, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 20) {
                DashboardSidebarRegion(
                    orchestrator: orchestrator,
                    hotGroups: hotGroups,
                    searchQuery: normalizedSearchQuery,
                    onConfigureAI: onConfigureAI ?? onOpenSettings,
                    onOpenResearch: onOpenResearchCenter
                )
                sourceBrowserRegion(groups: rssGroups, hotMatchCount: hotMatchCount)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sourceBrowserRegion(groups: [DashboardBrowseGroup], hotMatchCount: Int) -> some View {
        DashboardSourceBrowserRegion(
            orchestrator: orchestrator,
            sourceFilter: sourceFilter,
            groups: groups,
            hotMatchCount: hotMatchCount,
            searchQuery: normalizedSearchQuery,
            hasAnyFilter: hasAnyFilter,
            collapsedSourceIDs: collapsedRSSSourceIDs,
            onToggleExpansion: toggleRSSSourceExpansion,
            onRefresh: { source in
                Task { await orchestrator.refreshRSSSource(source, settings: settings) }
            },
            onOpenSettings: onOpenSettings,
            onResetFilters: { searchText = ""; sourceFilter = .all }
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
    @Binding var sourceFilter: DashboardSourceFilter
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
                ForEach(DashboardSourceFilter.allCases) { filter in
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

    private func filterChip(_ filter: DashboardSourceFilter) -> some View {
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
    let sourceFilter: DashboardSourceFilter
    let query: String?
    let forYou: Bool

    private var count: Int {
        if forYou {
            return InterestController.shared.recommendations?.items.filter {
                sourceFilter.matches($0.item.source) && DashboardSearch.matches($0.item, query: query)
            }.count ?? 0
        }
        return DashboardBrowseCatalog.groups(
            sources: settings.activeSources,
            weiboItems: orchestrator.weiboItems,
            bilibiliItems: orchestrator.bilibiliItems,
            rssItems: orchestrator.rssItemsMap,
            filter: sourceFilter,
            query: query
        ).reduce(0) { $0 + $1.matchCount }
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
    let hotGroups: [DashboardBrowseGroup]
    let searchQuery: String?
    let onConfigureAI: () -> Void
    let onOpenResearch: (String?) -> Void

    private func items(for source: NewsSource) -> [NewsItem] {
        let items: [NewsItem]
        switch source {
        case .weibo: items = orchestrator.weiboItems
        case .bilibili: items = orchestrator.bilibiliItems
        case .rss: items = []
        }
        return items.filter { DashboardSearch.matches($0, query: searchQuery) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            EditorialSectionHeading(
                index: "01",
                title: L10n.string("dash.briefing.title"),
                subtitle: L10n.string("dash.briefing.sectionSubtitle")
            )

            DashboardAIBriefingPanel(
                orchestrator: orchestrator,
                onConfigureAI: onConfigureAI
            )

            // A chip such as RSS empties this list; keeping the heading would
            // leave an orphan "02" block with no cards above "03".
            if !hotGroups.isEmpty {
                EditorialSectionHeading(
                    index: "02",
                    title: L10n.string("dash.hotTrends.title"),
                    subtitle: L10n.string("dash.hotTrends.subtitle")
                )

                ForEach(hotGroups) { group in
                    DashboardHotTrendCard(
                        source: group.source,
                        items: items(for: group.source)
                    )
                }
            }

            DashboardResearchSection(
                index: "03",
                entries: orchestrator.researchHighlights,
                onOpen: onOpenResearch
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Research sidebar section

private struct DashboardResearchSection: View {
    @Environment(AppSettings.self) private var settings
    let index: String
    let entries: [ResearchIndexEntry]
    let onOpen: (String?) -> Void

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                EditorialSectionHeading(
                    index: index,
                    title: L10n.string("research.dashboard.title", language: settings.appLanguage),
                    subtitle: L10n.string("research.dashboard.subtitle", language: settings.appLanguage)
                )

                VStack(spacing: 2) {
                    ForEach(entries) { entry in
                        Button {
                            onOpen(entry.id)
                        } label: {
                            row(entry)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(accessibilityLabel(entry))
                    }
                }

                Button {
                    onOpen(nil)
                } label: {
                    HStack(spacing: 4) {
                        Text(L10n.string("research.dashboard.viewAll", language: settings.appLanguage))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.string("research.center.title", language: settings.appLanguage))
            }
        }
    }

    private func row(_ entry: ResearchIndexEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(tint(entry))
                .frame(width: 6, height: 6)
                .padding(.top, 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle(entry))
                    .font(.system(size: 11, weight: entry.isRead ? .regular : .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 4) {
                    Text(L10n.string("research.origin.\(entry.origin.rawValue)", language: settings.appLanguage))
                    Text("·")
                    Text(Self.relativeFormatter.localizedString(for: entry.updatedAt, relativeTo: Date()))
                    Spacer(minLength: 0)
                    badge(entry)
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func displayTitle(_ entry: ResearchIndexEntry) -> String {
        entry.topic.isEmpty
            ? ResearchStatusPresentation.label(entry.status, language: settings.appLanguage)
            : entry.topic
    }

    @ViewBuilder
    private func badge(_ entry: ResearchIndexEntry) -> some View {
        if entry.status == .running || entry.status == .queued {
            Text(ResearchStatusPresentation.label(entry.status, language: settings.appLanguage))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint(entry))
        } else if let verdict = entry.verdict {
            Text(L10n.string("research.verdict.short.\(verdict.rawValue)", language: settings.appLanguage))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint(entry))
        } else if entry.strength > 0 {
            Text("\(entry.strength)/4")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint(entry))
        }
    }

    private func tint(_ entry: ResearchIndexEntry) -> Color {
        ResearchStatusPresentation.tint(entry.status)
    }

    private func accessibilityLabel(_ entry: ResearchIndexEntry) -> String {
        let separator = settings.appLanguage == .en ? ", " : "，"
        return [
            displayTitle(entry),
            ResearchStatusPresentation.label(entry.status, language: settings.appLanguage),
            L10n.string("research.origin.\(entry.origin.rawValue)", language: settings.appLanguage),
        ].joined(separator: separator)
    }
}

// MARK: - Source browser

private struct DashboardSourceBrowserRegion: View {
    @Environment(AppSettings.self) private var settings
    let orchestrator: NewsOrchestrator
    let sourceFilter: DashboardSourceFilter
    let groups: [DashboardBrowseGroup]
    let hotMatchCount: Int
    let searchQuery: String?
    let hasAnyFilter: Bool
    let collapsedSourceIDs: Set<NewsSource.ID>
    let onToggleExpansion: (NewsSource) -> Void
    let onRefresh: (NewsSource) -> Void
    let onOpenSettings: () -> Void
    let onResetFilters: () -> Void

    private var hasRSSSources: Bool {
        settings.activeSources.contains { !$0.isBuiltIn }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            EditorialSectionHeading(
                index: "03",
                title: L10n.string("dash.browse.title"),
                subtitle: subtitle
            )

            if groups.isEmpty {
                if !hasRSSSources {
                    rssOnboardingState
                } else if hotMatchCount > 0 {
                    hotElsewhereState
                } else {
                    noMatchState
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { group in
                        DashboardRSSSourceCard(
                            source: group.source,
                            orchestrator: orchestrator,
                            sourceFilter: sourceFilter,
                            searchQuery: searchQuery,
                            hasAnyFilter: hasAnyFilter,
                            isExpanded: !collapsedSourceIDs.contains(group.source.id),
                            onRefresh: { onRefresh(group.source) },
                            onToggleExpansion: { onToggleExpansion(group.source) }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        guard !groups.isEmpty else {
            if !hasRSSSources { return L10n.string("dash.browse.rssEmptyTitle") }
            if hotMatchCount > 0 { return L10n.string("dash.browse.noRSSMatch") }
            return L10n.string("dash.browse.empty")
        }
        let matchCount = groups.reduce(0) { $0 + $1.matchCount }
        return L10n.string("dash.browse.subtitle", groups.count, matchCount)
    }

    private var hotElsewhereState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(L10n.string(
                    "dash.browse.hotElsewhere",
                    hotMatchCount,
                    L10n.string("dash.hotTrends.title")
                ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            Button(L10n.string("dash.browse.reset")) {
                onResetFilters()
            }
            .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
            .controlSize(.small)
        }
        .padding(14)
        .newsCardSurface()
    }

    private var noMatchState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("dash.browse.empty"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Button(L10n.string("dash.browse.reset")) {
                onResetFilters()
            }
            .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
            .controlSize(.small)
        }
        .padding(14)
        .newsCardSurface()
    }

    private var rssOnboardingState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(L10n.string("dash.browse.rssEmptyTitle"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            Text(L10n.string("dash.browse.rssEmptyBody"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(L10n.string("dash.browse.openSettings")) {
                onOpenSettings()
            }
            .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
            .controlSize(.small)
        }
        .padding(14)
        .newsCardSurface()
    }
}

// MARK: - Compact hot trends (reader side pane)

/// The reader squeezes the list to 320–480pt. Two full trend cards would push
/// the source list out of the first screen, so each source collapses to one
/// row that expands to its top five items on demand.
private struct DashboardCompactHotTrends: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let groups: [DashboardBrowseGroup]
    let orchestrator: NewsOrchestrator
    let searchQuery: String?
    @State private var expandedSourceIDs: Set<NewsSource.ID> = []

    private func items(for source: NewsSource) -> [NewsItem] {
        let items: [NewsItem]
        switch source {
        case .weibo: items = orchestrator.weiboItems
        case .bilibili: items = orchestrator.bilibiliItems
        case .rss: items = []
        }
        return items.filter { DashboardSearch.matches($0, query: searchQuery) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorialSectionHeading(
                index: "02",
                title: L10n.string("dash.hotTrends.title"),
                subtitle: L10n.string("dash.hotTrends.subtitle")
            )

            ForEach(groups) { group in
                sourceRow(group)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func sourceRow(_ group: DashboardBrowseGroup) -> some View {
        let presentation = DashboardTrendPresentation(for: group.source)
        let isExpanded = expandedSourceIDs.contains(group.source.id)
        let visibleItems = Array(items(for: group.source).prefix(5))

        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggle(group.source)
            } label: {
                HStack(spacing: 9) {
                    EditorialSourceBadge(
                        mark: presentation.mark,
                        fallbackTint: presentation.accent,
                        size: 24
                    )

                    Text(presentation.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    EditorialTag(
                        text: L10n.string("news.count", group.matchCount),
                        fallbackTint: presentation.accent
                    )

                    Spacer(minLength: 8)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isExpanded
                    ? L10n.string("dash.collapseCard", presentation.title)
                    : L10n.string("dash.expandCard", presentation.title)
            )

            if isExpanded, !visibleItems.isEmpty {
                Divider().padding(.horizontal, 12)

                LazyVStack(spacing: 0) {
                    ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                        DashboardTrendRow(
                            item: item,
                            sourceLabel: presentation.title,
                            sourceMark: presentation.mark,
                            accent: presentation.accent,
                            rankFallback: index + 1,
                            reduceMotion: reduceMotion
                        )

                        if index < visibleItems.count - 1 {
                            Divider().padding(.horizontal, 12)
                        }
                    }
                }
            }
        }
        .newsCardSurface(cornerRadius: 12)
    }

    private func toggle(_ source: NewsSource) {
        let update = {
            if expandedSourceIDs.contains(source.id) {
                expandedSourceIDs.remove(source.id)
            } else {
                expandedSourceIDs.insert(source.id)
            }
        }

        if reduceMotion {
            update()
        } else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                update()
            }
        }
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
