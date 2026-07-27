import SwiftUI
import AppKit

struct PopoverContent: View {
    @Environment(AppSettings.self) private var settings
    @ObservedObject var orchestrator: NewsOrchestrator
    @ObservedObject var updateChecker: UpdateChecker

    var onOpenSettings: () -> Void
    var onOpenDashboard: () -> Void
    var onConfigureKey: (() -> Void)?

    @State private var aiSummaryExpanded = true
    @State private var expandedRSSSourceIDs: Set<String> = []
    @State private var rssLoadedCounts: [String: Int] = [:]

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

    var body: some View {
        VStack(spacing: 0) {
            headerView

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    if let error = allSourcesFailureMessage {
                        errorBanner(error)
                    }

                    if let warning = orchestrator.manualRefreshWarning {
                        warningBanner(warning)
                    }

                    if settings.aiSummaryEnabled, orchestrator.aiSummaryState != .idle {
                        AISummaryCard(
                            state: orchestrator.aiSummaryState,
                            isExpanded: $aiSummaryExpanded,
                            allItems: orchestrator.aiSummaryItems,
                            onRegenerate: {
                                Task {
                                    await orchestrator.regenerateAISummary(settings: settings)
                                }
                            },
                            onConfigureKey: onConfigureKey
                        )
                        Divider().padding(.horizontal, Metrics.sectionDividerInset)
                    }

                    HStack(alignment: .top, spacing: 8) {
                        NewsSection(
                            title: "微博热搜",
                            icon: "flame.fill",
                            color: .orange,
                            items: orchestrator.weiboItems,
                            showRank: true,
                            state: orchestrator.sourceStates[NewsSource.weibo.id] ?? .idle,
                            maxVisible: 5,
                            presentation: .compactTrend
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)

                        NewsSection(
                            title: "B站热搜",
                            icon: "play.rectangle.fill",
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

                    ForEach(settings.activeSources.filter { !$0.isBuiltIn }, id: \.id) { source in
                        Divider().padding(.horizontal, Metrics.sectionDividerInset)

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
                                Label("\(rss.name) · 收起", systemImage: "chevron.up")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial)
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
        .background(.regularMaterial)
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

        return allFailed ? "所有新闻源更新失败，请稍后重试" : nil
    }

    private var headerView: some View {
        HStack {
            Image(systemName: "newspaper.fill")
                .font(.system(size: Metrics.headerIconSize, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("NewsBar")
                .font(.system(size: Metrics.headerTextSize, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            UpdateBadge(checker: updateChecker)
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("退出 NewsBar")
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
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
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, Metrics.sectionDividerInset)
        .padding(.bottom, Metrics.bannerBottomSpacing)
    }
}
