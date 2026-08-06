import SwiftUI

struct DashboardWindow: View {
    @Environment(AppSettings.self) private var settings
    let orchestrator: NewsOrchestrator
    @State private var collapsedRSSSourceIDs: Set<NewsSource.ID> = []
    @State private var searchText = ""
    @State private var sourceFilter: DashboardSourceFilter = .all

    var onOpenSettings: () -> Void = {}
    var onConfigureAI: (() -> Void)? = nil

    private let layoutBreakpoint: CGFloat = 960
    private let sidebarWidth: CGFloat = 336

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

    private var hasStatusFeedback: Bool {
        orchestrator.manualRefreshWarning != nil || orchestrator.batchProgress.total > 0
    }

    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func matchesSearch(_ item: NewsItem) -> Bool {
        guard isSearchActive else { return true }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return item.displayTitle.folding(options: [.caseInsensitive], locale: .current)
            .contains(q.folding(options: [.caseInsensitive], locale: .current))
    }

    private func filteredTrendItems(_ source: NewsSource, _ items: [NewsItem]) -> [NewsItem] {
        guard sourceFilter.matches(source) else { return [] }
        return items.filter(matchesSearch)
    }

    private func filteredRSSItems(_ source: NewsSource) -> [NewsItem] {
        guard sourceFilter.matches(source) else { return [] }
        return (orchestrator.rssItemsMap[source.id] ?? []).filter(matchesSearch)
    }

    private var hasAnyFilter: Bool {
        isSearchActive || sourceFilter != .all
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

    private var statusFeedback: some View {
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
    }

    var body: some View {
        GeometryReader { proxy in
            let isWideLayout = proxy.size.width >= layoutBreakpoint

            VStack(spacing: 0) {
                if hasStatusFeedback {
                    statusFeedback
                        .padding(.top, 12)
                }

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 22) {
                        dashboardMasthead

                        dashboardFilterBar

                        contentLayout(isWideLayout: isWideLayout)
                    }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    toolbarTitle
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    DashboardToolbarAction(
                        title: "刷新",
                        symbol: "arrow.clockwise",
                        isDisabled: orchestrator.isRefreshing
                    ) {
                        Task { await orchestrator.manualRefresh(settings: settings) }
                    }

                    DashboardToolbarAction(
                        title: "设置",
                        symbol: "gearshape",
                        action: onOpenSettings
                    )
                }
            }
            .adaptiveColorScheme()
            .appThemeSurface()
            .task {
                await orchestrator.loadCached(settings: settings)
            }
        }
        .frame(minWidth: 960, minHeight: 720)
    }

    @ViewBuilder
    private func contentLayout(isWideLayout: Bool) -> some View {
        if isWideLayout {
            HStack(alignment: .top, spacing: 20) {
                rssMainRegion
                    .frame(maxWidth: .infinity, alignment: .leading)

                sidebarRegion
                    .frame(width: sidebarWidth, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 20) {
                sidebarRegion
                rssMainRegion
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var toolbarTitle: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 10, weight: isRetro ? .black : .semibold))
                Text("DASHBOARD")
                    .font(.system(size: 11, weight: isRetro ? .black : .semibold, design: isRetro ? .monospaced : .default))
                    .tracking(isRetro ? 0.7 : 0)
                Text("趋势 · RSS · AI")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Text("DASHBOARD")
                .font(.system(size: 10, weight: isRetro ? .black : .semibold, design: isRetro ? .monospaced : .default))

            Image(systemName: "rectangle.split.2x1")
                .accessibilityLabel("Dashboard")
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Dashboard")
    }

    private var dashboardFilterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                    Text(filteredResultLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var filteredResultLabel: String {
        var count = 0
        count += filteredTrendItems(.weibo, orchestrator.weiboItems).count
        count += filteredTrendItems(.bilibili, orchestrator.bilibiliItems).count
        for source in selectedRSSSources {
            count += filteredRSSItems(source).count
        }
        return L10n.string("dash.filterCount", count)
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

    private var dashboardMasthead: some View {
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
                EditorialTag(text: "热榜 \(orchestrator.weiboItems.count + orchestrator.bilibiliItems.count)", fallbackTint: .secondary)
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
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial)
            }
        }
        .overlay {
            if isRetro {
                Rectangle().strokeBorder(RetroEditorialTokens.ink, lineWidth: 1.5)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
            }
        }
        .compositingGroup()
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

    private var mastheadInk: Color {
        isRetro ? RetroEditorialTokens.ink : .primary
    }

    private var mastheadAccent: Color {
        isRetro ? RetroEditorialTokens.brick : .accentColor
    }

    private var mastheadSecondary: Color {
        isRetro ? RetroEditorialTokens.fadedInk : .secondary
    }

    private var issueNumber: String {
        String(format: "%02d", Calendar.current.component(.day, from: Date()))
    }

    private var issueDate: String {
        Self.issueDateFormatter.string(from: Date())
    }

    private var rssMainRegion: some View {
        VStack(alignment: .leading, spacing: 16) {
            regionHeader

            if selectedRSSSources.isEmpty {
                emptyRSSState
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(selectedRSSSources) { source in
                        let filteredItems = filteredRSSItems(source)
                        if sourceFilter.matches(source) && (!filteredItems.isEmpty || !hasAnyFilter) {
                            DashboardRSSSourceCard(
                                source: source,
                                items: filteredItems,
                                state: orchestrator.sourceStates[source.id] ?? .idle,
                                isExpanded: isRSSSourceExpanded(source),
                                onRefresh: {
                                    Task {
                                        await orchestrator.refreshRSSSource(source, settings: settings)
                                    }
                                },
                                onToggleExpansion: { toggleRSSSourceExpansion(source) }
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var regionHeader: some View {
        EditorialSectionHeading(
            index: "03",
            title: "RSS 主版",
            subtitle: selectedRSSSources.isEmpty
                ? "尚未启用 RSS 源"
                : "\(selectedRSSSources.count) 个已启用源 · \(totalRSSItemCount) 条内容"
        )
    }

    private var emptyRSSState: some View {
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

    private var sidebarRegion: some View {
        VStack(alignment: .leading, spacing: 16) {
            EditorialSectionHeading(
                index: "01",
                title: "每日简报",
                subtitle: "AI 编辑部整理的重要线索"
            )

            DashboardAIBriefingPanel(
                orchestrator: orchestrator,
                onConfigureAI: onConfigureAI ?? onOpenSettings
            )

            EditorialSectionHeading(
                index: "02",
                title: "实时热榜",
                subtitle: "社交平台正在发生"
            )

            if sourceFilter.matches(.weibo) || !isSearchActive {
                DashboardHotTrendCard(source: .weibo, items: filteredTrendItems(.weibo, orchestrator.weiboItems))
            }
            if sourceFilter.matches(.bilibili) || !isSearchActive {
                DashboardHotTrendCard(source: .bilibili, items: filteredTrendItems(.bilibili, orchestrator.bilibiliItems))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
