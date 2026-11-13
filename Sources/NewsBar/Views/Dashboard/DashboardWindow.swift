import AppKit
import SwiftUI

struct DashboardWindow: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let orchestrator: NewsOrchestrator
    var weiboMonitor: WeiboMonitorViewModel? = nil
    var readerPresentationState: DashboardReaderPresentationState? = nil
    @State private var actionToasts = ActionToastCenter.shared
    @State private var collapsedRSSSourceIDs: Set<NewsSource.ID> = []
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var sourceFilter: DashboardSourceFilter = .all
    @State private var browseMode: DashboardBrowseMode = .forYou
    /// Panes visited at least once. Only these are mounted, so the dashboard
    /// never builds the by-source catalog or the follow feed for a tab the
    /// user has not opened.
    @State private var mountedModes: Set<DashboardBrowseMode> = [.forYou]
    /// Panes scrolled past roughly one screen; drives their "back to top"
    /// button. One entry per browse mode.
    @State private var scrolledPanes: Set<DashboardBrowseMode> = []
    @State private var followingFilter: WeiboFollowingFilter = .all
    @State private var followingSearch = ""
    @State private var followingAccountUID: String?
    @State private var listWidth: CGFloat = 400
    @State private var tabs = WorkspaceTabStore.shared

    var onOpenSettings: () -> Void = {}
    var onConfigureAI: (() -> Void)? = nil
    var onOpenResearchCenter: (String?) -> Void = { _ in }
    var onOpenEventMonitor: () -> Void = {}
    var onOpenWeiboMonitorSettings: (() -> Void)? = nil

    private let layoutBreakpoint = DashboardLayoutMetrics.layoutBreakpoint
    private let sidebarWidth = DashboardLayoutMetrics.sidebarWidth

    private var normalizedSearchQuery: String? {
        DashboardSearch.normalized(debouncedSearchText)
    }

    private var hasAnyFilter: Bool {
        isSearchActive || sourceFilter != .all
    }

    private var rssItemCount: Int {
        settings.activeSources
            .filter { !$0.isBuiltIn }
            .reduce(0) { total, source in
                total + (orchestrator.rssItemsMap[source.id]?.count ?? 0)
            }
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
        VStack(spacing: 0) {
            DashboardNewsroomBar(
                mode: browseMode,
                followingUnread: weiboMonitor?.snapshot.unreadCount ?? 0,
                badgeEnabled: settings.weiboMonitorDashboardBadgeEnabled,
                tabs: tabs.tabs,
                activeID: tabs.activeID,
                isRefreshing: orchestrator.isRefreshing,
                showsRefresh: browseMode != .following,
                onSelectMode: { newMode in
                    router.selection = nil
                    browseMode = newMode
                },
                onSelectBrowse: { router.selection = nil },
                onSelectTab: { id in
                    if let request = tabs.request(for: id) {
                        router.selection = request
                    }
                },
                onCloseTab: { id in closeTab(id, router: router) },
                onRefresh: { Task { await orchestrator.manualRefresh(settings: settings) } },
                onOpenResearch: { onOpenResearchCenter(nil) },
                onOpenEventMonitor: onOpenEventMonitor,
                onOpenSettings: onOpenSettings
            )
            DashboardReaderPresentation(
                selection: $router.selection,
                listWidth: $listWidth,
                isRetro: settings.appTheme == .retroEditorial,
                reduceMotion: reduceMotion,
                transitionOriginProvider: { ReaderTransitionCoordinator.shared.consume() },
                presentationState: readerPresentationState
            ) { context in
                browsePane(isReaderCompact: context.isReaderCompact, phase: context.phase)
            } readerContent: { _, readerPresented in
                readerPanes(readerPresented: readerPresented)
            }
        }
        .onAppear { syncTabs(with: router.selection) }
        .onChange(of: router.selection?.id) { _, _ in
            syncTabs(with: router.selection)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWeiboFollowFeed)) { _ in
            browseMode = .following
        }
        .onChange(of: browseMode) { _, newMode in
            // The first visit mounts the pane; every later visit reuses the
            // same view (and its scroll view), which is what keeps the offset.
            mountedModes.insert(newMode)
            // A hidden TextField keeps the field editor alive. Without this,
            // typing after a tab switch lands in an invisible filter box.
            clearTextFocus()
            WeiboMonitorViewModel.setFeedVisible(newMode == .following)
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
        .frame(minWidth: 960, minHeight: 720)
        .adaptiveColorScheme()
        .appThemeSurface()
        // Rebuild the surface when the process-wide language changes so every
        // `.localized` label, not only the ones reading `settings`, refreshes.
        .id(settings.appLanguage)
        .sheet(item: $router.digest) { request in
            NewsDigestSheet(request: request)
                .environment(settings)
        }
    }

    @ViewBuilder
    private func readerPanes(readerPresented: Bool) -> some View {
        ZStack {
            ForEach(tabs.tabs) { tab in
                let active = tabs.activeID == tab.id
                NewsReaderView(
                    model: tabs.model(for: tab),
                    activeNewsItems: orchestrator.allActiveItems(settings: settings),
                    readerPresented: readerPresented,
                    isActiveTab: active,
                    onOpenSettings: openInterestSettings,
                    onOpenResearch: { onOpenResearchCenter($0) },
                    onConfigureAI: onConfigureAI ?? {}
                )
                .id(tab.id)
                .opacity(active ? 1 : 0)
                .allowsHitTesting(active)
                .accessibilityHidden(!active)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func syncTabs(with request: NewsReaderRequest?) {
        guard let request else {
            tabs.deactivate()
            return
        }
        tabs.openOrActivate(request)
    }

    private func closeTab(_ id: UUID, router: NewsNavigationRouter) {
        let wasActive = tabs.activeID == id
        guard let next = tabs.close(id) else {
            router.selection = nil
            return
        }
        if wasActive {
            router.selection = next.request
        }
    }

    private func browsePane(isReaderCompact: Bool, phase: ReaderPresentationPhase) -> some View {
        GeometryReader { proxy in
            let isWideLayout = proxy.size.width >= layoutBreakpoint
            let contentWidth = max(0, proxy.size.width - 40)
            // A mounted by-source pane keeps rendering its catalog, so the
            // build is only skippable until that pane has been opened once.
            let needsSourceGroups = browseMode == .bySource || mountedModes.contains(.bySource)
            let sourceGroups = needsSourceGroups ? browseGroups : []

            ZStack {
                ForEach(DashboardBrowseMode.allCases) { mode in
                    if mountedModes.contains(mode) {
                        browsePaneLayer(
                            mode: mode,
                            phase: phase,
                            isWideLayout: isWideLayout,
                            isReaderCompact: isReaderCompact,
                            contentWidth: contentWidth,
                            sourceGroups: sourceGroups
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .top) {
                // Floating status keeps the feed from shifting down 40pt every
                // time a refresh starts or a warning appears. One overlay for
                // every pane: it reads the shared orchestrator.
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

    /// One mounted browse mode. It stays in the tree after its first visit, so
    /// its scroll offset and every `@State` page count survive a tab switch.
    @ViewBuilder
    private func browsePaneLayer(
        mode: DashboardBrowseMode,
        phase: ReaderPresentationPhase,
        isWideLayout: Bool,
        isReaderCompact: Bool,
        contentWidth: CGFloat,
        sourceGroups: [DashboardBrowseGroup]
    ) -> some View {
        let isActive = mode == browseMode
        BrowsePaneAccess(isActive: isActive) {
            if mode == .following, let weiboMonitor,
               weiboMonitor.snapshot.isEnabled, !weiboMonitor.snapshot.users.isEmpty {
                ZStack {
                    FollowingReaderWorkspace(
                        monitor: weiboMonitor,
                        filter: $followingFilter,
                        searchText: $followingSearch,
                        accountUID: $followingAccountUID,
                        isActive: isActive,
                        onOpenSettings: onOpenWeiboMonitorSettings ?? onOpenSettings
                    )
                    .opacity(isReaderCompact ? 0 : 1)
                    .allowsHitTesting(!isReaderCompact)
                    .accessibilityHidden(isReaderCompact)

                    if isReaderCompact {
                        browseScroll(
                            mode: mode,
                            isActive: isActive,
                            phase: phase,
                            isWideLayout: isWideLayout,
                            isReaderCompact: isReaderCompact,
                            contentWidth: contentWidth,
                            sourceGroups: sourceGroups,
                            managesFollowingPresence: false
                        )
                    }
                }
            } else {
                browseScroll(
                    mode: mode,
                    isActive: isActive,
                    phase: phase,
                    isWideLayout: isWideLayout,
                    isReaderCompact: isReaderCompact,
                    contentWidth: contentWidth,
                    sourceGroups: sourceGroups
                )
            }
        }
        .opacity(isActive ? 1 : 0)
        .allowsHitTesting(isActive)
        .accessibilityHidden(!isActive)
        .zIndex(isActive ? 1 : 0)
    }

    private func browseScroll(
        mode: DashboardBrowseMode,
        isActive: Bool,
        phase: ReaderPresentationPhase,
        isWideLayout: Bool,
        isReaderCompact: Bool,
        contentWidth: CGFloat,
        sourceGroups: [DashboardBrowseGroup],
        managesFollowingPresence: Bool = true
    ) -> some View {
        let anchorID = "browse-top-\(mode.rawValue)"
        return ScrollViewReader { scrollProxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 0) {
                    // A stable top anchor per pane: the reader hand-off resets
                    // the active list and the back-to-top button scrolls this
                    // pane only. No scroll-position binding is kept in the
                    // view, which would invalidate the dashboard on every tick.
                    Color.clear
                        .frame(height: 0)
                        .id(anchorID)

                    browsePaneContent(
                        mode: mode,
                        isActive: isActive,
                        isWideLayout: isWideLayout,
                        isReaderCompact: isReaderCompact,
                        contentWidth: contentWidth,
                        sourceGroups: sourceGroups,
                        managesFollowingPresence: managesFollowingPresence
                    )
                }
            }
            .onChange(of: phase) { _, newPhase in
                // The list narrows and gains the compact 02 block when the
                // reader opens; a preserved offset would point past the
                // reflowed content. Only the pane the reader was opened from
                // gives up its offset — the other panes keep theirs.
                guard newPhase == .presented, isActive else { return }
                Task { @MainActor in
                    scrollProxy.scrollTo(anchorID, anchor: .top)
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y > max(120, geometry.containerSize.height * 0.9)
            } action: { _, isPastTop in
                // Fires only when the threshold flips, so scrolling never
                // re-evaluates the dashboard body on every tick.
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    if isPastTop {
                        scrolledPanes.insert(mode)
                    } else {
                        scrolledPanes.remove(mode)
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isActive, scrolledPanes.contains(mode) {
                    BrowseBackToTopButton {
                        if reduceMotion {
                            scrollProxy.scrollTo(anchorID, anchor: .top)
                        } else {
                            withAnimation(.easeOut(duration: 0.26)) {
                                scrollProxy.scrollTo(anchorID, anchor: .top)
                            }
                        }
                    }
                    .padding(.trailing, 18)
                    // Step over the undo capsule that shares this corner.
                    .padding(.bottom, actionToasts.toast == nil ? 18 : 64)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
        }
    }

    @ViewBuilder
    private func browsePaneContent(
        mode: DashboardBrowseMode,
        isActive: Bool,
        isWideLayout: Bool,
        isReaderCompact: Bool,
        contentWidth: CGFloat,
        sourceGroups: [DashboardBrowseGroup],
        managesFollowingPresence: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if mode == .following {
                WeiboFollowingFeedView(
                    monitor: weiboMonitor,
                    filter: $followingFilter,
                    searchText: $followingSearch,
                    mode: $browseMode,
                    accountUID: $followingAccountUID,
                    followingUnread: weiboMonitor?.snapshot.unreadCount ?? 0,
                    badgeEnabled: settings.weiboMonitorDashboardBadgeEnabled,
                    showsModeControl: false,
                    availableWidth: contentWidth,
                    isActive: isActive,
                    managesPresence: managesFollowingPresence,
                    onOpenSettings: onOpenWeiboMonitorSettings ?? onOpenSettings
                )
            } else {
                DashboardDateline()

                DashboardFilterBar(
                    searchText: $searchText,
                    sourceFilter: $sourceFilter,
                    groups: sourceGroups,
                    forYou: mode == .forYou,
                    debouncedQuery: normalizedSearchQuery,
                    availableWidth: contentWidth,
                    weiboCount: orchestrator.weiboItems.count,
                    bilibiliCount: orchestrator.bilibiliItems.count,
                    rssCount: rssItemCount
                )

                contentLayout(
                    mode: mode,
                    groups: sourceGroups,
                    isWideLayout: isWideLayout,
                    isReaderCompact: isReaderCompact,
                    availableWidth: contentWidth
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func clearTextFocus() {
        guard let window = NSApp.keyWindow, let responder = window.firstResponder else { return }
        // The field editor is an NSTextView; leaving it first responder keeps
        // keystrokes going to a pane that is no longer visible.
        if responder is NSTextView {
            window.makeFirstResponder(nil)
        }
    }

    private func openInterestSettings() {
        NotificationCenter.default.post(name: .interestSettingsRequested, object: nil)
    }

    private func recommendationsView(width: CGFloat) -> some View {
        // Normalize once per render instead of once per item inside the
        // feed's predicate (`folding` per item was repeated for every pass).
        let query = normalizedSearchQuery
        return RecommendationFeedView(
            matches: { sourceFilter.matches($0.source) && DashboardSearch.matches($0, query: query) },
            width: width,
            hasFilter: hasAnyFilter,
            onOpenSettings: openInterestSettings,
            onResetFilters: { searchText = ""; sourceFilter = .all },
            onRefresh: { Task { await orchestrator.manualRefresh(settings: settings) } },
            onShowSources: { browseMode = .bySource },
            isRefreshing: orchestrator.isRefreshing,
            lastRefreshAt: orchestrator.lastFeedRefreshAt
        )
    }

    private var followingSidebarEntries: [FollowingPostEntry] {
        guard let monitor = weiboMonitor else { return [] }
        return FollowingFeedModel.recentEntries(
            snapshot: monitor.snapshot,
            limit: 5,
            includeCollapsed: !settings.weiboMonitorRelevanceEnabled
        )
    }

    private var followingSidebarHasAccounts: Bool {
        !(weiboMonitor?.snapshot.users.isEmpty ?? true)
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

    /// Built-in trend counters for the recommendation sidebar. Filtering the
    /// sources first keeps the RSS half of the catalog out of a mode that never
    /// renders it.
    private var hotBrowseGroups: [DashboardBrowseGroup] {
        DashboardBrowseCatalog.groups(
            sources: settings.activeSources.filter(\.isBuiltIn),
            weiboItems: orchestrator.weiboItems,
            bilibiliItems: orchestrator.bilibiliItems,
            rssItems: orchestrator.rssItemsMap,
            filter: sourceFilter,
            query: normalizedSearchQuery
        )
    }

    @ViewBuilder
    private func contentLayout(
        mode: DashboardBrowseMode,
        groups: [DashboardBrowseGroup],
        isWideLayout: Bool,
        isReaderCompact: Bool,
        availableWidth: CGFloat
    ) -> some View {
        let feedWidth = max(0, availableWidth - sidebarWidth - DashboardLayoutMetrics.sidebarGap)

        if mode == .forYou {
            if isWideLayout && !isReaderCompact {
                // Only the wide recommendation layout renders the sidebar, and
                // only the sidebar needs the built-in trend counters. Narrow
                // layouts never pay for this catalog build.
                let hotGroups = hotBrowseGroups
                HStack(alignment: .top, spacing: 20) {
                    recommendationsView(width: feedWidth)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    DashboardSidebarRegion(
                        orchestrator: orchestrator,
                        hotGroups: hotGroups,
                        searchQuery: normalizedSearchQuery,
                        followingEntries: followingSidebarEntries,
                        followingUnread: weiboMonitor?.snapshot.unreadCount ?? 0,
                        hasFollowingAccounts: followingSidebarHasAccounts,
                        onConfigureAI: onConfigureAI ?? onOpenSettings,
                        onOpenFollowingPost: { weiboMonitor?.openPost($0) },
                        onShowFollowing: { browseMode = .following }
                    )
                    .frame(width: sidebarWidth, alignment: .leading)
                }
            } else {
                recommendationsView(width: availableWidth)
            }
        } else {
            sourceLayout(
                groups: groups,
                isWideLayout: isWideLayout,
                isReaderCompact: isReaderCompact,
                availableWidth: availableWidth
            )
        }
    }

    /// By-source layout. Every group and counter here comes from the one
    /// catalog build done for this mode; the filter label reads the same array.
    @ViewBuilder
    private func sourceLayout(
        groups: [DashboardBrowseGroup],
        isWideLayout: Bool,
        isReaderCompact: Bool,
        availableWidth: CGFloat
    ) -> some View {
        let hotGroups = groups.filter { $0.source.isBuiltIn }
        let rssGroups = groups.filter { !$0.source.isBuiltIn }
        let matchedHotGroups = hotGroups.filter { $0.matchCount > 0 }
        let hotMatchCount = hotGroups.reduce(0) { $0 + $1.matchCount }
        let feedWidth = max(0, availableWidth - sidebarWidth - DashboardLayoutMetrics.sidebarGap)

        if isReaderCompact {
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
                sourceBrowserRegion(
                    groups: rssGroups,
                    hotMatchCount: hotMatchCount,
                    slotWidth: availableWidth
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if isWideLayout {
            HStack(alignment: .top, spacing: 20) {
                sourceBrowserRegion(
                    groups: rssGroups,
                    hotMatchCount: hotMatchCount,
                    slotWidth: feedWidth,
                    index: DashboardSectionIndex.sourceBrowser(
                        hasHotTrends: !hotGroups.isEmpty,
                        hasFollowing: followingSidebarHasAccounts
                    )
                )
                    .frame(maxWidth: .infinity, alignment: .leading)

                DashboardSidebarRegion(
                    orchestrator: orchestrator,
                    hotGroups: hotGroups,
                    searchQuery: normalizedSearchQuery,
                    followingEntries: followingSidebarEntries,
                    followingUnread: weiboMonitor?.snapshot.unreadCount ?? 0,
                    hasFollowingAccounts: followingSidebarHasAccounts,
                    onConfigureAI: onConfigureAI ?? onOpenSettings,
                    onOpenFollowingPost: { weiboMonitor?.openPost($0) },
                    onShowFollowing: { browseMode = .following }
                )
                .frame(width: sidebarWidth, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 20) {
                DashboardSidebarRegion(
                    orchestrator: orchestrator,
                    hotGroups: hotGroups,
                    searchQuery: normalizedSearchQuery,
                    followingEntries: followingSidebarEntries,
                    followingUnread: weiboMonitor?.snapshot.unreadCount ?? 0,
                    hasFollowingAccounts: followingSidebarHasAccounts,
                    onConfigureAI: onConfigureAI ?? onOpenSettings,
                    onOpenFollowingPost: { weiboMonitor?.openPost($0) },
                    onShowFollowing: { browseMode = .following }
                )
                sourceBrowserRegion(
                    groups: rssGroups,
                    hotMatchCount: hotMatchCount,
                    slotWidth: availableWidth,
                    index: DashboardSectionIndex.sourceBrowser(
                        hasHotTrends: !hotGroups.isEmpty,
                        hasFollowing: followingSidebarHasAccounts
                    )
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sourceBrowserRegion(
        groups: [DashboardBrowseGroup],
        hotMatchCount: Int,
        slotWidth: CGFloat,
        index: String = "03"
    ) -> some View {
        DashboardSourceBrowserRegion(
            orchestrator: orchestrator,
            sourceFilter: sourceFilter,
            groups: groups,
            index: index,
            hotMatchCount: hotMatchCount,
            searchQuery: normalizedSearchQuery,
            hasAnyFilter: hasAnyFilter,
            slotWidth: slotWidth,
            collapsedSourceIDs: collapsedRSSSourceIDs,
            onToggleExpansion: toggleRSSSourceExpansion,
            onRefresh: { source in
                Task { await orchestrator.refreshRSSSource(source, settings: settings) }
            },
            onOpenSettings: onOpenSettings,
            onResetFilters: { searchText = ""; sourceFilter = .all }
        )
    }
}

// MARK: - Pane gating

/// Gates the panes the dashboard keeps alive. The reader already tells the feed
/// when it covers the list; a pane that is merely hidden behind the active tab
/// has to say the same thing, or its cards keep counting as impressions —
/// `onScrollVisibilityChange` is geometric, not visual.
private struct BrowsePaneAccess<Content: View>: View {
    @Environment(\.dashboardListObscured) private var parentObscured
    let isActive: Bool
    private let content: () -> Content

    init(isActive: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.isActive = isActive
        self.content = content
    }

    var body: some View {
        content()
            .environment(
                \.dashboardListObscured,
                DashboardPaneGatingRules.obscuresExposure(
                    parentObscured: parentObscured,
                    isActive: isActive
                )
            )
    }
}

/// Pure rule behind `BrowsePaneAccess`, unit-testable without rendering.
enum DashboardPaneGatingRules {
    static func obscuresExposure(parentObscured: Bool, isActive: Bool) -> Bool {
        parentObscured || !isActive
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

private struct DashboardDateline: View {
    @Environment(AppSettings.self) private var settings

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var language: AppLanguage { settings.appLanguage }

    private var issueNumber: String {
        String(format: "%02d", Calendar.current.component(.day, from: Date()))
    }

    private var issueDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language.bcp47)
        formatter.dateFormat = language == .en ? "EEEE, MMM d, yyyy" : "yyyy年M月d日 EEEE"
        return formatter.string(from: Date())
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("VOL. 06 · NO. \(issueNumber)")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(0.7)

            Rectangle()
                .fill(isRetro ? RetroEditorialTokens.ink : Color(nsColor: .separatorColor))
                .frame(height: isRetro ? 1.2 : 1)

            Text(issueDate)
                .font(.system(size: 10, weight: .bold, design: isRetro ? .serif : .default))

            EditorialTag(text: L10n.string("brand.edition", language: language), fallbackTint: .secondary)
        }
        .foregroundStyle(isRetro ? RetroEditorialTokens.ink : Color.primary)
        .frame(height: 22)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("NewsBar, \(issueDate)")
    }
}

// MARK: - Filter bar

private struct DashboardFilterBar: View {
    @Binding var searchText: String
    @Binding var sourceFilter: DashboardSourceFilter
    /// The catalog already built for this mode. Recommendation mode passes an
    /// empty array — its feed filters its own snapshot.
    let groups: [DashboardBrowseGroup]
    let forYou: Bool
    let debouncedQuery: String?
    let availableWidth: CGFloat
    let weiboCount: Int
    let bilibiliCount: Int
    let rssCount: Int

    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasAnyFilter: Bool {
        isSearchActive || sourceFilter != .all
    }

    /// One count for the chip row. By source, every group was counted while the
    /// catalog was built; recommendation mode reads the feed's own snapshot.
    private var filterCount: Int {
        if forYou {
            return InterestController.shared.recommendations?.items.filter {
                sourceFilter.matches($0.item.source) && DashboardSearch.matches($0.item, query: debouncedQuery)
            }.count ?? 0
        }
        return groups.reduce(0) { $0 + $1.matchCount }
    }

    var body: some View {
        if availableWidth < 620 {
            VStack(alignment: .leading, spacing: 8) {
                searchField
                ScrollView(.horizontal, showsIndicators: false) {
                    chipRow
                }
            }
        } else {
            HStack(spacing: 10) {
                searchField
                    .frame(maxWidth: .infinity)
                chipRow
                    .fixedSize()
            }
        }
    }

    private var searchField: some View {
        DashboardSearchField(
            text: $searchText,
            placeholder: "dash.searchPlaceholder".localized
        )
    }

    private var chipRow: some View {
        HStack(spacing: 6) {
            ForEach(DashboardSourceFilter.allCases) { filter in
                DashboardFilterChip(
                    title: chipTitle(for: filter),
                    isSelected: sourceFilter == filter
                ) {
                    sourceFilter = filter
                }
            }

            if hasAnyFilter {
                DashboardFilterCountText(text: L10n.string("dash.filterCount", filterCount))
            }
        }
    }

    private func chipTitle(for filter: DashboardSourceFilter) -> String {
        switch filter {
        case .all: return filter.displayName
        case .weibo: return "\(filter.displayName) \(weiboCount)"
        case .bilibili: return "\(filter.displayName) \(bilibiliCount)"
        case .rss: return "\(filter.displayName) \(rssCount)"
        }
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
    let followingEntries: [FollowingPostEntry]
    let followingUnread: Int
    let hasFollowingAccounts: Bool
    let onConfigureAI: () -> Void
    let onOpenFollowingPost: (WeiboPost) -> Void
    let onShowFollowing: () -> Void

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
            // leave an orphan "02" block with no cards above the following
            // section.
            if !hotGroups.isEmpty {
                EditorialSectionHeading(
                    index: "02",
                    title: L10n.string("dash.hotTrends.title"),
                    subtitle: L10n.string("dash.hotTrends.subtitle")
                )

                DashboardIntegratedHotTrendCard(
                    weiboItems: items(for: .weibo),
                    bilibiliItems: items(for: .bilibili)
                )
            }

            if hasFollowingAccounts {
                EditorialSectionHeading(
                    index: hotGroups.isEmpty ? "02" : "03",
                    title: L10n.string("dash.followingRecent.title"),
                    subtitle: L10n.string("dash.followingRecent.subtitle")
                )

                FollowingRecentMessagesCard(
                    entries: followingEntries,
                    unreadCount: followingUnread,
                    onOpen: onOpenFollowingPost,
                    onShowMore: onShowFollowing
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


private struct DashboardSourceBrowserRegion: View {
    @Environment(AppSettings.self) private var settings
    let orchestrator: NewsOrchestrator
    let sourceFilter: DashboardSourceFilter
    let groups: [DashboardBrowseGroup]
    let index: String
    let hotMatchCount: Int
    let searchQuery: String?
    let hasAnyFilter: Bool
    /// Content width of this region; the RSS source cards inset it by 14 pt
    /// per side before laying out their cards.
    let slotWidth: CGFloat
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
                index: index,
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
                            onToggleExpansion: { onToggleExpansion(group.source) },
                            layoutWidth: slotWidth
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

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isExpanded)
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
        // This disclosure sits above the RSS waterfall. Animating its height
        // re-lays out the entire scroll content on every frame, turning a
        // five-row expansion into a multi-second freeze. Keep the disclosure
        // instant; only the chevron above is animated.
        if expandedSourceIDs.contains(source.id) {
            expandedSourceIDs.remove(source.id)
        } else {
            expandedSourceIDs.insert(source.id)
        }
    }
}

/// Section numbers shared by the sidebar and the source browser. The sidebar
/// renders 01 (briefing) and optionally 02 (hot trends) and following; the
/// source browser is always the last numbered section.
enum DashboardSectionIndex {
    static func sourceBrowser(hasHotTrends: Bool, hasFollowing: Bool) -> String {
        String(format: "%02d", 2 + (hasHotTrends ? 1 : 0) + (hasFollowing ? 1 : 0))
    }
}
