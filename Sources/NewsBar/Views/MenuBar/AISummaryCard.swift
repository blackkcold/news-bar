import SwiftUI

struct AISummaryCard: View {
    let state: AISummaryState
    @Binding var isExpanded: Bool
    var allItems: [NewsItem] = []
    var onRegenerate: (() -> Void)?
    var onConfigureKey: (() -> Void)?

    @State private var displayText = ""
    @State private var isRegenerating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerButton

            if isExpanded {
                contentArea
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .onAppear {
            switch state {
            case .done(let text), .truncated(let text):
                displayText = stripMarkdown(text)
            default: break
            }
        }
        .onChange(of: state) { _, newState in
            switch newState {
            case .done(let text), .truncated(let text):
                Task { await animateText(stripMarkdown(text)) }
            default:
                displayText = ""
            }
        }
    }

    // MARK: - Header

    private var headerButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                stateHeaderIcon
                Text("AI 总结")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                stateHeaderBadge
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var stateHeaderIcon: some View {
        switch state {
        case .noKey:
            Image(systemName: "key.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
        case .fetching, .summarizing:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
        case .done, .truncated:
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.purple)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var stateHeaderBadge: some View {
        switch state {
        case .noKey:
            Text("未配置")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.orange.opacity(0.15))
                .clipShape(Capsule())
        case .fetching:
            Text("获取中")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.blue)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.blue.opacity(0.15))
                .clipShape(Capsule())
        case .summarizing:
            Text("思考中")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.purple)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.purple.opacity(0.15))
                .clipShape(Capsule())
        case .error:
            Text("失败")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.red)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.red.opacity(0.15))
                .clipShape(Capsule())
        case .truncated:
            Text("不完整")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.orange.opacity(0.15))
                .clipShape(Capsule())
        default:
            EmptyView()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        VStack(alignment: .leading, spacing: 8) {
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
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.purple.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var noKeyContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API Key 未配置")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
            Text("需要配置 AI API Key 才能使用 AI 总结功能")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let onConfigureKey {
                Button {
                    onConfigureKey()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 10))
                        Text("配置 Key")
                            .font(.system(size: 11))
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
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
            Text(message)
                .font(.system(size: 12))
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
            if displayText == stripMarkdown(fullText) {
                sectionRenderedView(fullText)
            } else {
                Text(displayText)
                    .font(.system(size: 12))
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
        let sections = Self.parseSections(fullText, itemCount: allItems.count)
        if sections.isEmpty {
            Text((try? AttributedString(markdown: Self.stripCitations(fullText)))
                ?? AttributedString(Self.stripCitations(fullText)))
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineSpacing(4)
        } else {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                SectionRow(
                    title: section.title,
                    content: section.body,
                    matchedItem: section.primaryIndex.flatMap {
                        allItems.indices.contains($0) ? allItems[$0] : nil
                    }
                )
                if index < sections.count - 1 {
                    Divider().opacity(0.3).padding(.horizontal, 4)
                }
            }
        }
    }

    /// 按 ## 标题拆分 Markdown 文本为多个 section，提取引用编号
    static func parseSections(_ text: String, itemCount: Int)
        -> [(title: String, body: String, primaryIndex: Int?)] {
        let lines = text.components(separatedBy: "\n")
        var sections: [(title: String, body: String, primaryIndex: Int?)] = []
        var currentTitle = ""
        var currentBody = ""
        var currentIndices: [Int] = []

        func flush() {
            let t = currentTitle.trimmingCharacters(in: .whitespaces)
            let b = currentBody.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !b.isEmpty {
                let primary = currentIndices.first
                sections.append((title: t, body: b, primaryIndex: primary))
            }
            currentTitle = ""
            currentBody = ""
            currentIndices = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("【") {
                flush()
                let (title, inline) = extractTemplateTitle(trimmed)
                currentTitle = title
                if !inline.isEmpty {
                    currentBody = inline
                }
            } else if trimmed.hasPrefix("#") {
                flush()
                currentTitle = extractMarkdownTitle(trimmed)
            } else if trimmed.hasPrefix("引用：") {
                currentIndices = Self.parseCitationNumbers(trimmed, itemCount: itemCount)
            } else if !trimmed.isEmpty, !currentTitle.isEmpty {
                let refs = Self.parseCitationNumbers(trimmed, itemCount: itemCount)
                currentIndices.append(contentsOf: refs)
                currentBody += (currentBody.isEmpty ? "" : "\n") + trimmed
            }
        }
        flush()
        return sections
    }

    private static func extractTemplateTitle(_ line: String) -> (title: String, inlineBody: String) {
        guard let start = line.firstIndex(of: "【"),
              let end = line.firstIndex(of: "】"), end > start else {
            return (String(line.dropFirst()), "")
        }
        let title = String(line[line.index(after: start)..<end])
        let after = line.index(after: end)
        let inline = after < line.endIndex ? String(line[after...]).trimmingCharacters(in: .whitespaces) : ""
        return (title, inline)
    }

    private static func extractMarkdownTitle(_ line: String) -> String {
        line.replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func parseCitationNumbers(_ line: String, itemCount: Int) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: "\\[#(\\d+)\\]") else { return [] }
        let range = NSRange(line.startIndex..., in: line)
        return regex.matches(in: line, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: line),
                  let idx = Int(line[r]),
                  idx >= 0, idx < itemCount else { return nil }
            return idx
        }
    }

    static func stripCitations(_ text: String) -> String {
        text.replacingOccurrences(of: "\\[#\\d+\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private func errorContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                Text(message)
                    .font(.system(size: 12))
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
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                Text(isRegenerating ? "生成中..." : "重新生成")
                    .font(.system(size: 10))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isRegenerating)
    }

    // MARK: - Animation

    @MainActor
    private func animateText(_ fullText: String) async {
        let chars: [Character] = Array(fullText)
        guard !chars.isEmpty else { return }
        displayText = String(chars.prefix(1))
        for i in 2...chars.count {
            if Task.isCancelled { return }
            displayText = String(chars.prefix(i))
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    /// 剥离 Markdown 标记，返回纯文本用于逐字动画显示
    private func stripMarkdown(_ text: String) -> String {
        var result = text
        // 去除 **加粗** 标记
        result = result.replacingOccurrences(of: "\\*\\*(.*?)\\*\\*", with: "$1", options: .regularExpression)
        // 去除 *斜体* 标记（注意不要错误匹配 ** 中的单星号）
        result = result.replacingOccurrences(of: "(?<!\\*)\\*(?!\\*)(.*?)(?<!\\*)\\*(?!\\*)", with: "$1", options: .regularExpression)
        // 去除 `代码` 标记
        result = result.replacingOccurrences(of: "`(.*?)`", with: "$1", options: .regularExpression)
        // 去除行首 ## 标题标记
        result = result.replacingOccurrences(of: "(?m)^#{1,6}\\s+", with: "", options: .regularExpression)
        // 去除行首 - 列表标记
        result = result.replacingOccurrences(of: "(?m)^[-*+]\\s+", with: "", options: .regularExpression)
        // 去除行首 > 引用标记
        result = result.replacingOccurrences(of: "(?m)^>\\s+", with: "", options: .regularExpression)
        // 去除引用编号 [#N]
        result = result.replacingOccurrences(of: "\\[#\\d+\\]", with: "", options: .regularExpression)
        // 去除模板标记【标题】
        result = result.replacingOccurrences(of: "【[^】]*】", with: "", options: .regularExpression)
        // 去除引用：行
        result = result.replacingOccurrences(of: "(?m)^引用：.*$\\n?", with: "", options: .regularExpression)
        return result
    }
}

// MARK: - Section Row

struct SectionRow: View {
    let title: String
    let content: String
    let matchedItem: NewsItem?

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary)
                    Text((try? AttributedString(markdown: content)) ?? AttributedString(content))
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineSpacing(4)
                } else {
                    Text((try? AttributedString(markdown: content)) ?? AttributedString(content))
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineSpacing(4)
                }
            }

            Spacer(minLength: 4)

            if isHovered, let item = matchedItem {
                SourceBadge(sourceName: item.source.displayName, url: item.url)
                    .padding(.top, 2)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(8)
        .background(isHovered ? Color.primary.opacity(0.04) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Source Badge

private struct SourceBadge: View {
    let sourceName: String
    let url: String

    @State private var isBadgeHovered = false

    var body: some View {
        Button {
            URLOpener.open(url)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 7, weight: .bold))
                Text(sourceName)
                    .font(.system(size: 9, weight: .medium))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .scaleEffect(isBadgeHovered ? 1.08 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isBadgeHovered)
        .onHover { isBadgeHovered = $0 }
    }
}
