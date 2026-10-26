import SwiftUI
import AppKit

/// One horizontal rhythm for the whole popover. Cards, banners, headings,
/// dividers and the bottom bar all share the same outer gutter.
enum PopoverLayout {
    static let horizontalInset: CGFloat = 12
    static let sectionTopSpacing: CGFloat = 12
    static let sectionBottomSpacing: CGFloat = 8
}

struct PopoverContent: View {
    @Environment(AppSettings.self) private var settings
    let orchestrator: NewsOrchestrator
    @ObservedObject var updateChecker: UpdateChecker

    var onOpenSettings: () -> Void
    var onOpenDashboard: () -> Void
    var onConfigureKey: (() -> Void)?

    @State private var expandedRSSSourceIDs: Set<String> = []
    @State private var rssLoadedCounts: [String: Int] = [:]
    @State private var showQuitConfirmation = false

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    private static let issueDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            headerView

            PopoverFeedList(
                orchestrator: orchestrator,
                expandedRSSSourceIDs: $expandedRSSSourceIDs,
                rssLoadedCounts: $rssLoadedCounts,
                onConfigureKey: onConfigureKey
            )

            if !expandedRSSSourceIDs.isEmpty {
                PopoverCollapseBar(
                    expandedRSSSourceIDs: $expandedRSSSourceIDs,
                    rssLoadedCounts: $rssLoadedCounts
                )
            }

            PopoverBottomBar(
                orchestrator: orchestrator,
                onRefresh: {
                    Task {
                        await orchestrator.manualRefresh(settings: settings)
                    }
                },
                onOpenSettings: onOpenSettings,
                onOpenDashboard: onOpenDashboard
            )
        }
        .frame(width: 400)
        .adaptiveColorScheme()
        .appThemeSurface()
        .task {
            await orchestrator.loadCached(settings: settings)
        }
    }

    private var headerView: some View {
        publicationHeaderView
        .confirmationDialog("popover.quit.title".localized, isPresented: $showQuitConfirmation) {
            Button("popover.quit.confirm".localized, role: .destructive) {
                NSApplication.shared.terminate(nil)
            }
            Button("popover.quit.cancel".localized, role: .cancel) { }
        } message: {
            Text("popover.quit.message".localized)
        }
    }

    private var publicationHeaderView: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                EditorialSymbolBadge(
                    symbol: "newspaper.fill",
                    fallbackTint: .secondary,
                    size: 34,
                    rotation: -2
                )

                VStack(alignment: .leading, spacing: -2) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("NEWS")
                            .font(.system(size: 22, weight: .black, design: isRetro ? .serif : .default))
                        Text("BAR")
                            .font(.system(size: 22, weight: .black, design: isRetro ? .serif : .default))
                            .foregroundStyle(isRetro ? RetroEditorialTokens.brick : .accentColor)
                    }

                    Text("THE DAILY SIGNAL")
                        .font(.system(size: 8, weight: .bold, design: isRetro ? .monospaced : .default))
                        .tracking(isRetro ? 1.5 : 0.4)
                        .foregroundStyle(isRetro ? RetroEditorialTokens.fadedInk : .secondary)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 4) {
                    EditorialTag(text: issueNumber, fallbackTint: .secondary, filled: true)
                    UpdateBadge(checker: updateChecker)
                }

                Button {
                    showQuitConfirmation = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .black))
                }
                .buttonStyle(EditorialActionButtonStyle(tone: .destructive, compact: true))
                .help("popover.quit.help".localized)
                .accessibilityLabel("popover.quit.help".localized)
            }
            .padding(.horizontal, PopoverLayout.horizontalInset)
            .padding(.top, 9)
            .padding(.bottom, 7)

            HStack(spacing: 8) {
                Text(issueDate)
                    .font(.system(size: 9, weight: .bold, design: isRetro ? .serif : .default))
                Rectangle()
                    .fill(isRetro ? RetroEditorialTokens.ink : Color(nsColor: .separatorColor))
                    .frame(height: 1)
                Text("popover.issueDate".localized)
                    .font(.system(size: 8, weight: .black, design: isRetro ? .monospaced : .default))
                    .tracking(isRetro ? 0.7 : 0.25)
                    .foregroundStyle(isRetro ? RetroEditorialTokens.brick : .secondary)
            }
            .padding(.horizontal, PopoverLayout.horizontalInset)
            .padding(.bottom, 6)
        }
        .background(isRetro ? AnyShapeStyle(RetroEditorialTokens.raisedPaper) : AnyShapeStyle(.regularMaterial))
        .overlay(alignment: .bottom) {
            VStack(spacing: 2) {
                Rectangle()
                    .fill(isRetro ? RetroEditorialTokens.ink : Color(nsColor: .separatorColor))
                    .frame(height: 1)
                Rectangle()
                    .fill(isRetro ? RetroEditorialTokens.brick : Color.accentColor.opacity(0.65))
                    .frame(height: isRetro ? 3 : 1)
            }
        }
    }

    private var issueNumber: String {
        let day = Calendar.current.component(.day, from: Date())
        return L10n.string("popover.issueNumber", String(format: "%02d", day))
    }

    private var issueDate: String {
        Self.issueDateFormatter.string(from: Date())
    }
}

// MARK: - Feed list

/// Owns every read of the orchestrator's collections so a refresh no longer
/// re-evaluates the popover header, the collapse bar or the bottom bar.
private struct PopoverFeedList: View {
    @Environment(AppSettings.self) private var settings
    let orchestrator: NewsOrchestrator
    @Binding var expandedRSSSourceIDs: Set<String>
    @Binding var rssLoadedCounts: [String: Int]
    let onConfigureKey: (() -> Void)?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                PopoverFailureBanner(orchestrator: orchestrator)
                PopoverWarningBanner(orchestrator: orchestrator)

                PopoverAISummarySection(
                    orchestrator: orchestrator,
                    onConfigureKey: onConfigureKey
                )

                EditorialSectionHeading(
                    index: "01",
                    title: "popover.trending".localized,
                    subtitle: "popover.trending.subtitle".localized
                )
                .padding(.horizontal, PopoverLayout.horizontalInset)
                .padding(.top, PopoverLayout.sectionTopSpacing)
                .padding(.bottom, PopoverLayout.sectionBottomSpacing)

                PopoverHotTrendSection(orchestrator: orchestrator)

                ForEach(settings.activeSources.filter { !$0.isBuiltIn }, id: \.id) { source in
                    PopoverRSSSection(
                        source: source,
                        orchestrator: orchestrator,
                        expandedRSSSourceIDs: $expandedRSSSourceIDs,
                        rssLoadedCounts: $rssLoadedCounts
                    )
                }

                Color.clear.frame(height: 10)
            }
            .padding(.top, 10)
        }
    }
}

private struct PopoverWarningBanner: View {
    let orchestrator: NewsOrchestrator

    var body: some View {
        if let warning = orchestrator.manualRefreshWarning {
            PopoverBanner(
                message: warning,
                symbol: "info.circle.fill",
                tint: .yellow
            )
        }
    }
}

private struct PopoverFailureBanner: View {
    @Environment(AppSettings.self) private var settings
    let orchestrator: NewsOrchestrator

    var body: some View {
        if let message = allSourcesFailureMessage {
            PopoverBanner(
                message: message,
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }
    }

    private var allSourcesFailureMessage: String? {
        let sources = settings.activeSources
        guard !sources.isEmpty else { return nil }

        let allFailed = sources.allSatisfy { source in
            if case .failed = orchestrator.sourceStates[source.id] {
                return true
            }
            return false
        }

        return allFailed ? "popover.allFailed".localized : nil
    }
}

private struct PopoverBanner: View {
    enum Metrics {
        static let horizontalPadding: CGFloat = 10
        static let verticalPadding: CGFloat = 5
        static let bottomSpacing: CGFloat = 4
        static let compactTextSize: CGFloat = 10
    }

    let message: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: Metrics.compactTextSize))
            Text(message)
                .font(.system(size: Metrics.compactTextSize))
            Spacer()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .background(tint.opacity(0.1))
        .editorialClipShape(cornerRadius: 6)
        .padding(.horizontal, PopoverLayout.horizontalInset)
        .padding(.bottom, Metrics.bottomSpacing)
    }
}

private struct PopoverHotTrendSection: View {
    let orchestrator: NewsOrchestrator

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            NewsSection(
                title: "popover.weibo".localized,
                sourceMark: .weibo,
                color: .orange,
                items: orchestrator.weiboItems,
                showRank: true,
                state: orchestrator.sourceStates[NewsSource.weibo.id] ?? .idle,
                maxVisible: 5,
                presentation: .compactTrend
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            NewsSection(
                title: "popover.bilibili".localized,
                sourceMark: .bilibili,
                color: .pink,
                items: orchestrator.bilibiliItems,
                showRank: true,
                state: orchestrator.sourceStates[NewsSource.bilibili.id] ?? .idle,
                maxVisible: 3,
                presentation: .compactTrend
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PopoverLayout.horizontalInset)
    }
}

private struct PopoverRSSSection: View {
    @Environment(AppSettings.self) private var settings
    let source: NewsSource
    let orchestrator: NewsOrchestrator
    @Binding var expandedRSSSourceIDs: Set<String>
    @Binding var rssLoadedCounts: [String: Int]

    private var rssConfig: RSSSourceConfig? {
        settings.rssSources.first { $0.id == source.id }
    }

    private var displayMode: RSSSourceConfig.DisplayMode {
        rssConfig?.displayMode ?? .text
    }

    private var counts: (text: Int, image: Int) {
        if let rssConfig {
            return (
                settings.effectiveTextDisplayCount(for: rssConfig),
                settings.effectiveImageDisplayCount(for: rssConfig)
            )
        }
        return (settings.rssDefaultTextCount, settings.rssDefaultImageCount)
    }

    private var sourceItems: [NewsItem] {
        orchestrator.rssItemsMap[source.id] ?? []
    }

    private var pageSize: Int {
        let hasAnyImage = sourceItems.contains { $0.imageURL != nil }
        return displayMode == .image
            ? (hasAnyImage ? counts.image : counts.text)
            : counts.text
    }

    var body: some View {
        EditorialSectionHeading(
            index: "02",
            title: source.displayName,
            subtitle: "popover.rss.subtitle".localized
        )
        .padding(.horizontal, PopoverLayout.horizontalInset)
        .padding(.top, PopoverLayout.sectionTopSpacing)
        .padding(.bottom, PopoverLayout.sectionBottomSpacing)

        RSSWaterfallView(
            items: sourceItems,
            sourceName: source.displayName,
            state: orchestrator.sourceStates[source.id] ?? .idle,
            displayMode: displayMode,
            textCount: counts.text,
            imageCount: counts.image,
            isExpanded: expandedRSSSourceIDs.contains(source.id),
            loadedCount: rssLoadedCounts[source.id, default: pageSize],
            onToggleExpand: {
                if expandedRSSSourceIDs.contains(source.id) {
                    expandedRSSSourceIDs.remove(source.id)
                    rssLoadedCounts.removeValue(forKey: source.id)
                } else {
                    expandedRSSSourceIDs.insert(source.id)
                    rssLoadedCounts[source.id] = pageSize
                }
            },
            onLoadMore: {
                let current = rssLoadedCounts[source.id, default: pageSize]
                let total = sourceItems.count
                guard current < total else { return }
                rssLoadedCounts[source.id] = min(current + pageSize, total)
            }
        )
        .padding(.horizontal, PopoverLayout.horizontalInset)
    }
}

private struct PopoverCollapseBar: View {
    @Environment(AppSettings.self) private var settings
    @Binding var expandedRSSSourceIDs: Set<String>
    @Binding var rssLoadedCounts: [String: Int]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(settings.rssSources.filter { expandedRSSSourceIDs.contains($0.id) }) { rss in
                Button {
                    expandedRSSSourceIDs.remove(rss.id)
                    rssLoadedCounts.removeValue(forKey: rss.id)
                } label: {
                    Label(L10n.string("popover.collapse", rss.name), systemImage: "chevron.up")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, PopoverLayout.horizontalInset)
        .padding(.vertical, 4)
        .editorialMasthead()
    }
}

private struct PopoverBottomBar: View {
    let orchestrator: NewsOrchestrator
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void
    let onOpenDashboard: () -> Void

    var body: some View {
        BottomBar(
            isRefreshing: orchestrator.isRefreshing,
            batchProgress: orchestrator.batchProgress,
            onRefresh: onRefresh,
            onOpenSettings: onOpenSettings,
            onOpenDashboard: onOpenDashboard
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.55))
                .frame(height: 1)
                .allowsHitTesting(false)
        }
    }
}

private struct PopoverAISummarySection: View {
    @Environment(AppSettings.self) private var settings
    let orchestrator: NewsOrchestrator
    let onConfigureKey: (() -> Void)?
    @State private var isExpanded = true

    var body: some View {
        if settings.aiSummaryEnabled, orchestrator.aiSummaryState != .idle {
            AISummaryCard(
                state: orchestrator.aiSummaryState,
                isExpanded: $isExpanded,
                allItems: orchestrator.aiSummaryItems,
                parsedSummary: orchestrator.aiParsedSummary,
                maxSectionsPerCategory: 2,
                isRegenerating: orchestrator.aiSummaryState == .fetching || orchestrator.aiSummaryState == .summarizing,
                onRegenerate: {
                    Task {
                        await orchestrator.regenerateAISummary(settings: settings)
                    }
                },
                onConfigureKey: onConfigureKey,
                contextID: orchestrator.aiSummaryManifest?.id.uuidString
            )
            .padding(.horizontal, PopoverLayout.horizontalInset)
            .padding(.bottom, 6)
        }
    }
}
