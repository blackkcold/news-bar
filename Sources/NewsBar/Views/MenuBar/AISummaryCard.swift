import SwiftUI

struct AISummaryCard: View {
    let state: AISummaryState
    @Binding var isExpanded: Bool
    var allItems: [NewsItem] = []
    var parsedSummary: ParsedSummary?
    var maxSectionsPerCategory: Int?
    var isRegenerating = false
    var regenerationCooldownRemaining: TimeInterval = 0
    var onRegenerate: (() -> Void)?
    var onConfigureKey: (() -> Void)?

    @State private var displayText = ""
    @State private var animationTargetText = ""
    @State private var cachedGroups: [SummarySectionGroup] = []
    @State private var animationTask: Task<Void, Never>?
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

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
        static let revealAnimationDuration: TimeInterval = 0.18
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
        .newsCardSurface(rotation: 0.12)
        .onAppear {
            switch state {
            case .done(let text), .truncated(let text):
                prepareRenderModel(for: text)
                displayText = animationTargetText
            default: break
            }
        }
        .onChange(of: state) { _, newState in
            switch newState {
            case .done(let text), .truncated(let text):
                animationTask?.cancel()
                prepareRenderModel(for: text)
                let target = animationTargetText
                animationTask = Task { await animateText(target) }
            default:
                animationTask?.cancel()
                animationTask = nil
                displayText = ""
                animationTargetText = ""
                cachedGroups = []
            }
        }
        .onDisappear {
            animationTask?.cancel()
            animationTask = nil
        }
    }

    // MARK: - Header

    private var headerButton: some View {
        Button {
            toggleExpansion()
        } label: {
            HStack(alignment: .center, spacing: Metrics.headerSpacing) {
                EditorialSymbolBadge(
                    symbol: "text.bubble.fill",
                    fallbackTint: .purple,
                    size: Metrics.headerIconSize,
                    rotation: 1.5
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("AI 总结")
                            .editorialHeading(size: Metrics.headerTitleSize)
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
            EditorialTag(text: "未配置", fallbackTint: .orange)
        case .fetching:
            EditorialTag(text: "获取中", fallbackTint: .blue)
        case .summarizing:
            EditorialTag(text: "思考中", fallbackTint: .purple)
        case .error:
            EditorialTag(text: "失败", fallbackTint: .red)
        case .done:
            EditorialTag(text: "已完成", fallbackTint: .green)
        case .truncated:
            EditorialTag(text: "不完整", fallbackTint: .orange)
        case .idle:
            EditorialTag(text: "等待", fallbackTint: .secondary)
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
        .overlay(contentShape.stroke(Color(nsColor: .separatorColor).opacity(0.12), lineWidth: 1))
        .compositingGroup()
        .clipShape(contentShape)
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
                .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
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
            let fullyVisible = displayText == animationTargetText
            sectionRenderedView(fullText, visibleText: fullyVisible ? nil : displayText)

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
    private func sectionRenderedView(_ fullText: String, visibleText: String? = nil) -> some View {
        let groups = revealedSectionGroups(cachedGroups, visibleText: visibleText)
        if groups.allSatisfy({ $0.sections.isEmpty }) {
            let fallbackText = visibleText ?? AISummaryParser.stripCitations(fullText)
            Text((try? AttributedString(markdown: fallbackText)) ?? AttributedString(fallbackText))
                .font(.system(size: 11.5))
                .foregroundStyle(.primary)
                .lineSpacing(3)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : .smooth(duration: Metrics.revealAnimationDuration), value: fallbackText)
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
                            visibleContent: section.visibleBody,
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

    private struct SummarySectionGroup {
        let title: String
        let sections: [SummarySection]
    }

    private struct SummarySection {
        let title: String
        let body: String
        let revealCharacters: [Character]
        let visibleBody: String?
        let primaryIndex: Int?
    }

    private func resolvedSectionGroups(for fullText: String) -> [SummarySectionGroup] {
        if let parsedSummary {
            let visibleSummary = AISummaryParser.limited(
                parsedSummary,
                maxSectionsPerCategory: maxSectionsPerCategory
            )
            return [
                SummarySectionGroup(title: "趋势概览", sections: visibleSummary.trendOverview.map(summarySection)),
                SummarySectionGroup(title: "每日精选", sections: visibleSummary.dailyEssentials.map(summarySection))
            ].filter { !$0.sections.isEmpty }
        }

        let sections = AISummaryParser.parseSections(fullText, itemCount: allItems.count)
        return [SummarySectionGroup(title: "", sections: sections.map(summarySection))]
    }

    private func revealedSectionGroups(
        _ groups: [SummarySectionGroup],
        visibleText: String?
    ) -> [SummarySectionGroup] {
        guard let visibleText else { return groups }

        var remainingCharacters = visibleText.count
        return groups.map { group in
            let sections = group.sections.map { section in
                let visibleBody = String(section.revealCharacters.prefix(remainingCharacters))
                remainingCharacters = max(0, remainingCharacters - section.revealCharacters.count)
                return SummarySection(
                    title: section.title,
                    body: section.body,
                    revealCharacters: section.revealCharacters,
                    visibleBody: visibleBody,
                    primaryIndex: section.primaryIndex
                )
            }
            return SummarySectionGroup(title: group.title, sections: sections)
        }
    }

    private func summarySection(_ section: (title: String, body: String, primaryIndex: Int?)) -> SummarySection {
        SummarySection(
            title: section.title,
            body: section.body,
            revealCharacters: Array(renderedBodyText(section.body)),
            visibleBody: nil,
            primaryIndex: section.primaryIndex
        )
    }

    @MainActor
    private func prepareRenderModel(for fullText: String) {
        let groups = resolvedSectionGroups(for: fullText)
        cachedGroups = groups
        if groups.allSatisfy({ $0.sections.isEmpty }) {
            animationTargetText = AISummaryParser.stripMarkdown(fullText)
        } else {
            animationTargetText = groups
                .flatMap(\.sections)
                .flatMap(\.revealCharacters)
                .map(String.init)
                .joined()
        }
    }

    private func renderedBodyText(_ text: String) -> String {
        AISummaryParser.stripMarkdown(text)
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
        let cooldownSeconds = Int(ceil(regenerationCooldownRemaining))
        let isCoolingDown = cooldownSeconds > 0

        return Button {
            guard !isRegenerating, !isCoolingDown else { return }
            action()
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
                Text(regenerateButtonTitle(cooldownSeconds: cooldownSeconds))
                    .font(.system(size: 9.5))
            }
        }
        .buttonStyle(EditorialActionButtonStyle(compact: true))
        .controlSize(.small)
        .disabled(isRegenerating || isCoolingDown)
        .accessibilityLabel(regenerateButtonTitle(cooldownSeconds: cooldownSeconds))
        .accessibilityHint(isCoolingDown ? "请等待冷却结束后再重新生成。" : "重新生成 Popup 与 Dashboard 共用的 AI 总结。")
    }

    private func regenerateButtonTitle(cooldownSeconds: Int) -> String {
        if isRegenerating { return "生成中..." }
        if cooldownSeconds > 0 { return "冷却中 \(cooldownSeconds)秒" }
        return "重新生成"
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
        contentShape.fill(.purple.opacity(0.05))
    }

    private var contentShape: AnyShape {
        isRetro
            ? AnyShape(Rectangle())
            : AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

}

// MARK: - Section Row

struct SectionRow: View {
    let title: String
    let content: String
    var visibleContent: String? = nil
    let matchedItem: NewsItem?

    @State private var isHovered = false
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    private enum Metrics {
        static let revealAnimationDuration: TimeInterval = 0.18
    }

    private var accessibilityLabelText: String {
        let stripped = AISummaryParser.stripCitations(displayContent)
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

    private var displayContent: String {
        visibleContent ?? content
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                Text((try? AttributedString(markdown: displayContent)) ?? AttributedString(displayContent))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : .smooth(duration: Metrics.revealAnimationDuration), value: displayContent)
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

    private var rowShape: AnyShape {
        isRetro
            ? AnyShape(Rectangle())
            : AnyShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var rowBackground: some View {
        rowShape.fill(isHovered ? Color.purple.opacity(0.05) : Color.clear)
    }

    private var rowStroke: some View {
        rowShape.stroke(rowStrokeStyle, lineWidth: 1)
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
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    var body: some View {
        Button {
            URLOpener.open(url)
        } label: {
            HStack(spacing: 3) {
                EditorialSourceBadge(
                    mark: sourceMark,
                    fallbackTint: sourceTint,
                    size: 16
                )
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 7, weight: .bold))
                Text(sourceName)
                    .font(.system(size: 8.5, weight: isRetro ? .black : .medium, design: isRetro ? .serif : .default))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.ultraThinMaterial)
            .editorialClipShape(cornerRadius: 20)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开 \(sourceName) 原文")
        .accessibilityHint("在浏览器中打开")
        .scaleEffect(reduceMotion ? 1.0 : (isBadgeHovered ? 1.08 : 1.0))
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: isBadgeHovered)
        .onHover { isBadgeHovered = $0 }
    }

    private var sourceMark: EditorialSourceMark {
        if sourceName.contains("微博") { return .weibo }
        if sourceName.contains("B站") || sourceName.lowercased().contains("bilibili") { return .bilibili }
        return .rss
    }

    private var sourceTint: Color {
        switch sourceMark {
        case .weibo: return .orange
        case .bilibili: return .pink
        case .rss: return .blue
        }
    }
}
