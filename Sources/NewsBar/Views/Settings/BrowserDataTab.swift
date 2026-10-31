import SwiftUI

/// Browser memory and local reading history. It contributes sections to the
/// privacy pane rather than owning a Form, so its rows share one scroll with
/// interests and storage cleanup. Both lists start collapsed so the page stays
/// short.
struct BrowserDataTab: View {
    @Environment(AppSettings.self) private var settings
    @State private var controller = BrowserDataController.shared
    @State private var archiveController = AISearchArchiveController.shared
    @State private var showCookieSites = false
    @State private var showHistory = false
    @State private var clearCookiesPrompt = false
    @State private var clearHistoryPrompt = false
    @State private var clearAISearchHistoryPrompt = false
    @State private var inspectingSite: ReaderSavedSite?

    private var english: Bool { settings.appLanguage == .en }

    var body: some View {
        Group {
            Section {
                Toggle(english ? "Remember site sign-ins (cookies)" : "记住网站登录（Cookie）", isOn: Binding(
                    get: { settings.readerCookieMemoryEnabled },
                    set: { settings.readerCookieMemoryEnabled = $0 }
                ))
                Toggle(english ? "Record reading history" : "记录阅读历史", isOn: Binding(
                    get: { settings.readerHistoryEnabled },
                    set: { settings.readerHistoryEnabled = $0 }
                ))
                Text(english
                     ? "First-party cookies are captured after a page loads and replayed when you reopen that site. Values are encrypted on this Mac; system browser cookies are never imported. Private reading and the off switch skip capture."
                     : "页面加载后自动保存该站第一方 Cookie，下次打开同一站点时回填；值加密保存在本机，不导入系统浏览器 Cookie。隐私阅读与关闭开关时均不保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(english ? "Browser memory" : "浏览记忆")
            }

            Section {
                DisclosureGroup(isExpanded: $showCookieSites) {
                    if controller.sites.isEmpty {
                        Text(english ? "No saved cookies yet. Open an article, then use the key menu in the reader." : "还没有已保存的 Cookie。打开文章后使用阅读器工具栏的钥匙菜单。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(controller.sites) { site in
                            cookieSiteRow(site)
                        }
                        Text(english
                             ? "\(controller.sites.count) sites · \(controller.totalCookieCount) cookies · values are masked until you inspect a site."
                             : "共 \(controller.sites.count) 个站点 · \(controller.totalCookieCount) 条 Cookie；展开站点后才能查看名称。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Text(english ? "Saved cookies (\(controller.sites.count))" : "已保存的 Cookie（\(controller.sites.count)）")
                }

                Button(english ? "Clear all saved cookies…" : "清除全部已保存 Cookie…", role: .destructive) {
                    clearCookiesPrompt = true
                }
                .disabled(controller.sites.isEmpty)
            } header: {
                Text(english ? "Cookies" : "Cookie")
            }

            Section {
                DisclosureGroup(isExpanded: $showHistory) {
                    if controller.history.isEmpty {
                        Text(english ? "No reading history yet." : "还没有阅读历史。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(controller.history.prefix(30))) { entry in
                            historyRow(entry)
                        }
                        if controller.history.count > 30 {
                            Text(english ? "Showing the latest 30 of \(controller.history.count) entries." : "显示最近 30 条，共 \(controller.history.count) 条。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    Text(english ? "Reading history (\(controller.history.count))" : "阅读历史（\(controller.history.count)）")
                }

                Button(english ? "Clear reading history…" : "清除阅读历史…", role: .destructive) {
                    clearHistoryPrompt = true
                }
                .disabled(controller.history.isEmpty)
            } header: {
                Text(english ? "History" : "历史")
            }

            Section {
                Toggle(
                    L10n.string("settings.browser.aiSearchHistory.enabled", language: settings.appLanguage),
                    isOn: Binding(
                        get: { settings.aiSearchHistoryEnabled },
                        set: { settings.aiSearchHistoryEnabled = $0 }
                    )
                )
                Text(L10n.string("settings.browser.aiSearchHistory.detail", language: settings.appLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.string(
                    "settings.browser.aiSearchHistory.count",
                    language: settings.appLanguage,
                    archiveController.entries.count
                ))
                    .font(.caption)
                if let error = archiveController.storageError {
                    Text(L10n.string(
                        "settings.browser.aiSearchHistory.error",
                        language: settings.appLanguage,
                        error
                    ))
                    .font(.caption)
                    .foregroundStyle(.red)
                }
                Button(
                    L10n.string("settings.browser.aiSearchHistory.clear", language: settings.appLanguage),
                    role: .destructive
                ) {
                    clearAISearchHistoryPrompt = true
                }
                .disabled(
                    !archiveController.isReady
                        || (archiveController.entries.isEmpty && archiveController.storageError == nil)
                )
            } header: {
                Text(L10n.string("settings.browser.aiSearchHistory.title", language: settings.appLanguage))
            }

            if let error = controller.storageError {
                Section {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .task {
            await controller.prepare()
            await archiveController.prepare()
        }
        .confirmationDialog(
            english ? "Clear all saved cookies?" : "清除全部已保存 Cookie？",
            isPresented: $clearCookiesPrompt
        ) {
            Button(english ? "Clear cookies" : "清除 Cookie", role: .destructive) {
                Task { await controller.clearCookies() }
            }
        } message: {
            Text(english ? "Saved sign-ins will be removed from this Mac. This cannot be undone." : "将删除本机保存的所有站点登录 Cookie，无法撤销。")
        }
        .confirmationDialog(
            english ? "Clear reading history?" : "清除阅读历史？",
            isPresented: $clearHistoryPrompt
        ) {
            Button(english ? "Clear history" : "清除历史", role: .destructive) {
                Task { await controller.clearHistory() }
            }
        } message: {
            Text(english ? "Only the local list of opened articles is removed; personalization data is untouched." : "只删除本机的已打开文章列表，不影响个性化数据。")
        }
        .confirmationDialog(
            L10n.string("settings.browser.aiSearchHistory.clear.title", language: settings.appLanguage),
            isPresented: $clearAISearchHistoryPrompt
        ) {
            Button(
                L10n.string("settings.browser.aiSearchHistory.clear.confirm", language: settings.appLanguage),
                role: .destructive
            ) {
                Task { await archiveController.clear() }
            }
            Button(
                L10n.string("settings.browser.aiSearchHistory.clear.cancel", language: settings.appLanguage),
                role: .cancel
            ) {}
        } message: {
            Text(L10n.string("settings.browser.aiSearchHistory.clear.message", language: settings.appLanguage))
        }
        .sheet(item: $inspectingSite) { site in
            CookieSiteInspector(
                site: site,
                english: english,
                onForget: {
                    Task { await controller.removeSite(site.host) }
                    inspectingSite = nil
                }
            )
        }
    }

    private func cookieSiteRow(_ site: ReaderSavedSite) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(site.host)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(site.title?.isEmpty == false ? site.title! : site.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(english ? "\(site.cookies.count) cookies" : "\(site.cookies.count) 条")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(site.updatedAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button(english ? "Inspect" : "查看") {
                inspectingSite = site
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) {
                Task { await controller.removeSite(site.host) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(english ? "Forget this site" : "移除此站登录")
        }
    }

    private func historyRow(_ entry: ReaderHistoryEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 12))
                    .lineLimit(2)
                Text(english
                     ? "\(entry.host) · \(entry.visitCount) visit\(entry.visitCount == 1 ? "" : "s")"
                     : "\(entry.host) · \(entry.visitCount) 次")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(entry.lastOpenedAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button {
                NewsNavigationRouter.shared.open(url: entry.url, title: entry.title, surface: "settingsHistory")
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(english ? "Open this article" : "重新打开这篇文章")
            Button(role: .destructive) {
                Task { await controller.removeHistory(entry.id) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(english ? "Remove from history" : "从历史中删除")
        }
    }
}

private struct CookieSiteInspector: View {
    let site: ReaderSavedSite
    let english: Bool
    let onForget: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var revealValues = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(site.host).font(.headline)
                    Text(english
                         ? "Saved \(site.savedAt.formatted(date: .abbreviated, time: .shortened))"
                         : "保存于 \(site.savedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(english ? "Done" : "完成") { dismiss() }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    let cookies: [ReaderStoredCookie] = site.cookies
                    ForEach(cookies, id: \.identity) { cookie in
                        cookieRow(cookie, isLast: cookie.identity == cookies.last?.identity)
                    }
                }
            }

            Divider()

            HStack {
                Toggle(english ? "Show values" : "显示值", isOn: $revealValues)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
                Button(english ? "Forget this site…" : "移除此站登录…", role: .destructive, action: onForget)
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 360)
    }

    @ViewBuilder
    private func cookieRow(_ cookie: ReaderStoredCookie, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(cookie.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                if cookie.isSecure {
                    Text("Secure").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                if cookie.isHTTPOnly {
                    Text("HTTP-only").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            Text(cookie.domain + cookie.path)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(revealValues ? cookie.value : "••••••••••••")
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(expiryLabel(cookie))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        if !isLast { Divider() }
    }

    private func expiryLabel(_ cookie: ReaderStoredCookie) -> String {
        if let expiresAt = cookie.expiresAt {
            return english
                ? "Expires \(expiresAt.formatted(date: .abbreviated, time: .shortened))"
                : "到期 \(expiresAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return english ? "Session cookie · kept 30 days" : "会话 Cookie · 保留 30 天"
    }
}
