import SwiftUI

struct DashboardWindow: View {
    @Environment(AppSettings.self) private var settings
    @ObservedObject var orchestrator: NewsOrchestrator

    @State private var expandedRSSSourceIDs: Set<String> = []
    @State private var rssLoadedCounts: [String: Int] = [:]

    var body: some View {
        VStack(spacing: 0) {
            toolbarView

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    if case .done(let summary) = orchestrator.aiSummaryState {
                        if !summary.isEmpty {
                            summaryCard(summary, items: orchestrator.allActiveItems(settings: settings))
                            Divider().padding(.horizontal, 12)
                        }
                    }
                    if case .truncated(let summary) = orchestrator.aiSummaryState {
                        if !summary.isEmpty {
                            summaryCard(summary, items: orchestrator.allActiveItems(settings: settings))
                            Divider().padding(.horizontal, 12)
                        }
                    }
                    if case .fetching = orchestrator.aiSummaryState {
                        statusCard("获取新闻数据...")
                    }
                    if case .summarizing = orchestrator.aiSummaryState {
                        statusCard("AI 思考中...")
                    }

                    NewsSection(
                        title: "微博热搜",
                        icon: "flame.fill",
                        color: .orange,
                        items: orchestrator.weiboItems,
                        showRank: true,
                        state: orchestrator.sourceStates[NewsSource.weibo.id] ?? .idle
                    )

                    Divider().padding(.horizontal, 12)

                    NewsSection(
                        title: "B站热搜",
                        icon: "play.rectangle.fill",
                        color: .pink,
                        items: orchestrator.bilibiliItems,
                        showRank: true,
                        state: orchestrator.sourceStates[NewsSource.bilibili.id] ?? .idle
                    )

                    ForEach(settings.activeSources.filter { !$0.isBuiltIn }, id: \.id) { source in
                        Divider().padding(.horizontal, 12)
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

                    Color.clear.frame(height: 12)
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

            bottomStatusBar
        }
        .frame(minWidth: 360, minHeight: 480)
        .adaptiveColorScheme()
        .background(.regularMaterial)
        .task {
            await orchestrator.loadCached(settings: settings)
        }
    }

    private var toolbarView: some View {
        HStack(spacing: 8) {
            Image(systemName: "newspaper.fill")
                .font(.system(size: 14))
                .foregroundStyle(.blue)
            Text("NewsBar Dashboard")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            Button {
                Task {
                    await orchestrator.manualRefresh(settings: settings)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                    Text("刷新")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(orchestrator.isRefreshing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func summaryCard(_ text: String, items: [NewsItem] = []) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(.purple)
                Text("AI 总结")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 8) {
                let sections = AISummaryParser.parseSections(text, itemCount: items.count)
                if sections.isEmpty {
                    Text((try? AttributedString(markdown: AISummaryParser.stripCitations(text)))
                        ?? AttributedString(AISummaryParser.stripCitations(text)))
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineSpacing(4)
                } else {
                    ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                        SectionRow(
                            title: section.title,
                            content: section.body,
                            matchedItem: section.primaryIndex.flatMap {
                                items.indices.contains($0) ? items[$0] : nil
                            }
                        )
                        if index < sections.count - 1 {
                            Divider().opacity(0.3).padding(.horizontal, 4)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.purple.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
    }

    private func statusCard(_ message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var bottomStatusBar: some View {
        HStack {
            Spacer()

            if orchestrator.isRefreshing {
                HStack(spacing: 4) {
                    ProgressView().scaleEffect(0.5)
                    Text("刷新中...")
                        .font(.system(size: 10))
                }
            }

            if let warning = orchestrator.manualRefreshWarning {
                Text(warning)
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .foregroundStyle(.tertiary)
        .background(.ultraThinMaterial)
    }
}
