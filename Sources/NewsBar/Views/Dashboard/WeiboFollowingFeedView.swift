import SwiftUI

enum WeiboFollowingFilter: String, CaseIterable, Identifiable {
    case all
    case unread
    case p0

    var id: String { rawValue }
    var titleKey: String { "weibo.feed.filter.\(rawValue)" }
}

/// The reader can squeeze this page to a 280 pt content width. At that size
/// the dashboard-sized chips wrap, so fall back to the pre-unification compact
/// metrics below 380 pt. Normal widths keep the shared dashboard baseline.
private enum FollowingCompactFilterMetrics {
    static let threshold: CGFloat = 380
    static let chipFontSize: CGFloat = 10.5
    static let chipHorizontalPadding: CGFloat = 10
    static let chipVerticalPadding: CGFloat = 5
    static let countFontSize: CGFloat = 9.5
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
    /// The dashboard renders the mode switch once at the top of the scroll
    /// content so it keeps one identity across all three modes. Standalone
    /// callers (rendering tests, previews) keep the self-contained control.
    var showsModeControl = true
    var availableWidth: CGFloat = FollowingMasonryLayout.maxFeedWidth
    /// The dashboard keeps a visited browse pane alive after a tab switch.
    /// Presence and polling follow the *visible* tab, not the view lifetime.
    var isActive = true
    let onOpenSettings: () -> Void

    @State private var showCollapsed = false

    private var accent: Color {
        settings.appTheme == .retroEditorial ? RetroEditorialTokens.brick : Color.accentColor
    }

    private var language: AppLanguage { settings.appLanguage }

    private var usesCompactFilterMetrics: Bool {
        availableWidth < FollowingCompactFilterMetrics.threshold
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsModeControl {
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
            guard isActive else { return }
            activate()
        }
        .onChange(of: isActive) { _, active in
            if active {
                activate()
            } else {
                WeiboFeedPresence.setVisible(false)
            }
        }
        .onDisappear {
            WeiboFeedPresence.setVisible(false)
        }
    }

    /// Called both on first mount and every time this pane becomes the visible
    /// tab. `monitor.start()` is idempotent, so a repeated call is free.
    private func activate() {
        WeiboFeedPresence.setVisible(true)
        guard let monitor else { return }
        // `start()` already refreshes on the path that actually loads the
        // store; afterwards the change notification keeps `snapshot` live.
        // The extra `refresh()` here ran a full snapshot reduce on every
        // re-entry into the page.
        Task { await monitor.start() }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ monitor: WeiboMonitorViewModel) -> some View {
        let snapshot = monitor.snapshot

        VStack(alignment: .leading, spacing: 18) {
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
                feedSection(monitor, snapshot: snapshot)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: snapshot.users.map(\.uid)) { _, uids in
            if let accountUID, !uids.contains(accountUID) {
                self.accountUID = nil
            }
        }
    }

    /// One `snapshot + query` pass feeds the counter and the waterfall. It used
    /// to run `FollowingFeedModel.entries` twice plus `collapsedPosts` on every
    /// render — the counter alone re-filtered and re-sorted the whole snapshot.
    @ViewBuilder
    private func feedSection(
        _ monitor: WeiboMonitorViewModel,
        snapshot: WeiboMonitorSnapshot
    ) -> some View {
        let contents = FollowingFeedModel.contents(snapshot: snapshot, query: feedQuery())
        filterBar(snapshot: snapshot, matchCount: contents.entries.count)
        feed(
            monitor,
            entries: contents.entries,
            collapsed: contents.collapsedPosts
        )
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

    private func filterBar(snapshot: WeiboMonitorSnapshot, matchCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DashboardSearchField(
                text: $searchText,
                placeholder: L10n.string("weibo.feed.searchPlaceholder", language: language)
            )

            HStack(spacing: 6) {
                ForEach(WeiboFollowingFilter.allCases) { item in
                    DashboardFilterChip(
                        title: L10n.string(item.titleKey, language: language),
                        isSelected: filter == item,
                        fontSize: usesCompactFilterMetrics
                            ? FollowingCompactFilterMetrics.chipFontSize
                            : DashboardFilterMetrics.chipFontSize,
                        horizontalPadding: usesCompactFilterMetrics
                            ? FollowingCompactFilterMetrics.chipHorizontalPadding
                            : DashboardFilterMetrics.chipHorizontalPadding,
                        verticalPadding: usesCompactFilterMetrics
                            ? FollowingCompactFilterMetrics.chipVerticalPadding
                            : DashboardFilterMetrics.chipVerticalPadding
                    ) {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                            filter = item
                        }
                    }
                }

                accountFilterMenu(snapshot)

                Spacer(minLength: 0)

                DashboardFilterCountText(
                    text: L10n.string(
                        "weibo.feed.filterCount",
                        language: language,
                        matchCount
                    ),
                    fontSize: usesCompactFilterMetrics
                        ? FollowingCompactFilterMetrics.countFontSize
                        : DashboardFilterMetrics.countFontSize
                )
                .monospacedDigit()
            }
            .frame(
                maxWidth: FollowingMasonryLayout.maxFeedWidth,
                alignment: .leading
            )
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

    // MARK: - Feed

    @ViewBuilder
    private func feed(
        _ monitor: WeiboMonitorViewModel,
        entries: [FollowingPostEntry],
        collapsed: [WeiboPost]
    ) -> some View {
        if entries.isEmpty && collapsed.isEmpty {
            noMatchState
        } else {
            LazyVStack(alignment: .leading, spacing: 14) {
                if !collapsed.isEmpty {
                    collapsedSection(monitor, posts: collapsed)
                }
                FollowingMasonryFeed(
                    entries: entries,
                    width: FollowingMasonryLayout.feedWidth(for: availableWidth),
                    onOpen: { monitor.openPost($0) }
                )
            }
            .frame(
                maxWidth: FollowingMasonryLayout.maxFeedWidth,
                alignment: .leading
            )
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

    private func displayName(_ user: WeiboMonitorUser) -> String {
        let name = user.screenName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "UID \(user.uid)" : name
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
        .frame(
            maxWidth: FollowingMasonryLayout.maxFeedWidth,
            alignment: .leading
        )
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
