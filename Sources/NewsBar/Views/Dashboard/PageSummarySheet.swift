import SwiftUI

/// A page overview is deliberately a sheet, not a message in the AI-search
/// transcript: it has no question field and leaves no search history entry.
struct PageSummarySheet: View {
    let input: PageSummaryInput
    var onOpenSettings: () -> Void = {}

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = PageSummaryModel()
    @State private var hasConfirmed = false
    @State private var didStart = false

    private var english: Bool { settings.appLanguage == .en }
    private var providerName: String {
        settings.providerDisplayName(forID: settings.aiProvider)
    }
    private var requiresDisclosure: Bool {
        input.scope == .article && !hasConfirmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            basisLine

            if requiresDisclosure {
                disclosure
            } else {
                content
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(22)
        .frame(width: 580)
        .frame(minHeight: 380, alignment: .topLeading)
        .background(.regularMaterial)
        .onAppear {
            guard !didStart, input.scope == .list else { return }
            start()
        }
        .onDisappear { model.cancel() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 30, height: 30)
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(english ? "Page overview" : "页面概览")
                    .font(.headline)
                Text(input.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let host = input.url.flatMap(URL.init(string:))?.host {
                    Text(host)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if input.isPrivate {
                Label(english ? "Private" : "隐私阅读", systemImage: "hand.raised.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }

            Button {
                model.cancel()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(english ? "Close" : "关闭")
            .help(english ? "Close" : "关闭")
        }
    }

    private var basisLine: some View {
        HStack(spacing: 6) {
            Image(systemName: input.scope == .article ? "doc.text" : "list.bullet")
                .font(.system(size: 10, weight: .semibold))
            Text(basisText)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
    }

    private var basisText: String {
        if input.scope == .article {
            let characters = input.articleText?.count ?? 0
            let cap = PageSummaryService.maxArticleCharacters
            if characters > cap {
                return english
                    ? "Based on the current browser page · first \(cap) characters of \(characters)"
                    : "基于当前浏览器页面正文 · 已截断到 \(cap) 字（原文 \(characters) 字）"
            }
            return english
                ? "Based on the current browser page · up to \(cap) characters"
                : "基于当前浏览器页面正文 · 最多 \(cap) 字"
        }
        return english
            ? "Based on \(input.listRows.count) loaded headlines · titles only"
            : "基于当前已加载的 \(input.listRows.count) 条标题 · 仅标题"
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

            if input.isPrivate {
                Text(english
                    ? "Private reading is on: this overview stays in this session and is not cached."
                    : "隐私阅读已开启：概览只保留在本次会话，不会写入缓存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(english ? "Generate overview" : "生成概览") {
                    hasConfirmed = true
                    start()
                }
                .buttonStyle(.borderedProminent)

                Button(english ? "Cancel" : "取消") { dismiss() }
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

    @ViewBuilder
    private var content: some View {
        if let summary = model.summary {
            summaryContent(summary)
        } else if model.isBusy {
            loadingContent
        } else if case .failed(let message) = model.state {
            failureContent(message)
        } else {
            loadingContent
        }
    }

    private var loadingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text(english ? "Reading this page and writing an overview…" : "正在阅读当前页面并生成概览…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    private func failureContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(english ? "Try again" : "重试") { start() }
                    .buttonStyle(.borderedProminent)
                Button(english ? "AI settings" : "AI 设置", action: onOpenSettings)
                    .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func summaryContent(_ summary: PageSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = model.errorMessage {
                Label(
                    english ? "Generation failed; showing the previous overview. \(error)" : "生成失败，正在显示上次结果。\(error)",
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
                        if let citation = point.citationIndex,
                           let source = summary.citations.first(where: { $0.index == citation }) {
                            Button("#\(citation)") { open(source) }
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
                            open(citation)
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
                if let summary = model.summary {
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

                if model.summary != nil || !requiresDisclosure {
                    Button {
                        start()
                    } label: {
                        Label(
                            model.isBusy
                                ? (english ? "Generating…" : "生成中…")
                                : (english ? "Regenerate" : "重新生成"),
                            systemImage: "arrow.clockwise"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isBusy)
                }
            }
        }
    }

    private func start() {
        guard !model.isBusy else { return }
        didStart = true
        model.summarize(input: input, settings: settings)
    }

    private func open(_ citation: PageSummaryCitation) {
        model.cancel()
        dismiss()
        NewsNavigationRouter.shared.open(
            citation.item,
            surface: "pageSummary",
            position: citation.position
        )
    }
}
