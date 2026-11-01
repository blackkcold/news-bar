import XCTest
import WebKit
@testable import NewsBar

final class ReaderPresentationTests: XCTestCase {
    func testDNSFailureIsNotMislabelledAsPrivateNetworkBlock() {
        XCTAssertEqual(ReaderNavigationPolicy.classifyAddresses([]), .unresolved)
        XCTAssertEqual(ReaderNavigationPolicy.classifyAddresses(["122.9.119.16"]), .publicDestination)
        XCTAssertEqual(ReaderNavigationPolicy.classifyAddresses(["122.9.119.16", "127.0.0.1"]), .privateDestination)
    }

    func testFakeIPIsNotReportedAsPrivateDestination() {
        XCTAssertEqual(ReaderNavigationPolicy.classifyAddresses(["198.18.28.202"]), .fakeIPDestination)
        XCTAssertEqual(ReaderNavigationPolicy.classifyAddresses(["198.19.1.1"]), .fakeIPDestination)
        XCTAssertEqual(ReaderNavigationPolicy.classifyAddresses(["198.18.28.202", "8.8.8.8"]), .fakeIPDestination)
        XCTAssertEqual(ReaderNavigationPolicy.classifyAddresses(["198.18.28.202", "127.0.0.1"]), .privateDestination)
    }

    func testFailureTextUsesOneSelectedLanguageAndActionableRecovery() {
        XCTAssertTrue(ReaderFailure.networkUnavailable.message(language: .zh).contains("网络"))
        XCTAssertFalse(ReaderFailure.networkUnavailable.message(language: .zh).contains("Network"))
        XCTAssertTrue(ReaderFailure.networkUnavailable.message(language: .en).contains("network"))
        XCTAssertFalse(ReaderFailure.networkUnavailable.message(language: .en).contains("网络"))
        XCTAssertFalse(ReaderFailure.unsupportedURL.canRetry)
        XCTAssertFalse(ReaderFailure.privateDestination.canRetry)
        XCTAssertTrue(ReaderFailure.networkUnavailable.canRetry)
        XCTAssertTrue(ReaderFailure.safetyRulesUnavailable.canRetry)
        XCTAssertFalse(ReaderFailure.siteBlocked.canRetry)
        XCTAssertTrue(ReaderFailure.siteBlocked.message(language: .zh).contains("风控"))
        XCTAssertTrue(ReaderFailure.siteBlocked.message(language: .en).contains("security policy"))
        XCTAssertFalse(ReaderFailure.siteBlocked.message(language: .zh).contains("security policy"))
        XCTAssertFalse(ReaderFailure.siteBlocked.message(language: .en).contains("风控"))
    }

    @MainActor
    func testNetworkErrorExposesNetworkRecoveryRatherThanSecurityWarning() {
        let request = NewsReaderRequest(url: "https://www.ifanr.com/article", title: "Article", item: nil, surface: "test", contextID: nil, consentEpoch: UUID(), privateSession: true)
        let model = NewsReaderModel(request: request)
        model.webView(WKWebView(), didFailProvisionalNavigation: nil, withError: URLError(.notConnectedToInternet))
        XCTAssertEqual(model.failure, .networkUnavailable)
        XCTAssertTrue(model.canOpenExternally)
        XCTAssertTrue(model.canRetry)
    }

    @MainActor
    func testDNSAndTimeoutFailuresProvideDifferentRecovery() {
        let request = NewsReaderRequest(url: "https://www.bilibili.com/video/BV1xx411c7mD", title: "Video", item: nil, surface: "test", contextID: nil, consentEpoch: UUID(), privateSession: true)
        let dnsReader = NewsReaderModel(request: request)
        let timeoutReader = NewsReaderModel(request: request)
        dnsReader.webView(WKWebView(), didFailProvisionalNavigation: nil, withError: URLError(.cannotFindHost))
        timeoutReader.webView(WKWebView(), didFailProvisionalNavigation: nil, withError: URLError(.timedOut))

        XCTAssertNotEqual(dnsReader.failure, timeoutReader.failure)
        XCTAssertTrue(dnsReader.canRetry)
        XCTAssertTrue(timeoutReader.canRetry)
        XCTAssertTrue(dnsReader.canOpenExternally)
        XCTAssertTrue(timeoutReader.canOpenExternally)
    }

    @MainActor
    func testUnsupportedURLDisablesBrowserHandoffAndFutileRetries() {
        let request = NewsReaderRequest(url: "file:///private/story.html", title: "Unsafe", item: nil, surface: "test", contextID: nil, consentEpoch: UUID(), privateSession: true)
        let model = NewsReaderModel(request: request)
        model.loadInitial()
        XCTAssertEqual(model.failure, .unsupportedURL)
        XCTAssertFalse(model.canOpenExternally)
        XCTAssertFalse(model.canRetry)
    }
}
