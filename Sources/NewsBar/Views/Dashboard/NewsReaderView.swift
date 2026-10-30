import AppKit
import os
import SwiftUI
import WebKit

private let readerCookieLogger = Logger(subsystem: "com.newsbar.app", category: "ReaderCookie")

@MainActor
enum ReaderRuleListCache {
    private static let identifier = "newsbar-local-resource-policy-v1"
    private static var cached: WKContentRuleList?
    private static var inFlight: Task<WKContentRuleList?, Never>?

    static func prewarm() async {
        _ = await rules()
    }

    static func rules() async -> WKContentRuleList? {
        if let cached { return cached }
        if let inFlight { return await inFlight.value }
        let task = Task { () -> WKContentRuleList? in
            do {
                return try await WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: identifier,
                    encodedContentRuleList: ReaderNavigationPolicy.resourceRules
                )
            } catch {
                return nil
            }
        }
        inFlight = task
        let list = await task.value
        inFlight = nil
        if let list { cached = list }
        return list
    }
}

@MainActor
@Observable
final class NewsReaderModel: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKHTTPCookieStoreObserver {
    struct SessionOptions: Equatable {
        var cookieMemoryEnabled = false
        var historyEnabled = false
    }

    /// A right-click on selected page text. The view owns presentation; the
    /// model only reports what the user selected.
    struct SelectionExplainRequest: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

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
    private(set) var selectionExplainRequest: SelectionExplainRequest?
    /// Reader mode is a native re-layout of the current page. It is cleared on
    /// every navigation and on close, so a stale article can never be shown for
    /// a different URL.
    private(set) var readerModeDocument: ReaderModeDocument?
    private(set) var isReaderModeActive = false
    private(set) var isReaderModeExtracting = false
    private(set) var readerModeNotice: String?
    private let readerModeExtractor = ReaderModeExtractor()
    var currentURL: String
    var canGoBack = false
    var canGoForward = false
    private var evidence = ReaderEvidence()
    private var openAttribution = OpenAttribution()
    private var documentAttribution = DocumentAttribution()
    private var loaded = false
    private var attributed = false
    private var adapted = false
    private var nonce = UUID().uuidString
    /// Fixed for the reader session. The user script survives navigations, so a
    /// per-navigation nonce would reject the first link the reader follows.
    private let selectionToken = UUID().uuidString
    private var timer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var lastMessageAt: TimeInterval = 0
    private var stopped = false
    private var sessionOptions = SessionOptions()
    private var didRecordHistory = false
    private var observingCookieStore: WKHTTPCookieStore?
    private var cookieCaptureTask: Task<Void, Never>?
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

    func start(options: SessionOptions? = nil) async {
        guard webView == nil, !stopped else { return }
        ReaderSessionRegistry.active = self
        if let options { sessionOptions = options }
        networkRevision = proxyController.revision
        do { proxySession = try proxyController.authorizedSession() }
        catch { fail(.proxyTrustRequired); return }
        recordHistoryIfNeeded()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if let proxySession { configuration.websiteDataStore.proxyConfigurations = [proxySession.configuration] }
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        guard let rules = await ReaderRuleListCache.rules() else {
            loading = false
            failure = .safetyRulesUnavailable
            return
        }
        configuration.userContentController.add(rules)
        guard !stopped else { return }
        guard networkContextIsCurrent else { fail(.proxyTrustRequired); return }
        configuration.userContentController.add(self, contentWorld: world, name: "aggregate")
        configuration.userContentController.add(self, contentWorld: world, name: "selectionMenu")
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.selectionMenuScript(token: selectionToken),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
                in: world
            )
        )
        // Give the opening transition a chance to paint before WebKit's
        // synchronous construction and first layout land on the main thread.
        try? await Task.sleep(for: .milliseconds(50))
        guard !stopped else { return }
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.customUserAgent = ReaderUserAgent.value()
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        webView = web
        readerModeExtractor.attach(to: web, world: world)
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
        if sessionOptions.cookieMemoryEnabled, !request.privateSession {
            let hosts = ReaderCookieSiteScope.injectionHosts(for: request.url)
            if !hosts.isEmpty {
                await BrowserDataController.shared.prepare()
                let cookies = await BrowserDataController.shared.cookiesForInjection(hosts: hosts)
                let cookieStore = web.configuration.websiteDataStore.httpCookieStore
                await injectCookies(cookies, into: cookieStore)
                guard !stopped else { return }
                #if DEBUG
                await verifyInjectedCookies(cookies, in: cookieStore, host: hosts.joined(separator: ","))
                #endif
                cookieStore.add(self)
                observingCookieStore = cookieStore
            }
        }
        guard !stopped, networkContextIsCurrent else { return }
        installLifecycleObservers()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        loadInitial()
    }

    func stop(terminal: ReadingTerminalState? = nil) {
        guard !stopped else { return }
        tick(final: true)
        cookieCaptureTask?.cancel()
        cookieCaptureTask = nil
        observingCookieStore?.remove(self)
        observingCookieStore = nil
        if sessionOptions.cookieMemoryEnabled, !request.privateSession,
           let cookieStore = webView?.configuration.websiteDataStore.httpCookieStore {
            let host = currentHost
            let title = pageTitle
            let allowEmptyRemoval = isLogoutDestination
            Task {
                let cookies = await cookieStore.allCookies()
                guard let host else { return }
                let count = await BrowserDataController.shared.capture(
                    cookies: cookies, host: host, title: title, allowEmptyRemoval: allowEmptyRemoval
                )
                readerCookieLogger.debug("capture host=\(host, privacy: .public) cookies=\(cookies.count, privacy: .public) stored=\(count, privacy: .public) reason=stop")
            }
        }
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
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "selectionMenu", contentWorld: world)
        readerModeExtractor.detach()
        readerModeDocument = nil
        isReaderModeActive = false
        isReaderModeExtracting = false
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        if ReaderSessionRegistry.active === self { ReaderSessionRegistry.active = nil }
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

    // MARK: - Reader mode

    /// Extracts the current document into a native re-layout. Failure never
    /// blanks the reader: the web view stays visible and one line explains why.
    func toggleReaderMode() async {
        if isReaderModeActive {
            exitReaderMode()
            return
        }
        guard !isReaderModeExtracting, !loading, loaded, webView?.url != nil else { return }
        isReaderModeExtracting = true
        readerModeNotice = nil
        let extraction = await readerModeExtractor.extract()
        isReaderModeExtracting = false
        if let document = extraction.document {
            readerModeDocument = document
            isReaderModeActive = true
        } else {
            readerModeDocument = nil
            isReaderModeActive = false
            readerModeNotice = (extraction.error ?? .tooShort).message(language: L10n.currentLanguage)
        }
    }

    func exitReaderMode() {
        readerModeDocument = nil
        isReaderModeActive = false
        isReaderModeExtracting = false
        readerModeNotice = nil
    }

    func dismissReaderModeNotice() { readerModeNotice = nil }

    /// Links inside the native layout reuse the reader's own web session and
    /// leave reader mode, so the destination is checked by the same navigation
    /// policy as every other page.
    func openReaderModeLink(_ url: URL) {
        guard ReaderNavigationPolicy.allowedURL(url.absoluteString) != nil else { return }
        exitReaderMode()
        webView?.load(URLRequest(url: url))
    }

    /// Plain text for the AI search panel's "current page" scope. It reuses the
    /// same extractor instead of a second text pipeline.
    func currentPagePlainText() async -> String? {
        if let readerModeDocument { return readerModeDocument.plainText }
        let extraction = await readerModeExtractor.extract()
        return extraction.document?.plainText
    }

    var initialHost: String? {
        ReaderCookieHost.normalize(URL(string: request.url)?.host)
    }

    var currentHost: String? {
        ReaderCookieHost.normalize(webView?.url?.host)
            ?? ReaderCookieHost.normalize(URL(string: currentURL)?.host)
            ?? initialHost
    }

    private func recordHistoryIfNeeded() {
        guard sessionOptions.historyEnabled, !request.privateSession, !didRecordHistory,
              let host = initialHost else { return }
        didRecordHistory = true
        let url = request.url
        let title = request.title
        Task { await BrowserDataController.shared.recordOpen(url: url, title: title, host: host) }
    }

    /// Captures the current page's first-party cookies. An explicit save still works
    /// when the global switch is off; the view turns the switch on for that case.
    /// - Parameter allowEmptyRemoval: only a capture made on the site's log-out
    ///   destination may clear a saved site when the jar comes back empty.
    func captureCurrentSite(force: Bool = false, allowEmptyRemoval: Bool = false) async -> Int {
        guard force || sessionOptions.cookieMemoryEnabled, !request.privateSession,
              let webView, let host = currentHost else { return 0 }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let count = await BrowserDataController.shared.capture(
            cookies: cookies, host: host, title: pageTitle, allowEmptyRemoval: allowEmptyRemoval
        )
        readerCookieLogger.debug("capture host=\(host, privacy: .public) cookies=\(cookies.count, privacy: .public) stored=\(count, privacy: .public)")
        return count
    }

    /// Last-chance capture when the app is quitting.
    ///
    /// The reader already captures after every load and every cookie-store
    /// change; this only covers a sign-in that landed in the final moment
    /// before the process exits.
    func flushCookiesBeforeTermination() async {
        guard sessionOptions.cookieMemoryEnabled, !request.privateSession else { return }
        _ = await captureCurrentSite()
    }

    /// QR sign-in often writes cookies from JS/XHR without a new `didFinish`.
    /// Debounce cookie-store notifications so a burst of `Set-Cookie` writes
    /// produces one vault update.
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in
            self?.scheduleCookieCapture()
        }
    }

    private func scheduleCookieCapture() {
        guard !stopped, sessionOptions.cookieMemoryEnabled, !request.privateSession else { return }
        cookieCaptureTask?.cancel()
        cookieCaptureTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, !self.stopped else { return }
            _ = await self.captureCurrentSite(allowEmptyRemoval: self.isLogoutDestination)
        }
    }

    /// True once the reader is showing the current site's own log-out landing page.
    private var isLogoutDestination: Bool {
        ReaderNavigationPolicy.isLogoutDestination(webView?.url?.absoluteString ?? currentURL)
    }

    private func injectCookies(_ cookies: [HTTPCookie], into store: WKHTTPCookieStore) async {
        guard !cookies.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for cookie in cookies {
                group.enter()
                store.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main) { continuation.resume() }
        }
    }

    private func verifyInjectedCookies(_ cookies: [HTTPCookie], in store: WKHTTPCookieStore, host: String) async {
        guard !cookies.isEmpty else { return }
        let installed = await store.allCookies()
        let installedIDs = Set(installed.map { "\($0.name)|\($0.domain)|\($0.path)" })
        let missing = cookies.filter { !installedIDs.contains("\($0.name)|\($0.domain)|\($0.path)") }
        readerCookieLogger.debug("inject host=\(host, privacy: .public) requested=\(cookies.count, privacy: .public) installed=\(installed.count, privacy: .public) missing=\(missing.count, privacy: .public)")
        for cookie in cookies.prefix(24) {
            readerCookieLogger.debug("inject cookie=\(cookie.name, privacy: .public) domain=\(cookie.domain, privacy: .public) path=\(cookie.path, privacy: .public) secure=\(cookie.isSecure, privacy: .public)")
        }
        for cookie in missing.prefix(12) {
            readerCookieLogger.debug("inject missing=\(cookie.name, privacy: .public) domain=\(cookie.domain, privacy: .public) path=\(cookie.path, privacy: .public)")
        }
    }

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
        let active = NSApp.isActive && window?.isKeyWindow == true && visible && !suspended
        let idle: TimeInterval
        if active {
            let mouseIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
            let keyboardIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            let scrollIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel)
            idle = min(mouseIdle, min(keyboardIdle, scrollIdle))
        } else {
            idle = .greatestFiniteMagnitude
        }
        evidence.tick(elapsed: elapsed, loaded: loaded, active: active,
                      visible: visible, unlocked: !suspended, idle: idle)
        // Aggregated evidence only; never persist per-frame trajectories.
        if evidence.shouldEmit(final: final), let kind = evidence.signal(articleAdapted: adapted) {
            InterestController.shared.record(
                item,
                kind: kind,
                epoch: request.consentEpoch,
                sessionID: request.id,
                surface: request.surface,
                contextID: request.contextID,
                position: request.position,
                readerSessionID: request.id,
                policyVersion: request.policyVersion,
                profileVersion: request.profileVersion
            )
        }
    }

    private func fail(_ reason: ReaderFailure, kind: InterestEventKind = .failed) {
        loading = false
        loaded = false
        attributed = false
        failure = reason
        terminalState = kind == .blocked ? .blocked : .error
        if let item = request.item, !request.privateSession {
            InterestController.shared.record(
                item,
                kind: kind,
                epoch: request.consentEpoch,
                sessionID: request.id,
                surface: request.surface,
                contextID: request.contextID,
                position: request.position,
                readerSessionID: request.id,
                policyVersion: request.policyVersion,
                profileVersion: request.profileVersion
            )
        }
    }

    private func blockMainNavigation(_ reason: ReaderFailure) {
        if loaded {
            notice = reason
            loading = false
        } else { fail(reason, kind: reason.canRetry ? .failed : .blocked) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let isSubframe = navigationAction.targetFrame?.isMainFrame == false
        guard !stopped, networkContextIsCurrent else { return .cancel }
        let raw = navigationAction.request.url?.absoluteString ?? ""
        // Empty/srcdoc frames are browser-created documents, not external URL
        // exceptions. Never allow them as a top-level destination.
        if isSubframe && (raw == "about:blank" || raw == "about:srcdoc") { return .allow }
        if navigationAction.targetFrame == nil, navigationAction.navigationType != .linkActivated { return .cancel }
        if !isSubframe,
           [.linkActivated, .formSubmitted, .backForward].contains(navigationAction.navigationType) {
            documentAttribution.noteUserNavigation()
        }
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
                if !isSubframe { blockMainNavigation(destination == .privateDestination ? .privateDestination : .dnsUnavailable) }
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

    /// Popups never get their own web view: a second `WKWebView` would escape
    /// the ephemeral store and the content rule list. A `window.open` target is
    /// loaded in place instead, and anything unloadable is dropped.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard !stopped, networkContextIsCurrent,
              let url = ReaderNavigationPolicy.popupDestination(
                  navigationAction.request.url?.absoluteString
              ) else { return nil }
        webView.load(URLRequest(url: url))
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard !stopped, networkContextIsCurrent else { return .cancel }
        guard navigationResponse.canShowMIMEType else {
            if navigationResponse.isForMainFrame {
                blockMainNavigation(.downloadBlocked)
            }
            return .cancel
        }
        if navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse,
           ReaderResponsePolicy.isRiskControlRejection(status: response.statusCode) {
            blockMainNavigation(.siteBlocked)
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
        openAttribution.beginNavigation()
        adapted = false
        failure = nil
        notice = nil
        // A native re-layout belongs to exactly one document. Leaving it up
        // while the web view navigates would show text from another page.
        readerModeDocument = nil
        isReaderModeActive = false
        readerModeNotice = nil
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard !stopped, networkContextIsCurrent else { return }
        documentAttribution.noteServerRedirect()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !stopped, networkContextIsCurrent else { return }
        loading = false
        progress = 1
        loaded = true
        lastTick = ProcessInfo.processInfo.systemUptime
        currentURL = webView.url?.absoluteString ?? request.url
        pageTitle = webView.title?.isEmpty == false ? (webView.title ?? request.title) : request.title
        attributed = documentAttribution.evaluate(finalURL: currentURL, itemURL: request.url)
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if sessionOptions.cookieMemoryEnabled, !request.privateSession {
            let allowEmptyRemoval = ReaderNavigationPolicy.isLogoutDestination(
                webView.url?.absoluteString ?? currentURL
            )
            Task { _ = await self.captureCurrentSite(allowEmptyRemoval: allowEmptyRemoval) }
        }
        let path = webView.url?.path.lowercased() ?? ""
        if ["login", "signin", "account", "passport", "captcha", "challenge"].contains(where: path.contains) { attributed = false }
        // Only a successfully loaded, attributed document counts as an open.
        if openAttribution.shouldRecordLoaded(attributed: attributed, privateSession: request.privateSession),
           let item = request.item {
            InterestController.shared.record(
                item,
                kind: .opened,
                epoch: request.consentEpoch,
                sessionID: request.id,
                surface: request.surface,
                contextID: request.contextID,
                position: request.position,
                readerSessionID: request.id,
                policyVersion: request.policyVersion,
                profileVersion: request.profileVersion
            )
        }
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
        if message.name == "selectionMenu" {
            handleSelectionMenu(message)
            return
        }
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

    // MARK: - Selected-text menu

    private static func selectionMenuScript(token: String) -> String {
        """
        (() => {
          if (window.__newsbarSelectionMenuInstalled) return;
          window.__newsbarSelectionMenuInstalled = true;
          const token = '\(token)';
          document.addEventListener('contextmenu', (event) => {
            const selection = window.getSelection();
            const text = (selection ? selection.toString() : '').trim();
            if (!text) return;
            const active = document.activeElement;
            if (active && (active.tagName === 'INPUT' || active.tagName === 'TEXTAREA' || active.isContentEditable)) return;
            event.preventDefault();
            event.stopPropagation();
            window.webkit.messageHandlers.selectionMenu.postMessage({
              token: token,
              text: text.slice(0, 4000),
              url: location.href
            });
          }, true);
        })();
        """
    }

    private func handleSelectionMenu(_ message: WKScriptMessage) {
        guard !stopped, message.frameInfo.isMainFrame, loaded,
              let body = message.body as? [String: Any],
              body["token"] as? String == selectionToken,
              let raw = body["url"] as? String,
              ContentIdentity.canonicalURL(raw) == ContentIdentity.canonicalURL(webView?.url?.absoluteString ?? ""),
              let text = (body["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= 4_000,
              let web = webView, let window = web.window else { return }
        // The JS bridge carries no reliable view coordinate: WebKit delivers it
        // after hit testing. The pointer is still where the user right-clicked.
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = web.convert(inWindow, from: nil)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let english = L10n.currentLanguage == .en
        let explain = NSMenuItem(
            title: english ? "Explain with AI" : "用 AI 解释",
            action: #selector(explainSelection(_:)),
            keyEquivalent: ""
        )
        explain.target = self
        explain.representedObject = text
        explain.isEnabled = true
        menu.addItem(explain)
        menu.addItem(.separator())
        let copy = NSMenuItem(
            title: english ? "Copy" : "复制",
            action: #selector(copySelection(_:)),
            keyEquivalent: ""
        )
        copy.target = self
        copy.representedObject = text
        copy.isEnabled = true
        menu.addItem(copy)
        menu.popUp(positioning: nil, at: point, in: web)
    }

    @objc private func explainSelection(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        selectionExplainRequest = SelectionExplainRequest(text: text)
    }

    @objc private func copySelection(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !stopped else { return }
        if (error as NSError).code != NSURLErrorCancelled { fail(proxySession == nil ? ReaderFailure.networkError(error) : .proxyUnavailable) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !stopped else { return }
        if (error as NSError).code != NSURLErrorCancelled { fail(proxySession == nil ? ReaderFailure.networkError(error) : .proxyUnavailable) }
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
    @Environment(AppSettings.self) private var settings
    var onOpenSettings: () -> Void = {}
    var onOpenResearch: (String) -> Void = { _ in }
    var onConfigureAI: () -> Void = {}

    init(request: NewsReaderRequest, onOpenSettings: @escaping () -> Void = {}, onOpenResearch: @escaping (String) -> Void = { _ in }, onConfigureAI: @escaping () -> Void = {}) {
        _model = State(initialValue: NewsReaderModel(request: request))
        self.onOpenSettings = onOpenSettings
        self.onOpenResearch = onOpenResearch
        self.onConfigureAI = onConfigureAI
    }

    var body: some View {
        ReaderContentView(model: model, onClose: { ReaderTransitionCoordinator.shared.requestClose() }, onOpenSettings: onOpenSettings, onOpenResearch: onOpenResearch, onConfigureAI: onConfigureAI)
            .task {
                await model.start(options: NewsReaderModel.SessionOptions(
                    cookieMemoryEnabled: settings.readerCookieMemoryEnabled,
                    historyEnabled: settings.readerHistoryEnabled
                ))
            }
            .onDisappear { model.stop() }
            .onReceive(NotificationCenter.default.publisher(for: .interestDataCleared)) { _ in
                model.stop()
                ReaderTransitionCoordinator.shared.requestClose()
            }
    }
}

/// Injected observable state keeps the native chrome independently renderable;
/// the owning NewsReaderView controls the web-session lifecycle.
struct ReaderContentView: View {
    @Bindable var model: NewsReaderModel
    var onClose: () -> Void
    var onOpenSettings: () -> Void = {}
    var onOpenResearch: (String) -> Void = { _ in }
    var onConfigureAI: () -> Void = {}
    @State private var lastFeedback: UUID?
    @State private var feedbackMessage: String?
    @State private var askExternal = false
    @State private var showPrivacy = false
    @State private var showResearch = false
    @State private var research = ReaderResearchPanelModel()
    @State private var explainModel = SelectionExplainModel()
    @State private var searchModel = AISearchPanelModel()
    @State private var showAISearch = false
    @State private var browserData = BrowserDataController.shared
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var explainPanel: some View {
        SelectionExplainPanel(
            model: explainModel,
            language: settings.appLanguage,
            providerName: settings.providerDisplayName(forID: settings.aiProvider),
            onClose: { explainModel.dismiss() },
            onCopy: { answer in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answer, forType: .string)
            },
            onRetry: { explainModel.retry(settings: settings) },
            onOpenSettings: {
                explainModel.dismiss()
                onConfigureAI()
            },
            onOpenSource: { url in
                explainModel.dismiss()
                model.openReaderModeLink(url)
            },
            canLookUp: settings.aiSearchEnabled && !settings.researchSearchProviders.isEmpty,
            onLookUp: { explainModel.requestLookUp() },
            onConfirmLookUp: { explainModel.confirmLookUp(settings: settings) },
            onCancelLookUp: { explainModel.cancelLookUp() }
        )
    }

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
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.loading)
                .accessibilityLabel(english ? "Page loading progress" : "网页加载进度")
                .accessibilityHidden(!model.loading)

            ZStack(alignment: .top) {
                readerContent
                if let notice = model.notice {
                    noticeView(notice)
                }
                if let message = model.readerModeNotice {
                    readerModeNoticeView(message)
                }
                if showResearch {
                    HStack(spacing: 0) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { showResearch = false }
                        ReaderResearchPanel(
                            model: research,
                            language: settings.appLanguage,
                            onClose: { showResearch = false },
                            onOpen: onOpenResearch,
                            onVerify: verifyCurrentPage,
                            canVerify: !model.loading && ReaderNavigationPolicy.allowedURL(model.currentURL) != nil
                        )
                    }
                }
            }
            .animation(reduceMotion ? nil : DashboardMotion.micro, value: model.notice != nil)
            .overlay(alignment: .bottomTrailing) {
                if explainModel.state != .idle {
                    explainPanel
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear { explainModel.setRevealEnabled(!reduceMotion) }
                    .onChange(of: reduceMotion) { _, value in
                        explainModel.setRevealEnabled(!value)
                    }
                }
            }
            .animation(reduceMotion ? nil : DashboardMotion.micro, value: explainModel.state)
            .overlay(alignment: .topTrailing) {
                if showAISearch {
                    AISearchPanel(
                        model: searchModel,
                        language: settings.appLanguage,
                        providerName: settings.providerDisplayName(forID: settings.aiProvider),
                        modelName: settings.effectiveAISearchModel,
                        webEnabled: settings.aiSearchUseWeb,
                        onSubmit: { searchModel.submit(settings: settings) },
                        onRetry: { searchModel.retry(settings: settings) },
                        onClose: { closeAISearch() },
                        onOpenCitation: { url in
                            closeAISearch()
                            model.openReaderModeLink(url)
                        },
                        onCopy: { text in
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        },
                        onOpenSettings: {
                            closeAISearch()
                            onConfigureAI()
                        }
                    )
                    .padding(16)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .onAppear { searchModel.setRevealEnabled(!reduceMotion) }
                    .onChange(of: reduceMotion) { _, value in
                        searchModel.setRevealEnabled(!value)
                    }
                }
            }
            .animation(reduceMotion ? nil : DashboardMotion.micro, value: showAISearch)
            .overlay(alignment: .bottom) {
                ZStack {
                    if let message = feedbackMessage {
                        feedbackView(message)
                    }
                }
                .animation(reduceMotion ? nil : DashboardMotion.micro, value: feedbackMessage)
            }

            Divider()
            footer
        }
        .readerSurface(cornerRadius: 12)
        .task(id: model.currentURL + "\n" + model.pageTitle + "\n\(model.loading)") { await refreshResearch() }
        .onAppear {
            searchModel.pageContextProvider = { [model] in
                if let document = model.readerModeDocument {
                    return AISearchPageContext(url: document.url, title: document.title, text: document.plainText)
                }
                guard let text = await model.currentPagePlainText(), !text.isEmpty else { return nil }
                return AISearchPageContext(url: model.currentURL, title: model.pageTitle, text: text)
            }
        }
        .onChange(of: model.selectionExplainRequest) { _, request in
            guard let request else { return }
            explainModel.explain(request.text, settings: settings)
        }
        .onChange(of: model.currentURL) { _, _ in
            explainModel.dismiss()
            // A page-scoped answer must not survive navigation.
            if showAISearch { closeAISearch() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .researchRecordsChanged)) { _ in
            Task { await refreshResearch() }
        }
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

    @ViewBuilder
    private var readerContent: some View {
        if let failure = model.failure {
            failureContent(failure)
        } else if let document = model.readerModeDocument {
            ReaderModeView(
                document: document,
                language: settings.appLanguage,
                onOpenLink: { url in model.openReaderModeLink(url) },
                onExit: { model.exitReaderMode() }
            )
        } else if let web = model.webView {
            ReaderWebSurface(webView: web)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text(english ? "Preparing the reader…" : "正在准备阅读会话…")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func readerModeNoticeView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "doc.plaintext")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { model.dismissReaderModeNotice() } label: { Image(systemName: "xmark") }
                .accessibilityLabel(english ? "Dismiss notice" : "关闭提示")
        }
        .padding(12)
        .background(.quaternary.opacity(0.4))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func noticeView(_ notice: ReaderFailure) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: notice.symbol).foregroundStyle(.secondary)
            Text(notice.message(language: settings.appLanguage)).font(.caption)
            Spacer(minLength: 0)
            Button { model.dismissNotice() } label: { Image(systemName: "xmark") }
                .accessibilityLabel(english ? "Dismiss notice" : "关闭提示")
        }
        .padding(12)
        .background(.quaternary.opacity(0.4))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func feedbackView(_ message: String) -> some View {
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
        .transition(.move(edge: .bottom).combined(with: .opacity))
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
            .keyboardShortcut(showResearch || explainModel.state != .idle ? nil : KeyboardShortcut(.escape, modifiers: []))
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
            if settings.aiSearchEnabled {
                Button {
                    toggleAISearch()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .frame(width: 28, height: 28)
                }
                .keyboardShortcut("k", modifiers: .command)
                .accessibilityLabel(L10n.string("reader.search.toolbar", language: settings.appLanguage))
                .help(L10n.string("reader.search.toolbar.help", language: settings.appLanguage))
            }
            Button {
                Task { await model.toggleReaderMode() }
            } label: {
                if model.isReaderModeExtracting {
                    ProgressView().controlSize(.mini).frame(width: 28, height: 28)
                } else {
                    Image(systemName: model.isReaderModeActive ? "doc.plaintext.fill" : "doc.plaintext")
                        .frame(width: 28, height: 28)
                }
            }
            .disabled((model.loading && !model.isReaderModeActive) || model.isReaderModeExtracting)
            .accessibilityLabel(model.isReaderModeActive
                ? (english ? "Leave reader mode" : "退出阅读模式")
                : (english ? "Reader mode" : "阅读模式"))
            .help(model.isReaderModeActive
                ? (english ? "Back to the web page" : "返回网页")
                : (english ? "Re-layout this article as text" : "以原生排版阅读正文"))
            Button { showResearch.toggle() } label: {
                Image(systemName: "sidebar.trailing")
                    .frame(width: 28, height: 28)
                    .overlay(alignment: .topTrailing) {
                        if research.match != nil {
                            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        }
                    }
            }
            .accessibilityLabel(english ? "Toggle research sidebar" : "切换研究侧栏")
            .help(english ? "Research for this page" : "查看当前页面的研究")
            if let item = model.request.item {
                Button {
                    NotificationCenter.default.post(
                        name: .researchRequested,
                        object: nil,
                        userInfo: ["item": item]
                    )
                } label: {
                    Image(systemName: "checkmark.seal").frame(width: 28, height: 28)
                }
                .accessibilityLabel(english ? "Verify online" : "联网核查")
                .help(english ? "Cross-check this story with public sources" : "用公开来源核查这条新闻")
                Button {
                    lastFeedback = controller.toggleBookmark(item)
                    feedbackMessage = isBookmarked ? (english ? "Article bookmarked" : "已收藏文章") : (english ? "Bookmark removed" : "已取消收藏")
                } label: { Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark").frame(width: 28, height: 28) }
                .disabled(!controller.canManagePreferences)
                .accessibilityLabel(isBookmarked ? (english ? "Remove bookmark" : "取消收藏") : (english ? "Bookmark article" : "收藏文章"))
                .help(controller.canManagePreferences ? (isBookmarked ? (english ? "Remove bookmark" : "取消收藏") : (english ? "Bookmark article" : "收藏文章"))
                      : (english ? "Local preference storage is unavailable" : "本地偏好存储暂不可用"))
                Menu {
                    Button(english ? "More like this (session)" : "更多同类（本次会话）") { recordFeedback(item, kind: .moreLikeThis) }
                        .disabled(!controller.canLearn)
                        .help(controller.canLearn
                              ? (english ? "Uses this session's short-term interest only." : "仅影响本次会话的短期兴趣。")
                              : InterestFeedbackCopy.softFeedbackUnavailable(english ? .en : .zh))
                    Divider()
                    Button(english ? "Not interested: this article" : "不感兴趣：仅这条") { recordFeedback(item, kind: .notInterested) }
                    Button(english ? "Hide this event" : "不再看这个事件") { recordFeedback(item, kind: .hideEvent) }
                    Button(english ? "Mute this source" : "屏蔽这个来源") { recordFeedback(item, kind: .muteSource) }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 28, height: 28) }
                .disabled(!controller.canManagePreferences)
                .accessibilityLabel(english ? "Article preferences" : "文章偏好操作")
                .help(english ? "More reading preferences" : "更多阅读偏好")
            }
            cookieMenu
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

    private func toggleAISearch() {
        if showAISearch {
            closeAISearch()
        } else {
            showAISearch = true
            searchModel.present()
        }
    }

    private func closeAISearch() {
        showAISearch = false
        searchModel.dismiss()
    }

    private func refreshResearch() async {
        await research.refresh(item: model.request.item, requestURL: model.request.url, currentURL: model.currentURL, title: model.loading ? "" : model.pageTitle)
    }

    private func verifyCurrentPage() {
        guard !model.loading, let item = ReaderResearchPanelModel.verificationItem(
            original: model.request.item, requestURL: model.request.url,
            currentURL: model.currentURL, title: model.pageTitle
        ) else { return }
        NotificationCenter.default.post(name: .researchRequested, object: nil, userInfo: ["item": item])
    }

    private var cookieMenu: some View {
        Menu {
            Button(english ? "Remember this site's sign-in" : "记住此站登录") {
                Task { await saveSiteCookies() }
            }
            if let host = model.currentHost, browserData.hasSite(host) {
                Button(english ? "Update saved cookies" : "更新已保存的 Cookie") {
                    Task { await saveSiteCookies() }
                }
                Button(english ? "Forget this site" : "移除此站登录", role: .destructive) {
                    Task { await forgetSite() }
                }
            }
            Divider()
            Button(english ? "Manage browser data…" : "管理浏览器数据…") {
                NotificationCenter.default.post(name: .browserSettingsRequested, object: nil)
            }
        } label: {
            Image(systemName: "key")
                .frame(width: 24, height: 28)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(english ? "Saved sign-ins" : "登录与 Cookie")
        .help(english ? "Remember this site's sign-in" : "记住此站登录")
    }

    private func saveSiteCookies() async {
        if !settings.readerCookieMemoryEnabled {
            settings.readerCookieMemoryEnabled = true
        }
        let count = await model.captureCurrentSite(force: true)
        lastFeedback = nil
        feedbackMessage = count > 0
            ? (english ? "Saved \(count) cookies for this site (encrypted on this Mac)" : "已保存 \(count) 条 Cookie（仅本机加密）")
            : (english ? "No cookies found for this site yet" : "当前站点暂无可保存的 Cookie")
    }

    private func forgetSite() async {
        guard let host = model.currentHost else { return }
        await browserData.removeSite(host)
        lastFeedback = nil
        feedbackMessage = english ? "Saved sign-in removed for this site" : "已移除此站的登录 Cookie"
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
            Label(settings.readerCookieMemoryEnabled
                  ? (english ? "Sign-in memory" : "登录记忆")
                  : (english ? "Temporary session" : "临时会话"),
                  systemImage: settings.readerCookieMemoryEnabled ? "key.fill" : "lock.shield")
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
                    Text(english ? "The reader uses an isolated web session. Only first-party cookies saved on this Mac are replayed on your next visit to keep you signed in. System browser cookies are never imported, and site restrictions still apply." : "阅读器使用独立网页会话；只有你保存在本机的该站第一方 Cookie 会在下次打开时回填，用于保持登录。不会导入系统浏览器 Cookie，也不会绕过网站限制。")
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

private extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    func setCookie(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            self.setCookie(cookie, completionHandler: {
                continuation.resume()
            })
        }
    }
}
