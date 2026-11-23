import SwiftUI

/// The following feed has different reading semantics from a third-party
/// article: account, post and discussion stay together in the same workspace.
///
/// Width handling lives here, not in the dashboard split. The dashboard gives
/// this view the full content width while the reader is closed, and the
/// workspace decides for itself how many columns fit.
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
                if geometry.size.width >= WorkspaceLayout.threeColumn && showAccounts {
                    accountSidebar
                        .frame(minWidth: 165, idealWidth: 192, maxWidth: 240)
                }
                postList(
                    contents: contents,
                    selected: selection,
                    canToggleAccounts: geometry.size.width >= WorkspaceLayout.threeColumn
                )
                .frame(minWidth: 280, idealWidth: 312, maxWidth: 380)
                reader(selection)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
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
            FollowingReaderPane(
                entry: entry,
                monitor: monitor,
                imageSelection: $imageSelection
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "text.book.closed")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text(copy("选择一条博文开始阅读", "Select a post to read"))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(retro ? RetroEditorialTokens.raisedPaper : Color(nsColor: .controlBackgroundColor))
        }
    }
}

/// Column floors for the workspace itself, measured in the width the dashboard
/// gives this view.
///
/// There is deliberately no "narrow, single column" branch here. While a web
/// reader covers the window the dashboard hands this view a 320–480pt frame
/// and hides it; branching on that width would rebuild the split and drop the
/// list's scroll position the moment the reader closes. The three panes stay
/// mounted and only the account rail drops out.
private enum WorkspaceLayout {
    static let threeColumn: CGFloat = 1040
}
