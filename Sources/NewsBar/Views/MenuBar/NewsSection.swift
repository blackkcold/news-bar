import SwiftUI

enum NewsSectionPresentation: Equatable {
    case standard
    case compactTrend

    var isCompactTrend: Bool {
        self == .compactTrend
    }
}

struct NewsSection: View {
    let title: String
    let sourceMark: EditorialSourceMark
    let color: Color
    let items: [NewsItem]
    let showRank: Bool
    var state: SourceLoadState = .idle
    var maxVisible: Int? = nil
    var presentation: NewsSectionPresentation = .standard

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    private var isCompactPresentation: Bool {
        presentation.isCompactTrend
    }

    private var cardPadding: CGFloat { isCompactPresentation ? 8 : 10 }
    private var headerSpacing: CGFloat { isCompactPresentation ? 6 : 8 }
    private var headerIconSize: CGFloat { isCompactPresentation ? 20 : 24 }
    private var headerIconCornerRadius: CGFloat { isCompactPresentation ? 8 : 9 }
    private var headerTitleSize: CGFloat { isCompactPresentation ? 12.5 : 13 }
    private var helperTextSize: CGFloat { 10 }
    private var headerBottomSpacing: CGFloat { isCompactPresentation ? 4 : 6 }
    private var rowDividerLeadingRank: CGFloat { isCompactPresentation ? 28 : 32 }
    private var rowDividerLeadingPlain: CGFloat { isCompactPresentation ? 10 : 12 }
    private var rowDividerTrailing: CGFloat { isCompactPresentation ? 8 : 10 }
    private var emptyStateVerticalPadding: CGFloat { isCompactPresentation ? 6 : 8 }
    private var staleHintHorizontalPadding: CGFloat { isCompactPresentation ? 8 : 10 }
    private var staleHintVerticalPadding: CGFloat { isCompactPresentation ? 4 : 5 }
    private var rowButtonTextSize: CGFloat { 10 }
    private var expandButtonIconSize: CGFloat { isCompactPresentation ? 8.5 : 8 }
    private var expandButtonHitPadding: CGFloat { isCompactPresentation ? 2 : 0 }
    private var expandButtonCornerRadius: CGFloat { isCompactPresentation ? 7 : 0 }
    private var showHeaderHelperText: Bool { !isCompactPresentation }

    private var visibleItems: [NewsItem] {
        guard let max = maxVisible, items.count > max, !isExpanded else {
            return items
        }
        return Array(items.prefix(max))
    }

    private var hiddenCount: Int {
        guard let max = maxVisible, items.count > max else { return 0 }
        return items.count - max
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader

            if items.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                        NewsItemRow(item: item, showRank: showRank, presentation: presentation)

                        if index < visibleItems.count - 1 {
                            Divider()
                                .padding(.leading, showRank ? rowDividerLeadingRank : rowDividerLeadingPlain)
                                .padding(.trailing, rowDividerTrailing)
                        }
                    }
                }

                if case .failed(let message) = state {
                    staleDataHint(message)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(cardPadding)
        .newsCardSurface(rotation: title == "微博热搜" ? -0.2 : 0.2)
    }

    private var sectionHeader: some View {
        HStack(alignment: .center, spacing: headerSpacing) {
            EditorialSourceBadge(
                mark: sourceMark,
                fallbackTint: color,
                size: headerIconSize,
                rotation: title == "微博热搜" ? -2 : 2
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .editorialHeading(size: headerTitleSize)
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    EditorialTag(text: "\(items.count) 条", fallbackTint: color)
                }

                if showHeaderHelperText {
                    Text("点击打开浏览器")
                        .font(.system(size: helperTextSize))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if case .loading = state {
                statusPill(text: "加载中", tint: .secondary)
            } else if case .failed = state {
                statusPill(text: "加载失败", tint: .orange)
            }

            if hiddenCount > 0 {
                expandButton
            }
        }
        .padding(.bottom, headerBottomSpacing)
    }

    private var emptyState: some View {
        HStack(spacing: 6) {
            switch state {
            case .loading:
                ProgressView()
                    .scaleEffect(0.52)
                    .frame(width: 12, height: 12)
                Text("加载中...")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                Text("加载失败")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            case .idle, .loaded:
                Text("暂无数据")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, emptyStateVerticalPadding)
    }

    private func staleDataHint(_ message: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8, weight: .semibold))
            Text("更新失败，显示缓存")
                .font(.system(size: 9.5, weight: .medium))
            Text(message)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, staleHintHorizontalPadding)
        .padding(.vertical, staleHintVerticalPadding)
        .background(.orange.opacity(0.08))
        .overlay(
            Rectangle()
                .strokeBorder(.orange.opacity(0.15), lineWidth: 1)
        )
        .editorialClipShape(cornerRadius: 10)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var expandButton: some View {
        if isCompactPresentation {
            Button {
                toggleExpansion()
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: expandButtonIconSize, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 18, height: 18)
                    .padding(expandButtonHitPadding)
                    .background(color.opacity(0.12))
                    .editorialClipShape(cornerRadius: expandButtonCornerRadius)
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .tint(color)
            .accessibilityLabel(isExpanded ? "收起 \(hiddenCount) 条" : "展开 \(hiddenCount) 条")
            .help(isExpanded ? "收起" : "展开 \(hiddenCount) 条")
        } else {
            Button {
                toggleExpansion()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: expandButtonIconSize, weight: .semibold))
                    Text(isExpanded ? "收起" : "展开 \(hiddenCount) 条")
                        .font(.system(size: rowButtonTextSize, weight: .medium))
                }
                .frame(minWidth: 0)
                .foregroundStyle(color)
                .contentShape(Rectangle())
            }
            .buttonStyle(EditorialActionButtonStyle(compact: true))
            .controlSize(.small)
            .tint(color)
            .accessibilityLabel(isExpanded ? "收起 \(hiddenCount) 条" : "展开 \(hiddenCount) 条")
            .help(isExpanded ? "收起" : "展开 \(hiddenCount) 条")
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

    @ViewBuilder
    private func statusPill(text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12))
            .editorialClipShape(cornerRadius: 20)
    }

    private func toggleExpansion() {
        if reduceMotion {
            isExpanded.toggle()
        } else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                isExpanded.toggle()
            }
        }
    }
}
