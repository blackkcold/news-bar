import SwiftUI

enum WeiboFollowingFilter: String, CaseIterable, Identifiable {
    case all
    case unread
    case p0

    var id: String { rawValue }
    var titleKey: String { "weibo.feed.filter.\(rawValue)" }
}

/// Dashboard → Following. It is a browse mode, not a source filter: the feed
/// groups posts by account, keeps unread weight visible, and opens the original
/// post in the existing reader (with the reader's cookie session).
struct WeiboFollowingFeedView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let monitor: WeiboMonitorViewModel?
    @Binding var filter: WeiboFollowingFilter
    @Binding var searchText: String
    @Binding var mode: DashboardBrowseMode
    @Binding var accountUID: String?
    let followingUnread: Int
    var badgeEnabled = true
    var availableWidth: CGFloat = 920
    let onOpenSettings: () -> Void

    @State private var showCollapsed = false

    private var accent: Color {
        settings.appTheme == .retroEditorial ? RetroEditorialTokens.brick : Color.accentColor
    }

    private var language: AppLanguage { settings.appLanguage }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsFallbackModeControl {
                DashboardModeSegmentedControl(
                    mode: $mode,
                    followingUnread: followingUnread,
                    badgeEnabled: badgeEnabled
                )
            }

            Group {
                if let monitor {
                    content(monitor)
                } else {
                    unavailableState
                }
            }
        }
        .onAppear {
            WeiboFeedPresence.setVisible(true)
            guard let monitor else { return }
            Task {
                await monitor.start()
                await monitor.refresh()
            }
        }
        .onDisappear {
            WeiboFeedPresence.setVisible(false)
        }
    }

    /// The filter bar owns the mode control while the feed is usable. When the
    /// monitor is off, has no accounts, or is unavailable, the filter bar is
    /// not rendered; keep a fallback switch so the user can always leave the
    /// following page.
    private var showsFallbackModeControl: Bool {
        guard let monitor else { return true }
        let snapshot = monitor.snapshot
        return !snapshot.isEnabled || snapshot.users.isEmpty
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ monitor: WeiboMonitorViewModel) -> some View {
        let snapshot = monitor.snapshot

        VStack(alignment: .leading, spacing: 14) {
            header(monitor, snapshot: snapshot)

            if let banner = authBanner(monitor, snapshot: snapshot) {
                bannerRow(banner)
            }
            if snapshot.gapSuspectedCount > 0 {
                bannerRow(
                    FeedBanner(
                        symbol: "exclamationmark.triangle",
                        tint: .orange,
                        text: L10n.string("weibo.accounts.gapHint", language: language),
                        actionTitle: L10n.string("weibo.gap.ack", language: language),
                        action: { Task { await monitor.clearGap() } }
                    )
                )
            }
            if !snapshot.isOnline {
                bannerRow(
                    FeedBanner(
                        symbol: "wifi.slash",
                        tint: .secondary,
                        text: L10n.string("weibo.feed.offline", language: language),
                        actionTitle: nil,
                        action: nil
                    )
                )
            }

            if !snapshot.isEnabled {
                disabledState(monitor)
            } else if snapshot.users.isEmpty {
                emptyState
            } else {
                filterBar(snapshot: snapshot)
                feed(monitor, snapshot: snapshot)
            }
        }
        .frame(maxWidth: 920)
        .frame(maxWidth: .infinity, alignment: .center)
        .onChange(of: snapshot.users.map(\.uid)) { _, uids in
            if let accountUID, !uids.contains(accountUID) {
                self.accountUID = nil
            }
        }
    }

    private func header(
        _ monitor: WeiboMonitorViewModel,
        snapshot: WeiboMonitorSnapshot
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            wideHeader(monitor, snapshot: snapshot)
            compactHeader(monitor, snapshot: snapshot)
        }
    }

    private func wideHeader(
        _ monitor: WeiboMonitorViewModel,
        snapshot: WeiboMonitorSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                headerTitle(size: 24)
                headerSummary(snapshot)
                Spacer(minLength: 8)
                pauseResumeButton(monitor, snapshot: snapshot)
                markAllReadButton(monitor, snapshot: snapshot)
                checkAllButton(monitor, snapshot: snapshot)
            }
            statusLine(snapshot)
        }
    }

    /// The reader can squeeze the list pane to 320pt. Keep the title and the
    /// primary check action; move the rest into an overflow menu.
    private func compactHeader(
        _ monitor: WeiboMonitorViewModel,
        snapshot: WeiboMonitorSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                headerTitle(size: 20)
                headerSummary(snapshot)
                Spacer(minLength: 4)

                Button {
                    Task { await monitor.checkAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(EditorialActionButtonStyle(tone: .selected, compact: true))
                .controlSize(.small)
                .disabled(!snapshot.isEnabled || monitor.isWorking)
                .accessibilityLabel(L10n.string("weibo.header.checkAll", language: language))

                Menu {
                    Button(L10n.string("weibo.feed.markAllRead", language: language)) {
                        Task { await monitor.markAllRead() }
                    }
                    .disabled(snapshot.unreadCount == 0)
                    if let until = snapshot.pausedUntil, until > Date() {
                        Button(L10n.string("weibo.feed.resume", language: language)) {
                            Task { await monitor.resumeAll() }
                        }
                    } else {
                        Button(L10n.string("weibo.feed.pause1h", language: language)) {
                            Task { await monitor.pauseAll() }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!snapshot.isEnabled || monitor.isWorking)
                .accessibilityLabel(L10n.string("weibo.feed.accountMenu", language: language))
            }
            statusLine(snapshot)
        }
    }

    private func headerTitle(size: CGFloat) -> some View {
        Text(L10n.string("weibo.feed.title", language: language))
            .font(.system(size: size, weight: .bold, design: settings.appTheme == .retroEditorial ? .serif : .default))
            .lineLimit(1)
    }

    private func headerSummary(_ snapshot: WeiboMonitorSnapshot) -> some View {
        Text(
            L10n.string(
                "weibo.header.summary",
                language: language,
                snapshot.users.count,
                snapshot.unreadCount
            )
        )
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
    }

    private func pauseResumeButton(
        _ monitor: WeiboMonitorViewModel,
        snapshot: WeiboMonitorSnapshot
    ) -> some View {
        Group {
            if let until = snapshot.pausedUntil, until > Date() {
                Button(L10n.string("weibo.feed.resume", language: language)) {
                    Task { await monitor.resumeAll() }
                }
            } else {
                Button(L10n.string("weibo.feed.pause1h", language: language)) {
                    Task { await monitor.pauseAll() }
                }
            }
        }
        .buttonStyle(EditorialActionButtonStyle(compact: true))
        .controlSize(.small)
        .disabled(!snapshot.isEnabled || monitor.isWorking)
    }

    private func markAllReadButton(
        _ monitor: WeiboMonitorViewModel,
        snapshot: WeiboMonitorSnapshot
    ) -> some View {
        Button(L10n.string("weibo.feed.markAllRead", language: language)) {
            Task { await monitor.markAllRead() }
        }
        .buttonStyle(EditorialActionButtonStyle(compact: true))
        .controlSize(.small)
        .disabled(snapshot.unreadCount == 0 || !snapshot.isEnabled || monitor.isWorking)
    }

    private func checkAllButton(
        _ monitor: WeiboMonitorViewModel,
        snapshot: WeiboMonitorSnapshot
    ) -> some View {
        Button(L10n.string("weibo.header.checkAll", language: language)) {
            Task { await monitor.checkAll() }
        }
        .buttonStyle(EditorialActionButtonStyle(tone: .selected, compact: true))
        .controlSize(.small)
        .disabled(!snapshot.isEnabled || monitor.isWorking)
    }

    private func statusLine(_ snapshot: WeiboMonitorSnapshot) -> some View {
        HStack(spacing: 10) {
            loginPill(snapshot.loginState)
            if let last = snapshot.lastTickAt ?? snapshot.users.compactMap(\.lastCheckedAt).max() {
                Text(L10n.string("weibo.feed.lastCheck", language: language, formatted(last)))
            }
            if let next = snapshot.nextCheckAt {
                Text(L10n.string("weibo.feed.nextCheck", language: language, formatted(next)))
            }
            if snapshot.isTicking {
                ProgressView().controlSize(.mini).scaleEffect(0.65)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 9.5))
        .foregroundStyle(.secondary)
    }

    private struct FeedBanner {
        let symbol: String
        let tint: Color
        let text: String
        let actionTitle: String?
        let action: (() -> Void)?
    }

    private func authBanner(
        _ monitor: WeiboMonitorViewModel,
        snapshot: WeiboMonitorSnapshot
    ) -> FeedBanner? {
        switch snapshot.loginState {
        case .expired:
            return FeedBanner(
                symbol: "person.crop.circle.badge.exclamationmark",
                tint: .red,
                text: L10n.string("weibo.feed.auth.body", language: language),
                actionTitle: L10n.string("weibo.feed.auth.action", language: language),
                action: monitor.openLogin
            )
        case .anonymous where !snapshot.users.isEmpty:
            return FeedBanner(
                symbol: "person.crop.circle.badge.questionmark",
                tint: .orange,
                text: L10n.string("weibo.header.anonymousHint", language: language),
                actionTitle: L10n.string("weibo.header.goLogin", language: language),
                action: monitor.openLogin
            )
        default:
            return nil
        }
    }

    private func bannerRow(_ banner: FeedBanner) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: banner.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(banner.tint)
                .frame(width: 14)
            Text(banner.text)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let title = banner.actionTitle, let action = banner.action {
                Button(title, action: action)
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .font(.system(size: 10))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            if settings.appTheme == .retroEditorial {
                Rectangle().fill(RetroEditorialTokens.raisedPaper)
            } else {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(banner.tint.opacity(0.07))
            }
        }
        .overlay {
            if settings.appTheme == .retroEditorial {
                Rectangle().strokeBorder(RetroEditorialTokens.ink, lineWidth: 1)
            }
        }
    }

    // MARK: - Filter

    private func filterBar(snapshot: WeiboMonitorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField(
                    L10n.string("weibo.feed.searchPlaceholder", language: language),
                    text: $searchText
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string("dash.searchClear", language: language))
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background {
                if settings.appTheme == .retroEditorial {
                    Rectangle().fill(RetroEditorialTokens.raisedPaper)
                } else {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                }
            }
            .overlay {
                if settings.appTheme == .retroEditorial {
                    Rectangle().strokeBorder(RetroEditorialTokens.ink, lineWidth: 1.3)
                } else {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
                }
            }

            DashboardModeSegmentedControl(
                mode: $mode,
                followingUnread: followingUnread,
                badgeEnabled: badgeEnabled
            )

            HStack(spacing: 6) {
                ForEach(WeiboFollowingFilter.allCases) { item in
                    filterChip(item, snapshot: snapshot)
                }

                accountFilterMenu(snapshot)

                Spacer(minLength: 0)

                Text(L10n.string("weibo.feed.filterCount", language: language, filteredPostCount(snapshot)))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private func accountFilterMenu(_ snapshot: WeiboMonitorSnapshot) -> some View {
        if snapshot.users.count > 1 {
            Menu {
                Button {
                    accountUID = nil
                } label: {
                    Label(
                        L10n.string("weibo.feed.allAccounts", language: language),
                        systemImage: accountUID == nil ? "checkmark" : "person.2"
                    )
                }
                Divider()
                ForEach(sortedUsers(snapshot.users)) { user in
                    Button {
                        accountUID = user.uid
                    } label: {
                        HStack {
                            Text(displayName(user))
                            if user.priority == .p0 {
                                Text("P0")
                            }
                            if accountUID == user.uid {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(accountLabel(snapshot))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                }
                .font(.system(size: 10))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    if settings.appTheme == .retroEditorial {
                        Rectangle().fill(RetroEditorialTokens.raisedPaper)
                    } else {
                        Capsule().fill(Color(nsColor: .controlBackgroundColor))
                    }
                }
                .overlay {
                    if settings.appTheme == .retroEditorial {
                        Rectangle().strokeBorder(RetroEditorialTokens.ink, lineWidth: 1)
                    } else {
                        Capsule().strokeBorder(
                            Color(nsColor: .separatorColor).opacity(0.35),
                            lineWidth: 1
                        )
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(
                L10n.string("weibo.feed.accountFilter", language: language, accountLabel(snapshot))
            )
        }
    }

    private func accountLabel(_ snapshot: WeiboMonitorSnapshot) -> String {
        guard let accountUID,
              let user = snapshot.users.first(where: { $0.uid == accountUID }) else {
            return L10n.string("weibo.feed.allAccounts", language: language)
        }
        return displayName(user)
    }

    private func sortedUsers(_ users: [WeiboMonitorUser]) -> [WeiboMonitorUser] {
        users.sorted { lhs, rhs in
            if lhs.priority.rank != rhs.priority.rank {
                return lhs.priority.rank < rhs.priority.rank
            }
            return lhs.addedAt < rhs.addedAt
        }
    }

    private func filterChip(
        _ item: WeiboFollowingFilter,
        snapshot: WeiboMonitorSnapshot
    ) -> some View {
        let selected = filter == item
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                filter = item
            }
        } label: {
            Text(L10n.string(item.titleKey, language: language))
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    if settings.appTheme == .retroEditorial {
                        Rectangle().fill(selected ? RetroEditorialTokens.brick : RetroEditorialTokens.raisedPaper)
                    } else {
                        Capsule().fill(
                            selected
                                ? accent.opacity(0.16)
                                : Color(nsColor: .controlBackgroundColor)
                        )
                    }
                }
                .overlay {
                    if settings.appTheme == .retroEditorial {
                        Rectangle().strokeBorder(RetroEditorialTokens.ink, lineWidth: 1)
                    } else {
                        Capsule().strokeBorder(
                            Color(nsColor: .separatorColor).opacity(0.35),
                            lineWidth: 1
                        )
                    }
                }
                .foregroundStyle(
                    selected
                        ? (settings.appTheme == .retroEditorial ? RetroEditorialTokens.raisedPaper : accent)
                        : .primary
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Feed

    @ViewBuilder
    private func feed(
        _ monitor: WeiboMonitorViewModel,
        snapshot: WeiboMonitorSnapshot
    ) -> some View {
        let query = feedQuery()
        let entries = FollowingFeedModel.entries(snapshot: snapshot, query: query)
        let collapsed = FollowingFeedModel.collapsedPosts(snapshot: snapshot, query: query)
        if entries.isEmpty && collapsed.isEmpty {
            noMatchState
        } else {
            LazyVStack(alignment: .leading, spacing: 14) {
                if !collapsed.isEmpty {
                    collapsedSection(monitor, posts: collapsed)
                }
                FollowingMasonryFeed(
                    entries: entries,
                    width: min(max(1, availableWidth), 920),
                    onOpen: { monitor.openPost($0) }
                )
            }
        }
    }

    private func feedQuery() -> FollowingFeedQuery {
        FollowingFeedQuery(
            filter: filter,
            accountUID: accountUID,
            searchText: searchText,
            includeCollapsed: !settings.weiboMonitorRelevanceEnabled
        )
    }

    /// A one-line, collapsed-by-default block. It is the only way a filtered
    /// post can be missed, so it always says how many are hidden and offers
    /// both "expand" and "turn filtering off" without leaving the feed.
    private func collapsedSection(
        _ monitor: WeiboMonitorViewModel,
        posts: [WeiboPost]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                    showCollapsed.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: showCollapsed ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(
                        L10n.string(
                            "weibo.relevance.collapsedCount",
                            language: language,
                            posts.count
                        )
                    )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(
                        L10n.string(
                            showCollapsed ? "weibo.relevance.hide" : "weibo.relevance.show",
                            language: language
                        )
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(accent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                L10n.string("weibo.relevance.collapsedCount", language: language, posts.count)
            )

            if showCollapsed {
                Divider().opacity(0.45)
                VStack(spacing: 0) {
                    ForEach(Array(posts.enumerated()), id: \.element.id) { index, post in
                        collapsedPostRow(monitor, post: post)
                        if index < posts.count - 1 {
                            Divider().opacity(0.3).padding(.leading, 12)
                        }
                    }
                }
                .padding(.bottom, 3)

                Divider().opacity(0.45)
                Button {
                    settings.weiboMonitorRelevanceEnabled = false
                } label: {
                    Text(L10n.string("weibo.relevance.disable", language: language))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .newsCardSurface(cornerRadius: 15)
    }

    private func collapsedPostRow(
        _ monitor: WeiboMonitorViewModel,
        post: WeiboPost
    ) -> some View {
        Button {
            monitor.openPost(post)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(post.screenName)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 62, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text(post.displayText)
                        .font(.system(size: 11))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        verdictBadge(post)
                        Text(relativeTime(post.createdAt))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(reasonsText(for: post))
    }

    private func verdictBadge(_ post: WeiboPost) -> some View {
        let verdict = post.relevance?.verdict ?? .lowConfidence
        return Text(L10n.string(verdict.titleKey, language: language))
            .font(.system(size: 8.5, weight: .medium))
            .foregroundStyle(verdictTint(verdict))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                Capsule().fill(verdictTint(verdict).opacity(0.12))
            )
    }

    private func verdictTint(_ verdict: WeiboRelevanceVerdict) -> Color {
        switch verdict {
        case .filtered: return .orange
        case .offTopic: return .secondary
        case .lowConfidence: return .secondary
        case .relevant: return accent
        }
    }

    private func reasonsText(for post: WeiboPost) -> String {
        guard let relevance = post.relevance else { return "" }
        let reasons = relevance.reasons.prefix(3).map { raw -> String in
            let code = raw.split(separator: ":", maxSplits: 1).first.map(String.init) ?? raw
            return L10n.string("weibo.relevance.reason.\(code)", language: language)
        }
        return reasons.joined(separator: " · ")
    }

    /// All posts the model collapsed, filtered by the current feed tab and
    /// search. Search intentionally looks through the collapsed section too,
    /// so a remembered post never becomes unreachable.
    private func collapsedPosts(_ snapshot: WeiboMonitorSnapshot) -> [WeiboPost] {
        guard settings.weiboMonitorRelevanceEnabled else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty else { return [] }
        switch filter {
        case .unread:
            return []
        case .p0:
            let allowed = Set(snapshot.users.filter { $0.priority == .p0 }.map(\.uid))
            return snapshot.postsByUID
                .filter { allowed.contains($0.key) }
                .flatMap(\.value)
                .filter(\.isCollapsedByRelevance)
                .sorted { $0.createdAt > $1.createdAt }
        case .all:
            return snapshot.postsByUID
                .flatMap(\.value)
                .filter(\.isCollapsedByRelevance)
                .sorted { $0.createdAt > $1.createdAt }
        }
    }

    private func filteredGroups(_ snapshot: WeiboMonitorSnapshot) -> [WeiboAccountFeedGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot.groups.compactMap { group in
            if filter == .p0 && group.user.priority != .p0 { return nil }

            var posts = group.posts
            if filter == .unread {
                posts = posts.filter { !$0.read && !$0.isCollapsedByRelevance }
            }
            if !query.isEmpty {
                // Search is a full-text escape hatch: it sees collapsed posts
                // as well, so a half-remembered post is never unreachable.
                posts = posts.filter {
                    $0.displayText.localizedCaseInsensitiveContains(query)
                        || $0.screenName.localizedCaseInsensitiveContains(query)
                }
            } else if settings.weiboMonitorRelevanceEnabled {
                posts = posts.filter { !$0.isCollapsedByRelevance }
            }
            guard !posts.isEmpty else { return nil }
            let unread = posts.reduce(0) {
                $0 + (($1.read || $1.isCollapsedByRelevance) ? 0 : 1)
            }
            return WeiboAccountFeedGroup(user: group.user, posts: posts, unreadCount: unread)
        }
    }

    private func filteredPostCount(_ snapshot: WeiboMonitorSnapshot) -> Int {
        FollowingFeedModel.entries(snapshot: snapshot, query: feedQuery()).count
    }

    private func accountGroup(
        _ monitor: WeiboMonitorViewModel,
        group: WeiboAccountFeedGroup
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                avatar(group.user)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(displayName(group.user))
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        priorityTag(group.user.priority)
                        if group.unreadCount > 0 {
                            Text(
                                L10n.string(
                                    "weibo.feed.accountUnread",
                                    language: language,
                                    group.unreadCount
                                )
                            )
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        }
                    }
                    if group.user.gapSuspected {
                        Text(L10n.string("weibo.feed.gap", language: language))
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                }

                Spacer(minLength: 6)

                accountMenu(monitor, user: group.user)
            }
            .padding(.bottom, 4)

            ForEach(Array(group.posts.enumerated()), id: \.element.id) { index, post in
                postRow(monitor, post: post)
                if index < group.posts.count - 1 {
                    Divider().opacity(0.45)
                }
            }
        }
        .padding(12)
        .newsCardSurface(cornerRadius: 15)
    }

    private func postRow(
        _ monitor: WeiboMonitorViewModel,
        post: WeiboPost
    ) -> some View {
        HoverRow { hovered in
            Button {
                monitor.openPost(post)
            } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    if !post.read {
                        Circle()
                            .fill(accent)
                            .frame(width: 5, height: 5)
                            .padding(.top, 5)
                            .accessibilityLabel(L10n.string("weibo.feed.unreadCount", language: language, 1))
                    }
                    Text(post.displayText)
                        .font(.system(size: 12, weight: post.read ? .regular : .medium))
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }

                if !post.imageURLs.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(Array(post.imageURLs.prefix(3)), id: \.self) { url in
                            thumbnail(url)
                        }
                    }
                }

                HStack(spacing: 7) {
                    Text(relativeTime(post.createdAt))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if post.isLongText {
                        metaTag(L10n.string("weibo.feed.longText", language: language))
                    }
                    if post.isRetweet {
                        metaTag(L10n.string("weibo.feed.retweet", language: language))
                    }
                    if !post.imageURLs.isEmpty {
                        metaTag(L10n.string("weibo.feed.images", language: language, post.imageURLs.count))
                    }
                    Spacer(minLength: 0)
                    if hovered {
                        HStack(spacing: 3) {
                            Text(L10n.string("weibo.feed.openPost", language: language))
                            Image(systemName: "arrow.up.forward")
                        }
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovered ? accent.opacity(0.055) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(post.displayText)
        .accessibilityValue(
            post.read ? "" : L10n.string("weibo.feed.filter.unread", language: language)
        )
        }
    }

    private func thumbnail(_ raw: String) -> some View {
        Group {
            if let url = URL(string: raw) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.2))
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.2))
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
        )
    }

    private func avatar(_ user: WeiboMonitorUser) -> some View {
        Group {
            if let raw = user.avatarURL, let url = URL(string: raw) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        avatarPlaceholder(user)
                    }
                }
            } else {
                avatarPlaceholder(user)
            }
        }
        .frame(width: 26, height: 26)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private func avatarPlaceholder(_ user: WeiboMonitorUser) -> some View {
        ZStack {
            Circle().fill(accent.opacity(0.12))
            Text(String(displayName(user).prefix(1)))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
        }
    }

    private func displayName(_ user: WeiboMonitorUser) -> String {
        let name = user.screenName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "UID \(user.uid)" : name
    }

    private func accountMenu(
        _ monitor: WeiboMonitorViewModel,
        user: WeiboMonitorUser
    ) -> some View {
        Menu {
            Button(L10n.string("weibo.feed.checkNow", language: language)) {
                Task { await monitor.checkNow(user.uid) }
            }
            Button(L10n.string("weibo.feed.mute", language: language)) {
                Task { await monitor.mute(user.uid) }
            }
            if user.needsManualResume || user.pausedUntil != nil || user.mutedUntil != nil {
                Button(L10n.string("weibo.accounts.resume", language: language)) {
                    Task { await monitor.resumeUser(user.uid) }
                }
            }
            if user.gapSuspected {
                Button(L10n.string("weibo.feed.gap", language: language)) {
                    Task { await monitor.clearGap(uid: user.uid) }
                }
            }
            Divider()
            Toggle(
                L10n.string("weibo.relevance.accountAlwaysShow", language: language),
                isOn: Binding(
                    get: { user.relevanceMode == .off },
                    set: { alwaysShow in
                        Task {
                            await monitor.setRelevanceMode(
                                user.uid,
                                mode: alwaysShow ? .off : nil
                            )
                        }
                    }
                )
            )
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(monitor.isWorking)
        .accessibilityLabel(L10n.string("weibo.feed.accountMenu", language: language))
    }

    private func priorityTag(_ priority: WeiboMonitorPriority) -> some View {
        Text(L10n.string(priority.titleKey, language: language))
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(priorityColor(priority))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(priorityColor(priority).opacity(0.12)))
    }

    private func priorityColor(_ priority: WeiboMonitorPriority) -> Color {
        switch priority {
        case .p0: return .red
        case .p1: return .orange
        case .p2: return .secondary
        }
    }

    private func metaTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.18)))
    }

    private func loginPill(_ state: WeiboLoginState) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(loginColor(state))
                .frame(width: 5, height: 5)
            Text(L10n.string(state.titleKey, language: language))
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func loginColor(_ state: WeiboLoginState) -> Color {
        switch state {
        case .loggedIn: return .green
        case .mobileOnly: return .orange
        case .expired: return .red
        case .anonymous, .unknown: return .secondary
        }
    }

    // MARK: - Empty states

    private func disabledState(_ monitor: WeiboMonitorViewModel) -> some View {
        stateCard(
            symbol: "bell.slash",
            title: L10n.string("weibo.feed.disabled.title", language: language),
            body: L10n.string("weibo.feed.disabled.body", language: language),
            actionTitle: L10n.string("weibo.feed.disabled.action", language: language),
            action: {
                settings.weiboMonitorEnabled = true
                Task { await monitor.tick() }
            },
            secondaryTitle: L10n.string("weibo.feed.empty.action", language: language),
            secondaryAction: onOpenSettings
        )
    }

    private var emptyState: some View {
        stateCard(
            symbol: "person.2",
            title: L10n.string("weibo.feed.empty.title", language: language),
            body: L10n.string("weibo.feed.empty.body", language: language),
            actionTitle: L10n.string("weibo.feed.empty.action", language: language),
            action: onOpenSettings,
            secondaryTitle: nil,
            secondaryAction: nil
        )
    }

    private var noMatchState: some View {
        stateCard(
            symbol: "line.3.horizontal.decrease.circle",
            title: L10n.string("weibo.feed.noMatch", language: language),
            body: "",
            actionTitle: L10n.string("weibo.feed.clearFilters", language: language),
            action: {
                filter = .all
                searchText = ""
            },
            secondaryTitle: nil,
            secondaryAction: nil
        )
    }

    private var unavailableState: some View {
        stateCard(
            symbol: "binoculars",
            title: L10n.string("weibo.feed.empty.title", language: language),
            body: L10n.string("weibo.header.masterHint", language: language),
            actionTitle: nil,
            action: nil,
            secondaryTitle: nil,
            secondaryAction: nil
        )
    }

    private func stateCard(
        symbol: String,
        title: String,
        body: String,
        actionTitle: String?,
        action: (() -> Void)?,
        secondaryTitle: String?,
        secondaryAction: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            if !body.isEmpty {
                Text(body)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(EditorialActionButtonStyle(tone: .selected, compact: true))
                        .controlSize(.small)
                }
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                        .buttonStyle(EditorialActionButtonStyle(compact: true))
                        .controlSize(.small)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .newsCardSurface(cornerRadius: 14)
    }

    // MARK: - Time

    private func relativeTime(_ date: Date) -> String {
        let delta = Date().timeIntervalSince(date)
        if delta < 60 {
            return L10n.string("weibo.feed.justNow", language: language)
        }
        if delta < 3600 {
            return L10n.string("weibo.feed.minutesAgo", language: language, max(1, Int(delta / 60)))
        }
        if delta < 24 * 3600 {
            return L10n.string("weibo.feed.hoursAgo", language: language, max(1, Int(delta / 3600)))
        }
        if delta < 7 * 24 * 3600 {
            return L10n.string("weibo.feed.daysAgo", language: language, max(1, Int(delta / 86400)))
        }
        return cachedFormatter("MM-dd HH:mm").string(from: date)
    }

    private func formatted(_ date: Date) -> String {
        let format = Calendar.current.isDateInToday(date) ? "HH:mm" : "MM-dd HH:mm"
        return cachedFormatter(format).string(from: date)
    }

    /// A formatter per locale/format, reused across body evaluations. Creating
    /// a DateFormatter inside `body` allocated on every hover and scroll tick.
    private func cachedFormatter(_ format: String) -> DateFormatter {
        let key = "\(language.bcp47)|\(format)" as NSString
        if let cached = Self.formatterCache.object(forKey: key) {
            return cached
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language.bcp47)
        formatter.dateFormat = format
        Self.formatterCache.setObject(formatter, forKey: key)
        return formatter
    }

    private static let formatterCache = NSCache<NSString, DateFormatter>()
}

/// Keeps hover state inside the row. A container-level `@State` re-evaluated
/// every account group and every filtered post on each hover change.
private struct HoverRow<Content: View>: View {
    let content: (Bool) -> Content
    @State private var hovered = false

    init(@ViewBuilder content: @escaping (Bool) -> Content) {
        self.content = content
    }

    var body: some View {
        content(hovered)
            .onHover { hovering in
                guard hovered != hovering else { return }
                hovered = hovering
            }
    }
}
