import AppKit
import SwiftUI

/// Settings → Weibo Monitor. The page is intentionally organized around the
/// three things a person actually does here: turn it on, see the login state,
/// and manage accounts. The advanced rules stay collapsed until needed.
struct WeiboMonitorTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let monitor: WeiboMonitorViewModel?

    @State private var addText = ""
    @State private var addPriority: WeiboMonitorPriority = .p1
    @State private var addNotifyMode: WeiboNotifyMode = .keywords
    @State private var showAdvanced = false
    @State private var showEvents = false
    @State private var pendingDelete: WeiboMonitorUser?
    @State private var keywordInput = ""
    @State private var copied = false
    @State private var pendingAICorrection = false

    private var accent: Color {
        settings.appTheme == .retroEditorial ? RetroEditorialTokens.brick : Color.accentColor
    }

    private var language: AppLanguage { settings.appLanguage }

    var body: some View {
        Group {
            if let monitor {
                Form {
                    content(monitor)
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .onAppear {
                    Task {
                        await monitor.start()
                        await monitor.refreshNotificationStatus()
                    }
                }
                .confirmationDialog(
                    L10n.string("weibo.accounts.deleteAction", language: settings.appLanguage),
                    isPresented: Binding(
                        get: { pendingDelete != nil },
                        set: { if !$0 { pendingDelete = nil } }
                    ),
                    presenting: pendingDelete
                ) { user in
                    Button(L10n.string("weibo.accounts.delete", language: settings.appLanguage), role: .destructive) {
                        Task { await monitor.removeUser(user.uid) }
                        pendingDelete = nil
                    }
                    Button(L10n.string("weibo.header.cancel", language: settings.appLanguage), role: .cancel) {
                        pendingDelete = nil
                    }
                } message: { user in
                    Text(
                        L10n.string(
                            "weibo.accounts.deleteConfirm",
                            language: settings.appLanguage,
                            user.screenName
                        )
                    )
                }
            } else {
                unavailableState
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ monitor: WeiboMonitorViewModel) -> some View {
        let snapshot = monitor.snapshot

        Section {
            header(monitor, snapshot: snapshot)
        }

        let banners = bannerItems(monitor, snapshot: snapshot)
        if !banners.isEmpty {
            Section {
                ForEach(banners) { banner in
                    calloutRow(banner)
                }
            }
        }

        Section {
            accountsSection(monitor, snapshot: snapshot)
        } header: {
            Text(L10n.string("weibo.accounts.title", language: settings.appLanguage))
        }

        Section {
            addAccountSection(monitor)
        } header: {
            Text(L10n.string("weibo.accounts.add", language: settings.appLanguage))
        }

        Section {
            relevanceSection(snapshot: snapshot)
        } header: {
            Text(L10n.string("weibo.relevance.section", language: settings.appLanguage))
        }

        Section {
            advancedSection(monitor, snapshot: snapshot)
        }

        Section {
            eventsSection(monitor, snapshot: snapshot)
        }
    }

    // MARK: - Header

    private func header(
        _ monitor: WeiboMonitorViewModel,
        snapshot: WeiboMonitorSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 10) {
                Toggle(
                    L10n.string("weibo.header.master", language: settings.appLanguage),
                    isOn: Binding(
                        get: { settings.weiboMonitorEnabled },
                        set: { enabled in
                            settings.weiboMonitorEnabled = enabled
                            Task { await monitor.tick() }
                        }
                    )
                )
                .toggleStyle(.switch)

                Spacer(minLength: 8)

                loginPill(snapshot.loginState)
            }

            Text(L10n.string("weibo.header.masterHint", language: settings.appLanguage))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Text(
                    L10n.string(
                        "weibo.header.summary",
                        language: settings.appLanguage,
                        snapshot.users.count,
                        snapshot.unreadCount
                    )
                )
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()

                if snapshot.isTicking {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                }

                Spacer(minLength: 8)

                Button(L10n.string("weibo.header.checkAll", language: settings.appLanguage)) {
                    Task { await monitor.checkAll() }
                }
                .buttonStyle(EditorialActionButtonStyle(tone: .selected, compact: true))
                .controlSize(.small)
                .disabled(monitor.isWorking || !settings.weiboMonitorEnabled)
            }

            if let until = snapshot.pausedUntil, until > Date() {
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.orange)
                    Text(
                        L10n.string(
                            "weibo.header.pausedHint",
                            language: settings.appLanguage,
                            formattedTime(until)
                        )
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.string("weibo.header.resume", language: settings.appLanguage)) {
                        Task { await monitor.resumeAll() }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func loginPill(_ state: WeiboLoginState) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(loginColor(state))
                .frame(width: 6, height: 6)
            Text(L10n.string(state.titleKey, language: settings.appLanguage))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(loginColor(state).opacity(0.10))
        )
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

    // MARK: - Banners

    private struct Banner: Identifiable {
        let id: String
        let symbol: String
        let tint: Color
        let text: String
        let actionTitle: String?
        let action: (() -> Void)?
    }

    private func bannerItems(
        _ monitor: WeiboMonitorViewModel,
        snapshot: WeiboMonitorSnapshot
    ) -> [Banner] {
        var items: [Banner] = []
        let language = settings.appLanguage

        if snapshot.loginState == .expired {
            items.append(
                Banner(
                    id: "auth",
                    symbol: "person.crop.circle.badge.exclamationmark",
                    tint: .red,
                    text: L10n.string("weibo.header.expiredHint", language: language),
                    actionTitle: L10n.string("weibo.header.goLogin", language: language),
                    action: monitor.openLogin
                )
            )
        } else if snapshot.loginState == .anonymous {
            let hint = snapshot.users.isEmpty
                ? L10n.string("weibo.header.loginHint", language: language)
                : L10n.string("weibo.header.anonymousHint", language: language)
            items.append(
                Banner(
                    id: "anonymous",
                    symbol: "person.crop.circle.badge.questionmark",
                    tint: .orange,
                    text: hint,
                    actionTitle: L10n.string("weibo.header.goLogin", language: language),
                    action: monitor.openLogin
                )
            )
        }

        if snapshot.loginState == .mobileOnly {
            items.append(
                Banner(
                    id: "mobile-only",
                    symbol: "iphone",
                    tint: .orange,
                    text: L10n.string("weibo.header.mobileOnlyHint", language: language),
                    actionTitle: L10n.string("weibo.header.goLogin", language: language),
                    action: monitor.openLogin
                )
            )
        }

        if monitor.notificationStatus == .denied {
            items.append(
                Banner(
                    id: "notifications",
                    symbol: "bell.slash",
                    tint: .orange,
                    text: L10n.string("weibo.header.notificationsDenied", language: language),
                    actionTitle: L10n.string("weibo.header.openNotificationSettings", language: language),
                    action: monitor.openNotificationSettings
                )
            )
        }

        if !snapshot.isOnline {
            items.append(
                Banner(
                    id: "offline",
                    symbol: "wifi.slash",
                    tint: .secondary,
                    text: L10n.string("weibo.feed.offline", language: language),
                    actionTitle: nil,
                    action: nil
                )
            )
        }

        if snapshot.gapSuspectedCount > 0 {
            items.append(
                Banner(
                    id: "gap",
                    symbol: "exclamationmark.triangle",
                    tint: .orange,
                    text: L10n.string("weibo.accounts.gapHint", language: language),
                    actionTitle: L10n.string("weibo.gap.ack", language: language),
                    action: { Task { await monitor.clearGap() } }
                )
            )
        }

        if snapshot.storeError != nil {
            items.append(
                Banner(
                    id: "store",
                    symbol: "externaldrive.badge.exclamationmark",
                    tint: .red,
                    text: L10n.string("weibo.events.storeError", language: language),
                    actionTitle: nil,
                    action: nil
                )
            )
        }

        return items
    }

    private func calloutRow(_ banner: Banner) -> some View {
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
            if let actionTitle = banner.actionTitle, let action = banner.action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .font(.system(size: 10))
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Accounts

    @ViewBuilder
    private func accountsSection(
        _ monitor: WeiboMonitorViewModel,
        snapshot: WeiboMonitorSnapshot
    ) -> some View {
        if snapshot.users.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.string("weibo.accounts.empty", language: settings.appLanguage))
                    .font(.system(size: 12, weight: .medium))
                Text(L10n.string("weibo.accounts.emptyHint", language: settings.appLanguage))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        } else {
            ForEach(sortedUsers(snapshot.users)) { user in
                accountRow(monitor, user: user)
            }
        }
    }

    private func sortedUsers(_ users: [WeiboMonitorUser]) -> [WeiboMonitorUser] {
        users.sorted { lhs, rhs in
            if lhs.priority.rank != rhs.priority.rank {
                return lhs.priority.rank < rhs.priority.rank
            }
            return lhs.addedAt < rhs.addedAt
        }
    }

    private func accountRow(
        _ monitor: WeiboMonitorViewModel,
        user: WeiboMonitorUser
    ) -> some View {
        let now = Date()
        let status = statusDescription(
            user,
            now: now,
            loginState: monitor.snapshot.loginState
        )

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                avatar(user)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(displayName(user))
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        priorityMenu(monitor, user: user)
                        notifyModeMenu(monitor, user: user)
                    }

                    HStack(spacing: 7) {
                        Text("UID \(user.uid)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                        statusPill(status)
                    }
                }

                Spacer(minLength: 6)

                Toggle(
                    "",
                    isOn: Binding(
                        get: { user.enabled },
                        set: { enabled in
                            Task { await monitor.setEnabled(user.uid, enabled: enabled) }
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(monitor.isWorking)
                .accessibilityLabel(
                    "\(displayName(user)) \(L10n.string("weibo.accounts.enabled", language: settings.appLanguage))"
                )

                accountMenu(monitor, user: user)
            }

            HStack(spacing: 12) {
                statItem(
                    L10n.string("weibo.accounts.lastCheck", language: settings.appLanguage, formattedTime(user.lastCheckedAt)),
                    symbol: "clock"
                )
                statItem(
                    L10n.string("weibo.accounts.nextCheck", language: settings.appLanguage, formattedTime(user.nextDueAt)),
                    symbol: "clock.arrow.circlepath"
                )
                statItem(
                    L10n.string("weibo.accounts.posts7d", language: settings.appLanguage, user.stats.posts7d),
                    symbol: "text.bubble"
                )

                Spacer(minLength: 4)

                if user.gapSuspected {
                    smallTag(
                        L10n.string("weibo.accounts.gap", language: settings.appLanguage),
                        tint: .orange
                    )
                }
                if user.isBaselinePending && user.lastErrorKind == nil {
                    smallTag(
                        L10n.string("weibo.accounts.baselinePending", language: settings.appLanguage),
                        tint: .secondary
                    )
                }
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)

            if let reason = statusReason(user, now: now) {
                HStack(spacing: 7) {
                    Text(reason)
                        .font(.system(size: 9.5))
                        .foregroundStyle(status.tint)
                    if user.needsManualResume || user.pausedUntil != nil || user.mutedUntil != nil {
                        if user.lastErrorKind != .disk {
                            Button(L10n.string("weibo.accounts.resume", language: settings.appLanguage)) {
                                Task { await monitor.resumeUser(user.uid) }
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 9.5))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 3)
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
        .frame(width: 28, height: 28)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private func avatarPlaceholder(_ user: WeiboMonitorUser) -> some View {
        ZStack {
            Circle().fill(accent.opacity(0.12))
            Text(String(displayName(user).prefix(1)))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
        }
    }

    private func displayName(_ user: WeiboMonitorUser) -> String {
        let name = user.screenName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "UID \(user.uid)" : name
    }

    private func priorityMenu(
        _ monitor: WeiboMonitorViewModel,
        user: WeiboMonitorUser
    ) -> some View {
        Menu {
            ForEach(WeiboMonitorPriority.allCases) { priority in
                Button {
                    Task { await monitor.setPriority(user.uid, priority: priority) }
                } label: {
                    Text(L10n.string(priority.titleKey, language: settings.appLanguage))
                }
            }
        } label: {
            smallTag(
                L10n.string(user.priority.titleKey, language: settings.appLanguage),
                tint: priorityColor(user.priority)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(monitor.isWorking)
    }

    private func notifyModeMenu(
        _ monitor: WeiboMonitorViewModel,
        user: WeiboMonitorUser
    ) -> some View {
        Menu {
            ForEach(WeiboNotifyMode.allCases) { mode in
                Button {
                    Task { await monitor.setNotifyMode(user.uid, mode: mode) }
                } label: {
                    Text(L10n.string(mode.titleKey, language: settings.appLanguage))
                }
            }
        } label: {
            Text(L10n.string(user.notifyMode.titleKey, language: settings.appLanguage))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(monitor.isWorking)
    }

    private func accountMenu(
        _ monitor: WeiboMonitorViewModel,
        user: WeiboMonitorUser
    ) -> some View {
        Menu {
            Button(L10n.string("weibo.accounts.checkNow", language: settings.appLanguage)) {
                Task { await monitor.checkNow(user.uid) }
            }
            Button(L10n.string("weibo.accounts.mute1h", language: settings.appLanguage)) {
                Task { await monitor.mute(user.uid) }
            }
            if user.needsManualResume || user.pausedUntil != nil || user.mutedUntil != nil {
                if user.lastErrorKind != .disk {
                    Button(L10n.string("weibo.accounts.resume", language: settings.appLanguage)) {
                        Task { await monitor.resumeUser(user.uid) }
                    }
                }
            }
            if user.gapSuspected {
                Button(L10n.string("weibo.gap.ack", language: settings.appLanguage)) {
                    Task { await monitor.clearGap(uid: user.uid) }
                }
            }
            Divider()
            Button(L10n.string("weibo.accounts.delete", language: settings.appLanguage), role: .destructive) {
                pendingDelete = user
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(monitor.isWorking)
        .accessibilityLabel(L10n.string("weibo.feed.accountMenu", language: settings.appLanguage))
    }

    private struct StatusDescription {
        let titleKey: String
        let tint: Color
        let isWarning: Bool
    }

    private func statusDescription(
        _ user: WeiboMonitorUser,
        now: Date,
        loginState: WeiboLoginState
    ) -> StatusDescription {
        if !user.enabled {
            return StatusDescription(titleKey: "weibo.accounts.disabled", tint: .secondary, isWarning: false)
        }
        if user.needsManualResume {
            return StatusDescription(titleKey: "weibo.accounts.suspended", tint: .red, isWarning: true)
        }
        if let kind = user.lastErrorKind,
           kind == .rateLimited || kind == .authExpired || kind == .challenge
            || kind == .parseChanged || kind == .disk {
            return StatusDescription(titleKey: "weibo.accounts.statusError", tint: .red, isWarning: true)
        }
        if user.consecutiveFailures >= 3 {
            return StatusDescription(titleKey: "weibo.accounts.statusError", tint: .red, isWarning: true)
        }
        if let until = user.pausedUntil, until > now {
            return StatusDescription(
                titleKey: user.consecutiveFailures >= 3
                    ? "weibo.accounts.statusError"
                    : "weibo.accounts.statusWarning",
                tint: user.consecutiveFailures >= 3 ? .red : .orange,
                isWarning: true
            )
        }
        if user.consecutiveFailures > 0
            || user.gapSuspected
            || user.isBaselinePending
            || user.lastErrorKind?.isWarning == true
            || loginState == .anonymous
            || loginState == .mobileOnly {
            return StatusDescription(titleKey: "weibo.accounts.statusWarning", tint: .orange, isWarning: true)
        }
        return StatusDescription(titleKey: "weibo.accounts.statusNormal", tint: .green, isWarning: false)
    }

    private func statusPill(_ status: StatusDescription) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.tint)
                .frame(width: 5, height: 5)
            Text(L10n.string(status.titleKey, language: settings.appLanguage))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func statusReason(_ user: WeiboMonitorUser, now: Date) -> String? {
        if user.lastErrorKind == .disk {
            return L10n.string("weibo.accounts.diskRestart", language: settings.appLanguage)
        }
        if user.needsManualResume {
            return L10n.string("weibo.accounts.suspended", language: settings.appLanguage)
        }
        if let until = user.pausedUntil, until > now {
            return L10n.string(
                "weibo.feed.pausedUntil",
                language: settings.appLanguage,
                formattedTime(until)
            )
        }
        if let mutedUntil = user.mutedUntil, mutedUntil > now {
            return L10n.string(
                "weibo.accounts.mutedUntil",
                language: settings.appLanguage,
                formattedTime(mutedUntil)
            )
        }
        if let kind = user.lastErrorKind, kind.isWarning {
            return L10n.string(kind.titleKey, language: settings.appLanguage)
        }
        if user.gapSuspected {
            return L10n.string("weibo.accounts.gapHint", language: settings.appLanguage)
        }
        return nil
    }

    private func statItem(_ text: String, symbol: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 8))
            Text(text)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func smallTag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    private func priorityColor(_ priority: WeiboMonitorPriority) -> Color {
        switch priority {
        case .p0: return .red
        case .p1: return .orange
        case .p2: return .secondary
        }
    }

    // MARK: - Add account

    private func addAccountSection(_ monitor: WeiboMonitorViewModel) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                TextField(
                    "",
                    text: $addText,
                    prompt: Text(
                        L10n.string("weibo.accounts.addPlaceholder", language: settings.appLanguage)
                    )
                )
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit { add(monitor) }

                Button {
                    add(monitor)
                } label: {
                    Label(
                        L10n.string("weibo.accounts.add", language: settings.appLanguage),
                        systemImage: "plus"
                    )
                }
                .buttonStyle(EditorialActionButtonStyle(tone: .selected, compact: true))
                .controlSize(.small)
                .disabled(
                    addText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || monitor.isAdding
                )
            }

            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("weibo.accounts.priority", language: settings.appLanguage))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $addPriority) {
                        ForEach(WeiboMonitorPriority.allCases) { priority in
                            Text(L10n.string(priority.titleKey, language: settings.appLanguage)).tag(priority)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .onChange(of: addPriority) { _, newValue in
                        addNotifyMode = WeiboNotifyMode.defaultMode(for: newValue)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("weibo.accounts.notifyMode", language: settings.appLanguage))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $addNotifyMode) {
                        ForEach(WeiboNotifyMode.allCases) { mode in
                            Text(L10n.string(mode.titleKey, language: settings.appLanguage)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }

            Text(L10n.string("weibo.accounts.addHint", language: settings.appLanguage))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)

            if let error = monitor.actionError {
                Text(error)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.red)
            }

            if monitor.isAdding {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                    Text(L10n.string("weibo.accounts.adding", language: settings.appLanguage))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func add(_ monitor: WeiboMonitorViewModel) {
        let input = addText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        Task {
            let added = await monitor.addUser(
                input: input,
                priority: addPriority,
                notifyMode: addNotifyMode
            )
            if added { addText = "" }
        }
    }

    // MARK: - Relevance

    @ViewBuilder
    private func relevanceSection(snapshot: WeiboMonitorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                L10n.string("weibo.relevance.toggle", language: language),
                isOn: Binding(
                    get: { settings.weiboMonitorRelevanceEnabled },
                    set: { settings.weiboMonitorRelevanceEnabled = $0 }
                )
            )
            .toggleStyle(.switch)

            Text(L10n.string("weibo.relevance.toggleHint", language: language))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)

            if settings.weiboMonitorRelevanceEnabled {
                Divider()

                Text(L10n.string("weibo.relevance.strength", language: language))
                    .font(.system(size: 11, weight: .medium))

                Picker(
                    L10n.string("weibo.relevance.strength", language: language),
                    selection: Binding(
                        get: { settings.weiboMonitorRelevanceMode },
                        set: { settings.weiboMonitorRelevanceMode = $0 }
                    )
                ) {
                    ForEach(WeiboRelevanceMode.allCases.filter { $0 != .off }) { mode in
                        Text(L10n.string(mode.titleKey, language: language)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(
                    L10n.string(
                        settings.weiboMonitorRelevanceMode.hintKey,
                        language: language
                    )
                )
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)

                let stats = relevanceTotals(snapshot)
                if stats.decided > 0 {
                    Text(
                        L10n.string(
                            "weibo.relevance.stats",
                            language: language,
                            stats.decided,
                            stats.relevant,
                            stats.decided - stats.relevant
                        )
                    )
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }

                Divider()

                Toggle(
                    L10n.string("weibo.relevance.aiCorrection", language: language),
                    isOn: Binding(
                        get: { settings.weiboMonitorRelevanceAICorrection },
                        set: { newValue in
                            if newValue, settings.weiboMonitorRelevancePrivacyAckAt == nil {
                                pendingAICorrection = true
                            } else {
                                settings.weiboMonitorRelevanceAICorrection = newValue
                            }
                        }
                    )
                )
                .toggleStyle(.switch)
                .confirmationDialog(
                    L10n.string("weibo.relevance.aiCorrection", language: language),
                    isPresented: $pendingAICorrection,
                    titleVisibility: .visible
                ) {
                    Button(L10n.string("weibo.relevance.aiPrivacyConfirm", language: language)) {
                        settings.weiboMonitorRelevancePrivacyAckAt = Date()
                        settings.weiboMonitorRelevanceAICorrection = true
                    }
                    Button(L10n.string("weibo.header.cancel", language: language), role: .cancel) {}
                } message: {
                    Text(L10n.string("weibo.relevance.aiPrivacy", language: language))
                }

                Text(L10n.string("weibo.relevance.aiCorrectionHint", language: language))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)

                if settings.weiboMonitorRelevanceAICorrection {
                    Text(L10n.string("weibo.relevance.aiPrivacy", language: language))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)

                    Toggle(
                        L10n.string("weibo.relevance.preferLocal", language: language),
                        isOn: Binding(
                            get: { settings.weiboMonitorRelevancePreferLocal },
                            set: { settings.weiboMonitorRelevancePreferLocal = $0 }
                        )
                    )
                    .toggleStyle(.switch)

                    Text(L10n.string("weibo.relevance.preferLocalHint", language: language))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func relevanceTotals(_ snapshot: WeiboMonitorSnapshot) -> WeiboRelevanceStats {
        var totals = WeiboRelevanceStats()
        for user in snapshot.users {
            guard let stats = user.relevanceStats else { continue }
            totals.decided += stats.decided
            totals.relevant += stats.relevant
            totals.filtered += stats.filtered
            totals.lowConfidence += stats.lowConfidence
            totals.offTopic += stats.offTopic
            totals.aiCorrected += stats.aiCorrected
            totals.disagreement += stats.disagreement
        }
        return totals
    }

    // MARK: - Advanced

    private func advancedSection(
        _ monitor: WeiboMonitorViewModel,
        snapshot: WeiboMonitorSnapshot
    ) -> some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.string("weibo.advanced.notifyToggle", language: settings.appLanguage))
                    .font(.system(size: 11, weight: .medium))
                Toggle(
                    L10n.string("weibo.advanced.notifyToggle", language: settings.appLanguage),
                    isOn: Binding(
                        get: { settings.weiboMonitorNotifyEnabled },
                        set: { settings.weiboMonitorNotifyEnabled = $0 }
                    )
                )
                .toggleStyle(.switch)
                .labelsHidden()

                Text(L10n.string("weibo.advanced.notifyToggleHint", language: settings.appLanguage))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)

                Divider()

                Text(L10n.string("weibo.advanced.intervals", language: settings.appLanguage))
                    .font(.system(size: 11, weight: .medium))

                intervalRow(
                    titleKey: "weibo.advanced.p0",
                    value: Binding(
                        get: { settings.weiboMonitorP0Seconds },
                        set: { settings.weiboMonitorP0Seconds = $0 }
                    ),
                    range: 90...900,
                    step: 30
                )
                intervalRow(
                    titleKey: "weibo.advanced.p1",
                    value: Binding(
                        get: { settings.weiboMonitorP1Seconds },
                        set: { settings.weiboMonitorP1Seconds = $0 }
                    ),
                    range: 180...1800,
                    step: 60
                )
                intervalRow(
                    titleKey: "weibo.advanced.p2",
                    value: Binding(
                        get: { settings.weiboMonitorP2Seconds },
                        set: { settings.weiboMonitorP2Seconds = $0 }
                    ),
                    range: 600...3600,
                    step: 300
                )

                Divider()

                Toggle(
                    L10n.string("weibo.advanced.night", language: settings.appLanguage),
                    isOn: Binding(
                        get: { settings.weiboMonitorNightEnabled },
                        set: { settings.weiboMonitorNightEnabled = $0 }
                    )
                )
                .toggleStyle(.switch)

                if settings.weiboMonitorNightEnabled {
                    HStack(spacing: 14) {
                        DatePicker(
                            L10n.string("weibo.advanced.nightStart", language: settings.appLanguage),
                            selection: minuteBinding(
                                get: { settings.weiboMonitorNightStartMinute },
                                set: { settings.weiboMonitorNightStartMinute = $0 }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                        DatePicker(
                            L10n.string("weibo.advanced.nightEnd", language: settings.appLanguage),
                            selection: minuteBinding(
                                get: { settings.weiboMonitorNightEndMinute },
                                set: { settings.weiboMonitorNightEndMinute = $0 }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                    }
                    .font(.system(size: 10.5))
                }

                if settings.weiboMonitorNightEnabled {
                    Text(L10n.string("weibo.advanced.nightHint", language: settings.appLanguage))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text(L10n.string("weibo.advanced.keywords", language: settings.appLanguage))
                    .font(.system(size: 11, weight: .medium))

                Toggle(
                    L10n.string("weibo.advanced.keywordNotify", language: settings.appLanguage),
                    isOn: Binding(
                        get: { settings.weiboMonitorKeywordNotifyEnabled },
                        set: { settings.weiboMonitorKeywordNotifyEnabled = $0 }
                    )
                )
                .toggleStyle(.switch)
                .labelsHidden()

                HStack(spacing: 8) {
                    TextField(
                        "",
                        text: $keywordInput,
                        prompt: Text(
                            L10n.string("weibo.advanced.keywordPlaceholder", language: settings.appLanguage)
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit { addKeyword() }

                    Button {
                        addKeyword()
                    } label: {
                        Label("", systemImage: "plus")
                    }
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
                    .controlSize(.small)
                    .disabled(keywordInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !settings.weiboMonitorKeywordList.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 64), spacing: 6)],
                        alignment: .leading,
                        spacing: 6
                    ) {
                        ForEach(settings.weiboMonitorKeywordList, id: \.self) { keyword in
                            keywordChip(keyword)
                        }
                    }
                }

                Text(L10n.string("weibo.advanced.keywordHint", language: settings.appLanguage))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)

                Divider()

                Text(L10n.string("weibo.advanced.caps", language: settings.appLanguage))
                    .font(.system(size: 11, weight: .medium))

                Stepper(
                    L10n.string(
                        "weibo.advanced.perAccountCapValue",
                        language: settings.appLanguage,
                        settings.weiboMonitorPerAccountHourlyCap
                    ),
                    value: Binding(
                        get: { settings.weiboMonitorPerAccountHourlyCap },
                        set: { settings.weiboMonitorPerAccountHourlyCap = min(50, max(1, $0)) }
                    ),
                    in: 1...50
                )
                Stepper(
                    L10n.string(
                        "weibo.advanced.globalCapValue",
                        language: settings.appLanguage,
                        settings.weiboMonitorGlobalHourlyCap
                    ),
                    value: Binding(
                        get: { settings.weiboMonitorGlobalHourlyCap },
                        set: { settings.weiboMonitorGlobalHourlyCap = min(100, max(1, $0)) }
                    ),
                    in: 1...100
                )

                HStack {
                    Text(L10n.string("weibo.advanced.backfill", language: settings.appLanguage))
                        .font(.system(size: 10.5))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { settings.weiboMonitorBackfillHours },
                        set: { settings.weiboMonitorBackfillHours = $0 }
                    )) {
                        Text("0").tag(0)
                        Text("1").tag(1)
                        Text("2").tag(2)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                Text(L10n.string("weibo.advanced.backfillHint", language: settings.appLanguage))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)

                Divider()

                Toggle(
                    L10n.string("weibo.advanced.popoverChip", language: settings.appLanguage),
                    isOn: Binding(
                        get: { settings.weiboMonitorShowPopoverChip },
                        set: { settings.weiboMonitorShowPopoverChip = $0 }
                    )
                )
                .toggleStyle(.switch)

                LaunchAtLoginRow(
                    titleKey: "weibo.advanced.loginItem",
                    hintKey: "weibo.advanced.loginItemHint"
                )
            }
            .padding(.vertical, 4)
        } label: {
            Label(
                L10n.string("weibo.advanced.title", language: settings.appLanguage),
                systemImage: "slider.horizontal.3"
            )
            .font(.system(size: 11, weight: .medium))
        }
    }

    private func intervalRow(
        titleKey: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        Stepper(
            "\(L10n.string(titleKey, language: settings.appLanguage)): \(intervalLabel(value.wrappedValue))",
            value: value,
            in: range,
            step: step
        )
        .font(.system(size: 10.5))
    }

    private func intervalLabel(_ seconds: Int) -> String {
        if seconds % 60 == 0 {
            return L10n.string(
                "weibo.advanced.minutesShort",
                language: settings.appLanguage,
                seconds / 60
            )
        }
        return L10n.string(
            "weibo.advanced.secondsShort",
            language: settings.appLanguage,
            seconds
        )
    }

    private func minuteBinding(
        get: @escaping () -> Int,
        set: @escaping (Int) -> Void
    ) -> Binding<Date> {
        Binding(
            get: { dateForMinute(get()) },
            set: { set(minuteFromDate($0)) }
        )
    }

    private func dateForMinute(_ minute: Int) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .minute, value: minute, to: start) ?? start
    }

    private func minuteFromDate(_ date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return min(1439, max(0, (components.hour ?? 0) * 60 + (components.minute ?? 0)))
    }

    private func addKeyword() {
        let value = keywordInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var list = settings.weiboMonitorKeywordList
        list.append(value)
        settings.weiboMonitorKeywordList = AppSettings.normalizedKeywords(list)
        keywordInput = ""
    }

    private func keywordChip(_ keyword: String) -> some View {
        HStack(spacing: 3) {
            Text(keyword)
                .font(.system(size: 9.5))
                .lineLimit(1)
            Button {
                settings.weiboMonitorKeywordList.removeAll { $0 == keyword }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(accent.opacity(0.10)))
    }

    // MARK: - Events

    private func eventsSection(
        _ monitor: WeiboMonitorViewModel,
        snapshot: WeiboMonitorSnapshot
    ) -> some View {
        DisclosureGroup(isExpanded: $showEvents) {
            VStack(alignment: .leading, spacing: 6) {
                if snapshot.events.isEmpty {
                    Text(L10n.string("weibo.events.empty", language: settings.appLanguage))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(snapshot.events.reversed())) { event in
                        HStack(alignment: .top, spacing: 7) {
                            Circle()
                                .fill(eventColor(event.kind))
                                .frame(width: 5, height: 5)
                                .padding(.top, 4)
                            Text(eventTime(event.at))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 42, alignment: .leading)
                            Text(event.message)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button(copied
                           ? L10n.string("weibo.events.copied", language: settings.appLanguage)
                           : L10n.string("weibo.events.copy", language: settings.appLanguage)) {
                        copyDiagnostics(snapshot)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 9.5))
                    .disabled(snapshot.events.isEmpty)

                    Spacer()
                    Text(L10n.string("weibo.events.hint", language: settings.appLanguage))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 3)
            }
            .padding(.vertical, 3)
        } label: {
            Label(
                L10n.string("weibo.events.title", language: settings.appLanguage),
                systemImage: "clock.arrow.circlepath"
            )
            .font(.system(size: 11, weight: .medium))
        }
    }

    private func eventColor(_ kind: WeiboMonitorEvent.Kind) -> Color {
        switch kind {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func eventTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: settings.appLanguage.bcp47)
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func copyDiagnostics(_ snapshot: WeiboMonitorSnapshot) {
        let formatter = ISO8601DateFormatter()
        let lines = snapshot.events.reversed().map {
            "\(formatter.string(from: $0.at)) [\($0.kind.rawValue)] \($0.message)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    // MARK: - Time

    private func formattedTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: settings.appLanguage.bcp47)
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private var unavailableState: some View {
        VStack(spacing: 8) {
            Image(systemName: "binoculars")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(L10n.string("settings.weiboMonitor", language: settings.appLanguage))
                .font(.system(size: 14, weight: .semibold))
            Text(L10n.string("weibo.header.masterHint", language: settings.appLanguage))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
