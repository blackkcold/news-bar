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
    @ObservedObject var updater: SparkleUpdater

    var onOpenSettings: () -> Void
    var onOpenDashboard: () -> Void
    var onOpenRSSSettings: () -> Void = {}
    var onOpenResearchCenter: () -> Void = {}
    var onConfigureKey: (() -> Void)?
    var weiboMonitor: WeiboMonitorViewModel? = nil

    @State private var expandedRSSSourceIDs: Set<String> = []
    @State private var rssLoadedCounts: [String: Int] = [:]
    @State private var showQuitConfirmation = false

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            PopoverFeedList(
                orchestrator: orchestrator,
                expandedRSSSourceIDs: $expandedRSSSourceIDs,
                rssLoadedCounts: $rssLoadedCounts,
                onConfigureKey: onConfigureKey,
                onOpenResearchCenter: onOpenResearchCenter,
                weiboMonitor: weiboMonitor,
                onOpenDashboard: onOpenDashboard,
                onOpenRSSSettings: onOpenRSSSettings
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
        // `.localized` reads a process-wide language; changing it must rebuild
        // the surface so every label refreshes immediately.
        .id(settings.appLanguage)
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
            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("NEWS")
                    Text("BAR")
                        .foregroundStyle(isRetro ? RetroEditorialTokens.brick : .accentColor)
                }
                .font(.system(size: 15, weight: .black, design: isRetro ? .serif : .default))
                .tracking(isRetro ? 0.4 : -0.5)

                Text(shortIssueDate)
                    .font(.system(size: 8.5, weight: .medium, design: isRetro ? .serif : .default))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                UpdateBadge(updater: updater)

                Button {
                    showQuitConfirmation = true
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("popover.quit.help".localized)
                .accessibilityLabel("popover.quit.help".localized)
            }
            .padding(.horizontal, PopoverLayout.horizontalInset)
            .padding(.top, 7)
            .padding(.bottom, 6)

            VStack(spacing: 2) {
                Rectangle()
                    .fill(isRetro ? RetroEditorialTokens.ink : Color(nsColor: .separatorColor))
                    .frame(height: 1)
                Rectangle()
                    .fill(isRetro ? RetroEditorialTokens.brick : Color.accentColor.opacity(0.65))
                    .frame(height: isRetro ? 3 : 1)
            }
        }
        .background {
            if isRetro {
                RetroEditorialTokens.raisedPaper
            }
        }
    }

    private var shortIssueDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: settings.appLanguage.bcp47)
        formatter.dateFormat = settings.appLanguage == .en ? "EEE, MMM d" : "M月d日 EEE"
        return formatter.string(from: Date())
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
    let onOpenResearchCenter: () -> Void
    let weiboMonitor: WeiboMonitorViewModel?
    let onOpenDashboard: () -> Void
    let onOpenRSSSettings: () -> Void

    private var showsResearchChip: Bool {
        settings.researchShowPopoverChip && orchestrator.researchSummary.burstCount > 0
    }

    private var showsFollowChip: Bool {
        settings.weiboMonitorShowPopoverChip
            && (weiboMonitor?.snapshot.unreadCount ?? 0) > 0
    }

    private var rssSources: [NewsSource] {
        settings.activeSources.filter { !$0.isBuiltIn }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                PopoverFailureBanner(orchestrator: orchestrator)
                PopoverWarningBanner(orchestrator: orchestrator)

                PopoverAISummarySection(
                    orchestrator: orchestrator,
                    onConfigureKey: onConfigureKey
                )

                if showsResearchChip || showsFollowChip {
                    HStack(spacing: 6) {
                        if showsResearchChip {
                            PopoverResearchChip(
                                summary: orchestrator.researchSummary,
                                onOpen: onOpenResearchCenter,
                                compact: true
                            )
                        }

                        if showsFollowChip, let weiboMonitor {
                            PopoverWeiboFollowChip(
                                unreadCount: weiboMonitor.snapshot.unreadCount,
                                onOpen: {
                                    onOpenDashboard()
                                    NotificationCenter.default.post(
                                        name: .openWeiboFollowFeed,
                                        object: nil
                                    )
                                },
                                compact: true
                            )
                        }
                    }
                    .padding(.horizontal, PopoverLayout.horizontalInset)
                    .padding(.bottom, 6)
                }

                PopoverGroupLabel(title: "popover.trending".localized)
                PopoverHotTrendSection(orchestrator: orchestrator)

                if !rssSources.isEmpty {
                    PopoverGroupLabel(
                        title: "RSS",
                        detail: L10n.string("popover.rss.sourceCount", rssSources.count)
                    )
                }

                if settings.rssSources.isEmpty || settings.selectedRSSSourceIDs.isEmpty {
                    PopoverRSSEmptyCard(onOpenSettings: onOpenRSSSettings)
                }

                ForEach(rssSources, id: \.id) { source in
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

/// Compact group label for the popover. The dashboard keeps the numbered
/// editorial headings; at 400pt the popover only needs a small section cue.
private struct PopoverGroupLabel: View {
    @Environment(AppSettings.self) private var settings

    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(
                    size: 10,
                    weight: .semibold,
                    design: settings.appTheme == .retroEditorial ? .serif : .default
                ))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)

            if let detail {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, PopoverLayout.horizontalInset)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

private struct PopoverRSSEmptyCard: View {
    @Environment(AppSettings.self) private var settings
    let onOpenSettings: () -> Void

    private var hasSources: Bool { !settings.rssSources.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                EditorialSymbolBadge(
                    symbol: "antenna.radiowaves.left.and.right",
                    fallbackTint: .blue,
                    size: 26
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(hasSources ? "popover.rssEmpty.noneSelected.title".localized : "popover.rssEmpty.title".localized)
                        .font(.system(size: 12, weight: .semibold))
                    Text(hasSources ? "popover.rssEmpty.noneSelected.body".localized : "popover.rssEmpty.body".localized)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            Button {
                onOpenSettings()
            } label: {
                Text(hasSources ? "popover.rssEmpty.noneSelected.action".localized : "popover.rssEmpty.action".localized)
            }
            .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
            .controlSize(.small)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.secondary.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .padding(.horizontal, PopoverLayout.horizontalInset)
        .padding(.bottom, PopoverLayout.sectionBottomSpacing)
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
                maxVisible: 5,
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
        if settings.aiSummaryEnabled, displayState != .idle {
            AISummaryCard(
                state: displayState,
                isExpanded: $isExpanded,
                allItems: orchestrator.aiSummaryItems,
                parsedSummary: orchestrator.aiParsedSummary,
                maxSectionsPerCategory: 2,
                isRegenerating: displayState == .fetching
                    || displayState == .summarizing
                    || orchestrator.aiSummaryUpdating,
                onRegenerate: {
                    Task {
                        await orchestrator.regenerateAISummary(settings: settings)
                    }
                },
                onConfigureKey: onConfigureKey,
                contextID: orchestrator.aiSummaryManifest?.id.uuidString,
                generatedAt: orchestrator.aiSummaryGeneratedAt ?? orchestrator.aiSummaryManifest?.asOf,
                updateError: orchestrator.aiSummaryUpdateError
            )
            .padding(.horizontal, PopoverLayout.horizontalInset)
            .padding(.bottom, 6)
        }
    }

    /// The cache can leave a completed result visible while no work is running.
    private var displayState: AISummaryState {
        if orchestrator.aiSummaryState == .idle, let text = orchestrator.aiSummaryText {
            return .done(text)
        }
        return orchestrator.aiSummaryState
    }
}
