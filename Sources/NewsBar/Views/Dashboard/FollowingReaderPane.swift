import AppKit
import SwiftUI

/// Layout constants for the following reader.
///
/// Three independent caps, deliberately not derived from each other:
/// - `contentMax` is the column: it stops a wide window from stretching a
///   heading across the whole pane.
/// - `proseMax` is the reading measure: 560pt keeps a Chinese line near 36
///   characters. The old 680 cap never took effect below a 1240pt window, so
///   the body actually rendered at the panel width (620pt at 1180).
/// - `mediaMax` lets images and the discussion use more width than prose.
enum FollowingReaderMetrics {
    static let contentMax: CGFloat = 700
    static let proseMax: CGFloat = 560
    static let mediaMax: CGFloat = 640
    static let horizontalPadding: CGFloat = 24

    static let avatarSize: CGFloat = 36
    static let commentAvatar: CGFloat = 24
    /// Leading inset of every comment row. The author bar is drawn inside it,
    /// so an author reply never shifts the avatar out of the column.
    static let commentInset: CGFloat = 10
    /// Aligns a comment divider with the comment text, not with the avatar.
    static let commentDividerInset: CGFloat = commentInset + commentAvatar + 8
}

/// The entry point that applies comments a background refresh left pending.
///
/// Extracted from the view so the decision and its wording are testable
/// without an accessibility tree: deleting the banner used to leave the
/// pending queue unreachable while every test stayed green.
enum FollowingDiscussionBanner {
    static func title(newComments: Int, language: AppLanguage) -> String? {
        guard newComments > 0 else { return nil }
        return language == .en
            ? "\(newComments) new comments · Show"
            : "有 \(newComments) 条新评论 · 显示"
    }

    static func accessibilityLabel(newComments: Int, language: AppLanguage) -> String {
        language == .en
            ? "Show \(newComments) new comments"
            : "显示 \(newComments) 条新评论"
    }
}

/// The reading column for one following post: byline, body, media, the
/// interaction snapshot and the discussion tree.
struct FollowingReaderPane: View {
    let entry: FollowingPostEntry
    let monitor: WeiboMonitorViewModel
    @Binding var imageSelection: FollowingReaderImageSelection?

    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var contrast

    private var retro: Bool { settings.appTheme == .retroEditorial }
    private var accent: Color { retro ? RetroEditorialTokens.brick : .accentColor }
    private var english: Bool { settings.appLanguage == .en }
    private func copy(_ zh: String, _ en: String) -> String { english ? en : zh }

    private var thread: WeiboCommentThread { monitor.comments.thread(for: entry.post.mid) }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // The author bar stays put. It carries the only original-post
                // entry, and a long post used to scroll that entry away at
                // exactly the depth where it is needed.
                bylineBar
                Rectangle()
                    .fill(dividerColor)
                    .frame(height: 1)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 18) {
                        bodyBlock
                        if let original = quotedText {
                            quoteBlock(original)
                        }
                        if entry.post.isLongText {
                            longTextHint
                        }
                        mediaGrid
                        metricsRow { scrollToDiscussion(proxy) }
                        Rectangle()
                            .fill(dividerColor)
                            .frame(height: 1)
                        discussionHeader
                        newCommentsBanner
                        commentTree
                        commentFooter
                        if let issue = thread.loadMoreError, !thread.comments.isEmpty {
                            inlineError(issue)
                        }
                    }
                    .frame(maxWidth: FollowingReaderMetrics.contentMax, alignment: .leading)
                    .padding(.horizontal, FollowingReaderMetrics.horizontalPadding)
                    .padding(.top, 20)
                    .padding(.bottom, 30)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .id(entry.id)
            }
        }
        .background(retro ? RetroEditorialTokens.raisedPaper : Color(nsColor: .controlBackgroundColor))
        .task(id: entry.id) {
            await monitor.loadComments(for: entry.post)
        }
    }

    // MARK: - Post

    private var displayText: String {
        let value = entry.post.displayText
        return value.isEmpty
            ? L10n.string("weibo.feed.noText", language: settings.appLanguage)
            : value
    }

    private var quotedText: String? {
        guard let original = entry.post.retweetText,
              !original.isEmpty,
              original != entry.post.displayText
        else { return nil }
        return original
    }

    private var byline: some View {
        HStack(alignment: .center, spacing: 10) {
            FollowingAvatar(user: entry.user, size: FollowingReaderMetrics.avatarSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.user.screenName)
                    .font(.system(size: 15, weight: .semibold, design: retro ? .serif : .default))
                    .lineLimit(1)
                Text(entry.post.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button { monitor.openPost(entry.post) } label: {
                Label(copy("原网页", "Original"), systemImage: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(copy("在微博中打开这条博文", "Open this post on Weibo"))
            .accessibilityLabel(copy("在微博中打开这条博文", "Open this post on Weibo"))
        }
    }

    /// Pinned above the scroll view so the author and the original-post entry
    /// survive a long read. It aligns with the prose column instead of
    /// stretching across a wide pane.
    private var bylineBar: some View {
        byline
            .frame(maxWidth: FollowingReaderMetrics.contentMax, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FollowingReaderMetrics.horizontalPadding)
            .padding(.vertical, 11)
    }

    private var bodyBlock: some View {
        Text(displayText)
            .font(.system(size: 15.5))
            .lineSpacing(6)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: FollowingReaderMetrics.proseMax, alignment: .leading)
    }

    private func quoteBlock(_ original: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(copy("转发内容", "Reposted"))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(original)
                .font(.system(size: 14))
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 12)
        .padding(.vertical, 2)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accent.opacity(0.45))
                .frame(width: 3)
        }
        .frame(maxWidth: FollowingReaderMetrics.proseMax, alignment: .leading)
    }

    private var longTextHint: some View {
        Text(copy(
            "长微博内容可能不完整，可打开原网页查看。",
            "This long post may be incomplete. Open the original to read it in full."
        ))
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .frame(maxWidth: FollowingReaderMetrics.proseMax, alignment: .leading)
    }

    // MARK: - Media

    private var imageShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: retro ? 0 : 8, style: .continuous)
    }

    @ViewBuilder
    private var mediaGrid: some View {
        let urls = entry.post.imageURLs.compactMap(URL.init(string:))
        if urls.count == 1, let url = urls.first {
            singleImage(url)
        } else if urls.count > 1 {
            galleryGrid(urls)
        }
    }

    /// A single image keeps its own proportions. Cropping a long screenshot to
    /// a square would make it useless, so the slot is 4:3 and the image fits
    /// inside it. `Color.clear` provides the height that a bare image lacks.
    private func singleImage(_ url: URL) -> some View {
        Button { imageSelection = FollowingReaderImageSelection(urls: [url], index: 0) } label: {
            Color.clear
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: 380)
                .overlay {
                    CachedRemoteImage(
                        url: url,
                        maxPixelSize: ImageCache.pixelSize(forPoints: 380, displayScale: displayScale),
                        contentMode: .fit
                    ) {
                        ZStack {
                            Rectangle().fill(Color.primary.opacity(0.05))
                            Image(systemName: "photo")
                                .font(.system(size: 20, weight: .light))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .clipShape(imageShape)
                .overlay(imageShape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copy("查看图片", "View image"))
    }

    /// 3 × 104 matches the platform's own nine-grid convention. The old
    /// adaptive grid produced five columns at 620pt, turning nine images into
    /// a 5 + 4 strip.
    private func galleryGrid(_ urls: [URL]) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(104), spacing: 6), count: 3),
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                Button { imageSelection = FollowingReaderImageSelection(urls: urls, index: index) } label: {
                    CachedRemoteImage(
                        url: url,
                        maxPixelSize: ImageCache.pixelSize(
                            forPoints: 104,
                            displayScale: displayScale,
                            step: 64
                        )
                    ) {
                        ZStack {
                            Rectangle().fill(Color.primary.opacity(0.05))
                            Image(systemName: "photo")
                                .font(.system(size: 16, weight: .light))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 104, height: 104)
                    .clipShape(imageShape)
                    .overlay(imageShape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copy("查看图片 \(index + 1)", "View image \(index + 1)"))
            }
        }
        .frame(maxWidth: 324, alignment: .leading)
    }

    // MARK: - Interaction snapshot

    private func countText(_ value: Int?) -> String {
        guard let value else { return "—" }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private var separator: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    /// One tabular line instead of the old 4-cell adaptive grid. The grid put
    /// "Views —" in a cell that could never hold a number and let three
    /// counters start at three different x positions.
    private func metricsRow(scrollToDiscussion: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Button(action: scrollToDiscussion) {
                Text("\(copy("评论", "Comments")) \(countText(entry.post.commentCount))")
                    .fontWeight(.semibold)
                    .foregroundStyle(accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(copy("跳到评论区", "Jump to comments"))

            separator
            Text("\(copy("转发", "Reposts")) \(countText(entry.post.repostCount))")
            separator
            Text("\(copy("赞", "Likes")) \(countText(entry.post.likeCount))")

            Spacer(minLength: 8)

            if let fetchedAt = entry.post.metricsFetchedAt {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .help(
                        "\(copy("互动数据采集于", "Interaction snapshot")) "
                            + fetchedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                    .accessibilityLabel(copy("互动数据采集时间", "Interaction snapshot time"))
            }
        }
        .font(.system(size: 11.5))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(maxWidth: FollowingReaderMetrics.mediaMax, alignment: .leading)
    }

    // MARK: - Discussion

    private var dividerColor: Color {
        if retro { return RetroEditorialTokens.rule.opacity(0.22) }
        return Color(nsColor: .separatorColor)
            .opacity(contrast == .increased ? 0.8 : 0.30)
    }

    private func scrollToDiscussion(_ proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo(DiscussionAnchor.id, anchor: .top)
        } else {
            withAnimation(.easeInOut(duration: 0.22)) {
                proxy.scrollTo(DiscussionAnchor.id, anchor: .top)
            }
        }
    }

    private var discussionHeader: some View {
        HStack(spacing: 8) {
            Text(copy("评论", "Comments"))
                .font(.system(size: 13, weight: .semibold, design: retro ? .serif : .default))

            if thread.isRefreshing {
                ProgressView().controlSize(.mini)
            }

            Spacer(minLength: 8)

            Button {
                Task { await monitor.loadComments(for: entry.post, force: true) }
            } label: {
                // Fixed 20pt slot: the spinning state must not shift the row.
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(thread.isRefreshing)
            .accessibilityLabel(copy("刷新评论", "Refresh comments"))
        }
        .frame(maxWidth: FollowingReaderMetrics.mediaMax, alignment: .leading)
        .id(DiscussionAnchor.id)
    }

    /// A background refresh never reorders visible rows: the fresh comments
    /// wait behind `newComments` until the reader applies them. Without this
    /// entry, a refresh would look like it did nothing until the next launch.
    @ViewBuilder
    private var newCommentsBanner: some View {
        if let title = FollowingDiscussionBanner.title(
            newComments: thread.newComments,
            language: settings.appLanguage
        ) {
            Button {
                Task { await monitor.comments.applyPending(mid: entry.post.mid) }
            } label: {
                Label(title, systemImage: "arrow.up.circle")
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(accent.opacity(0.08))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .frame(maxWidth: FollowingReaderMetrics.mediaMax, alignment: .leading)
            .accessibilityLabel(FollowingDiscussionBanner.accessibilityLabel(
                newComments: thread.newComments,
                language: settings.appLanguage
            ))
        }
    }

    @ViewBuilder
    private var commentTree: some View {
        if thread.comments.isEmpty {
            commentPlaceholder
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(thread.comments.enumerated()), id: \.element.id) { index, comment in
                    FollowingCommentRow(
                        comment: comment,
                        language: settings.appLanguage,
                        accent: accent,
                        retro: retro,
                        onOpenOriginal: { monitor.openPost(entry.post) }
                    )
                    if index < thread.comments.count - 1 {
                        Rectangle()
                            .fill(dividerColor)
                            .frame(height: 1)
                            .padding(.leading, FollowingReaderMetrics.commentDividerInset)
                    }
                }
            }
            .frame(maxWidth: FollowingReaderMetrics.mediaMax, alignment: .leading)
        }
    }

    @ViewBuilder
    private var commentPlaceholder: some View {
        switch thread.state {
        case .idle:
            if settings.weiboCommentsAutoLoad {
                commentSkeleton
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(copy("已关闭自动加载评论。", "Comment auto-load is off."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button(copy("加载评论", "Load comments")) {
                        Task { await monitor.loadComments(for: entry.post, force: true) }
                    }
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
                    .controlSize(.small)
                }
            }
        case .loadingFirst:
            commentSkeleton
        case .empty:
            emptyComments
        case .authRequired:
            VStack(alignment: .leading, spacing: 8) {
                Text(copy("登录微博后加载评论。", "Sign in to Weibo to load comments."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Button(copy("登录微博", "Sign in")) { monitor.openLogin() }
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
                    .controlSize(.small)
            }
        case .rateLimited(let until):
            VStack(alignment: .leading, spacing: 8) {
                Text(issueMessage(.rateLimited(until: until)))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Button(copy("打开原网页", "Open original")) { monitor.openPost(entry.post) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(accent)
            }
        case .failed(let issue, let canRetry):
            VStack(alignment: .leading, spacing: 8) {
                Text(issueMessage(issue))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if canRetry {
                        Button(copy("重试", "Retry")) {
                            Task { await monitor.loadComments(for: entry.post, force: true) }
                        }
                        .buttonStyle(EditorialActionButtonStyle(compact: true))
                        .controlSize(.small)
                    }
                    Button(copy("打开原网页", "Open original")) { monitor.openPost(entry.post) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(accent)
                }
            }
        case .loaded, .loadingMore:
            emptyComments
        }
    }

    private var emptyComments: some View {
        Text(copy("暂无评论", "No comments yet"))
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
    }

    private var commentSkeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(Color.secondary.opacity(0.10))
                        .frame(width: FollowingReaderMetrics.commentAvatar, height: FollowingReaderMetrics.commentAvatar)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.10))
                            .frame(width: 90, height: 9)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.08))
                            .frame(height: 10)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.08))
                            .frame(width: 180, height: 10)
                    }
                }
            }
        }
        .padding(.leading, FollowingReaderMetrics.commentInset)
        .accessibilityLabel(copy("正在加载评论", "Loading comments"))
    }

    @ViewBuilder
    private var commentFooter: some View {
        if thread.state == .loadingMore {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(copy("正在加载更多评论…", "Loading more comments…"))
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } else if thread.canLoadMore {
            VStack(spacing: 2) {
                Button(copy("加载更多评论", "Load more comments")) {
                    Task { await monitor.loadMoreComments(for: entry.post) }
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))
                .controlSize(.small)

                Color.clear
                    .frame(height: 1)
                    .onScrollVisibilityChange(threshold: 0.01) { visible in
                        guard visible else { return }
                        Task { await monitor.loadMoreComments(for: entry.post) }
                    }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        } else if thread.comments.count >= WeiboCommentLimits.maxComments {
            Button(copy("查看全部评论", "View all comments")) { monitor.openPost(entry.post) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(accent)
                .padding(.vertical, 6)
        }
    }

    private func inlineError(_ issue: WeiboCommentIssue) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(issueMessage(issue))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            switch issue {
            case .authRequired:
                Button(copy("登录", "Sign in")) { monitor.openLogin() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(accent)
            case .rateLimited, .challenge, .parseChanged:
                Button(copy("原网页", "Original")) { monitor.openPost(entry.post) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(accent)
            case .network, .server, .unknown:
                Button(copy("重试", "Retry")) {
                    Task { await monitor.loadMoreComments(for: entry.post) }
                }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(accent)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.06))
    }

    private func issueMessage(_ issue: WeiboCommentIssue) -> String {
        switch issue {
        case .network:
            return copy("网络不可用，评论加载失败。", "Comments could not load because the network is unavailable.")
        case .server:
            return copy("微博服务器暂时不可用。", "Weibo's server is temporarily unavailable.")
        case .parseChanged:
            return copy("评论接口可能已更新，可打开原网页查看。", "The comment interface may have changed. Open the original to view comments.")
        case .challenge:
            return copy("微博要求验证，暂时无法加载评论。", "Weibo requires verification, so comments cannot load right now.")
        case .authRequired:
            return copy("登录状态已失效。", "Your Weibo session has expired.")
        case .rateLimited(let until):
            return copy(
                "评论请求过于频繁，请稍后再试（\(until.formatted(date: .omitted, time: .shortened))）。",
                "Comments are rate limited. Try again around \(until.formatted(date: .omitted, time: .shortened))."
            )
        case .unknown:
            return copy("评论加载失败，请稍后重试。", "Comments could not load. Try again later.")
        }
    }
}

private enum DiscussionAnchor {
    static let id = "following-reader-discussion"
}

/// One row in the discussion tree.
///
/// Links are real `AttributedString` links. That is why the row is not wrapped
/// in a `Button`: a link inside a button label cannot be clicked.
private struct FollowingCommentRow: View {
    let comment: WeiboComment
    let language: AppLanguage
    let accent: Color
    let retro: Bool
    let onOpenOriginal: () -> Void

    @Environment(\.displayScale) private var displayScale

    private var english: Bool { language == .en }
    private func copy(_ zh: String, _ en: String) -> String { english ? en : zh }

    /// `Text(_:style:.relative)` renders "15 分钟 0 秒". The short form matches
    /// the feed cards and stays one token wide in the row header.
    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: language.bcp47)
        formatter.unitsStyle = .short
        return formatter.localizedString(for: comment.createdAt, relativeTo: Date())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                header
                commentBody
                if let like = comment.likeCount, like > 0 {
                    likeLine(like)
                }
            }
        }
        .padding(.leading, FollowingReaderMetrics.commentInset)
        .padding(.trailing, 2)
        .padding(.vertical, 10)
        .overlay(alignment: .leading) {
            if comment.isAuthor {
                Capsule()
                    .fill(accent.opacity(0.45))
                    .frame(width: 2.5)
                    .padding(.vertical, 9)
            }
        }
        // `.contain`, not `.combine`: combining would merge the links into a
        // single static element that VoiceOver can read but not activate.
        .accessibilityElement(children: .contain)
        .contextMenu { menu }
    }

    @ViewBuilder
    private var avatar: some View {
        let initial = Text(String(comment.screenName.prefix(1)))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(accent)
        if let raw = comment.avatarURL, let url = URL(string: raw) {
            CachedRemoteImage(
                url: url,
                maxPixelSize: ImageCache.pixelSize(
                    forPoints: FollowingReaderMetrics.commentAvatar,
                    displayScale: displayScale,
                    step: 64
                )
            ) {
                ZStack {
                    Circle().fill(accent.opacity(0.14))
                    initial
                }
            }
            .frame(width: FollowingReaderMetrics.commentAvatar, height: FollowingReaderMetrics.commentAvatar)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        } else {
            ZStack {
                Circle().fill(accent.opacity(0.14))
                initial
            }
            .frame(width: FollowingReaderMetrics.commentAvatar, height: FollowingReaderMetrics.commentAvatar)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(comment.screenName)
                .font(.system(size: 12, weight: .semibold, design: retro ? .serif : .default))
                .foregroundStyle(comment.isAuthor ? accent : .primary)
                .lineLimit(1)

            if comment.isAuthor {
                Text(copy("作者", "Author"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            }

            if let replyTo = comment.replyToName, !replyTo.isEmpty {
                Text(copy("回复 @\(replyTo)", "to @\(replyTo)"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(relativeTime)
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var commentBody: some View {
        if let runs = comment.runs, !runs.isEmpty {
            Text(attributed(runs))
                .font(.system(size: 13))
                .lineSpacing(4.5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(comment.text)
                .font(.system(size: 13))
                .lineSpacing(4.5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func attributed(_ runs: [WeiboCommentRun]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            switch run.kind {
            case .link, .mention, .topic:
                // Re-validate even though the parser already did: the runs can
                // come back from a cache file on disk.
                if let raw = run.url, let url = ReaderNavigationPolicy.allowedURL(raw) {
                    piece.link = url
                }
                piece.foregroundColor = accent
                if run.kind == .link {
                    piece.underlineStyle = .single
                }
            case .text:
                break
            }
            result.append(piece)
        }
        return result
    }

    private func likeLine(_ count: Int) -> some View {
        Label("\(count)", systemImage: "hand.thumbsup")
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.top, 1)
            .accessibilityLabel(copy("\(count) 人赞", "\(count) likes"))
    }

    private var firstLink: URL? {
        guard let runs = comment.runs else { return nil }
        for run in runs where run.kind == .link {
            if let raw = run.url, let url = URL(string: raw) { return url }
        }
        return nil
    }

    @ViewBuilder
    private var menu: some View {
        if let link = firstLink {
            Button(L10n.string("weibo.comments.copyLink", language: language)) {
                copyToPasteboard(link.absoluteString)
            }
        }
        Button(L10n.string("weibo.comments.copyText", language: language)) {
            copyToPasteboard(comment.text)
        }
        Divider()
        Button(L10n.string("weibo.comments.openOriginal", language: language), action: onOpenOriginal)
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}
