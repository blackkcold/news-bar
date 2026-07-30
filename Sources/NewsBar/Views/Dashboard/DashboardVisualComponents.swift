import AppKit
import SwiftUI

// MARK: - Dashboard Hot Trend Card

struct DashboardHotTrendCard: View {
    let source: NewsSource
    let items: [NewsItem]
    var collapsedLimit: Int = 5

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    private var presentation: DashboardTrendPresentation {
        DashboardTrendPresentation(for: source)
    }

    private var visibleItems: [NewsItem] {
        guard !isExpanded else { return items }
        return Array(items.prefix(collapsedLimit))
    }

    private var hiddenCount: Int {
        max(0, items.count - visibleItems.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if items.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                        DashboardTrendRow(
                            item: item,
                            sourceLabel: presentation.title,
                            sourceMark: presentation.mark,
                            accent: presentation.accent,
                            rankFallback: index + 1,
                            reduceMotion: reduceMotion
                        )

                        if index < visibleItems.count - 1 {
                            Divider().padding(.horizontal, 14)
                        }
                    }
                }

                if hiddenCount > 0 {
                    footerButton
                }
            }
        }
        .padding(14)
        .newsCardSurface(rotation: presentation.title == "微博热搜" ? -0.16 : 0.16)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            EditorialSourceBadge(
                mark: presentation.mark,
                fallbackTint: presentation.accent,
                size: 30,
                rotation: presentation.title == "微博热搜" ? -2 : 2
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(presentation.title)
                        .editorialHeading(size: 14)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    EditorialTag(text: "\(items.count) 条", fallbackTint: presentation.accent)
                }

                Text("原生热点卡片 · 点击打开浏览器")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            if items.count > collapsedLimit {
                Button {
                    toggleExpansion()
                } label: {
                    Label(isExpanded ? "收起" : "展开 \(hiddenCount) 条", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))
                .controlSize(.small)
                .tint(presentation.accent)
                .accessibilityLabel(isExpanded ? "收起 \(presentation.title)" : "展开更多 \(presentation.title)")
            }
        }
        .padding(.bottom, 10)
    }

    private var footerButton: some View {
        Button {
            toggleExpansion()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                Text(isExpanded ? "收起" : "展开全部")
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(EditorialActionButtonStyle(compact: true))
        .controlSize(.small)
        .tint(presentation.accent)
        .padding(.top, 10)
    }

    private var emptyState: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("暂无趋势数据")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 10)
        .accessibilityLabel("暂无趋势数据")
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    private var cardBackground: some View {
        cardShape.fill(.ultraThinMaterial)
    }

    private var cardStroke: some View {
        cardShape.strokeBorder(.separator.opacity(0.35), lineWidth: 1)
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

private struct DashboardTrendRow: View {
    let item: NewsItem
    let sourceLabel: String
    let sourceMark: EditorialSourceMark
    let accent: Color
    let rankFallback: Int
    let reduceMotion: Bool

    @Environment(AppSettings.self) private var settings
    @State private var isHovering = false

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    private var rank: Int {
        item.rank ?? rankFallback
    }

    var body: some View {
        Button {
            URLOpener.open(item.url)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                rankBadge

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        sourcePill

                        if let host = URL(string: item.url)?.host, !host.isEmpty {
                            Text(host)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovering ? 1 : 0.55)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(rowBackground)
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("在浏览器中打开")
        .accessibilityValue(sourceLabel)
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

    private var rankBadge: some View {
        Text("\(rank)")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(rank <= 3 ? .white : accent)
            .frame(width: 22, height: 22)
            .background(rank <= 3 ? rankColor(rank) : accent.opacity(0.12))
            .editorialClipShape(cornerRadius: 11)
            .accessibilityHidden(true)
    }

    private var sourcePill: some View {
        HStack(spacing: 4) {
            EditorialSourceBadge(
                mark: sourceMark,
                fallbackTint: accent,
                size: 17
            )
            Text(sourceLabel)
                .font(.system(size: 10, weight: isRetro ? .black : .medium, design: isRetro ? .serif : .default))
        }
            .foregroundStyle(accent)
            .padding(.horizontal, isRetro ? 4 : 6)
            .padding(.vertical, isRetro ? 3 : 2)
            .background(accent.opacity(0.12))
            .editorialClipShape(cornerRadius: 20)
            .accessibilityHidden(true)
    }

    private var rowBackground: some View {
        rowShape
            .fill(isHovering ? accent.opacity(0.07) : Color.clear)
            .overlay {
                rowShape.stroke(isHovering ? accent.opacity(0.16) : .clear, lineWidth: 1)
            }
    }

    private var rowShape: AnyShape {
        isRetro
            ? AnyShape(Rectangle())
            : AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var accessibilityLabel: String {
        if let rank = item.rank {
            return "\(sourceLabel) 第\(rank)位，\(item.title)"
        }
        return "\(sourceLabel)，\(item.title)"
    }

    private func rankColor(_ rank: Int) -> Color {
        if isRetro {
            return rank <= 3 ? RetroEditorialTokens.brick : RetroEditorialTokens.ink
        }
        switch rank {
        case 1: return .red
        case 2: return .orange
        case 3: return .yellow
        default: return accent
        }
    }
}

private struct DashboardTrendPresentation {
    let title: String
    let mark: EditorialSourceMark
    let accent: Color

    init(for source: NewsSource) {
        switch source {
        case .weibo:
            title = "微博热搜"
            mark = .weibo
            accent = .orange
        case .bilibili:
            title = "B站热搜"
            mark = .bilibili
            accent = .pink
        case let .rss(name, _):
            title = name
            mark = .rss
            accent = DashboardPalette.tint(for: name)
        }
    }
}

struct DashboardRSSSourceCard: View {
    let source: NewsSource
    let items: [NewsItem]
    let state: SourceLoadState
    let isExpanded: Bool
    let onToggleExpansion: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sourceTint: Color {
        DashboardPalette.tint(for: source.displayName)
    }

    private var stateLabel: String {
        switch state {
        case .idle: return "空闲"
        case .loading: return "加载中"
        case .loaded: return "已加载"
        case .failed: return "失败"
        }
    }

    private var stateTint: Color {
        switch state {
        case .idle: return .secondary
        case .loading: return .blue
        case .loaded: return .green
        case .failed: return .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if isExpanded {
                DashboardAdaptiveRSSMasonryFeed(
                    items: items,
                    title: source.displayName,
                    state: state,
                    showsHeader: false
                )
            }
        }
        .padding(14)
        .newsCardSurface(rotation: -0.1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            EditorialSourceBadge(
                mark: .rss,
                fallbackTint: sourceTint,
                size: 30,
                rotation: -1.5
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(source.displayName)
                        .editorialHeading(size: 14)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    EditorialTag(text: "\(items.count) 条", fallbackTint: sourceTint)

                    EditorialTag(text: stateLabel, fallbackTint: stateTint)
                }

                Text("自适应瀑布流 · 点击在浏览器中打开")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Button {
                toggleExpansion()
            } label: {
                Label(isExpanded ? "收起" : "展开", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(EditorialActionButtonStyle(compact: true))
            .controlSize(.small)
            .tint(sourceTint)
            .accessibilityLabel(isExpanded ? "收起 \(source.displayName)" : "展开 \(source.displayName)")
        }
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    private var cardBackground: some View {
        cardShape.fill(.ultraThinMaterial)
    }

    private var cardStroke: some View {
        cardShape.strokeBorder(.separator.opacity(0.35), lineWidth: 1)
    }

    private func toggleExpansion() {
        if reduceMotion {
            onToggleExpansion()
        } else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                onToggleExpansion()
            }
        }
    }
}

// MARK: - Dashboard RSS Masonry Feed

struct DashboardAdaptiveRSSMasonryFeed: View {
    let items: [NewsItem]
    var title: String = "RSS 订阅"
    var state: SourceLoadState = .idle
    var showsHeader: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var sourceSummaries: [(name: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]

        for item in items {
            let name = item.source.displayName
            if counts[name] == nil {
                order.append(name)
            }
            counts[name, default: 0] += 1
        }

        return order.map { ($0, counts[$0, default: 0]) }
    }

    private var statusMessage: String? {
        switch state {
        case .idle:
            return items.isEmpty ? "暂无 RSS 内容" : nil
        case .loading:
            return items.isEmpty ? "RSS 源加载中…" : "RSS 源加载中，当前显示缓存内容"
        case .loaded:
            return items.isEmpty ? "暂无 RSS 内容" : nil
        case .failed(let message):
            return items.isEmpty ? message : nil
        }
    }

    private var statusSymbol: String {
        switch state {
        case .idle: return "tray"
        case .loading: return "arrow.triangle.2.circlepath"
        case .loaded: return "tray"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusTint: Color {
        switch state {
        case .idle, .loaded: return .secondary
        case .loading: return .blue
        case .failed: return .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeader {
                header
            }

            if items.isEmpty {
                emptyState
            } else {
                if case .loading = state {
                    banner(message: "RSS 源加载中，当前显示缓存内容", symbol: "arrow.triangle.2.circlepath", tint: .blue)
                } else if case .failed(let message) = state {
                    banner(message: message, symbol: "exclamationmark.triangle.fill", tint: .orange)
                }

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(items) { item in
                        DashboardRSSMasonryCard(item: item, reduceMotion: reduceMotion)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            EditorialSourceBadge(
                mark: .rss,
                fallbackTint: .blue,
                size: 30,
                rotation: 1
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    Text("\(items.count) 条 RSS 内容")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if !sourceSummaries.isEmpty {
                        Text("·")
                            .foregroundStyle(.tertiary)

                        Text(sourceSummaries.map { $0.name }.joined(separator: " / "))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            Spacer(minLength: 0)

            EditorialTag(text: "自适应", fallbackTint: .secondary)
                .accessibilityLabel("自适应布局")
        }
    }

    private var emptyState: some View {
        banner(
            message: statusMessage ?? "暂无 RSS 内容",
            symbol: statusSymbol,
            tint: statusTint
        )
    }

    private func banner(message: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.vertical, 10)
        .accessibilityLabel(message)
    }
}

private struct DashboardRSSMasonryCard: View {
    let item: NewsItem
    let reduceMotion: Bool

    @Environment(\.accessibilityReduceMotion) private var environmentReduceMotion
    @Environment(AppSettings.self) private var settings
    @State private var imagePhase: DashboardRemoteImagePhase = .idle
    @State private var isHovering = false

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    private var sourceTint: Color {
        DashboardPalette.tint(for: item.source.displayName)
    }

    private var effectiveReduceMotion: Bool {
        reduceMotion || environmentReduceMotion
    }

    private var hasRemoteImage: Bool {
        item.imageURL.flatMap(URL.init(string:)) != nil
    }

    private var headerBackground: Color {
        sourceTint.opacity(0.12)
    }

    var body: some View {
        Button {
            URLOpener.open(item.url)
        } label: {
            cardContent
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .newsCardSurface(cornerRadius: 16, rotation: 0.12, isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.source.displayName)
        .accessibilityHint("在浏览器中打开")
        .onHover { hovering in
            if effectiveReduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        if hasRemoteImage {
            imageCardContent
        } else {
            textCardContent
        }
    }

    private var imageCardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            imageHeader

            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                footerMeta
            }
            .padding(12)
        }
        .task(id: item.imageURL) {
            await loadImage()
        }
    }

    private var textCardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(4)
                .multilineTextAlignment(.leading)

            footerMeta
        }
        .padding(12)
    }

    private var imageHeader: some View {
        ZStack(alignment: .topLeading) {
            headerBackground

            if case .loaded(let image) = imagePhase {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .editorialArchiveImage()
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .clipped()
                    .transition(effectiveReduceMotion ? .identity : .opacity)
            } else {
                headerPlaceholder
                    .frame(height: 120)
            }

            LinearGradient(
                colors: [Color.black.opacity(0.18), Color.black.opacity(0.03), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity)
            .frame(height: 120)

            sourceBadge
                .padding(10)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
        .clipped()
    }

    private var headerPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 0, style: .continuous)
                .fill(headerBackground)

            if case .loading = imagePhase {
                ProgressView()
                    .controlSize(.small)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(sourceTint)
                    Text("RSS 图像")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sourceBadge: some View {
        HStack(spacing: 4) {
            EditorialSourceBadge(
                mark: sourceMark,
                fallbackTint: sourceTint,
                size: 16
            )
            Text(item.source.displayName)
                .font(.system(size: 10, weight: isRetro ? .black : .medium, design: isRetro ? .serif : .default))
                .lineLimit(1)
        }
        .foregroundStyle(sourceTint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial)
        .editorialClipShape(cornerRadius: 20)
        .accessibilityHidden(true)
    }

    private var footerMeta: some View {
        HStack(alignment: .center, spacing: 6) {
            HStack(spacing: 4) {
                EditorialSourceBadge(
                    mark: sourceMark,
                    fallbackTint: sourceTint,
                    size: 16
                )
                Text(item.source.displayName)
                    .font(.system(size: 10, weight: isRetro ? .black : .medium, design: isRetro ? .serif : .default))
            }
                .foregroundStyle(sourceTint)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(sourceTint.opacity(0.12))
                .editorialClipShape(cornerRadius: 20)

            if let host = URL(string: item.url)?.host, !host.isEmpty {
                Text(host)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            Image(systemName: "arrow.up.forward")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .opacity(isHovering ? 1 : 0.55)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    private var cardBackground: some View {
        cardShape.fill(.ultraThinMaterial)
    }

    private var cardStroke: some View {
        cardShape.strokeBorder(.separator.opacity(isHovering ? 0.45 : 0.28), lineWidth: 1)
    }

    private var sourceMark: EditorialSourceMark {
        switch item.source {
        case .weibo: return .weibo
        case .bilibili: return .bilibili
        case .rss: return .rss
        }
    }

    private func loadImage() async {
        guard let urlString = item.imageURL, let url = URL(string: urlString) else {
            imagePhase = .idle
            return
        }

        imagePhase = .loading
        let loadedImage = await ImageCache.shared.image(for: url)

        if let loadedImage {
            if effectiveReduceMotion {
                imagePhase = .loaded(loadedImage)
            } else {
                withAnimation(.easeInOut(duration: 0.18)) {
                    imagePhase = .loaded(loadedImage)
                }
            }
        } else {
            imagePhase = .failed
        }
    }
}

private enum DashboardRemoteImagePhase {
    case idle
    case loading
    case loaded(NSImage)
    case failed
}

private enum DashboardPalette {
    private static let colors: [Color] = [.blue, .purple, .teal, .green, .orange, .pink, .indigo, .cyan]

    static func tint(for key: String) -> Color {
        let seed = key.unicodeScalars.reduce(0) { partial, scalar in
            partial &* 31 &+ Int(scalar.value)
        }
        let index = (seed & 0x7fffffff) % colors.count
        return colors[index]
    }
}

#Preview("Dashboard Hot Trend Cards") {
    VStack(spacing: 14) {
        DashboardHotTrendCard(
            source: .weibo,
            items: [
                NewsItem(title: "微博热搜一号", url: "https://example.com/weibo-1", source: .weibo, rank: 1),
                NewsItem(title: "微博热搜二号", url: "https://example.com/weibo-2", source: .weibo, rank: 2),
                NewsItem(title: "微博热搜三号", url: "https://example.com/weibo-3", source: .weibo, rank: 3),
                NewsItem(title: "微博热搜四号", url: "https://example.com/weibo-4", source: .weibo, rank: 4),
                NewsItem(title: "微博热搜五号", url: "https://example.com/weibo-5", source: .weibo, rank: 5),
                NewsItem(title: "微博热搜六号", url: "https://example.com/weibo-6", source: .weibo, rank: 6)
            ]
        )

        DashboardHotTrendCard(
            source: .bilibili,
            items: [
                NewsItem(title: "B站热搜一号", url: "https://example.com/bili-1", source: .bilibili, rank: 1),
                NewsItem(title: "B站热搜二号", url: "https://example.com/bili-2", source: .bilibili, rank: 2),
                NewsItem(title: "B站热搜三号", url: "https://example.com/bili-3", source: .bilibili, rank: 3)
            ]
        )
    }
    .padding(16)
    .frame(width: 420)
    .background(.regularMaterial)
    .environment(AppSettings())
    .adaptiveColorScheme()
}

#Preview("Dashboard RSS Feed") {
    DashboardAdaptiveRSSMasonryFeed(
        items: [
            NewsItem(title: "苹果发布新系统视觉规范，Dashboard 组件值得一看", url: "https://example.com/rss-1", source: .rss(name: "科技日报", url: "https://example.com/feed-1")),
            NewsItem(title: "本地新闻：SwiftUI 在 macOS 15 上的布局技巧", url: "https://example.com/rss-2", source: .rss(name: "开发者周刊", url: "https://example.com/feed-2")),
            NewsItem(title: "RSS 订阅源更新：产品设计案例集合", url: "https://example.com/rss-3", source: .rss(name: "设计周报", url: "https://example.com/feed-3")),
            NewsItem(title: "一篇较长的标题用于测试两列自适应 masonry 布局是否稳定", url: "https://example.com/rss-4", source: .rss(name: "长文精选", url: "https://example.com/feed-4")),
            NewsItem(title: "保持懒加载与卡片高度平衡", url: "https://example.com/rss-5", source: .rss(name: "架构笔记", url: "https://example.com/feed-5")),
            NewsItem(title: "单列回退在窄宽度下依然应当保持可读性", url: "https://example.com/rss-6", source: .rss(name: "产品观察", url: "https://example.com/feed-6"))
        ]
    )
    .padding(16)
    .frame(width: 760)
    .background(.regularMaterial)
    .environment(AppSettings())
    .adaptiveColorScheme()
}

#Preview("Dashboard RSS Width Stress") {
    DashboardAdaptiveRSSMasonryFeed(
        items: [
            NewsItem(title: "这是一个非常长的中文标题用于测试窄宽度下的自适应瀑布流卡片是否会错误吞掉列间距并挤压相邻内容", url: "https://example.com/stress-cjk", source: .rss(name: "宽度压力测试", url: "https://example.com/feed-stress")),
            NewsItem(title: "ThisIsAnExtremelyLongUnbrokenLatinTitleForWidthStressTestingWithoutAnySpacesOrHyphenation0123456789", url: "https://example.com/stress-latin", source: .rss(name: "Width Lab", url: "https://example.com/feed-width"), imageURL: "file:///nonexistent-preview-image-1.jpg"),
            NewsItem(title: "混合 URL 样式标题 https://news.example.com/path/to/article?foo=bar&baz=qux 以及更多尾部文本来继续压测", url: "https://example.com/stress-mixed", source: .rss(name: "URL 混排", url: "https://example.com/feed-mixed")),
            NewsItem(title: "卡片图文双路径都要覆盖：图像卡片路径与纯文本卡片路径在同一窄宽度中都应稳定", url: "https://example.com/stress-image", source: .rss(name: "图文回归", url: "https://example.com/feed-image"), imageURL: "file:///nonexistent-preview-image-2.jpg")
        ]
    )
    .padding(16)
    .frame(width: 536)
    .background(.regularMaterial)
    .environment(AppSettings())
    .adaptiveColorScheme()
}
