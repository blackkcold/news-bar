import SwiftUI
import AppKit

struct RSSWaterfallView: View {
    let items: [NewsItem]
    let sourceName: String
    let state: SourceLoadState
    let displayMode: RSSSourceConfig.DisplayMode
    let textCount: Int
    let imageCount: Int
    let isExpanded: Bool
    let loadedCount: Int
    let onToggleExpand: () -> Void
    let onLoadMore: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 170), spacing: 8)
    ]

    @State private var effectiveDisplayMode: RSSSourceConfig.DisplayMode?

    private var resolvedMode: RSSSourceConfig.DisplayMode {
        if let effectiveDisplayMode {
            return effectiveDisplayMode
        }
        if displayMode == .image, !items.isEmpty {
            let hasAnyImage = items.contains { $0.imageURL != nil }
            return hasAnyImage ? .image : .text
        }
        return displayMode
    }

    private var pageSize: Int {
        resolvedMode == .image ? imageCount : textCount
    }

    private var displayItems: [NewsItem] {
        guard isExpanded else {
            return Array(items.prefix(pageSize))
        }
        return Array(items.prefix(loadedCount))
    }

    private var hasMore: Bool {
        items.count > displayItems.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader

            if items.isEmpty {
                emptyState
            } else {
                if resolvedMode == .text {
                    textModeContent
                } else {
                    imageModeContent
                }

                if case .failed(let message) = state {
                    staleDataHint(message)
                }
            }
        }
        .onAppear {
            if effectiveDisplayMode == nil, !items.isEmpty {
                effectiveDisplayMode = resolvedMode
            }
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.blue)
            Text(sourceName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if items.count > pageSize {
                Spacer()
                Button(isExpanded ? "收起" : "展开更多") {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        onToggleExpand()
                    }
                }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var textModeContent: some View {
        LazyVStack(spacing: 0) {
            ForEach(displayItems) { item in
                RSSTextRow(item: item, sourceName: sourceName)
                if item.id != displayItems.last?.id {
                    Divider().padding(.horizontal, 14)
                }
            }
            if isExpanded && hasMore {
                sentinelView
            }
        }
    }

    private var imageModeContent: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(displayItems) { item in
                    RSSImageCard(item: item, sourceName: sourceName)
                }
            }
            .padding(.horizontal, 12)

            if isExpanded && hasMore {
                sentinelView
            }
        }
    }

    private var sentinelView: some View {
        Color.clear
            .frame(height: 1)
            .task(id: displayItems.count) {
                onLoadMore()
            }
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
        .padding(.horizontal, 14)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}

struct RSSTextRow: View {
    let item: NewsItem
    let sourceName: String
    @State private var isHovering = false

    var body: some View {
        Button {
            URLOpener.open(item.url)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(sourceName)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(isHovering ? Color.primary.opacity(0.04) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

struct RSSImageCard: View {
    let item: NewsItem
    let sourceName: String
    @State private var imageLoadState: ImageLoadState = .idle
    @State private var isHovering = false

    enum ImageLoadState {
        case idle
        case loading
        case loaded(NSImage)
        case failed
    }

    var body: some View {
        Button {
            URLOpener.open(item.url)
        } label: {
            VStack(spacing: 0) {
                if case .loaded(let img) = imageLoadState {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                        .frame(height: 96)
                        .clipped()
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 11))
                        .lineLimit(2)
                    Text(sourceName)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(isHovering ? 0.15 : 0), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title) - \(sourceName)")
        .accessibilityHint("在浏览器中打开")
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .task {
            guard let urlStr = item.imageURL,
                  let url = URL(string: urlStr) else {
                imageLoadState = .idle
                return
            }
            imageLoadState = .loading
            let loaded = await ImageCache.shared.image(for: url)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                imageLoadState = loaded != nil ? .loaded(loaded!) : .failed
            }
        }
    }
}
