import SwiftUI

/// Image validation shared by the card and the masonry estimator. A row only
/// reserves an image box when the URL can actually be requested over HTTPS.
enum RecommendationCardMedia {
    static func normalizedURLString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("//") { return "https:" + trimmed }
        return trimmed
    }

    static func validatedURL(for item: NewsItem) -> URL? {
        guard let raw = item.imageURL else { return nil }
        return ReaderNavigationPolicy.allowedURL(normalizedURLString(raw))
    }
}

private enum RecommendationImagePhase {
    case idle
    case loading
    case loaded(NSImage)
    case failed
}

/// One recommendation card. The ranking position, batch identity and reason
/// travel with the card; only its visual column changes in the masonry.
struct RecommendationCardView: View {
    let row: ScoredRecommendation
    let contextID: String
    let position: Int
    let policyVersion: String
    let profileVersion: Int
    let columnWidth: CGFloat

    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var controller = InterestController.shared
    @State private var imagePhase: RecommendationImagePhase = .idle
    @State private var expandedReason = false
    @State private var isHovering = false

    private var english: Bool { settings.appLanguage == .en }
    private var imageURL: URL? { RecommendationCardMedia.validatedURL(for: row.item) }
    private var hasImage: Bool { imageURL != nil }
    private var imageHeight: CGFloat {
        RecommendationMasonryLayout.imageHeight(forColumnWidth: columnWidth)
    }
    private var sourceTint: Color {
        DashboardPalette.tint(for: row.item.source.displayName)
    }
    private var sourceMark: EditorialSourceMark {
        switch row.item.source {
        case .weibo: return .weibo
        case .bilibili: return .bilibili
        case .rss: return .rss
        }
    }
    private var effectiveReduceMotion: Bool { reduceMotion }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeroOpenButton(
                item: row.item,
                surface: "recommendation",
                contextID: contextID,
                policyVersion: policyVersion,
                profileVersion: profileVersion,
                position: position
            ) {
                openableContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
                .opacity(0.35)
                .padding(.horizontal, 14)

            actionRow
                .padding(.horizontal, 14)
                .padding(.top, 9)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .newsCardSurface(cornerRadius: 14, isHovering: isHovering)
        .onHover { hovering in
            if effectiveReduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
        }
        .task(id: imageURL) {
            await loadImage()
        }
    }

    private var openableContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasImage {
                imageHeader
            }

            VStack(alignment: .leading, spacing: 8) {
                if !hasImage {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(sourceTint.opacity(0.55))
                        .frame(width: 28, height: 3)
                        .accessibilityHidden(true)
                }

                Text(row.item.displayTitle)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(RecommendationMasonryLayout.maxTitleLines)

                metaRow
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var imageHeader: some View {
        ZStack(alignment: .topLeading) {
            sourceTint.opacity(0.12)

            if case .loaded(let image) = imagePhase {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: imageHeight)
                    .clipped()
                    .accessibilityHidden(true)
                    .transition(effectiveReduceMotion ? .identity : .opacity)
            } else {
                imagePlaceholder
                    .frame(height: imageHeight)
            }

            LinearGradient(
                colors: [Color.black.opacity(0.16), Color.black.opacity(0.02), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
            .frame(height: imageHeight)

            sourceBadge
                .padding(10)
        }
        .frame(maxWidth: .infinity)
        .frame(height: imageHeight)
        .clipped()
    }

    private var imagePlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [sourceTint.opacity(0.18), sourceTint.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if case .loading = imagePhase {
                ProgressView()
                    .controlSize(.small)
                    .tint(sourceTint)
            } else if case .failed = imagePhase {
                Image(systemName: "photo")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(sourceTint.opacity(0.65))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(sourceTint.opacity(0.5))
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
            Text(row.item.source.displayName)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(sourceTint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.88))
        .editorialClipShape(cornerRadius: 20)
        .accessibilityHidden(true)
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            EditorialSourceBadge(mark: sourceMark, fallbackTint: sourceTint, size: 15)
            Text(row.item.source.displayName)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)

            if let publishedAt = row.item.publishedAt {
                Text("·").foregroundStyle(.tertiary)
                Text(publishedAt, format: .dateTime.month(.twoDigits).day(.twoDigits))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            if let hotLabel = row.item.hotLabel, !hotLabel.isEmpty {
                Text(hotLabel)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(sourceTint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(sourceTint.opacity(0.12), in: Capsule())
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button(reason) {
                expandedReason.toggle()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
            .accessibilityHint(english ? "Show why this was recommended" : "查看推荐依据")
            .popover(isPresented: $expandedReason, arrowEdge: .bottom) {
                explanationPopover
            }

            Spacer(minLength: 0)

            Menu {
                Button(english ? "Bookmark / remove" : "收藏／取消收藏") {
                    if let id = controller.toggleBookmark(row.item) {
                        ActionToastCenter.shared.show(english ? "Bookmarked" : "已收藏") {
                            controller.undo(id)
                        }
                    }
                }
                Button(english ? "More like this (session)" : "更多同类（本次会话）") {
                    if let id = controller.feedback(row.item, kind: .moreLikeThis) {
                        ActionToastCenter.shared.show(english ? "More like this" : "已记录：更多同类") {
                            controller.undo(id)
                        }
                    }
                }
                .disabled(!controller.canLearn)
                .help(softFeedbackHelp)

                Divider()

                Menu(english ? "Less like this" : "少推荐") {
                    Button(english ? "This article" : "这条内容") {
                        if let id = controller.feedback(row.item, kind: .lessLikeContent) {
                            ActionToastCenter.shared.show(english ? "Fewer like this" : "已减少推荐：这条") {
                                controller.undo(id)
                            }
                        }
                    }
                    if let topic = row.topic {
                        Button(english ? "This topic" : "这个主题") {
                            if let id = controller.feedback(row.item, kind: .reduceTopic, topic: topic) {
                                ActionToastCenter.shared.show(english ? "Fewer like this topic" : "已减少推荐：这个主题") {
                                    controller.undo(id)
                                }
                            }
                        }
                    }
                    Button(english ? "This source" : "这个来源") {
                        if let id = controller.feedback(row.item, kind: .lessLikeSource) {
                            ActionToastCenter.shared.show(english ? "Fewer like this source" : "已减少推荐：这个来源") {
                                controller.undo(id)
                            }
                        }
                    }
                }
                .disabled(!controller.canLearn)
                .help(softFeedbackHelp)

                Menu(english ? "Hide" : "屏蔽") {
                    Button(english ? "This article" : "不再看这条") {
                        if let id = controller.feedback(row.item, kind: .notInterested) {
                            ActionToastCenter.shared.show(english ? "Hidden: this article" : "已屏蔽：这条") {
                                controller.undo(id)
                            }
                        }
                    }
                    Button(english ? "This event" : "不再看这个事件") {
                        if let id = controller.feedback(row.item, kind: .hideEvent) {
                            ActionToastCenter.shared.show(english ? "Hidden: this event" : "已屏蔽：这个事件") {
                                controller.undo(id)
                            }
                        }
                    }
                    Button(english ? "This source" : "屏蔽这个来源") {
                        if let id = controller.feedback(row.item, kind: .muteSource) {
                            ActionToastCenter.shared.show(english ? "Muted source" : "已屏蔽：这个来源") {
                                controller.undo(id)
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(minWidth: 28, minHeight: 28)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!controller.canManagePreferences)
            .accessibilityLabel(english ? "Reading preferences" : "阅读偏好操作")
            .help(
                controller.canManagePreferences
                    ? (english ? "Reading preferences" : "阅读偏好")
                    : (english ? "Local preference storage is unavailable" : "本地偏好存储暂不可用")
            )
        }
        .buttonStyle(.borderless)
    }

    private var explanationPopover: some View {
        Text(explanation)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(width: 280, alignment: .leading)
    }

    private var softFeedbackHelp: String {
        controller.canLearn
            ? (english ? "Uses this session's short-term interest only." : "仅影响本次会话的短期兴趣。")
            : InterestFeedbackCopy.softFeedbackUnavailable(settings.appLanguage)
    }

    private var reason: String {
        switch row.reason {
        case "interest": return english ? "Related to your interests" : "与你的阅读与关注主题相关"
        case "publicHeat": return english ? "Public chart signal" : "公开榜单热度"
        case "exploration": return english ? "Source rotation" : "来源补位"
        default: return english ? "Recently discovered" : "近期采集内容"
        }
    }

    private var explanation: String {
        let labels = english
            ? ["interest": "Topic match", "source": "Source preference", "recency": "Recency", "novelty": "Novelty", "publicHeat": "Public heat"]
            : ["interest": "主题相关", "source": "来源偏好", "recency": "时效", "novelty": "新颖性", "publicHeat": "公开热度"]
        let values = row.components.sorted { $0.key < $1.key }
            .map { "\(labels[$0.key] ?? $0.key)：\(String(format: "%.2f", $0.value))" }
            .joined(separator: " · ")
        return reason + "\n" + values + (english
            ? "\nMissing features are unknown; scores are heuristics, not predicted reading probabilities."
            : "\n缺失特征按未知处理；分数是启发式排序，不是阅读概率。")
    }

    private func loadImage() async {
        guard let imageURL else {
            imagePhase = .idle
            return
        }
        if case .loaded = imagePhase { return }
        imagePhase = .loading
        let loaded = await ImageCache.shared.image(
            for: imageURL,
            maxPixelSize: Int(columnWidth * 2)
        )
        guard !Task.isCancelled else { return }
        if let loaded {
            if effectiveReduceMotion {
                imagePhase = .loaded(loaded)
            } else {
                withAnimation(.easeInOut(duration: 0.18)) {
                    imagePhase = .loaded(loaded)
                }
            }
        } else {
            imagePhase = .failed
        }
    }
}
