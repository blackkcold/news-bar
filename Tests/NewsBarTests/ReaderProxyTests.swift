import XCTest
import Network
import WebKit
@testable import NewsBar

final class ReaderProxyTests: XCTestCase {
    func testFakeIPAndPrivateDestinationsRemainRejectedByStrictPolicy() {
        for ip in ["198.18.0.182", "198.19.1.1", "127.0.0.1", "192.168.0.14", "100.83.165.48"] {
            XCTAssertEqual(ReaderNavigationPolicy.classifyAddresses([ip]), .privateDestination)
            XCTAssertNil(ReaderNavigationPolicy.allowedURL("https://\(ip)/"))
        }
        XCTAssertEqual(ReaderNavigationPolicy.classifyAddresses(["8.8.8.8"]), .publicDestination)
    }

    func testProxyEndpointOnlyAcceptsExplicitUnicastLANOrLoopbackIPv4() throws {
        XCTAssertEqual(try ReaderProxyEndpoint(host: "192.168.0.14", port: 7890).host, "192.168.0.14")
        XCTAssertNoThrow(try ReaderProxyEndpoint(host: "127.0.0.1", port: 7890))
        for host in ["198.18.0.1", "8.8.8.8", "0.0.0.0", "169.254.169.254", "router.local", "192.168.0.14/path", "192.168.0.14:7890", "192.168.0.255", "192.168.000.14"] {
            XCTAssertThrowsError(try ReaderProxyEndpoint(host: host, port: 7890), host)
        }
        XCTAssertThrowsError(try ReaderProxyEndpoint(host: "192.168.0.14", port: 0))
        XCTAssertThrowsError(try ReaderProxyEndpoint(host: "192.168.0.14", port: 65536))
    }

    @MainActor
    func testStrictDefaultAndExplicitNetworkBoundAuthorizationNeverPersistsSecrets() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "reader-proxy-tests-\(UUID())"))
        let vault = ProxyCredentialFixture()
        let controller = ReaderProxyController(defaults: defaults, credentials: vault.store, monitor: nil)
        XCTAssertEqual(controller.mode, .strict)
        XCTAssertNil(try controller.authorizedSession())
        controller.mode = .trustedProxy
        XCTAssertThrowsError(try controller.authorizedSession())
        controller.updateNetwork(available: true)
        let endpoint = try ReaderProxyEndpoint(host: "192.168.0.14", port: 7890)
        try await controller.trust(endpoint: endpoint, username: "fixture-user", password: "fixture-secret")
        let session = try XCTUnwrap(controller.authorizedSession())
        XCTAssertEqual(session.endpoint, endpoint)
        XCTAssertFalse(session.configuration.allowFailover)
        XCTAssertTrue(controller.isCurrent(session))
        let persisted = String(describing: defaults.dictionaryRepresentation())
        XCTAssertFalse(persisted.contains("fixture-secret"))
        XCTAssertFalse(persisted.contains("fixture-user"))
        let restarted = ReaderProxyController(defaults: defaults, credentials: vault.store, monitor: nil)
        restarted.updateNetwork(available: true)
        XCTAssertThrowsError(try restarted.authorizedSession())
        controller.updateNetwork(available: true)
        XCTAssertFalse(controller.isCurrent(session))
        XCTAssertThrowsError(try controller.authorizedSession())
    }

    @MainActor
    func testSwitchingToStrictWhileCredentialSaveIsPendingCannotActivateProxy() async throws {
        let started = expectation(description: "Credential save started")
        let vault = ProxyCredentialFixture(started: started)
        let controller = ReaderProxyController(defaults: try XCTUnwrap(UserDefaults(suiteName: "reader-proxy-tests-\(UUID())")), credentials: vault.store, monitor: nil)
        controller.updateNetwork(available: true)
        controller.mode = .trustedProxy
        let endpoint = try ReaderProxyEndpoint(host: "192.168.0.14", port: 7890)
        let pending = Task { try await controller.trust(endpoint: endpoint, username: "fixture-user", password: "fixture-secret") }
        await fulfillment(of: [started], timeout: 3)
        controller.mode = .strict
        await vault.completeSave()
        do { try await pending.value; XCTFail("Old save must not authorize a new context") }
        catch { XCTAssertEqual(error as? ReaderProxyError, .contextChanged) }
        XCTAssertNil(try controller.authorizedSession())
    }

    @MainActor
    func testSavedCredentialsAreScopedToExactEndpoint() async throws {
        let vault = ProxyCredentialFixture()
        let controller = ReaderProxyController(defaults: try XCTUnwrap(UserDefaults(suiteName: "reader-proxy-tests-\(UUID())")), credentials: vault.store, monitor: nil)
        controller.updateNetwork(available: true)
        controller.mode = .trustedProxy
        let endpoint = try ReaderProxyEndpoint(host: "192.168.0.14", port: 7890)
        try await controller.trust(endpoint: endpoint, username: "fixture-user", password: "fixture-secret")
        controller.updateNetwork(available: true)
        try await controller.trust(endpoint: endpoint, username: "fixture-user", password: "")
        XCTAssertNotNil(try controller.authorizedSession())
        do {
            try await controller.trust(endpoint: ReaderProxyEndpoint(host: "192.168.0.15", port: 7890), username: "fixture-user", password: "")
            XCTFail("Different endpoints must not receive the saved credential")
        } catch { XCTAssertEqual(error as? ReaderProxyError, .credentialsRequired) }
    }

    @MainActor
    func testWebKitSendsDomainCONNECTAndAuthenticationToConfiguredProxy() async throws {
        let proxy = try ProxyCONNECTFixture()
        try await proxy.start()
        defer { proxy.stop() }
        let vault = ProxyCredentialFixture()
        let controller = ReaderProxyController(defaults: try XCTUnwrap(UserDefaults(suiteName: "reader-proxy-tests-\(UUID())")), credentials: vault.store, monitor: nil)
        controller.mode = .trustedProxy
        controller.updateNetwork(available: true)
        let endpoint = try ReaderProxyEndpoint(host: "127.0.0.1", port: Int(try XCTUnwrap(proxy.listener.port).rawValue))
        try await controller.trust(endpoint: endpoint, username: "fixture-user", password: "fixture-secret")
        let session = try XCTUnwrap(controller.authorizedSession())
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.websiteDataStore.proxyConfigurations = [session.configuration]
        let failed = expectation(description: "Rejecting CONNECT proxy returns a navigation failure")
        let delegate = ProxyNavigationFixture(failed: failed)
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = delegate
        defer { web.stopLoading(); web.navigationDelegate = nil }
        web.load(URLRequest(url: try XCTUnwrap(URL(string: "https://reader-proxy-fixture.example/"))))
        await fulfillment(of: [failed], timeout: 20)
        XCTAssertTrue(proxy.requests.contains { $0.hasPrefix("CONNECT reader-proxy-fixture.example:443 HTTP/1.1") })
        let expected = "Proxy-Authorization: Basic " + Data("fixture-user:fixture-secret".utf8).base64EncodedString()
        XCTAssertTrue(proxy.requests.contains { $0.localizedCaseInsensitiveContains(expected) }, "The configured credential must reach the proxy only")
        XCTAssertFalse(proxy.requests.contains { $0.localizedCaseInsensitiveContains("\r\nAuthorization:") })
        XCTAssertFalse(configuration.websiteDataStore.proxyConfigurations[0].allowFailover)
        XCTAssertNotNil(delegate.error)
    }

    @MainActor
    func testUntrustedProxyModeStopsBeforeCreatingWebView() async throws {
        let controller = ReaderProxyController(defaults: try XCTUnwrap(UserDefaults(suiteName: "reader-proxy-tests-\(UUID())")), credentials: ProxyCredentialFixture().store, monitor: nil)
        controller.mode = .trustedProxy
        controller.updateNetwork(available: true)
        let request = NewsReaderRequest(url: "https://www.ifanr.com/", title: "Article", item: nil, surface: "test", contextID: nil, consentEpoch: UUID(), privateSession: true)
        let model = NewsReaderModel(request: request, proxyController: controller)
        await model.start()
        XCTAssertEqual(model.failure, .proxyTrustRequired)
        XCTAssertNil(model.webView)
        XCTAssertFalse(model.canRetry)
        model.stop()
    }

    @MainActor
    func testProductionReaderUsesProxyAndRevocationDestroysWebViewWithoutDirectFallback() async throws {
        let proxy = try ProxyCONNECTFixture()
        try await proxy.start()
        defer { proxy.stop() }
        let controller = ReaderProxyController(defaults: try XCTUnwrap(UserDefaults(suiteName: "reader-proxy-tests-\(UUID())")), credentials: ProxyCredentialFixture().store, monitor: nil)
        controller.mode = .trustedProxy
        controller.updateNetwork(available: true)
        let endpoint = try ReaderProxyEndpoint(host: "127.0.0.1", port: Int(try XCTUnwrap(proxy.listener.port).rawValue))
        try await controller.trust(endpoint: endpoint, username: "fixture-user", password: "fixture-secret")
        let request = NewsReaderRequest(url: "https://reader-proxy-fixture.example/", title: "Article", item: nil, surface: "test", contextID: nil, consentEpoch: UUID(), privateSession: true)
        let model = NewsReaderModel(request: request, proxyController: controller)
        defer { model.stop() }
        await model.start()
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in model.failure != nil }, object: nil)
        await fulfillment(of: [failed], timeout: 20)
        XCTAssertEqual(model.failure, .proxyUnavailable)
        XCTAssertTrue(proxy.requests.contains { $0.hasPrefix("CONNECT reader-proxy-fixture.example:443 ") })
        XCTAssertFalse(model.webView?.configuration.websiteDataStore.isPersistent ?? true)
        XCTAssertFalse(model.webView?.configuration.websiteDataStore.proxyConfigurations.first?.allowFailover ?? true)
        controller.updateNetwork(available: true)
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in model.webView == nil }, object: nil)
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(model.failure, .proxyTrustRequired)
        model.webViewWebContentProcessDidTerminate(WKWebView())
        XCTAssertEqual(model.failure, .proxyTrustRequired, "Late process callbacks must not replace the revoked-network failure")
        model.reload()
        XCTAssertNil(model.webView)
    }

    @MainActor
    func testTrustedProxyDoesNotMakeLANAddressesBrowsable() async throws {
        let controller = ReaderProxyController(defaults: try XCTUnwrap(UserDefaults(suiteName: "reader-proxy-tests-\(UUID())")), credentials: ProxyCredentialFixture().store, monitor: nil)
        controller.mode = .trustedProxy
        controller.updateNetwork(available: true)
        try await controller.trust(endpoint: ReaderProxyEndpoint(host: "192.168.0.14", port: 7890), username: "fixture-user", password: "fixture-secret")
        let request = NewsReaderRequest(url: "https://192.168.0.14/", title: "LAN", item: nil, surface: "test", contextID: nil, consentEpoch: UUID(), privateSession: true)
        let model = NewsReaderModel(request: request, proxyController: controller)
        await model.start()
        XCTAssertEqual(model.failure, .unsupportedURL)
        XCTAssertFalse(model.canOpenExternally)
        model.stop()
    }

    @MainActor
    func testWebKitLoopbackProxyBypassRequiresIndependentURLBlocking() async throws {
        let proxy = try ProxyCONNECTFixture(), origin = try ProxyCONNECTFixture()
        try await proxy.start()
        try await origin.start()
        defer { proxy.stop(); origin.stop() }
        let controller = ReaderProxyController(defaults: try XCTUnwrap(UserDefaults(suiteName: "reader-proxy-tests-\(UUID())")), credentials: ProxyCredentialFixture().store, monitor: nil)
        controller.mode = .trustedProxy
        controller.updateNetwork(available: true)
        try await controller.trust(endpoint: ReaderProxyEndpoint(host: "127.0.0.1", port: Int(try XCTUnwrap(proxy.listener.port).rawValue)), username: "fixture-user", password: "fixture-secret")
        let session = try XCTUnwrap(controller.authorizedSession())
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.websiteDataStore.proxyConfigurations = [session.configuration]
        let web = WKWebView(frame: .zero, configuration: configuration)
        defer { web.stopLoading() }
        let port = try XCTUnwrap(origin.listener.port).rawValue
        // This deliberately exercises transport without the production URL
        // policy, which independently blocks literal loopback destinations.
        web.load(URLRequest(url: try XCTUnwrap(URL(string: "https://127.0.0.1:\(port)/"))))
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in origin.connectionCount > 0 }, object: nil)
        await fulfillment(of: [connected], timeout: 5)
        XCTAssertEqual(proxy.connectionCount, 0)
        XCTAssertGreaterThan(origin.connectionCount, 0)
        XCTAssertNil(ReaderNavigationPolicy.allowedURL("https://127.0.0.1:\(port)/"))
    }

    @MainActor
    func testProductionReaderBlocksReachableLoopbackBeforeAnyNetworkConnection() async throws {
        let proxy = try ProxyCONNECTFixture(), origin = try ProxyCONNECTFixture()
        try await proxy.start()
        try await origin.start()
        defer { proxy.stop(); origin.stop() }
        let controller = ReaderProxyController(defaults: try XCTUnwrap(UserDefaults(suiteName: "reader-proxy-tests-\(UUID())")), credentials: ProxyCredentialFixture().store, monitor: nil)
        controller.mode = .trustedProxy
        controller.updateNetwork(available: true)
        try await controller.trust(endpoint: ReaderProxyEndpoint(host: "127.0.0.1", port: Int(try XCTUnwrap(proxy.listener.port).rawValue)), username: "fixture-user", password: "fixture-secret")
        let port = try XCTUnwrap(origin.listener.port).rawValue
        let request = NewsReaderRequest(url: "https://127.0.0.1:\(port)/", title: "Blocked", item: nil, surface: "test", contextID: nil, consentEpoch: UUID(), privateSession: true)
        let model = NewsReaderModel(request: request, proxyController: controller)
        await model.start()
        XCTAssertEqual(model.failure, .unsupportedURL)
        XCTAssertEqual(origin.connectionCount, 0)
        XCTAssertEqual(proxy.connectionCount, 0)
        model.stop()
    }

    @MainActor
    func testConnectionProbeUsesAuthorizedProxyAndDoesNotClaimRejectedCONNECTSuccess() async throws {
        let proxy = try ProxyCONNECTFixture()
        try await proxy.start()
        defer { proxy.stop() }
        let controller = ReaderProxyController(defaults: try XCTUnwrap(UserDefaults(suiteName: "reader-proxy-tests-\(UUID())")), credentials: ProxyCredentialFixture().store, monitor: nil)
        controller.mode = .trustedProxy
        controller.updateNetwork(available: true)
        try await controller.trust(endpoint: ReaderProxyEndpoint(host: "127.0.0.1", port: Int(try XCTUnwrap(proxy.listener.port).rawValue)), username: "fixture-user", password: "fixture-secret")
        do { try await controller.probeConnection(); XCTFail("Rejected CONNECT must not count as connectivity") }
        catch { XCTAssertEqual(error as? ReaderProxyError, .unavailable) }
        XCTAssertTrue(proxy.requests.contains { $0.hasPrefix("CONNECT www.apple.com:443 ") })
    }

    @MainActor
    func testNetworkChangeCancelsInFlightCredentialedProbeImmediately() async throws {
        let proxy = try ProxyCONNECTFixture(holdAuthenticatedRequests: true)
        try await proxy.start()
        defer { proxy.stop() }
        let controller = ReaderProxyController(defaults: try XCTUnwrap(UserDefaults(suiteName: "reader-proxy-tests-\(UUID())")), credentials: ProxyCredentialFixture().store, monitor: nil)
        controller.mode = .trustedProxy
        controller.updateNetwork(available: true)
        try await controller.trust(endpoint: ReaderProxyEndpoint(host: "127.0.0.1", port: Int(try XCTUnwrap(proxy.listener.port).rawValue)), username: "fixture-user", password: "fixture-secret")
        let cancelled = expectation(description: "A credentialed probe must not survive a network change")
        let task = Task { @MainActor in
            do { try await controller.probeConnection(); XCTFail("A revoked probe must not succeed") }
            catch { XCTAssertEqual(error as? ReaderProxyError, .contextChanged) }
            cancelled.fulfill()
        }
        let started = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in proxy.requests.contains { $0.localizedCaseInsensitiveContains("Proxy-Authorization:") } }, object: nil)
        await fulfillment(of: [started], timeout: 3)
        controller.updateNetwork(available: true)
        await fulfillment(of: [cancelled], timeout: 2)
        proxy.stop()
        await task.value
    }
}

@MainActor
private final class ProxyNavigationFixture: NSObject, WKNavigationDelegate {
    let failed: XCTestExpectation
    var error: Error?
    init(failed: XCTestExpectation) { self.failed = failed }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if self.error == nil { self.error = error; failed.fulfill() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if self.error == nil { self.error = error; failed.fulfill() }
    }
}

@MainActor
private final class ProxyCONNECTFixture {
    let listener: NWListener
    var requests: [String] = []
    private var connections: [NWConnection] = []
    private let holdAuthenticatedRequests: Bool
    var connectionCount: Int { connections.count }
    init(holdAuthenticatedRequests: Bool = false) throws {
        self.holdAuthenticatedRequests = holdAuthenticatedRequests
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: .main)
                self.receive(connection, accumulated: Data())
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var completed = false
            listener.stateUpdateHandler = { state in
                Task { @MainActor in
                    guard !completed else { return }
                    switch state {
                    case .ready: completed = true; continuation.resume()
                    case .failed(let error): completed = true; continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                var received = accumulated
                if let data { received.append(data) }
                let request = String(decoding: received, as: UTF8.self)
                guard received.count <= 16_384 else { connection.cancel(); return }
                guard request.contains("\r\n\r\n") else {
                    if !complete && error == nil { self.receive(connection, accumulated: received) }
                    else { connection.cancel() }
                    return
                }
                self.requests.append(request)
                if self.holdAuthenticatedRequests, request.localizedCaseInsensitiveContains("Proxy-Authorization:") { return }
                let response = request.localizedCaseInsensitiveContains("Proxy-Authorization:")
                    ? "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    : "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"NewsBar fixture\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
    func stop() { listener.cancel(); connections.forEach { $0.cancel() } }
}

private actor ProxyCredentialFixture {
    private var values: [String: String] = [:]
    private let started: XCTestExpectation?
    private var pending: CheckedContinuation<Void, Never>?
    init(started: XCTestExpectation? = nil) { self.started = started }
    nonisolated var store: ReaderProxyCredentialStore {
        ReaderProxyCredentialStore(read: { await self.read($0) }, save: { await self.save($0, account: $1) })
    }
    func read(_ account: String) -> String? { values[account] }
    func save(_ value: String, account: String) async -> Bool {
        if let started {
            await withCheckedContinuation { pending = $0; started.fulfill() }
        }
        values[account] = value
        return true
    }
    func completeSave() { pending?.resume(); pending = nil }
}
