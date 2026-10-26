import AppKit
import SwiftUI
import WebKit

@MainActor
@Observable
final class NewsReaderModel: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let request: NewsReaderRequest
    private(set) var webView: WKWebView?
    var loading = true
    private(set) var failure: ReaderFailure?
    var errorMessage: String? { failure?.message(language: L10n.currentLanguage) }
    var canRetry: Bool { failure?.canRetry ?? true }
    var canOpenExternally: Bool {
        failure != .privateDestination && ReaderNavigationPolicy.allowedURL(currentURL) != nil
    }
    private(set) var progress: Double = 0
    private(set) var pageTitle: String
    private(set) var notice: ReaderFailure?
    var currentURL: String
    var canGoBack = false
    var canGoForward = false
    private var evidence = ReaderEvidence()
    private var loaded = false
    private var attributed = false
    private var adapted = false
    private var nonce = UUID().uuidString
    private var timer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var lastMessageAt: TimeInterval = 0
    private var stopped = false
    private var terminalState = ReadingTerminalState.unknown
    private var suspended = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var urlObserver: NSKeyValueObservation?
    private var progressObserver: NSKeyValueObservation?
    private var backObserver: NSKeyValueObservation?
    private var forwardObserver: NSKeyValueObservation?
    private let world = WKContentWorld.world(name: "NewsBarAggregateMetrics")
    private let proxyController: ReaderProxyController
    private var proxySession: ReaderProxySession?
    private var networkRevision: UUID

    var usesTrustedProxy: Bool { proxySession != nil }
    private var networkContextIsCurrent: Bool {
        guard networkRevision == proxyController.revision else { return false }
        if let proxySession { return proxyController.isCurrent(proxySession) }
        return proxyController.mode == .strict
    }

    convenience init(request: NewsReaderRequest) {
        self.init(request: request, proxyController: .shared)
    }

    init(request: NewsReaderRequest, proxyController: ReaderProxyController) {
        self.request = request
        self.proxyController = proxyController
        self.networkRevision = proxyController.revision
        currentURL = request.url
        pageTitle = request.title
        super.init()
    }

    func start() async {
        guard webView == nil, !stopped else { return }
        networkRevision = proxyController.revision
        do { proxySession = try proxyController.authorizedSession() }
        catch { fail(.proxyTrustRequired); return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if let proxySession { configuration.websiteDataStore.proxyConfigurations = [proxySession.configuration] }
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        do {
            let rules = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "newsbar-local-resource-policy-v1", encodedContentRuleList: ReaderNavigationPolicy.resourceRules)
            if let rules { configuration.userContentController.add(rules) }
            else { throw NewsBarError.requestFailed }
        } catch {
            loading = false
            failure = .safetyRulesUnavailable
            return
        }
        guard !stopped else { return }
        guard networkContextIsCurrent else { fail(.proxyTrustRequired); return }
        configuration.userContentController.add(self, contentWorld: world, name: "aggregate")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        webView = web
        progressObserver = web.observe(\.estimatedProgress, options: [.new]) { [weak self] web, _ in
            let value = web.estimatedProgress
            Task { @MainActor [weak self] in self?.progress = value }
        }
        backObserver = web.observe(\.canGoBack, options: [.new]) { [weak self] web, _ in
            let value = web.canGoBack
            Task { @MainActor [weak self] in self?.canGoBack = value }
        }
        forwardObserver = web.observe(\.canGoForward, options: [.new]) { [weak self] web, _ in
            let value = web.canGoForward
            Task { @MainActor [weak self] in self?.canGoForward = value }
        }
        urlObserver = web.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentURL = self.webView?.url?.absoluteString ?? self.request.url
                if ContentIdentity.canonicalURL(self.currentURL) != ContentIdentity.canonicalURL(self.request.url) {
                    // Includes SPA history changes: never attribute another document to the original item.
                    self.attributed = false
                    self.loaded = false
                }
            }
        }
        installLifecycleObservers()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        loadInitial()
    }

    func stop(terminal: ReadingTerminalState? = nil) {
        guard !stopped else { return }
        tick(final: true)
        if let item = request.item, !request.privateSession {
            let finalState = terminal ?? (evidence.signal(articleAdapted: adapted) == .qualifiedRead || evidence.signal(articleAdapted: adapted) == .deepRead ? .engaged : terminalState)
            InterestController.shared.recordSession(ReadingSessionRecord(id: request.id, epoch: request.consentEpoch,
                newsItemID: item.id, contentID: ContentIdentity.id(for: item.url), surface: request.surface, contextID: request.contextID,
                endedAt: Date(), activeSeconds: evidence.activeSeconds, scrollCoverage: evidence.scrollCoverage,
                articleAdapted: adapted, terminalState: finalState))
        }
        stopped = true
        timer?.invalidate()
        timer = nil
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
        urlObserver?.invalidate()
        progressObserver?.invalidate()
        backObserver?.invalidate()
        forwardObserver?.invalidate()
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "aggregate", contentWorld: world)
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil // ephemeral cookies/data are released with the session
    }

    func loadInitial() {
        guard let url = ReaderNavigationPolicy.allowedURL(request.url) else {
            fail(.unsupportedURL, kind: .blocked)
            return
        }
        failure = nil
        webView?.load(URLRequest(url: url))
    }

    func reload() {
        guard canRetry, !stopped else { return }
        failure = nil
        notice = nil
        loading = true
        if webView == nil { Task { await start() } }
        else if webView?.url == nil { loadInitial() }
        else { webView?.reload() }
    }

    func dismissNotice() { notice = nil }

    private func installLifecycleObservers() {
        let proxyToken = NotificationCenter.default.addObserver(forName: .readerNetworkContextChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped, !self.networkContextIsCurrent else { return }
                self.fail(.proxyTrustRequired)
                self.stop(terminal: .error)
            }
        }
        observers.append((NotificationCenter.default, proxyToken))
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        for (center, name, paused) in [
            (distributed as NotificationCenter, Notification.Name("com.apple.screenIsLocked"), true),
            (distributed as NotificationCenter, Notification.Name("com.apple.screenIsUnlocked"), false),
            (workspace, NSWorkspace.willSleepNotification, true),
            (workspace, NSWorkspace.didWakeNotification, false)
        ] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.suspended = paused
                    self?.lastTick = ProcessInfo.processInfo.systemUptime
                }
            }
            observers.append((center, token))
        }
    }

    private func tick(final: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastTick
        lastTick = now
        guard !stopped, attributed, let webView, let item = request.item,
              !request.privateSession, !InterestController.shared.privateReading else { return }
        let window = webView.window
        let visible = window?.isVisible == true && window?.occlusionState.contains(.visible) == true && !webView.isHiddenOrHasHiddenAncestor
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        let keyboardIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let scrollIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel)
        let systemSession = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = systemSession?["CGSSessionScreenIsLocked"] as? Bool ?? false
        evidence.tick(elapsed: elapsed, loaded: loaded, active: NSApp.isActive && window?.isKeyWindow == true,
                      visible: visible, unlocked: !suspended && !locked, idle: min(idle, min(keyboardIdle, scrollIdle)))
        // Aggregated evidence only; never persist per-frame trajectories.
        if evidence.shouldEmit(final: final), let kind = evidence.signal(articleAdapted: adapted) {
            InterestController.shared.record(item, kind: kind, epoch: request.consentEpoch, sessionID: request.id)
        }
    }

    private func fail(_ reason: ReaderFailure, kind: InterestEventKind = .failed) {
        loading = false
        loaded = false
        attributed = false
        failure = reason
        terminalState = kind == .blocked ? .blocked : .error
        if let item = request.item, !request.privateSession {
            InterestController.shared.record(item, kind: kind, epoch: request.consentEpoch, sessionID: request.id)
        }
    }

    private func blockMainNavigation(_ reason: ReaderFailure) {
        if loaded {
            notice = reason
            loading = false
        } else { fail(reason, kind: reason == .networkUnavailable ? .failed : .blocked) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let isSubframe = navigationAction.targetFrame?.isMainFrame == false
        guard !stopped, networkContextIsCurrent else { return .cancel }
        let raw = navigationAction.request.url?.absoluteString ?? ""
        // Empty/srcdoc frames are browser-created documents, not external URL
        // exceptions. Never allow them as a top-level destination.
        if isSubframe && (raw == "about:blank" || raw == "about:srcdoc") { return .allow }
        if navigationAction.targetFrame == nil, navigationAction.navigationType != .linkActivated { return .cancel }
        guard !navigationAction.shouldPerformDownload else {
            if !isSubframe { blockMainNavigation(.downloadBlocked) }
            return .cancel
        }
        guard let url = ReaderNavigationPolicy.allowedURL(raw) else {
            if !isSubframe { blockMainNavigation(.unsupportedURL) }
            return .cancel
        }
        // An explicitly trusted CONNECT proxy owns destination resolution.
        // Local Fake-IP is not evidence of its final destination; all URL and
        // download restrictions still apply. Strict sessions keep DNS checks.
        if proxySession == nil {
            let destination = await ReaderNavigationPolicy.resolveDestination(url)
            guard destination == .publicDestination else {
                if !isSubframe { blockMainNavigation(destination == .privateDestination ? .privateDestination : .networkUnavailable) }
                return .cancel
            }
        }
        guard !stopped, networkContextIsCurrent else { return .cancel }
        if navigationAction.targetFrame == nil {
            // User-clicked target=_blank links reuse the isolated reader, never a browser popup.
            webView.load(URLRequest(url: url))
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard !stopped, networkContextIsCurrent else { return .cancel }
        guard navigationResponse.canShowMIMEType else {
            if navigationResponse.isForMainFrame {
                blockMainNavigation(.downloadBlocked)
            }
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !stopped, networkContextIsCurrent else { webView.stopLoading(); return }
        tick()
        nonce = UUID().uuidString
        evidence = ReaderEvidence()
        loading = true
        progress = 0
        loaded = false
        attributed = false
        adapted = false
        failure = nil
        notice = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !stopped, networkContextIsCurrent else { return }
        loading = false
        progress = 1
        loaded = true
        lastTick = ProcessInfo.processInfo.systemUptime
        currentURL = webView.url?.absoluteString ?? request.url
        pageTitle = webView.title?.isEmpty == false ? (webView.title ?? request.title) : request.title
        attributed = ContentIdentity.canonicalURL(currentURL) == ContentIdentity.canonicalURL(request.url)
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        let path = webView.url?.path.lowercased() ?? ""
        if ["login", "signin", "account", "passport", "captcha", "challenge"].contains(where: path.contains) { attributed = false }
        guard attributed, InterestController.shared.canLearn, !request.privateSession else { return }
        // Explicit site adapters only. Unknown sites receive weak native-time evidence.
        let host = webView.url?.host?.lowercased() ?? ""
        let adapters = ["ithome.com": "#paragraph", "sspai.com": "article", "arstechnica.com": "article", "bbc.com": "article", "theguardian.com": "article"]
        guard let adapter = adapters.first(where: { host == $0.key || host.hasSuffix("." + $0.key) }) else { return }
        let token = nonce
        let script = """
        (() => {
          const root = document.querySelector('\(adapter.value)');
          if (!root || document.querySelector('input[type=password]')) return;
          const originURL = location.href;
          const send = () => {
            if (location.href !== originURL) return;
            const rect = root.getBoundingClientRect();
            const length = Math.min(200000, (root.textContent || '').length);
            const scroll = Math.max(0, Math.min(1, (innerHeight - rect.top) / Math.max(1, rect.height)));
            window.webkit.messageHandlers.aggregate.postMessage({nonce:'\(token)', url:originURL, length:length, scroll:scroll});
          };
          send(); setInterval(send, 5000);
        })();
        """
        webView.evaluateJavaScript(script, in: nil, in: world) { _ in }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !stopped, message.frameInfo.isMainFrame, loaded, attributed,
              InterestController.shared.canLearn, !request.privateSession,
              now - lastMessageAt >= 4,
              let body = message.body as? [String: Any], body["nonce"] as? String == nonce,
              let raw = body["url"] as? String, raw == webView?.url?.absoluteString,
              let length = body["length"] as? Int, (100...200_000).contains(length),
              let scroll = body["scroll"] as? Double, scroll.isFinite, (0...1).contains(scroll) else { return }
        lastMessageAt = now
        adapted = true
        evidence.estimatedReadingSeconds = max(30, min(1200, Double(length) / 8))
        evidence.setScroll(scroll)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !stopped else { return }
        if (error as NSError).code != NSURLErrorCancelled { fail(proxySession == nil ? .networkUnavailable : .proxyUnavailable) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !stopped else { return }
        if (error as NSError).code != NSURLErrorCancelled { fail(proxySession == nil ? .networkUnavailable : .proxyUnavailable) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !stopped, networkContextIsCurrent else { return }
        fail(.processTerminated)
    }
}

private struct ReaderWebSurface: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct NewsReaderView: View {
    @State private var model: NewsReaderModel
    var onOpenSettings: () -> Void = {}

    init(request: NewsReaderRequest, onOpenSettings: @escaping () -> Void = {}) {
        _model = State(initialValue: NewsReaderModel(request: request))
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        ReaderContentView(model: model, onClose: { NewsNavigationRouter.shared.close() }, onOpenSettings: onOpenSettings)
            .task { await model.start() }
            .onDisappear { model.stop() }
            .onReceive(NotificationCenter.default.publisher(for: .interestDataCleared)) { _ in
                model.stop()
                NewsNavigationRouter.shared.close()
            }
    }
}

/// Injected observable state keeps the native chrome independently renderable;
/// the owning NewsReaderView controls the web-session lifecycle.
struct ReaderContentView: View {
    @Bindable var model: NewsReaderModel
    var onClose: () -> Void
    var onOpenSettings: () -> Void = {}
    @State private var lastFeedback: UUID?
    @State private var feedbackMessage: String?
    @State private var askExternal = false
    @State private var showPrivacy = false
    @Environment(AppSettings.self) private var settings

    private var english: Bool { settings.appLanguage == .en }
    private var controller: InterestController { InterestController.shared }
    private var isBookmarked: Bool {
        guard let item = model.request.item else { return false }
        return controller.state.feedbacks.contains { $0.kind == .bookmark && ContentIdentity.id(for: $0.item.url) == ContentIdentity.id(for: item.url) }
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                toolbar(compact: geometry.size.width < 700)
                    .padding(.horizontal, 12)
                    .frame(height: 58)
            }
            .frame(height: 58)
            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .opacity(model.loading ? 1 : 0)
                .frame(height: 3)
                .accessibilityLabel(english ? "Page loading progress" : "网页加载进度")
                .accessibilityHidden(!model.loading)
            if let notice = model.notice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: notice.symbol).foregroundStyle(.secondary)
                    Text(notice.message(language: settings.appLanguage)).font(.caption)
                    Spacer(minLength: 0)
                    Button { model.dismissNotice() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(english ? "Dismiss notice" : "关闭提示")
                }
                .padding(12)
                .background(.quaternary.opacity(0.4))
            }
            if let failure = model.failure {
                failureContent(failure)
            } else if let web = model.webView {
                ReaderWebSurface(webView: web)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(english ? "Preparing a private web session…" : "正在准备临时阅读会话…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let message = feedbackMessage {
                HStack {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    Text(message)
                    Spacer()
                    if let id = lastFeedback {
                        Button(english ? "Undo" : "撤销") {
                            controller.undo(id)
                            lastFeedback = nil
                            feedbackMessage = nil
                        }
                    }
                    Button { feedbackMessage = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(english ? "Dismiss feedback confirmation" : "关闭反馈确认")
                }
                .font(.caption).padding(10)
                .background(.quaternary.opacity(0.4))
            }
            Divider()
            footer
        }
        .newsCardSurface(cornerRadius: 12)
        .confirmationDialog(english ? "Open in your browser?" : "在系统浏览器打开？", isPresented: $askExternal) {
            Button(english ? "Open" : "打开") {
                let url = model.currentURL
                model.stop(terminal: .handoff)
                NewsNavigationRouter.shared.external(model.request, currentURL: url)
                onClose()
            }
        } message: {
            Text(english ? "Your browser's cookies and history settings will apply. Reading measurement ends at handoff." : "将使用浏览器自身的 Cookie 和历史设置；外开不作为有效阅读。")
        }
    }

    private func toolbar(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                HStack(spacing: 5) {
                    Image(systemName: "sidebar.left")
                    if !compact { Text(english ? "Back to list" : "返回列表") }
                }
                .frame(minWidth: 28, minHeight: 28)
            }
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel(english ? "Back to list" : "返回列表")
            .help(english ? "Back to list (Esc)" : "返回列表（Esc）")
            HStack(spacing: 2) {
                Button { model.webView?.goBack() } label: { Image(systemName: "chevron.left").frame(width: 28, height: 28) }
                    .disabled(!model.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .accessibilityLabel(english ? "Previous page" : "上一页")
                    .help(english ? "Previous page (⌘[)" : "上一页（⌘[）")
                Button { model.webView?.goForward() } label: { Image(systemName: "chevron.right").frame(width: 28, height: 28) }
                    .disabled(!model.canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
                    .accessibilityLabel(english ? "Next page" : "下一页")
                    .help(english ? "Next page (⌘])" : "下一页（⌘]）")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(model.pageTitle).font(.system(size: 13, weight: .medium)).lineLimit(1).help(model.pageTitle)
                Text(URL(string: model.currentURL)?.host ?? (english ? "News link" : "新闻链接"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button { model.reload() } label: { Image(systemName: "arrow.clockwise").frame(width: 28, height: 28) }
                .disabled(!model.canRetry)
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityLabel(english ? "Reload page" : "重新加载网页")
                .help(english ? "Reload page (⌘R)" : "重新加载网页（⌘R）")
            if let item = model.request.item {
                Button {
                    lastFeedback = controller.toggleBookmark(item)
                    feedbackMessage = isBookmarked ? (english ? "Article bookmarked" : "已收藏文章") : (english ? "Bookmark removed" : "已取消收藏")
                } label: { Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark").frame(width: 28, height: 28) }
                .disabled(!controller.canLearn)
                .accessibilityLabel(isBookmarked ? (english ? "Remove bookmark" : "取消收藏") : (english ? "Bookmark article" : "收藏文章"))
                .help(controller.canLearn ? (isBookmarked ? (english ? "Remove bookmark" : "取消收藏") : (english ? "Bookmark article" : "收藏文章"))
                      : (english ? "Enable local personalization to bookmark and give feedback" : "开启本地个性化后可收藏和反馈"))
                Menu {
                    Button(english ? "More like this (session)" : "更多同类（本次会话）") { recordFeedback(item, kind: .moreLikeThis) }
                    Divider()
                    Button(english ? "Not interested: this article" : "不感兴趣：仅这条") { recordFeedback(item, kind: .notInterested) }
                    Button(english ? "Hide this event" : "不再看这个事件") { recordFeedback(item, kind: .hideEvent) }
                    Button(english ? "Mute this source" : "屏蔽这个来源") { recordFeedback(item, kind: .muteSource) }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 28, height: 28) }
                .disabled(!controller.canLearn)
                .accessibilityLabel(english ? "Article preferences" : "文章偏好操作")
                .help(english ? "More reading preferences" : "更多阅读偏好")
            }
            Button { askExternal = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.forward.app")
                    if !compact { Text(english ? "Browser" : "浏览器打开") }
                }
                .frame(minWidth: 28, minHeight: 28)
            }
            .disabled(!model.canOpenExternally)
            .accessibilityLabel(english ? "Open article in browser" : "在浏览器中打开原文")
            .help(english ? "Open article in your browser" : "在系统浏览器中打开原文")
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
    }

    private func failureContent(_ failure: ReaderFailure) -> some View {
        VStack(spacing: 16) {
            Image(systemName: failure.symbol).font(.system(size: 36, weight: .light)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(failure.title(language: settings.appLanguage)).font(.title3.weight(.semibold))
            Text(failure.message(language: settings.appLanguage)).font(.callout).foregroundStyle(.secondary).lineSpacing(4)
            HStack(spacing: 12) {
                if failure == .proxyTrustRequired || failure == .proxyUnavailable {
                    Button(english ? "Reader network settings" : "阅读器网络设置", action: onOpenSettings)
                        .buttonStyle(EditorialActionButtonStyle())
                }
                if model.canRetry {
                    Button(english ? "Try again" : "重新加载") { model.reload() }
                        .buttonStyle(EditorialActionButtonStyle())
                }
                if model.canOpenExternally {
                    Button { askExternal = true } label: { Label(english ? "Open in browser" : "在浏览器打开", systemImage: "arrow.up.forward.app") }
                        .buttonStyle(EditorialActionButtonStyle(tone: .primary))
                }
            }
            Button(english ? "Back to news list" : "返回新闻列表", action: onClose).buttonStyle(.borderless)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Label(english ? "Temporary session" : "临时会话", systemImage: "lock.shield")
            if model.usesTrustedProxy {
                Text(english ? "· Trusted proxy" : "· 受信任代理")
                    .help(english ? "Destination resolution is delegated to the proxy; the reader cannot verify its final destination IP." : "目标解析交给代理；阅读器无法核验其最终连接 IP。")
            }
            Text("·").accessibilityHidden(true)
            Text(model.request.privateSession || !controller.canLearn || model.request.consentEpoch != controller.state.consentEpoch
                 ? (english ? "Not learning from this session" : "本次不参与学习")
                 : (english ? "Learning stays on this Mac" : "仅在本机学习"))
            Spacer(minLength: 0)
            Button { showPrivacy = true } label: { Image(systemName: "info.circle") }
                .accessibilityLabel(english ? "Reading privacy details" : "阅读隐私说明")
                .popover(isPresented: $showPrivacy) {
                    Text(english ? "This web session does not share browser cookies or store website sign-ins. Site restrictions still apply. Only supported article pages can produce qualified-reading evidence; unknown sites use weak browsing evidence." : "网页会话不共享浏览器 Cookie，不保存网站登录，不绕过网站限制。只有适配的文章页才采集合格阅读证据；未适配站点仅使用弱浏览信号。")
                        .font(.callout).padding(16).frame(width: 320)
                }
            Button(english ? "Privacy settings" : "隐私设置", action: onOpenSettings)
        }
        .font(.caption).foregroundStyle(.secondary)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private func recordFeedback(_ item: NewsItem, kind: InterestFeedbackKind) {
        lastFeedback = controller.feedback(item, kind: kind)
        if lastFeedback != nil { feedbackMessage = english ? "Reading preference updated" : "已更新阅读偏好" }
    }
}
