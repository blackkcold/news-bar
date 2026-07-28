import SwiftUI

struct AISummaryCard: View {
    let state: AISummaryState
    @Binding var isExpanded: Bool
    var allItems: [NewsItem] = []
    var parsedSummary: ParsedSummary?
    var onRegenerate: (() -> Void)?
    var onConfigureKey: (() -> Void)?

    @State private var displayText = ""
    @State private var isRegenerating = false
    @State private var animationTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Metrics {
        static let cardPadding: CGFloat = 10
        static let headerSpacing: CGFloat = 8
        static let headerIconSize: CGFloat = 24
        static let headerIconCornerRadius: CGFloat = 9
        static let headerTitleSize: CGFloat = 13
        static let helperTextSize: CGFloat = 10
        static let contentPadding: CGFloat = 8
        static let rowPadding: CGFloat = 8
        static let badgeFontSize: CGFloat = 9
        static let chevronSize: CGFloat = 8
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerButton

            if isExpanded {
                Divider()
                    .padding(.leading, 32)
                    .padding(.trailing, Metrics.cardPadding)

                contentArea
            }
        }
        .padding(Metrics.cardPadding)
        .background(cardBackground)
        .overlay(cardStroke)
        .clipShape(cardShape)
        .onAppear {
            switch state {
            case .done(let text), .truncated(let text):
                displayText = AISummaryParser.stripMarkdown(text)
            default: break
            }
        }
        .onChange(of: state) { _, newState in
            switch newState {
            case .done(let text), .truncated(let text):
                animationTask?.cancel()
                animationTask = Task { await animateText(AISummaryParser.stripMarkdown(text)) }
            default:
                animationTask?.cancel()
                animationTask = nil
                displayText = ""
            }
        }
    }

    // MARK: - Header

    private var headerButton: some View {
        Button {
            toggleExpansion()
        } label: {
            HStack(alignment: .center, spacing: Metrics.headerSpacing) {
                ZStack {
                    RoundedRectangle(cornerRadius: Metrics.headerIconCornerRadius, style: .continuous)
                        .fill(.purple.opacity(0.14))

                    stateHeaderIcon
                }
                .frame(width: Metrics.headerIconSize, height: Metrics.headerIconSize)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("AI 总结")
                            .font(.system(size: Metrics.headerTitleSize, weight: .semibold))
                            .foregroundStyle(.primary)

                        stateHeaderBadge
                    }

                    Text("趋势概览 / 每日精选 · 有引用显示来源徽章，点击打开原文")
                        .font(.system(size: Metrics.helperTextSize))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.down")
                    .font(.system(size: Metrics.chevronSize, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(isExpanded ? "收起AI总结" : "展开AI总结")
    }

    @ViewBuilder
    private var stateHeaderIcon: some View {
        switch state {
        case .noKey:
            Image(systemName: "key.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange)
        case .fetching, .summarizing:
            ProgressView()
                .scaleEffect(0.58)
                .frame(width: 12, height: 12)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.red)
        case .done, .truncated:
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.purple)
        case .idle:
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var stateHeaderBadge: some View {
        switch state {
        case .noKey:
            Text("未配置")
                .font(.system(size: Metrics.badgeFontSize, weight: .medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.orange.opacity(0.15))
                .clipShape(Capsule())
        case .fetching:
            Text("获取中")
                .font(.system(size: Metrics.badgeFontSize, weight: .medium))
                .foregroundStyle(.blue)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.blue.opacity(0.15))
                .clipShape(Capsule())
        case .summarizing:
            Text("思考中")
                .font(.system(size: Metrics.badgeFontSize, weight: .medium))
                .foregroundStyle(.purple)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.purple.opacity(0.15))
                .clipShape(Capsule())
        case .error:
            Text("失败")
                .font(.system(size: Metrics.badgeFontSize, weight: .medium))
                .foregroundStyle(.red)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.red.opacity(0.15))
                .clipShape(Capsule())
        case .done:
            Text("已完成")
                .font(.system(size: Metrics.badgeFontSize, weight: .medium))
                .foregroundStyle(.green)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.green.opacity(0.15))
                .clipShape(Capsule())
        case .truncated:
            Text("不完整")
                .font(.system(size: Metrics.badgeFontSize, weight: .medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.orange.opacity(0.15))
                .clipShape(Capsule())
        case .idle:
            Text("等待")
                .font(.system(size: Metrics.badgeFontSize, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.45))
                .clipShape(Capsule())
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch state {
            case .noKey:
                noKeyContent
            case .fetching:
                statusContent(message: "获取新闻数据...")
            case .summarizing:
                statusContent(message: "AI 思考中...")
            case .done, .truncated:
                summaryContent
            case .error(let msg):
                errorContent(msg)
            case .idle:
                EmptyView()
            }
        }
        .padding(Metrics.contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(contentBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var noKeyContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API Key 未配置")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
            Text("需要配置 AI API Key 才能使用 AI 总结功能")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if let onConfigureKey {
                Button {
                    onConfigureKey()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 9))
                        Text("配置 Key")
                            .font(.system(size: 10))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
            }
        }
    }

    private func statusContent(message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.64)
                .frame(width: 14, height: 14)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var summaryContent: some View {
        let fullText: String = {
            switch state {
            case .done(let t), .truncated(let t): return t
            default: return ""
            }
        }()

        VStack(alignment: .leading, spacing: 8) {
            if displayText == AISummaryParser.stripMarkdown(fullText) {
                sectionRenderedView(fullText)
            } else {
                Text(displayText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary)
                    .lineSpacing(4)
            }

            if case .truncated = state {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
            Text("摘要可能不完整")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Spacer()
                    if let onRegenerate {
                        regenerateButton(action: onRegenerate)
                    }
                }
            }

            if case .done = state {
                HStack {
                    Spacer()
                    if let onRegenerate {
                        regenerateButton(action: onRegenerate)
                    }
                }
            }
        }
    }

    // MARK: - Section Rendering

    @ViewBuilder
    private func sectionRenderedView(_ fullText: String) -> some View {
        let groups = resolvedSectionGroups(for: fullText)
        if groups.allSatisfy({ $0.sections.isEmpty }) {
            Text((try? AttributedString(markdown: AISummaryParser.stripCitations(fullText)))
                ?? AttributedString(AISummaryParser.stripCitations(fullText)))
                .font(.system(size: 11.5))
                .foregroundStyle(.primary)
                .lineSpacing(3)
        } else {
            ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
                if !group.sections.isEmpty {
                    if !group.title.isEmpty {
                        Text(group.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                    }

                    ForEach(Array(group.sections.enumerated()), id: \.offset) { index, section in
                        SectionRow(
                            title: section.title,
                            content: section.body,
                            matchedItem: section.primaryIndex.flatMap {
                                allItems.indices.contains($0) ? allItems[$0] : nil
                            }
                        )
                        if index < group.sections.count - 1 {
                            Divider().opacity(0.3).padding(.horizontal, 4)
                        }
                    }

                    if groupIndex < groups.count - 1 {
                        Divider().opacity(0.3).padding(.horizontal, 4)
                    }
                }
            }
        }
    }

    private func resolvedSectionGroups(for fullText: String) -> [(title: String, sections: [(title: String, body: String, primaryIndex: Int?)])] {
        if let parsedSummary {
            return [
                ("趋势概览", parsedSummary.trendOverview),
                ("每日精选", parsedSummary.dailyEssentials)
            ].filter { !$0.sections.isEmpty }
        }

        let sections = AISummaryParser.parseSections(fullText, itemCount: allItems.count)
        return [("", sections)]
    }

    private func errorContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let onRegenerate {
                regenerateButton(action: onRegenerate)
            }
        }
    }

    private func regenerateButton(action: @escaping () -> Void) -> some View {
        Button {
            isRegenerating = true
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                isRegenerating = false
            }
        } label: {
            HStack(spacing: 4) {
                if isRegenerating {
                    ProgressView()
                        .scaleEffect(0.56)
                        .frame(width: 11, height: 11)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9))
                }
                Text(isRegenerating ? "生成中..." : "重新生成")
                    .font(.system(size: 9.5))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isRegenerating)
    }

    // MARK: - Animation

    @MainActor
    private func animateText(_ fullText: String) async {
        guard !reduceMotion else {
            displayText = fullText
            return
        }

        let chars: [Character] = Array(fullText)
        guard !chars.isEmpty else { return }
        let chunkSize = 3
        var index = 0
        while index < chars.count {
            index = min(index + chunkSize, chars.count)
            displayText = String(chars.prefix(index))
            guard index < chars.count else { break }
            do {
                try await Task.sleep(nanoseconds: 30_000_000)
            } catch {
                displayText = fullText
                return
            }
        }
        displayText = fullText
    }

    private func toggleExpansion() {
        if reduceMotion {
            isExpanded.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
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

    private var contentBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.purple.opacity(0.05))
    }

}

// MARK: - Section Row

struct SectionRow: View {
    let title: String
    let content: String
    let matchedItem: NewsItem?

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accessibilityLabelText: String {
        let stripped = AISummaryParser.stripCitations(content)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedTitle.isEmpty { return stripped }
        if stripped.isEmpty { return normalizedTitle }
        return "\(normalizedTitle)。\(stripped)"
    }

    private var accessibilityHintText: String {
        if matchedItem != nil {
            return "可使用来源按钮打开原文。"
        }
        return "这是只读摘要内容。"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                Text((try? AttributedString(markdown: content)) ?? AttributedString(content))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabelText)
            .accessibilityValue(matchedItem?.source.displayName ?? "无可用来源")
            .accessibilityHint(accessibilityHintText)

            Spacer(minLength: 4)

            if let item = matchedItem {
                SourceBadge(sourceName: item.source.displayName, url: item.url)
                    .padding(.top, 2)
            }
        }
        .padding(8)
        .background(rowBackground)
        .overlay(rowStroke)
        .clipShape(rowShape)
        .onHover { hovering in
            if reduceMotion {
                isHovered = hovering
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isHovered = hovering
                }
            }
        }
    }

    private var rowShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
    }

    private var rowBackground: some View {
        rowShape.fill(isHovered ? Color.purple.opacity(0.05) : Color.clear)
    }

    private var rowStroke: some View {
        rowShape.strokeBorder(rowStrokeStyle, lineWidth: 1)
    }

    private var rowStrokeStyle: AnyShapeStyle {
        isHovered ? AnyShapeStyle(Color.purple.opacity(0.16)) : AnyShapeStyle(.separator.opacity(0.08))
    }
}

// MARK: - Source Badge

private struct SourceBadge: View {
    let sourceName: String
    let url: String

    @State private var isBadgeHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            URLOpener.open(url)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 7, weight: .bold))
                Text(sourceName)
                    .font(.system(size: 8.5, weight: .medium))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开 \(sourceName) 原文")
        .accessibilityHint("在浏览器中打开")
        .scaleEffect(reduceMotion ? 1.0 : (isBadgeHovered ? 1.08 : 1.0))
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: isBadgeHovered)
        .onHover { isBadgeHovered = $0 }
    }
}
