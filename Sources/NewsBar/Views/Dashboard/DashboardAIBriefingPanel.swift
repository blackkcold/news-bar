import SwiftUI

struct DashboardAIBriefingPanel: View {
    @Environment(AppSettings.self) private var settings
    @ObservedObject var orchestrator: NewsOrchestrator

    var onConfigureAI: () -> Void

    @State private var selectedCategory: DashboardBriefingCategory = .trendOverview

    private var dashboardSummaryState: AISummaryState {
        orchestrator.dashboardSummaryState
    }

    private var dashboardSummaryItems: [NewsItem] {
        orchestrator.dashboardSummaryItems
    }

    private var resolvedSummaryText: String? {
        switch dashboardSummaryState {
        case .done(let text), .truncated(let text):
            return text
        default:
            return nil
        }
    }

    private var parsedSummary: ParsedSummary? {
        guard hasCitationSnapshot else { return nil }

        if let parsed = orchestrator.dashboardParsedSummary {
            return parsed
        }

        guard let text = resolvedSummaryText else { return nil }
        return AISummaryParser.parseDualSummary(
            text,
            itemCount: dashboardSummaryItems.count,
            weiboBilibiliRange: 0..<(orchestrator.weiboItems.count + orchestrator.bilibiliItems.count)
        )
    }

    private var trendSections: [(title: String, body: String, primaryIndex: Int?)] {
        parsedSummary?.trendOverview ?? []
    }

    private var dailySections: [(title: String, body: String, primaryIndex: Int?)] {
        parsedSummary?.dailyEssentials ?? []
    }

    private var selectedSections: [(title: String, body: String, primaryIndex: Int?)] {
        switch selectedCategory {
        case .trendOverview:
            return trendSections
        case .dailyEssentials:
            return dailySections
        }
    }

    private var preferredCategory: DashboardBriefingCategory {
        if !trendSections.isEmpty { return .trendOverview }
        if !dailySections.isEmpty { return .dailyEssentials }
        return .trendOverview
    }

    private var summarySignature: String {
        "\(trendSections.count)-\(dailySections.count)-\(parsedSummary?.isLegacyFallback == true)"
    }

    private var summaryItems: [NewsItem] {
        dashboardSummaryItems
    }

    private var hasCitationSnapshot: Bool {
        !summaryItems.isEmpty
    }

    private var cardStateText: String {
        switch dashboardSummaryState {
        case .idle: return "等待 AI 简报"
        case .noKey: return "未配置 API Key"
        case .fetching: return "正在抓取新闻"
        case .summarizing: return "AI 正在生成简报"
        case .done: return "AI 简报已完成"
        case .truncated: return "AI 简报已完成但内容被截断"
        case .error: return "AI 简报生成失败"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            switch dashboardSummaryState {
            case .idle:
                emptyState(message: cardStateText, systemImage: "sparkles")
            case .noKey:
                emptyState(message: cardStateText, systemImage: "key.fill", actionTitle: "配置 AI Key") {
                    onConfigureAI()
                }
            case .fetching:
                loadingState(message: cardStateText)
            case .summarizing:
                loadingState(message: cardStateText)
            case .error(let message):
                errorState(message: message)
            case .done, .truncated:
                if hasCitationSnapshot, let parsedSummary {
                    briefingContent(parsedSummary: parsedSummary)
                } else if let text = resolvedSummaryText {
                    fallbackSummary(
                        text,
                        note: hasCitationSnapshot
                            ? nil
                            : "当前没有引用快照，源链接需要重新刷新后才能恢复。"
                    )
                } else {
                    emptyState(message: "暂无可展示的 AI 简报", systemImage: "sparkles")
                }
            }
        }
        .padding(16)
        .background(cardBackground)
        .overlay(cardStroke)
        .clipShape(cardShape)
        .accessibilityElement(children: .contain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if selectedSections.isEmpty {
                selectedCategory = preferredCategory
            }
            requestDashboardSummaryIfNeeded()
        }
        .onChange(of: summarySignature) { _, _ in
            if selectedSections.isEmpty {
                selectedCategory = preferredCategory
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.purple.opacity(0.14))

                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.purple)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("AI Briefing")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(cardStateText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(stateTint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(stateTint.opacity(0.12))
                        .clipShape(Capsule())

                    if parsedSummary?.isLegacyFallback == true {
                        Text("兼容格式")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.45))
                            .clipShape(Capsule())
                    }
                }

                Text("趋势概览 / 每日精选 · 有引用显示来源徽章，点击打开原文")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func briefingContent(parsedSummary: ParsedSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("AI Briefing 主题", selection: $selectedCategory) {
                Text("趋势概览 \(trendSections.count)")
                    .tag(DashboardBriefingCategory.trendOverview)
                Text("每日精选 \(dailySections.count)")
                    .tag(DashboardBriefingCategory.dailyEssentials)
            }
            .pickerStyle(.segmented)

            if selectedSections.isEmpty {
                emptyCategoryState
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(selectedSections.enumerated()), id: \.offset) { index, section in
                        SectionRow(
                            title: section.title,
                            content: section.body,
                            matchedItem: section.primaryIndex.flatMap {
                                summaryItems.indices.contains($0) ? summaryItems[$0] : nil
                            }
                        )

                        if index < selectedSections.count - 1 {
                            Divider().opacity(0.3).padding(.horizontal, 4)
                        }
                    }
                }
            }

            if parsedSummary.isLegacyFallback {
                Text("当前摘要使用兼容解析：仍保留引用快照，且可继续切换查看两类内容。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fallbackSummary(_ text: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("摘要内容可用，但尚未解析为双分类结构。")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Text((try? AttributedString(markdown: AISummaryParser.stripCitations(text)))
                ?? AttributedString(AISummaryParser.stripCitations(text)))
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineSpacing(4)

            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadingState(message: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private func errorState(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Button("重新打开设置") {
                onConfigureAI()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func emptyState(message: String, systemImage: String, actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if let actionTitle, let action {
                Button(actionTitle) {
                    action()
                }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var emptyCategoryState: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("当前分类暂无内容")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var stateTint: Color {
        switch dashboardSummaryState {
        case .idle: return .secondary
        case .noKey: return .orange
        case .fetching: return .blue
        case .summarizing: return .purple
        case .done: return .green
        case .truncated: return .orange
        case .error: return .red
        }
    }

    private var dashboardSummaryNeedsGeneration: Bool {
        switch dashboardSummaryState {
        case .idle, .error, .truncated:
            return true
        default:
            return false
        }
    }

    private func requestDashboardSummaryIfNeeded() {
        guard dashboardSummaryNeedsGeneration else { return }
        Task {
            await orchestrator.generateDashboardSummaryIfNeeded(settings: settings)
        }
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    private var cardBackground: some View {
        cardShape.fill(.ultraThinMaterial)
    }

    private var cardStroke: some View {
        cardShape.strokeBorder(.separator.opacity(0.32), lineWidth: 1)
    }
}

private enum DashboardBriefingCategory: String, CaseIterable, Hashable {
    case trendOverview
    case dailyEssentials
}
