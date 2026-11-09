import SwiftUI

/// One floating rail on the reader's trailing edge. Search and overview share
/// the same 360pt column, so opening one never moves the article. The rail
/// owns the only close control and the only Escape shortcut for both tabs.
struct ReaderAuxiliaryRail: View {
    @Bindable var auxiliary: ReaderAuxiliaryModel
    @Bindable var searchModel: AISearchPanelModel
    let quickSearchModel: QuickSearchModel
    let archiveController: AISearchArchiveController
    let activeNewsItems: [NewsItem]
    let readingHistory: [ReaderHistoryEntry]
    let pageContext: PageSummaryPanelContext
    let language: AppLanguage
    let isActiveTab: Bool
    let onOpenResult: (URL) -> Void
    let onOpenSource: (URL) -> Void
    let onConfigureAI: () -> Void
    let onClose: () -> Void
    let onOpenCitation: (PageSummaryCitation) -> Void
    let onSwitchToReaderMode: () -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var overviewFocused: Bool

    private static let railWidth: CGFloat = 360
    private static let headerHeight: CGFloat = 44

    private var english: Bool { language == .en }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                header
                Divider()
                ZStack {
                    searchPane(availableHeight: max(240, proxy.size.height - Self.headerHeight - 25))
                        .opacity(auxiliary.tab == .search ? 1 : 0)
                        .allowsHitTesting(auxiliary.tab == .search)
                        .accessibilityHidden(auxiliary.tab != .search)
                    overviewPane
                        .opacity(auxiliary.tab == .overview ? 1 : 0)
                        .allowsHitTesting(auxiliary.tab == .overview)
                        .accessibilityHidden(auxiliary.tab != .overview)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(
                    reduceMotion ? DashboardMotion.reduced : .easeInOut(duration: 0.12),
                    value: auxiliary.tab
                )
            }
        }
        .frame(width: Self.railWidth)
        .frame(maxHeight: .infinity)
        .floatingPanelSurface(
            RoundedRectangle(cornerRadius: 12, style: .continuous),
            shadowRadius: 18,
            shadowX: -6,
            shadowY: 0
        )
        .background(escapeButton)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("reader.auxiliary.label", language: language))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker(
                L10n.string("reader.auxiliary.label", language: language),
                selection: Binding(
                    get: { auxiliary.tab ?? .search },
                    set: { auxiliary.open($0) }
                )
            ) {
                Text(L10n.string("reader.auxiliary.search", language: language))
                    .tag(ReaderAuxiliaryTab.search)
                Text(L10n.string("reader.auxiliary.overview", language: language))
                    .tag(ReaderAuxiliaryTab.overview)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 196)

            statusDot

            Spacer(minLength: 0)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.string("reader.auxiliary.close", language: language))
            .help(L10n.string("reader.auxiliary.close", language: language))
        }
        .padding(.horizontal, 12)
        .frame(height: Self.headerHeight)
    }

    @ViewBuilder
    private var statusDot: some View {
        if let status = otherTabStatus {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
                .help(status.help)
                .accessibilityLabel(status.help)
        }
    }

    private var otherTabStatus: (color: Color, help: String)? {
        switch auxiliary.tab {
        case .search:
            if auxiliary.isPreparingOverview || auxiliary.phase == .generating {
                return (.accentColor, english ? "The overview is being prepared" : "概览正在准备")
            }
            if case .failed = auxiliary.phase {
                return (.orange, english ? "The overview failed" : "概览生成失败")
            }
            if case .unavailable = auxiliary.phase {
                return (.orange, english ? "No readable page text" : "没有可读页面正文")
            }
        case .overview:
            if searchModel.state.isBusy {
                return (.accentColor, english ? "Search is running" : "搜索正在进行")
            }
            if case .failed = searchModel.state {
                return (.orange, english ? "Search failed" : "搜索失败")
            }
        case nil:
            return nil
        }
        return nil
    }

    private func searchPane(availableHeight: CGFloat) -> some View {
        QuickSearchContent(
            model: quickSearchModel,
            aiModel: searchModel,
            archiveController: archiveController,
            activeNewsItems: activeNewsItems,
            readingHistory: readingHistory,
            settings: settings,
            language: language,
            surface: $auxiliary.searchSurface,
            selectedArchiveEntry: $auxiliary.archiveReplay,
            isActive: isActiveTab && auxiliary.tab == .search,
            fillsAvailableHeight: true,
            availableHeight: availableHeight,
            onOpenResult: onOpenResult,
            onOpenSource: onOpenSource,
            onConfigureAI: onConfigureAI
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var overviewPane: some View {
        PageSummaryPanel(
            context: resolvedContext,
            phase: auxiliary.phase,
            input: auxiliary.overviewInput,
            summary: auxiliary.summary.summary,
            errorMessage: auxiliary.summary.errorMessage,
            providerName: settings.providerDisplayName(forID: settings.aiProvider),
            onGenerate: { auxiliary.generate(settings: settings) },
            onCancelDisclosure: onClose,
            onRetry: {
                if auxiliary.overviewInput == nil {
                    auxiliary.retryPreparation()
                } else {
                    auxiliary.generate(settings: settings)
                }
            },
            onOpenSettings: onConfigureAI,
            onOpenCitation: onOpenCitation,
            onSwitchToReaderMode: onSwitchToReaderMode
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .focusable()
        .focused($overviewFocused)
        .focusEffectDisabled()
        .onAppear {
            if auxiliary.tab == .overview { overviewFocused = true }
        }
        .onChange(of: auxiliary.tab) { _, tab in
            overviewFocused = tab == .overview
        }
    }

    private var resolvedContext: PageSummaryPanelContext {
        guard let context = auxiliary.overviewContext else { return pageContext }
        return PageSummaryPanelContext(
            title: context.title,
            url: context.url,
            isPrivate: context.isPrivate,
            language: context.language
        )
    }

    /// One Escape handler for the whole rail. The archive replay is a layer on
    /// top of the search tab, so it unwinds first. Child panels must not add
    /// their own Escape shortcut while embedded.
    private var escapeButton: some View {
        Button("") {
            if auxiliary.archiveReplay != nil {
                auxiliary.archiveReplay = nil
            } else {
                onClose()
            }
        }
        .keyboardShortcut(.escape, modifiers: [])
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
        .disabled(!isActiveTab)
    }
}
