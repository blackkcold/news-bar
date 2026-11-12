import SwiftUI

/// The following feed has different reading semantics from a third-party
/// article: account, post and discussion stay together in the same workspace.
struct FollowingReaderWorkspace: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @AppStorage("followingReaderSelectedPostID") private var lastSelectedID = ""

    let monitor: WeiboMonitorViewModel
    @Binding var filter: WeiboFollowingFilter
    @Binding var searchText: String
    @Binding var accountUID: String?
    let isActive: Bool
    let onOpenSettings: () -> Void

    @State private var selectedID = ""
    @State private var keepSelectedAfterRead = false
    @State private var showCollapsed = false
    @State private var showAccounts = true
    @State private var accountSearch = ""
    @State private var imageSelection: FollowingReaderImageSelection?

    private var retro: Bool { settings.appTheme == .retroEditorial }
    private var accent: Color { retro ? RetroEditorialTokens.brick : .accentColor }
    private var english: Bool { settings.appLanguage == .en }
    private func copy(_ zh: String, _ en: String) -> String { english ? en : zh }
    private func countText(_ value: Int?) -> String {
        guard let value else { return "—" }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private var query: FollowingFeedQuery {
        FollowingFeedQuery(
            filter: filter,
            accountUID: accountUID,
            searchText: searchText,
            includeCollapsed: !settings.weiboMonitorRelevanceEnabled
        )
    }

    private var entries: FollowingFeedContents {
        FollowingFeedModel.contents(snapshot: monitor.snapshot, query: query)
    }

    private func selectedEntry(in entries: [FollowingPostEntry]) -> FollowingPostEntry? {
        if keepSelectedAfterRead, filter == .unread,
           let post = monitor.snapshot.postsByUID.values.lazy.flatMap({ $0 }).first(where: { $0.mid == selectedID }),
           let user = monitor.snapshot.users.first(where: { $0.uid == post.uid }) {
            return FollowingPostEntry(post: post, user: user)
        }
        return FollowingFeedModel.readerSelection(currentID: selectedID, entries: entries)
    }

    var body: some View {
        GeometryReader { geometry in
            let contents = entries
            let hiddenEntries: [FollowingPostEntry] = showCollapsed ? contents.collapsedPosts.compactMap { post in
                monitor.snapshot.users.first(where: { $0.uid == post.uid }).map { FollowingPostEntry(post: post, user: $0) }
            } : []
            let selection = selectedEntry(in: contents.entries + hiddenEntries)
            HSplitView {
                if geometry.size.width >= 1050 && showAccounts {
                    accountSidebar
                        .frame(minWidth: 165, idealWidth: 190, maxWidth: 260)
                }
                postList(contents: contents, selected: selection, canToggleAccounts: geometry.size.width >= 1050)
                    .frame(minWidth: 285, idealWidth: 320, maxWidth: 420)
                reader(selection)
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selectedID.isEmpty {
                selectedID = FollowingFeedModel.readerSelection(currentID: lastSelectedID, entries: entries.entries)?.id ?? ""
            }
            if isActive { activate() }
        }
        .onChange(of: isActive) { _, active in
            if active { activate() } else { WeiboFeedPresence.setVisible(false) }
        }
        .onDisappear { WeiboFeedPresence.setVisible(false) }
        .onChange(of: filter) { _, _ in resetSelection() }
        .onChange(of: accountUID) { _, _ in resetSelection() }
        .onChange(of: searchText) { _, _ in resetSelection() }
        .onChange(of: monitor.snapshot.users.map(\.uid)) { _, uids in
            if let accountUID, !uids.contains(accountUID) { self.accountUID = nil }
        }
        .sheet(item: $imageSelection) { selection in
            FollowingReaderImageSheet(urls: selection.urls, initialIndex: selection.index)
                .environment(settings)
        }
    }

    private func activate() {
        WeiboFeedPresence.setVisible(true)
        Task { await monitor.start() }
    }

    private func resetSelection() {
        selectedID = FollowingFeedModel.readerSelection(currentID: selectedID, entries: entries.entries)?.id ?? ""
        keepSelectedAfterRead = false
    }

    private func select(_ entry: FollowingPostEntry) {
        selectedID = entry.id
        lastSelectedID = entry.id
        keepSelectedAfterRead = true
        if !entry.post.read {
            Task { await monitor.markRead(mid: entry.post.mid, uid: entry.post.uid) }
        }
    }

    private var accountSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text(copy("关注", "Following"))
                    .font(.system(size: 22, weight: .bold, design: retro ? .serif : .default))
                Text(copy("\(monitor.snapshot.users.count) 位博主 · \(monitor.snapshot.unreadCount) 条未读", "\(monitor.snapshot.users.count) accounts · \(monitor.snapshot.unreadCount) unread"))
                    .font(.caption).foregroundStyle(.secondary)
                TextField(copy("搜索博主", "Search accounts"), text: $accountSearch)
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 8)
            }
            .padding(16)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    sidebarButton(title: copy("全部动态", "All posts"), symbol: "tray.full", count: monitor.snapshot.unreadCount, selected: accountUID == nil) {
                        accountUID = nil
                    }
                    Text(copy("我的关注", "ACCOUNTS"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.top, 18).padding(.bottom, 5)
                    ForEach(filteredUsers) { user in
                        let unread = (monitor.snapshot.postsByUID[user.uid] ?? []).filter { !$0.read && !$0.isCollapsedByRelevance }.count
                        Button { accountUID = user.uid } label: {
                            HStack(spacing: 8) {
                                FollowingAvatar(user: user, size: 25)
                                Text(user.screenName.isEmpty ? "UID \(user.uid)" : user.screenName)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if unread > 0 { Text("\(unread)").font(.caption2.monospacedDigit()).foregroundStyle(accent) }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(selectionFill(accountUID == user.uid))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }.padding(.horizontal, 8)
            }
            Divider()
            Button(action: onOpenSettings) {
                Label(copy("管理关注", "Manage accounts"), systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .buttonStyle(.plain)
        }
        .frame(maxHeight: .infinity)
        .background(retro ? RetroEditorialTokens.paper : Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private var filteredUsers: [WeiboMonitorUser] {
        let search = accountSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return monitor.snapshot.users
            .filter { search.isEmpty || $0.screenName.localizedCaseInsensitiveContains(search) || $0.uid.contains(search) }
            .sorted { lhs, rhs in
                if lhs.priority.rank != rhs.priority.rank { return lhs.priority.rank < rhs.priority.rank }
                return lhs.screenName.localizedCaseInsensitiveCompare(rhs.screenName) == .orderedAscending
            }
    }

    private func selectionFill(_ selected: Bool) -> Color {
        selected ? accent.opacity(retro ? 0.14 : 0.10) : .clear
    }

    private func sidebarButton(title: String, symbol: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if count > 0 { Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(accent) }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(selectionFill(selected))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func postList(contents: FollowingFeedContents, selected: FollowingPostEntry?, canToggleAccounts: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            listHeader(canToggleAccounts: canToggleAccounts)
            if monitor.snapshot.loginState == .expired || monitor.snapshot.loginState == .anonymous {
                Button(action: monitor.openLogin) {
                    Label(copy("微博登录不可用，点击登录", "Weibo login unavailable. Sign in"), systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.caption).foregroundStyle(accent)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.buttonStyle(.plain)
            }
            if !monitor.snapshot.isOnline {
                Label(copy("离线 · 显示缓存", "Offline · showing cached posts"), systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 8)
            }
            if monitor.snapshot.gapSuspectedCount > 0 {
                Button { Task { await monitor.clearGap() } } label: {
                    Label(L10n.string("weibo.accounts.gapHint", language: settings.appLanguage), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.leading)
                }.buttonStyle(.plain).padding(.horizontal, 14).padding(.bottom, 8)
            }
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !contents.collapsedPosts.isEmpty {
                        Button {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { showCollapsed.toggle() }
                        } label: {
                            HStack {
                                Text(L10n.string("weibo.relevance.collapsedCount", language: settings.appLanguage, contents.collapsedPosts.count))
                                Spacer()
                                Image(systemName: showCollapsed ? "chevron.up" : "chevron.down")
                            }.font(.caption).foregroundStyle(.secondary).padding(12)
                        }.buttonStyle(.plain)
                        if showCollapsed {
                            ForEach(contents.collapsedPosts) { post in
                                if let user = monitor.snapshot.users.first(where: { $0.uid == post.uid }) {
                                    postRow(FollowingPostEntry(post: post, user: user), selected: selected?.id == post.mid)
                                }
                            }
                        }
                    }
                    ForEach(contents.entries) { entry in
                        postRow(entry, selected: selected?.id == entry.id)
                    }
                    if contents.entries.isEmpty && contents.collapsedPosts.isEmpty {
                        Text(copy("没有符合条件的动态", "No matching posts"))
                            .font(.callout).foregroundStyle(.secondary).padding(24)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(retro ? RetroEditorialTokens.raisedPaper : Color(nsColor: .windowBackgroundColor))
    }

    private func listHeader(canToggleAccounts: Bool) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                if canToggleAccounts {
                    Button { showAccounts.toggle() } label: { Image(systemName: "sidebar.left") }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showAccounts ? copy("收起账号栏", "Hide accounts") : copy("显示账号栏", "Show accounts"))
                }
                Text(copy("最新动态", "Latest posts"))
                    .font(.system(size: 19, weight: .bold, design: retro ? .serif : .default))
                Spacer()
                Menu {
                    Button(copy("检查更新", "Check for updates")) { Task { await monitor.checkAll() } }
                    Button(copy("全部标为已读", "Mark all as read")) { Task { await monitor.markAllRead() } }
                    if let until = monitor.snapshot.pausedUntil, until > Date() {
                        Button(copy("恢复监控", "Resume monitoring")) { Task { await monitor.resumeAll() } }
                    } else {
                        Button(copy("暂停一小时", "Pause for an hour")) { Task { await monitor.pauseAll() } }
                    }
                    Button(copy("管理关注", "Manage accounts"), action: onOpenSettings)
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel(copy("关注操作", "Following actions"))
            }
            TextField(copy("搜索关注动态", "Search posts"), text: $searchText)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                ForEach(WeiboFollowingFilter.allCases) { item in
                    DashboardFilterChip(title: L10n.string(item.titleKey, language: settings.appLanguage), isSelected: filter == item) { filter = item }
                }
                Spacer(minLength: 0)
                Menu {
                    Button(copy("所有账号", "All accounts")) { accountUID = nil }
                    ForEach(monitor.snapshot.users) { user in
                        Button(user.screenName) { accountUID = user.uid }
                    }
                } label: { Image(systemName: "person.2").foregroundStyle(.secondary) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel(copy("筛选账号", "Filter accounts"))
            }
        }.padding(14)
    }

    private func postRow(_ entry: FollowingPostEntry, selected: Bool) -> some View {
        Button { select(entry) } label: {
            HStack(alignment: .top, spacing: 10) {
                FollowingAvatar(user: entry.user, size: 28)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(entry.user.screenName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        if !entry.post.read { Circle().fill(accent).frame(width: 5, height: 5) }
                        Spacer(minLength: 0)
                        Text(entry.post.createdAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(entry.post.displayText.isEmpty ? L10n.string("weibo.feed.noText", language: settings.appLanguage) : entry.post.displayText)
                        .font(.system(size: 12.5)).lineSpacing(2).lineLimit(4)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    if !entry.post.imageURLs.isEmpty || entry.post.commentCount != nil {
                        HStack(spacing: 12) {
                            if !entry.post.imageURLs.isEmpty {
                                Label(copy("\(entry.post.imageURLs.count) 张图片", "\(entry.post.imageURLs.count) images"), systemImage: "photo")
                            }
                            if let count = entry.post.commentCount {
                                Label(countText(count), systemImage: "bubble.left")
                            }
                        }.font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
            .background(selectionFill(selected))
            .overlay(alignment: .leading) { if selected { Rectangle().fill(accent).frame(width: 3) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.user.screenName), \(entry.post.displayText)")
        .accessibilityValue(entry.post.read ? "" : copy("未读", "Unread"))
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    @ViewBuilder
    private func reader(_ entry: FollowingPostEntry?) -> some View {
        if let entry {
            VStack(spacing: 0) {
                HStack {
                    Text(copy("博文阅读", "Post reader")).font(.headline)
                    Spacer()
                    Button(copy("打开原网页", "Open original")) { monitor.openPost(entry.post) }
                        .buttonStyle(EditorialActionButtonStyle(compact: true))
                }.padding(.horizontal, 20).padding(.vertical, 13)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 10) {
                            FollowingAvatar(user: entry.user, size: 38)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.user.screenName).font(.headline)
                                Text(entry.post.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        Text(entry.post.displayText.isEmpty ? L10n.string("weibo.feed.noText", language: settings.appLanguage) : entry.post.displayText)
                            .font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let original = entry.post.retweetText, !original.isEmpty, original != entry.post.displayText {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(copy("转发内容", "Reposted content")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(original).font(.callout).lineSpacing(3).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                                .background(Color.secondary.opacity(0.08))
                        }
                        if entry.post.isLongText {
                            Text(copy("长微博内容可能不完整，可打开原网页查看。", "This long post may be incomplete. Open the original to read it in full."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        imageGrid(entry.post.imageURLs)
                        Divider()
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), alignment: .leading)], alignment: .leading, spacing: 10) {
                            Label(copy("阅读量 —", "Views —"), systemImage: "eye")
                            Label("\(copy("评论", "Comments")) \(countText(entry.post.commentCount))", systemImage: "bubble.left")
                            Label("\(copy("转发", "Reposts")) \(countText(entry.post.repostCount))", systemImage: "arrow.2.squarepath")
                            Label("\(copy("赞", "Likes")) \(countText(entry.post.likeCount))", systemImage: "heart")
                        }.font(.caption).foregroundStyle(.secondary)
                        if let fetchedAt = entry.post.metricsFetchedAt {
                            Text("\(copy("互动数据采集于", "Interaction snapshot")) \(fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Divider()
                        commentsSection(entry)
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(24).frame(maxWidth: .infinity, alignment: .top)
                }.id(entry.id)
            }
            .background(retro ? RetroEditorialTokens.raisedPaper : Color(nsColor: .textBackgroundColor))
            .task(id: entry.id) {
                await monitor.loadComments(for: entry.post)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "text.book.closed").font(.largeTitle).foregroundStyle(.tertiary)
                Text(copy("选择一条博文开始阅读", "Select a post to read"))
                    .font(.headline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Comments

    @ViewBuilder
    private func commentsSection(_ entry: FollowingPostEntry) -> some View {
        let thread = monitor.comments.thread(for: entry.post.mid)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(copy("评论", "Comments")).font(.headline)
                if thread.displayTotal > 0 {
                    Text("\(thread.displayTotal)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if thread.isRefreshing {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                Button {
                    Task { await monitor.loadComments(for: entry.post, force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(thread.isRefreshing)
                .accessibilityLabel(copy("刷新评论", "Refresh comments"))
            }

            if thread.newComments > 0 {
                Button {
                    Task { await monitor.comments.applyPending(mid: entry.post.mid) }
                } label: {
                    Label(
                        copy("有 \(thread.newComments) 条新评论 · 显示", "\(thread.newComments) new comments · Show"),
                        systemImage: "arrow.up.circle"
                    )
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(accent.opacity(0.08))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
            }

            if thread.comments.isEmpty {
                commentPlaceholder(entry, thread: thread)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(thread.comments) { comment in
                        commentRow(comment)
                        Divider().opacity(0.35)
                    }
                }
                commentFooter(entry, thread: thread)
            }

            if let issue = thread.loadMoreError, !thread.comments.isEmpty {
                commentInlineError(entry, issue: issue)
            }
        }
    }

    @ViewBuilder
    private func commentPlaceholder(_ entry: FollowingPostEntry, thread: WeiboCommentThread) -> some View {
        switch thread.state {
        case .idle:
            if settings.weiboCommentsAutoLoad {
                commentSkeleton
            } else {
                Button(copy("加载评论", "Load comments")) {
                    Task { await monitor.loadComments(for: entry.post, force: true) }
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))
                .controlSize(.small)
            }
        case .loadingFirst:
            commentSkeleton
        case .empty:
            Text(copy("暂无评论", "No comments yet"))
                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
        case .authRequired:
            VStack(alignment: .leading, spacing: 8) {
                Text(copy("登录微博后加载评论。", "Sign in to Weibo to load comments."))
                    .font(.callout).foregroundStyle(.secondary)
                Button(copy("登录微博", "Sign in")) { monitor.openLogin() }
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
                    .controlSize(.small)
            }
        case .rateLimited(let until):
            VStack(alignment: .leading, spacing: 8) {
                Text(issueMessage(.rateLimited(until: until)))
                    .font(.callout).foregroundStyle(.secondary)
                Button(copy("打开原网页", "Open original")) { monitor.openPost(entry.post) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(accent)
            }
        case .failed(let issue, let canRetry):
            VStack(alignment: .leading, spacing: 8) {
                Text(issueMessage(issue)).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if canRetry {
                        Button(copy("重试", "Retry")) {
                            Task { await monitor.loadComments(for: entry.post, force: true) }
                        }
                        .buttonStyle(EditorialActionButtonStyle(compact: true))
                        .controlSize(.small)
                    }
                    Button(copy("打开原网页", "Open original")) { monitor.openPost(entry.post) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(accent)
                }
            }
        case .loaded, .loadingMore:
            Text(copy("暂无评论", "No comments yet"))
                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func commentFooter(_ entry: FollowingPostEntry, thread: WeiboCommentThread) -> some View {
        if thread.state == .loadingMore {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(copy("正在加载更多评论…", "Loading more comments…"))
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 8)
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
                .buttonStyle(.plain).font(.caption).foregroundStyle(accent)
                .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func commentInlineError(_ entry: FollowingPostEntry, issue: WeiboCommentIssue) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(issueMessage(issue)).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            switch issue {
            case .authRequired:
                Button(copy("登录", "Sign in")) { monitor.openLogin() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(accent)
            case .rateLimited, .challenge, .parseChanged:
                Button(copy("原网页", "Original")) { monitor.openPost(entry.post) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(accent)
            case .network, .server, .unknown:
                Button(copy("重试", "Retry")) {
                    Task { await monitor.loadMoreComments(for: entry.post) }
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(accent)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.06))
    }

    private var commentSkeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(Color.secondary.opacity(0.10))
                        .frame(width: 24, height: 24)
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
        .accessibilityLabel(copy("正在加载评论", "Loading comments"))
    }

    private func commentRow(_ comment: WeiboComment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            commentAvatar(comment)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.screenName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    if comment.isAuthor {
                        Text(copy("作者", "Author"))
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(accent.opacity(0.12))
                    }
                    Spacer(minLength: 4)
                    Text(comment.createdAt, style: .relative)
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(comment.text)
                    .font(.system(size: 12.5)).lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let like = comment.likeCount, like > 0 {
                    Label("\(like)", systemImage: "hand.thumbsup")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func commentAvatar(_ comment: WeiboComment) -> some View {
        let initial = Text(String(comment.screenName.prefix(1)))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(accent)
        if let raw = comment.avatarURL, let url = URL(string: raw) {
            CachedRemoteImage(
                url: url,
                maxPixelSize: ImageCache.pixelSize(forPoints: 24, displayScale: displayScale, step: 64)
            ) {
                ZStack {
                    Circle().fill(accent.opacity(0.14))
                    initial
                }
            }
            .frame(width: 24, height: 24)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        } else {
            ZStack {
                Circle().fill(accent.opacity(0.14))
                initial
            }
            .frame(width: 24, height: 24)
        }
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

    @ViewBuilder
    private func imageGrid(_ urls: [String]) -> some View {
        let valid = urls.compactMap(URL.init(string:))
        if !valid.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 180), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(Array(valid.enumerated()), id: \.offset) { index, url in
                    Button { imageSelection = FollowingReaderImageSelection(urls: valid, index: index) } label: {
                        CachedRemoteImage(url: url, maxPixelSize: 400) {
                            Rectangle().fill(Color.secondary.opacity(0.1)).overlay { Image(systemName: "photo").foregroundStyle(.tertiary) }
                        }
                        .frame(height: 110).clipped().clipShape(RoundedRectangle(cornerRadius: retro ? 0 : 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(copy("查看图片 \(index + 1)", "View image \(index + 1)"))
                }
            }
        }
    }
}

private struct FollowingReaderImageSelection: Identifiable {
    let id = UUID()
    let urls: [URL]
    let index: Int
}

private struct FollowingReaderImageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    let urls: [URL]
    @State private var index: Int
    @State private var image: NSImage?
    @State private var imageFailed = false

    init(urls: [URL], initialIndex: Int) {
        self.urls = urls
        _index = State(initialValue: initialIndex)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("\(index + 1) / \(urls.count)").font(.caption.monospacedDigit())
                Spacer()
                Button(settings.appLanguage == .en ? "Close" : "关闭") { dismiss() }
            }
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if imageFailed {
                    Text(settings.appLanguage == .en ? "Image unavailable. Try again later." : "图片加载失败，请稍后重试。")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button { index -= 1 } label: { Label(settings.appLanguage == .en ? "Previous" : "上一张", systemImage: "chevron.left") }
                    .disabled(index == 0)
                Spacer()
                Button { index += 1 } label: { Label(settings.appLanguage == .en ? "Next" : "下一张", systemImage: "chevron.right") }
                    .disabled(index >= urls.count - 1)
            }
        }
        .padding(20).frame(minWidth: 600, minHeight: 500)
        .task(id: index) {
            image = nil
            imageFailed = false
            let loaded = await ImageCache.shared.image(for: urls[index], maxPixelSize: 2000)
            guard !Task.isCancelled else { return }
            image = loaded
            imageFailed = loaded == nil
        }
    }
}
