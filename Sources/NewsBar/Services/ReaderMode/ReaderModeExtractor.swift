import Foundation
import Observation
import WebKit

/// The reader-mode JS bundle. Loaded once and reused for every extraction.
@MainActor
enum ReaderModeScript {
    static let messageName = "readerMode"
    static let fileName = "reader-mode"
    static let bundleName = "NewsBar_NewsBar.bundle"

    private static var cached: String?

    static func source() -> String? {
        if let cached { return cached }
        var candidates: [URL] = []
        if let url = Bundle.module.url(forResource: fileName, withExtension: "js") {
            candidates.append(url)
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources
                .appendingPathComponent(bundleName)
                .appendingPathComponent("\(fileName).js"))
            candidates.append(resources.appendingPathComponent("\(fileName).js"))
        }
        for url in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { continue }
            cached = text
            return text
        }
        return nil
    }
}

enum ReaderModeExtractionError: Equatable, Sendable {
    case unavailable
    case timeout
    case scriptFailed
    /// The JS extractor refused the page; the string is its own reason code.
    case rejected(String?)
    case tooShort
    case navigationChanged

    func message(language: AppLanguage) -> String {
        let english = language == .en
        switch self {
        case .unavailable:
            return english ? "Reader mode is not available for this page yet." : "此页面暂时无法使用阅读模式。"
        case .timeout:
            return english ? "Reader mode took too long. The web page is still shown." : "阅读模式抽取超时，已保留网页视图。"
        case .scriptFailed:
            return english ? "Reader mode could not read this page. The web page is still shown." : "阅读模式无法读取此页面，已保留网页视图。"
        case .rejected, .tooShort:
            return english ? "This page has too little article text for reader mode. The web page is still shown." : "此页正文太少，无法进入阅读模式，已保留网页视图。"
        case .navigationChanged:
            return english ? "The page changed while reader mode was opening." : "页面在进入阅读模式时发生了变化。"
        }
    }
}

struct ReaderModeExtraction: Equatable, Sendable {
    let document: ReaderModeDocument?
    let error: ReaderModeExtractionError?
    /// JS diagnostic values, used by the developer self-check only.
    let score: Int
    let selector: String?
    let reason: String?

    static func failure(_ error: ReaderModeExtractionError) -> ReaderModeExtraction {
        ReaderModeExtraction(document: nil, error: error, score: 0, selector: nil, reason: nil)
    }
}

/// Bridges the on-demand extractor script to Swift.
///
/// The script is evaluated only when the user turns reader mode on — it is not
/// installed as a user script, so ordinary reading pays no cost. Every message
/// carries a per-request token and the page URL; both must match the request
/// that is waiting, which is the same nonce + URL contract the reader already
/// uses for aggregate evidence.
@MainActor
final class ReaderModeExtractor: NSObject, WKScriptMessageHandler {
    private struct Pending {
        let token: String
        let url: String
        let continuation: CheckedContinuation<ReaderModeExtraction, Never>
    }

    private weak var webView: WKWebView?
    private weak var controller: WKUserContentController?
    private var world: WKContentWorld?
    private var pending: Pending?

    deinit {
        // A deinit cannot touch MainActor state; the continuation is resumed by
        // `detach` or by the timeout task while the object is still alive.
    }

    func attach(to webView: WKWebView, world: WKContentWorld) {
        self.webView = webView
        self.world = world
        let controller = webView.configuration.userContentController
        self.controller = controller
        controller.add(self, contentWorld: world, name: ReaderModeScript.messageName)
    }

    func detach() {
        if let controller, let world {
            controller.removeScriptMessageHandler(
                forName: ReaderModeScript.messageName,
                contentWorld: world
            )
        }
        finish(.failure(.navigationChanged))
        webView = nil
        world = nil
    }

    /// Runs the extractor with a hard 3 s ceiling. The timeout path resumes the
    /// continuation itself, so a page that never answers cannot hang the UI.
    func extract(timeout: TimeInterval = 3) async -> ReaderModeExtraction {
        guard let web = webView,
              let world,
              let url = web.url?.absoluteString,
              let source = ReaderModeScript.source() else {
            return .failure(.unavailable)
        }
        finish(.failure(.navigationChanged))

        let token = UUID().uuidString
        let outcome: ReaderModeExtraction = await withCheckedContinuation { continuation in
            pending = Pending(token: token, url: url, continuation: continuation)
            let preamble = "window.__newsbarReaderModeToken = \(Self.javaScriptString(token));"
            web.evaluateJavaScript(preamble, in: nil, in: world) { _ in }
            web.evaluateJavaScript(source, in: nil, in: world) { [weak self] result in
                guard case .failure = result else { return }
                Task { @MainActor in self?.finish(.failure(.scriptFailed), onlyIfToken: token) }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.finish(.failure(.timeout), onlyIfToken: token)
            }
        }
        // A navigation between the URL read and the reply invalidates the text.
        if outcome.document != nil, web.url?.absoluteString != url {
            return .failure(.navigationChanged)
        }
        return outcome
    }

    private func finish(_ outcome: ReaderModeExtraction, onlyIfToken: String? = nil) {
        guard let pending else { return }
        if let onlyIfToken, pending.token != onlyIfToken { return }
        self.pending = nil
        pending.continuation.resume(returning: outcome)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == ReaderModeScript.messageName,
              message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let token = body["token"] as? String,
              let pending,
              pending.token == token,
              let rawURL = body["url"] as? String,
              ContentIdentity.canonicalURL(rawURL) == ContentIdentity.canonicalURL(pending.url),
              let payload = body["payload"] as? [String: Any] else { return }

        let score = payload["score"] as? Int ?? 0
        let selector = payload["selector"] as? String
        let reason = payload["reason"] as? String
        let ok = payload["ok"] as? Bool ?? false
        guard ok else {
            finish(ReaderModeExtraction(document: nil, error: .rejected(reason), score: score, selector: selector, reason: reason))
            return
        }
        guard let document = ReaderModeDocument(payload: payload, expectedURL: pending.url) else {
            finish(ReaderModeExtraction(document: nil, error: .tooShort, score: score, selector: selector, reason: reason ?? "too_short"))
            return
        }
        finish(ReaderModeExtraction(document: document, error: nil, score: score, selector: selector, reason: nil))
    }

    private static func javaScriptString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(data: data, encoding: .utf8),
              json.count >= 2 else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }
}

// MARK: - Developer self-check

/// Manual extractor check for Settings → Developer.
///
/// It loads the URLs the user typed into a throwaway web view and prints the
/// extractor's own score, selector, reason, block count and character count.
/// This is deliberately not part of the automated suite: the Swift parser has
/// golden fixtures, while the JS extractor needs a real page.
@MainActor
@Observable
final class ReaderModeSelfCheck {
    struct Result: Identifiable, Sendable {
        let id = UUID()
        let url: String
        let ok: Bool
        let reason: String?
        let score: Int
        let selector: String?
        let blocks: Int
        let characters: Int
        let seconds: Double
    }

    private(set) var results: [Result] = []
    private(set) var isRunning = false
    private(set) var lastRun: Date?

    static let defaultURLs = [
        "https://www.ithome.com/",
        "https://sspai.com/",
        "https://arstechnica.com/",
        "https://www.bbc.com/news",
        "https://www.theguardian.com/international",
    ]

    func run(urls: [String]) async {
        guard !isRunning else { return }
        let cleaned = urls
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        isRunning = true
        results = []
        defer {
            isRunning = false
            lastRun = Date()
        }
        for raw in cleaned {
            guard let url = ReaderNavigationPolicy.allowedURL(raw) else {
                results.append(Result(url: raw, ok: false, reason: "invalid_url", score: 0, selector: nil, blocks: 0, characters: 0, seconds: 0))
                continue
            }
            let started = ProcessInfo.processInfo.systemUptime
            let outcome = await Self.check(url)
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            results.append(Result(
                url: raw,
                ok: outcome.document != nil,
                reason: outcome.reason ?? outcome.error.map { String(describing: $0) },
                score: outcome.score,
                selector: outcome.selector,
                blocks: outcome.document?.blocks.count ?? 0,
                characters: outcome.document?.characterCount ?? 0,
                seconds: elapsed
            ))
            if let document = outcome.document {
                print("READER-MODE ok=1 url=\(raw) score=\(outcome.score) selector=\(outcome.selector ?? "-") blocks=\(document.blocks.count) chars=\(document.characterCount) seconds=\(String(format: "%.2f", elapsed))")
            } else {
                print("READER-MODE ok=0 url=\(raw) reason=\(outcome.reason ?? "-") score=\(outcome.score) seconds=\(String(format: "%.2f", elapsed))")
            }
        }
    }

    private static func check(_ url: URL) async -> ReaderModeExtraction {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        let world = WKContentWorld.world(name: "NewsBarReaderModeSelfCheck")
        let extractor = ReaderModeExtractor()
        extractor.attach(to: web, world: world)
        let waiter = LoadWaiter()
        let loaded = await waiter.load(web, url: url, timeout: 15)
        guard loaded else {
            extractor.detach()
            return .failure(.timeout)
        }
        let outcome = await extractor.extract()
        extractor.detach()
        return outcome
    }
}

@MainActor
private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?

    func load(_ web: WKWebView, url: URL, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            web.navigationDelegate = self
            web.load(URLRequest(url: url))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.finish(false)
            }
        }
    }

    private func finish(_ ok: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: ok)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
}
