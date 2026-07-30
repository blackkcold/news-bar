import SwiftUI
import AppKit

private enum RSSPalette {
    static func tint(for key: String) -> Color {
        let colors: [Color] = [.blue, .purple, .teal, .green, .orange, .pink, .indigo, .cyan]
        let seed = key.unicodeScalars.reduce(0) { partial, scalar in
            partial &* 31 &+ Int(scalar.value)
        }
        let index = (seed & 0x7fffffff) % colors.count
        return colors[index]
    }
}

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
        GridItem(.adaptive(minimum: 170), spacing: 6)
    ]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var effectiveDisplayMode: RSSSourceConfig.DisplayMode?

    private var sourceTint: Color {
        RSSPalette.tint(for: sourceName)
    }

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
        .padding(10)
        .newsCardSurface(rotation: -0.12)
        .onAppear {
            if effectiveDisplayMode == nil, !items.isEmpty {
                effectiveDisplayMode = resolvedMode
            }
        }
    }

    private var sectionHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            EditorialSourceBadge(
                mark: .rss,
                fallbackTint: sourceTint,
                size: 24,
                rotation: -1
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(sourceName)
                        .editorialHeading(size: 13)
                        .foregroundStyle(.primary)

                    EditorialTag(text: "\(items.count) 条", fallbackTint: sourceTint)

                    EditorialTag(
                        text: resolvedMode == .image ? "图文" : "纯文本",
                        fallbackTint: .secondary
                    )
                }

                Text("点击打开浏览器")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if case .loading = state {
                statusPill(text: "加载中", tint: .secondary)
            } else if case .failed = state {
                statusPill(text: "加载失败", tint: .orange)
            }

            if items.count > pageSize {
                Button {
                    if reduceMotion {
                        onToggleExpand()
                    } else {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            onToggleExpand()
                        }
                    }
                } label: {
                    Label(isExpanded ? "收起" : "展开 \(items.count - pageSize) 条", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))
                .controlSize(.small)
                .tint(sourceTint)
            }
        }
        .padding(.bottom, 6)
    }

    private var textModeContent: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                RSSTextRow(item: item, sourceName: sourceName)

                if index < displayItems.count - 1 {
                    Divider()
                        .padding(.leading, 12)
                        .padding(.trailing, 12)
                }
            }

            if isExpanded && hasMore {
                sentinelView
            }
        }
    }

    private var imageModeContent: some View {
        VStack(spacing: 6) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(displayItems) { item in
                    RSSImageCard(item: item, sourceName: sourceName)
                }
            }

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
        HStack(spacing: 4) {
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
        .padding(.vertical, 8)
    }

    private func staleDataHint(_ message: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8, weight: .semibold))
            Text("更新失败，显示缓存")
                .font(.system(size: 10, weight: .medium))
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.orange.opacity(0.08))
        .overlay(
            Rectangle()
                .strokeBorder(.orange.opacity(0.15), lineWidth: 1)
        )
        .editorialClipShape(cornerRadius: 10)
        .padding(.top, 8)
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
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12))
            .editorialClipShape(cornerRadius: 20)
    }
}

struct RSSTextRow: View {
    let item: NewsItem
    let sourceName: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppSettings.self) private var settings
    @State private var isHovering = false

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    private var sourceTint: Color {
        tint(for: item.source)
    }

    private var cardShape: AnyShape {
        isRetro
            ? AnyShape(Rectangle())
            : AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    var body: some View {
        Button {
            URLOpener.open(item.url)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        EditorialSourceBadge(mark: .rss, fallbackTint: sourceTint, size: 16)
                        Text(sourceName)
                            .font(.system(size: 10, weight: isRetro ? .black : .medium, design: isRetro ? .serif : .default))
                    }
                        .foregroundStyle(sourceTint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(sourceTint.opacity(0.12))
                        .editorialClipShape(cornerRadius: 20)

                    if let host = URL(string: item.url)?.host, !host.isEmpty {
                        Text(host)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(isHovering ? 1 : 0.55)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(cardBackground)
            .overlay(cardStroke)
            .contentShape(cardShape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(sourceName)，\(item.title)")
        .accessibilityHint("在浏览器中打开")
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
        }
    }

    private var cardBackground: some View {
        cardShape
            .fill(isHovering ? sourceTint.opacity(0.06) : Color.clear)
    }

    private var cardStroke: some View {
        cardShape
            .stroke(rowStrokeStyle, lineWidth: 1)
    }

    private var rowStrokeStyle: AnyShapeStyle {
        isHovering ? AnyShapeStyle(sourceTint.opacity(0.16)) : AnyShapeStyle(.separator.opacity(0.08))
    }

    private func tint(for source: NewsSource) -> Color {
        switch source {
        case .weibo:
            return .orange
        case .bilibili:
            return .pink
        case let .rss(name, _):
            return RSSPalette.tint(for: name)
        }
    }
}

struct RSSImageCard: View {
    let item: NewsItem
    let sourceName: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppSettings.self) private var settings
    @State private var imageLoadState: ImageLoadState = .idle
    @State private var isHovering = false

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    enum ImageLoadState {
        case idle
        case loading
        case loaded(NSImage)
        case failed
    }

    private var sourceTint: Color {
        tint(for: item.source)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    var body: some View {
        Button {
            URLOpener.open(item.url)
        } label: {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if case .loaded(let img) = imageLoadState {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(16 / 9, contentMode: .fill)
                            .editorialArchiveImage()
                            .frame(height: 84)
                            .clipped()
                            .transition(reduceMotion ? .identity : .scale(scale: 0.92).combined(with: .opacity))
                    } else {
                        headerPlaceholder
                            .frame(height: 84)
                    }

                    LinearGradient(
                        colors: [Color.black.opacity(0.18), Color.black.opacity(0.03), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)
                    .frame(height: 84)

                    sourceBadge
                        .padding(6)
                }
                .frame(height: 84)
                .clipped()

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    footerMeta
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .newsCardSurface(cornerRadius: 16, rotation: 0.16, isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title) - \(sourceName)")
        .accessibilityHint("在浏览器中打开")
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
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

            if let loaded {
                if reduceMotion {
                    imageLoadState = .loaded(loaded)
                } else {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        imageLoadState = .loaded(loaded)
                    }
                }
            } else {
                imageLoadState = .failed
            }
        }
    }

    private var headerPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 0, style: .continuous)
                .fill(sourceTint.opacity(0.12))

            if case .loading = imageLoadState {
                ProgressView()
                    .controlSize(.small)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(sourceTint)
                    Text("RSS 图像")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sourceBadge: some View {
        HStack(spacing: 4) {
            EditorialSourceBadge(mark: .rss, fallbackTint: sourceTint, size: 16)
            Text(item.source.displayName)
                .font(.system(size: 10, weight: isRetro ? .black : .medium, design: isRetro ? .serif : .default))
                .lineLimit(1)
        }
        .foregroundStyle(sourceTint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.ultraThinMaterial)
        .editorialClipShape(cornerRadius: 20)
        .accessibilityHidden(true)
    }

    private var footerMeta: some View {
        HStack(alignment: .center, spacing: 4) {
            HStack(spacing: 4) {
                EditorialSourceBadge(mark: .rss, fallbackTint: sourceTint, size: 16)
                Text(item.source.displayName)
                    .font(.system(size: 10, weight: isRetro ? .black : .medium, design: isRetro ? .serif : .default))
            }
                .foregroundStyle(sourceTint)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(sourceTint.opacity(0.12))
                .editorialClipShape(cornerRadius: 20)

            if let host = URL(string: item.url)?.host, !host.isEmpty {
                Text(host)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "arrow.up.forward")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .opacity(isHovering ? 1 : 0.55)
        }
    }

    private var cardBackground: some View {
        cardShape.fill(.ultraThinMaterial)
    }

    private var cardStroke: some View {
        cardShape.strokeBorder(imageStrokeStyle, lineWidth: 1)
    }

    private var imageStrokeStyle: AnyShapeStyle {
        AnyShapeStyle(.separator.opacity(isHovering ? 0.45 : 0.28))
    }

    private func tint(for source: NewsSource) -> Color {
        switch source {
        case .weibo:
            return .orange
        case .bilibili:
            return .pink
        case let .rss(name, _):
            return RSSPalette.tint(for: name)
        }
    }
}
