import SwiftUI

struct DashboardWindow: View {
    @Environment(AppSettings.self) private var settings
    @ObservedObject var orchestrator: NewsOrchestrator
    @State private var collapsedRSSSourceIDs: Set<NewsSource.ID> = []

    var onOpenSettings: () -> Void = {}
    var onConfigureAI: (() -> Void)? = nil

    private let layoutBreakpoint: CGFloat = 960
    private let sidebarWidth: CGFloat = 336

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
                        Text("RSS 批量刷新中")
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
        .background(.thinMaterial)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator.opacity(0.25), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    contentLayout(isWideLayout: isWideLayout)
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
                    Button {
                        Task { await orchestrator.manualRefresh(settings: settings) }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(orchestrator.isRefreshing)

                    Button(action: onOpenSettings) {
                        Label("设置", systemImage: "gearshape")
                    }
                }
            }
            .background(.regularMaterial)
            .adaptiveColorScheme()
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
        VStack(spacing: 1) {
            Text("NewsBar Dashboard")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 240)

            Text("趋势 · RSS · AI")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: 240)
    }

    private var rssMainRegion: some View {
        VStack(alignment: .leading, spacing: 16) {
            regionHeader

            if selectedRSSSources.isEmpty {
                emptyRSSState
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(selectedRSSSources) { source in
                        DashboardRSSSourceCard(
                            source: source,
                            items: orchestrator.rssItemsMap[source.id] ?? [],
                            state: orchestrator.sourceStates[source.id] ?? .idle,
                            isExpanded: isRSSSourceExpanded(source),
                            onToggleExpansion: { toggleRSSSourceExpansion(source) }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var regionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("RSS 主区")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(selectedRSSSources.isEmpty
                     ? "尚未启用 RSS 源"
                     : "\(selectedRSSSources.count) 个已启用源 · \(totalRSSItemCount) 条内容")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            Text("按来源分卡")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.5))
                .clipShape(Capsule())
                .accessibilityHidden(true)
        }
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
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.separator.opacity(0.35), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var sidebarRegion: some View {
        VStack(alignment: .leading, spacing: 16) {
            DashboardAIBriefingPanel(
                orchestrator: orchestrator,
                onConfigureAI: onConfigureAI ?? onOpenSettings
            )

            DashboardHotTrendCard(source: .weibo, items: orchestrator.weiboItems)

            DashboardHotTrendCard(source: .bilibili, items: orchestrator.bilibiliItems)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
