import SwiftUI

struct NewsSection: View {
    let title: String
    let icon: String
    let color: Color
    let items: [NewsItem]
    let showRank: Bool
    var state: SourceLoadState = .idle
    var maxVisible: Int? = nil

    @State private var isExpanded = false

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
                ForEach(visibleItems) { item in
                    NewsItemRow(item: item, showRank: showRank)
                }

                if case .failed(let message) = state {
                    staleDataHint(message)
                }

                if hiddenCount > 0 {
                    expandButton
                }
            }
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        HStack(spacing: 6) {
            switch state {
            case .loading:
                ProgressView()
                    .scaleEffect(0.55)
                    .frame(width: 14, height: 14)
                Text("加载中...")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text("加载失败")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            case .idle, .loaded:
                Text("暂无数据")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func staleDataHint(_ message: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8))
            Text("更新失败，显示缓存")
                .font(.system(size: 10))
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    private var expandButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .medium))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                Text(isExpanded ? "收起" : "展开 \(hiddenCount) 条")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
