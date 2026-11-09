import SwiftUI

/// Where the overview came from: the page open in the reader. Kept separate
/// from `PageSummaryInput` so the rail can show the page identity while the
/// body is still being extracted.
struct PageSummaryPanelContext: Equatable {
    let title: String
    let url: String?
    let isPrivate: Bool
    let language: AppLanguage
}

enum PageSummaryPanelPhase: Equatable {
    case preparing
    case disclosure
    case readyToGenerate
    case generating
    case ready
    case failed(String)
    case unavailable(String)
}

/// Page overview content. The rail owns the width, material, padding and the
/// close control; this view only lays out the overview and its fixed footer.
/// Every state is passed in, so rendering tests can cover all of them without
/// a network request or an API key.
struct PageSummaryPanel: View {
    let context: PageSummaryPanelContext
    let phase: PageSummaryPanelPhase
    let input: PageSummaryInput?
    let summary: PageSummary?
    let errorMessage: String?
    let providerName: String
    var showsCloseButton = false
    var onGenerate: () -> Void = {}
    var onCancelDisclosure: () -> Void = {}
    var onRetry: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onClose: () -> Void = {}
    var onOpenCitation: (PageSummaryCitation) -> Void = { _ in }
    var onSwitchToReaderMode: (() -> Void)? = nil

    private var english: Bool { context.language == .en }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if let input {
                        basisLine(input)
                    }
                    content
                }
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 30, height: 30)
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(english ? "Page overview" : "页面概览")
                    .font(.headline)
                if !context.title.isEmpty {
                    Text(context.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let host = context.url.flatMap(URL.init(string:))?.host {
                    Text(host)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if context.isPrivate {
                Label(english ? "Private" : "隐私阅读", systemImage: "hand.raised.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
            }

            if showsCloseButton {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(english ? "Close" : "关闭")
                .help(english ? "Close" : "关闭")
            }
        }
    }

    private func basisLine(_ input: PageSummaryInput) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: input.scope == .article ? "doc.text" : "list.bullet")
                .font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)
            Text(basisText(input))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
    }

    private func basisText(_ input: PageSummaryInput) -> String {
        if input.scope == .article {
            let characters = input.articleText?.count ?? 0
            let cap = PageSummaryService.maxArticleCharacters
            if characters > cap {
                return english
                    ? "Based on the page open in this reader · first \(cap) characters of \(characters)"
                    : "基于当前阅读器打开的页面正文 · 已截断到 \(cap) 字（原文 \(characters) 字）"
            }
            return english
                ? "Based on the page open in this reader · up to \(cap) characters"
                : "基于当前阅读器打开的页面正文 · 最多 \(cap) 字"
        }
        return english
            ? "Based on \(input.listRows.count) loaded headlines · titles only"
            : "基于当前已加载的 \(input.listRows.count) 条标题 · 仅标题"
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .preparing:
            preparing
        case .unavailable(let message):
            unavailable(message)
        case .disclosure:
            disclosure
        case .readyToGenerate:
            readyToGenerate
        case .generating:
            if let summary {
                VStack(alignment: .leading, spacing: 12) {
                    busyBanner
                    summaryContent(summary)
                }
            } else {
                loading
            }
        case .ready:
            if let summary {
                summaryContent(summary)
            } else {
                loading
            }
        case .failed(let message):
            if let summary {
                VStack(alignment: .leading, spacing: 12) {
                    errorBanner(message)
                    summaryContent(summary)
                }
            } else {
                failureCard(message)
            }
        }
    }

    private var preparing: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text(english ? "Reading this page's text…" : "正在读取当前页面正文…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 170)
    }

    private func unavailable(_ message: String) -> some View {
        stateCard(
            symbol: "doc.text.magnifyingglass",
            message: message,
            detail: english
                ? "Wait for the page to finish loading, or switch to reader mode, then try again."
                : "可以等页面加载完成，或切换到阅读模式后再试。"
        ) {
            HStack(spacing: 10) {
                Button(english ? "Try again" : "重试", action: onRetry)
                    .buttonStyle(.borderedProminent)
                if let onSwitchToReaderMode {
                    Button(english ? "Reader mode" : "切换到阅读模式", action: onSwitchToReaderMode)
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                english ? "This sends page text to your AI provider" : "此操作会把页面正文发送给你的 AI 提供商",
                systemImage: "lock.shield"
            )
            .font(.callout.weight(.semibold))

            Text(english
                ? "The overview reads only the page open in this reader, up to \(PageSummaryService.maxArticleCharacters) characters. The text is sent to \(providerName) for this request; the app does not save the body. The provider's own privacy policy applies."
                : "概览只读取当前阅读器打开的页面，最多 \(PageSummaryService.maxArticleCharacters) 字；本次请求会把正文发送给 \(providerName)。应用不会保存正文，提供商仍受其隐私政策约束。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(english
                ? "Outside private reading, the overview and citation metadata are cached locally for 7 days (max 50 entries). The page body is never saved."
                : "非隐私阅读时，概览与引用元数据会在本地缓存 7 天、最多 50 条；不会保存页面正文。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if context.isPrivate || input?.isPrivate == true {
                Text(english
                    ? "Private reading is on: this overview stays in this session and is not cached."
                    : "隐私阅读已开启：概览只保留在本次会话，不会写入缓存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(english ? "Generate overview" : "生成概览", action: onGenerate)
                    .buttonStyle(.borderedProminent)
                Button(english ? "Cancel" : "取消", action: onCancelDisclosure)
                    .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.8)
        }
    }

    private var readyToGenerate: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(english
                    ? "Sends this page's text to \(providerName), up to \(PageSummaryService.maxArticleCharacters) characters."
                    : "会把当前页正文发送给 \(providerName)，最多 \(PageSummaryService.maxArticleCharacters) 字。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(english ? "Generate overview" : "生成概览", action: onGenerate)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text(english ? "Reading this page and writing an overview…" : "正在阅读当前页面并生成概览…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    private var busyBanner: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.mini)
            Text(english ? "Updating the overview…" : "正在更新概览…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(
            english ? "Generation failed; showing the previous overview. \(message)" : "生成失败，正在显示上次结果。\(message)",
            systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func failureCard(_ message: String) -> some View {
        stateCard(
            symbol: "exclamationmark.triangle.fill",
            message: message,
            detail: english
                ? "The page is still open; you can retry without losing your place."
                : "页面仍保持打开，可以重试且不会丢失阅读位置。"
        ) {
            HStack(spacing: 10) {
                Button(english ? "Try again" : "重试", action: onRetry)
                    .buttonStyle(.borderedProminent)
                Button(english ? "AI settings" : "AI 设置", action: onOpenSettings)
                    .buttonStyle(.borderless)
            }
        }
    }

    private func stateCard<Actions: View>(
        symbol: String,
        message: String,
        detail: String?,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: symbol)
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func summaryContent(_ summary: PageSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let errorMessage, phase != .generating {
                Label(
                    english ? "Generation failed; showing the previous overview. \(errorMessage)" : "生成失败，正在显示上次结果。\(errorMessage)",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text(summary.oneLine)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(summary.points.enumerated()), id: \.element.id) { index, point in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 12, alignment: .trailing)
                            .padding(.top, 2)
                        Text(point.text)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if let citation = point.citationIndex,
                           let source = summary.citations.first(where: { $0.index == citation }) {
                            Button("#\(citation)") { onOpenCitation(source) }
                                .font(.caption2.weight(.semibold))
                                .buttonStyle(.borderless)
                                .foregroundStyle(Color.accentColor)
                                .help(source.item.displayTitle)
                        }
                    }
                }
            }

            if !summary.citations.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(english ? "Cited sources" : "引用来源")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(summary.citations) { citation in
                        Button {
                            onOpenCitation(citation)
                        } label: {
                            HStack(spacing: 6) {
                                Text("#\(citation.index)")
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                Text(citation.item.displayTitle)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.forward")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                if let summary {
                    Text(english
                        ? "\(summary.providerName) · \(summary.model) · \(summary.inputCharacters) characters"
                        : "\(summary.providerName) · \(summary.model) · 输入 \(summary.inputCharacters) 字")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    if summary.wasTruncated {
                        Text(english ? "truncated" : "已截断")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text(english ? "Nothing is sent until you generate." : "生成前不会发送页面内容。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                if summary != nil {
                    Button(action: onGenerate) {
                        Label(
                            phase == .generating
                                ? (english ? "Generating…" : "生成中…")
                                : (english ? "Regenerate" : "重新生成"),
                            systemImage: "arrow.clockwise"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(phase == .generating)
                }
            }
        }
        .padding(.top, 8)
    }
}
