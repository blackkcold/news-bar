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
                            onRegenerate: {
                                Task {
                                    await orchestrator.regenerateAISummary(settings: settings)
                                }
                            },
                            onConfigureKey: onConfigureKey
                        )
                        Divider().padding(.horizontal, 12)
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

                        NewsSection(
                            title: source.displayName,
                            icon: "antenna.radiowaves.left.and.right",
                            color: .blue,
                            items: orchestrator.rssItemsMap[source.id] ?? [],
                            showRank: false,
                            state: orchestrator.sourceStates[source.id] ?? .idle,
                            maxVisible: 5
                        )
                    }

                    Color.clear.frame(height: 8)
                }
            }

            BottomBar(
                isRefreshing: orchestrator.isRefreshing,
                onRefresh: {
                    Task {
                        await orchestrator.manualRefresh(settings: settings)
                    }
                },
                onOpenSettings: onOpenSettings,
                onOpenDashboard: onOpenDashboard
            )
        }
        .frame(width: 360)
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("NewsBar")
                .font(.system(size: 13, weight: .semibold))
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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(message)
                .font(.system(size: 11))
            Spacer()
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func warningBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 10))
            Text(message)
                .font(.system(size: 11))
            Spacer()
        }
        .foregroundStyle(.yellow)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}
