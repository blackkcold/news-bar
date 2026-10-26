import XCTest
import WebKit
@testable import NewsBar

final class ReaderPolicyTests: XCTestCase {
    @MainActor
    func testPublicIfanrPageLoadsWithProductionNavigationPolicyWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["NEWSBAR_VALIDATE_PUBLIC_READER"] == "1" else {
            throw XCTSkip("Public network validation is opt-in; default tests remain offline.")
        }
        let request = NewsReaderRequest(url: "https://www.ifanr.com/", title: "爱范儿", item: nil, surface: "publicValidation", contextID: nil, consentEpoch: UUID(), privateSession: true)
        let model = NewsReaderModel(request: request)
        defer { model.stop() }
        await model.start()
        let web = try XCTUnwrap(model.webView)
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in model.failure != nil || model.progress >= 1 }, object: nil)
        await fulfillment(of: [settled], timeout: 45)
        XCTAssertNil(model.failure)
        XCTAssertEqual(web.url?.host, "www.ifanr.com")
        let body = try await web.evaluateJavaScript("document.body.innerText") as? String
        XCTAssertGreaterThan(body?.count ?? 0, 100)
        XCTAssertFalse(web.configuration.websiteDataStore.isPersistent)
    }

    @MainActor
    func testBlankSubframeDoesNotReplaceArticleWithSecurityError() async throws {
        let request = NewsReaderRequest(url: "https://www.ifanr.com/", title: "Article", item: nil, surface: "test", contextID: nil, consentEpoch: UUID(), privateSession: true)
        let model = NewsReaderModel(request: request)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        let checked = expectation(description: "Real WebKit blank subframe navigation inspected")
        let delegate = ReaderFrameFixtureDelegate(model: model, checked: checked)
        web.navigationDelegate = delegate
        web.loadHTMLString("<html><body><h1>Article remains visible</h1><iframe src='about:blank'></iframe></body></html>", baseURL: URL(string: request.url))
        await fulfillment(of: [checked], timeout: 10)
        XCTAssertEqual(delegate.childPolicy, .allow)
        XCTAssertNil(model.errorMessage)
        web.stopLoading()
        web.navigationDelegate = nil
        model.stop()
    }

    @MainActor
    func testBlockedDataSubframeIsCancelledWithoutFailingMainDocument() async {
        let request = NewsReaderRequest(url: "https://www.ifanr.com/", title: "Article", item: nil, surface: "test", contextID: nil, consentEpoch: UUID(), privateSession: true)
        let model = NewsReaderModel(request: request)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        let checked = expectation(description: "Unsupported subframe rejected in isolation")
        let delegate = ReaderFrameFixtureDelegate(model: model, checked: checked, expectedChildURL: "data:text/html,frame")
        web.navigationDelegate = delegate
        web.loadHTMLString("<html><body>Article<iframe src='data:text/html,frame'></iframe></body></html>", baseURL: URL(string: request.url))
        await fulfillment(of: [checked], timeout: 10)
        XCTAssertEqual(delegate.childPolicy, .cancel)
        XCTAssertNil(model.errorMessage)
        web.stopLoading()
        web.navigationDelegate = nil
        model.stop()
    }

    @MainActor
    func testCancelledNavigationDoesNotShowFailure() {
        let request = NewsReaderRequest(url: "https://example.com/story", title: "Article", item: nil, surface: "test", contextID: nil, consentEpoch: UUID(), privateSession: true)
        let model = NewsReaderModel(request: request)
        let web = WKWebView()
        model.webView(web, didFail: nil, withError: URLError(.cancelled))
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testWebKitRulesCompileAndUnsupportedURLHasVisibleFailure() async throws {
        let rules = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "newsbar-test-reader-policy", encodedContentRuleList: ReaderNavigationPolicy.resourceRules)
        XCTAssertNotNil(rules)
        let request = NewsReaderRequest(url: "http://example.com/", title: "Unsafe", item: nil, surface: "test", contextID: nil, consentEpoch: UUID(), privateSession: true)
        let reader = NewsReaderModel(request: request)
        await reader.start()
        XCTAssertFalse(reader.loading)
        XCTAssertNotNil(reader.errorMessage)
        XCTAssertFalse(reader.webView?.configuration.websiteDataStore.isPersistent ?? true)
        reader.stop()
        XCTAssertNil(reader.webView)
    }

    @MainActor
    func testRouterKeepsResearchContextWithoutFabricatingNewsMetadata() {
        let router = NewsNavigationRouter()
        router.open(url: "https://example.com/source", surface: "researchSource", contextID: "research-123")
        XCTAssertEqual(router.selection?.contextID, "research-123")
        XCTAssertNil(router.selection?.item)
        router.close()
        XCTAssertNil(router.selection)
    }
    func testNavigationBlocksPrivateSchemesHostsAndUserInfo() {
        for raw in ["http://example.com/a", "file:///etc/passwd", "javascript:alert(1)", "https://localhost/a", "https://127.0.0.1/", "https://10.0.0.2/", "https://[::1]/", "https://router.local/a", "https://user:secret@example.com/"] {
            XCTAssertNil(ReaderNavigationPolicy.allowedURL(raw), raw)
        }
        XCTAssertNotNil(ReaderNavigationPolicy.allowedURL("https://example.com/article?q=1"))
        XCTAssertFalse(ReaderNavigationPolicy.isPublicAddress("192.168.3.1"))
        XCTAssertFalse(ReaderNavigationPolicy.isPublicAddress("::ffff:127.0.0.1"))
        XCTAssertFalse(ReaderNavigationPolicy.isPublicAddress("169.254.169.254"))
        XCTAssertTrue(ReaderNavigationPolicy.isPublicAddress("8.8.8.8"))
    }

    func testOnlyLoadedVisibleActiveUnlockedReaderAccumulatesTime() {
        var evidence = ReaderEvidence()
        evidence.tick(elapsed: 20, loaded: false, active: true, visible: true, unlocked: true, idle: 0)
        evidence.tick(elapsed: 20, loaded: true, active: false, visible: true, unlocked: true, idle: 0)
        evidence.tick(elapsed: 20, loaded: true, active: true, visible: false, unlocked: true, idle: 0)
        evidence.tick(elapsed: 20, loaded: true, active: true, visible: true, unlocked: false, idle: 0)
        evidence.tick(elapsed: 20, loaded: true, active: true, visible: true, unlocked: true, idle: 61)
        XCTAssertEqual(evidence.activeSeconds, 0)
        evidence.tick(elapsed: 15, loaded: true, active: true, visible: true, unlocked: true, idle: 0)
        XCTAssertEqual(evidence.activeSeconds, 15)
        XCTAssertEqual(evidence.signal(articleAdapted: false), .browsed)
        XCTAssertNil(evidence.signal(articleAdapted: true))
        evidence.setScroll(0.25)
        XCTAssertEqual(evidence.signal(articleAdapted: true), .qualifiedRead)
    }

    func testShortArticleCanQualifyWithoutScrollingAndInvalidMetricsIgnored() {
        var evidence = ReaderEvidence()
        evidence.estimatedReadingSeconds = 30
        evidence.setScroll(.infinity)
        evidence.setScroll(-1)
        XCTAssertEqual(evidence.scrollCoverage, 0)
        evidence.tick(elapsed: 15, loaded: true, active: true, visible: true, unlocked: true, idle: 0)
        XCTAssertEqual(evidence.signal(articleAdapted: true), .qualifiedRead)
    }

    func testClosingBetweenHeartbeatBoundariesEmitsFinalEvidence() {
        var evidence = ReaderEvidence()
        evidence.tick(elapsed: 17, loaded: true, active: true, visible: true, unlocked: true, idle: 0)
        XCTAssertTrue(evidence.shouldEmit(final: false))
        evidence.tick(elapsed: 2, loaded: true, active: true, visible: true, unlocked: true, idle: 0)
        XCTAssertFalse(evidence.shouldEmit(final: false))
        XCTAssertTrue(evidence.shouldEmit(final: true))
    }

    func testImpressionRequiresContinuousVisibilityAndDeduplicates() {
        var exposure = QualifiedExposure()
        XCTAssertFalse(exposure.update(visibleFraction: 0.6, active: true, now: 1))
        XCTAssertFalse(exposure.update(visibleFraction: 0.3, active: true, now: 1.8))
        XCTAssertFalse(exposure.update(visibleFraction: 0.8, active: true, now: 2))
        XCTAssertTrue(exposure.update(visibleFraction: 0.8, active: true, now: 3.1))
        XCTAssertFalse(exposure.update(visibleFraction: 1, active: true, now: 5))
    }
}

@MainActor
private final class ReaderFrameFixtureDelegate: NSObject, WKNavigationDelegate {
    let model: NewsReaderModel
    let checked: XCTestExpectation
    var childPolicy: WKNavigationActionPolicy?
    let expectedChildURL: String

    init(model: NewsReaderModel, checked: XCTestExpectation, expectedChildURL: String = "about:blank") {
        self.model = model
        self.checked = checked
        self.expectedChildURL = expectedChildURL
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Only the fixture's initial synthetic main document is permitted here.
        // The production model makes the real child-frame policy decision.
        if action.targetFrame?.isMainFrame == true { return .allow }
        let result = await model.webView(webView, decidePolicyFor: action)
        if action.request.url?.absoluteString == expectedChildURL, childPolicy == nil {
            childPolicy = result
            checked.fulfill()
        }
        return result
    }
}
