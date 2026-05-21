import SwiftUI

struct DashboardWindow: View {
    @Environment(AppSettings.self) private var settings
    @ObservedObject var orchestrator: NewsOrchestrator

    var body: some View {
        VStack(spacing: 0) {
            toolbarView

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    if case .done(let summary) = orchestrator.aiSummaryState {
                        if !summary.isEmpty {
                            summaryCard(summary)
                            Divider().padding(.horizontal, 12)
                        }
                    }
                    if case .truncated(let summary) = orchestrator.aiSummaryState {
                        if !summary.isEmpty {
                            summaryCard(summary)
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
                        showRank: true
                    )

                    Divider().padding(.horizontal, 12)

                    NewsSection(
                        title: "B站热搜",
                        icon: "play.rectangle.fill",
                        color: .pink,
                        items: orchestrator.bilibiliItems,
                        showRank: true
                    )

                    ForEach(settings.activeSources.filter { !$0.isBuiltIn }, id: \.id) { source in
                        Divider().padding(.horizontal, 12)
                        NewsSection(
                            title: source.displayName,
                            icon: "antenna.radiowaves.left.and.right",
                            color: .blue,
                            items: orchestrator.rssItemsMap[source.id] ?? [],
                            showRank: false,
                            maxVisible: 5
                        )
                    }

                    Color.clear.frame(height: 12)
                }
            }

            bottomStatusBar
        }
        .frame(minWidth: 360, minHeight: 480)
        .background(.regularMaterial)
        .task {
            await orchestrator.loadCached()
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

    private func summaryCard(_ text: String) -> some View {
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

            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineSpacing(4)
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
