import SwiftUI
import AppKit

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

    private enum Metrics {
        static let horizontalPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 6
        static let sectionDividerInset: CGFloat = 10
        static let bannerHorizontalPadding: CGFloat = 12
        static let bannerVerticalPadding: CGFloat = 5
        static let bannerBottomSpacing: CGFloat = 4
        static let compactTextSize: CGFloat = 10
        static let headerIconSize: CGFloat = 12
        static let headerTextSize: CGFloat = 13
    }

    private static let issueDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            headerView

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    if let error = allSourcesFailureMessage {
                        errorBanner(error)
                    }

                    if let warning = orchestrator.manualRefreshWarning {
                        warningBanner(warning)
                    }

                    PopoverAISummarySection(
                        orchestrator: orchestrator,
                        onConfigureKey: onConfigureKey
                    )

                    EditorialSectionHeading(
                        index: "01",
                        title: "popover.trending".localized,
                        subtitle: "popover.trending.subtitle".localized
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

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
                    .padding(.horizontal, 12)

                    ForEach(settings.activeSources.filter { !$0.isBuiltIn }, id: \.id) { source in
                        EditorialSectionHeading(
                            index: "02",
                            title: source.displayName,
                            subtitle: "popover.rss.subtitle".localized
                        )
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        .padding(.bottom, 8)

                        let rssConfig = settings.rssSources.first { $0.id == source.id }
                        let displayMode = rssConfig?.displayMode ?? .text
                        let counts: (text: Int, image: Int) = {
                            if let rssConfig {
                                return (
                                    settings.effectiveTextDisplayCount(for: rssConfig),
                                    settings.effectiveImageDisplayCount(for: rssConfig)
                                )
                            }
                            return (settings.rssDefaultTextCount, settings.rssDefaultImageCount)
                        }()
                        let textCount = counts.text
                        let imageCount = counts.image
                        let sourceItems = orchestrator.rssItemsMap[source.id] ?? []
                        let hasAnyImage = sourceItems.contains { $0.imageURL != nil }
                        let pageSize = displayMode == .image
                            ? (hasAnyImage ? imageCount : textCount)
                            : textCount

                        RSSWaterfallView(
                            items: sourceItems,
                            sourceName: source.displayName,
                            state: orchestrator.sourceStates[source.id] ?? .idle,
                            displayMode: displayMode,
                            textCount: textCount,
                            imageCount: imageCount,
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
                        .padding(.horizontal, 12)
                    }

                    Color.clear.frame(height: 6)
                }
            }

            if !expandedRSSSourceIDs.isEmpty {
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
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .editorialMasthead()
            }

            BottomBar(
                isRefreshing: orchestrator.isRefreshing,
                batchProgress: orchestrator.batchProgress,
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
            .padding(.horizontal, 12)
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
            .padding(.horizontal, 12)
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

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Metrics.compactTextSize))
            Text(message)
                .font(.system(size: Metrics.compactTextSize))
            Spacer()
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, Metrics.bannerHorizontalPadding)
        .padding(.vertical, Metrics.bannerVerticalPadding)
        .background(.orange.opacity(0.1))
        .editorialClipShape(cornerRadius: 6)
        .padding(.horizontal, Metrics.sectionDividerInset)
        .padding(.bottom, Metrics.bannerBottomSpacing)
    }

    private func warningBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: Metrics.compactTextSize))
            Text(message)
                .font(.system(size: Metrics.compactTextSize))
            Spacer()
        }
        .foregroundStyle(.yellow)
        .padding(.horizontal, Metrics.bannerHorizontalPadding)
        .padding(.vertical, Metrics.bannerVerticalPadding)
        .background(.yellow.opacity(0.1))
        .editorialClipShape(cornerRadius: 6)
        .padding(.horizontal, Metrics.sectionDividerInset)
        .padding(.bottom, Metrics.bannerBottomSpacing)
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
                onConfigureKey: onConfigureKey
            )
            Divider().padding(.horizontal, 10)
        }
    }
}
