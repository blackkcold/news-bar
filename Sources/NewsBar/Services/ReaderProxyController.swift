import AppKit
import Foundation
import Network
import Observation

enum ReaderNetworkMode: String, Codable { case strict, trustedProxy }

enum ReaderProxyError: Error, Equatable {
    case invalidEndpoint, credentialsRequired, storageFailed, trustRequired, contextChanged, unavailable
    func message(language: AppLanguage) -> String {
        let en = language == .en
        switch self {
        case .invalidEndpoint: return en ? "Use a private LAN IPv4 address or 127.0.0.1 and a port from 1 to 65535." : "请输入局域网 IPv4 地址或 127.0.0.1，端口范围为 1–65535。"
        case .credentialsRequired: return en ? "Enter a username and password. A blank password only reuses credentials saved for this exact endpoint and username." : "请填写账号和密码。密码留空仅复用为相同地址、端口和账号保存的凭据。"
        case .storageFailed: return en ? "Credentials could not be saved. The proxy was not authorized." : "凭据保存失败，未授权代理。"
        case .trustRequired: return en ? "Authorize this network's proxy in Settings → General, then reopen the article. Restarting the app or changing networks requires authorization again." : "请在设置 → 通用中授权当前网络的代理，再重新打开文章。重启应用或网络变化后需重新确认。"
        case .contextChanged: return en ? "The network or reader settings changed. Re-authorize the proxy before continuing." : "网络或阅读器设置已变化，请重新授权代理后继续。"
        case .unavailable: return en ? "The proxy could not connect or rejected authentication. Check its address, username and password; no direct fallback was used." : "代理无法连接或认证被拒绝。请检查地址、账号和密码；未回退为直连。"
        }
    }
}

struct ReaderProxyEndpoint: Codable, Equatable, Sendable {
    let host: String
    let port: Int

    init(host: String, port: Int) throws {
        let values = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = values.compactMap { Int($0) }
        guard values.count == 4, octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }),
              octets.map(String.init).joined(separator: ".") == host, (1...65535).contains(port),
              octets[3] > 0, octets[3] < 255,
              host == "127.0.0.1" || octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168)
        else { throw ReaderProxyError.invalidEndpoint }
        self.host = host
        self.port = port
    }

    // Use the validating initializer when restoring even locally saved data.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(host: c.decode(String.self, forKey: .host), port: c.decode(Int.self, forKey: .port))
    }

    var credentialAccount: String { "reader-proxy-" + ContentIdentity.digest("\(host):\(port)") }
}

struct ReaderProxyCredentialStore: Sendable {
    let read: @Sendable (String) async -> String?
    let save: @Sendable (String, String) async -> Bool
    static let encrypted = Self(read: { await EncryptedKeyStore().readAPIKey(account: $0) },
                                save: { await EncryptedKeyStore().saveAPIKey($0, account: $1) })
}

private struct ReaderProxyCredentials: Codable, Sendable {
    let username: String
    let password: String
    var isValid: Bool {
        !username.isEmpty && !password.isEmpty && username.utf8.count <= 256 && password.utf8.count <= 1024
            && !username.contains(":") && !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !password.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

struct ReaderProxySession: Sendable {
    let id: UUID
    let endpoint: ReaderProxyEndpoint
    fileprivate let networkEpoch: UUID
    fileprivate let credentials: ReaderProxyCredentials
    var configuration: ProxyConfiguration {
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .init(endpoint.host), port: .init(rawValue: UInt16(endpoint.port))!))
        proxy.allowFailover = false
        proxy.matchDomains = []
        proxy.excludedDomains = []
        proxy.applyCredential(username: credentials.username, password: credentials.password)
        return proxy
    }
}

extension Notification.Name {
    static let readerNetworkContextChanged = Notification.Name("readerNetworkContextChanged")
}

@MainActor
@Observable
final class ReaderProxyController {
    static let shared = ReaderProxyController()
    var mode: ReaderNetworkMode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: "readerNetworkMode")
            invalidateTrust()
        }
    }
    private(set) var endpoint: ReaderProxyEndpoint?
    private(set) var networkAvailable = false
    private(set) var revision = UUID()
    private var networkEpoch = UUID()
    private var session: ReaderProxySession?
    private let defaults: UserDefaults
    private let credentials: ReaderProxyCredentialStore
    @ObservationIgnored private let monitor: NWPathMonitor?
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var activeProbe: (id: UUID, task: Task<Void, Error>)?

    init(defaults: UserDefaults = .standard, credentials: ReaderProxyCredentialStore = .encrypted, monitor: NWPathMonitor? = NWPathMonitor()) {
        self.defaults = defaults
        self.credentials = credentials
        self.monitor = monitor
        mode = ReaderNetworkMode(rawValue: defaults.string(forKey: "readerNetworkMode") ?? "") ?? .strict
        endpoint = defaults.data(forKey: "readerProxyEndpoint").flatMap { try? JSONDecoder().decode(ReaderProxyEndpoint.self, from: $0) }
        monitor?.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in self?.updateNetwork(available: available) }
        }
        monitor?.start(queue: DispatchQueue(label: "com.newsbar.reader-network"))
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateNetwork(available: false) }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateNetwork(available: self.monitor?.currentPath.status == .satisfied)
            }
        }
    }

    deinit {
        monitor?.cancel()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        activeProbe?.task.cancel()
    }

    /// Any network path event conservatively revokes trust, even if the new
    /// gateway happens to have the same private IP. This is not router identity
    /// authentication, and neither SSID nor location permission is collected.
    func updateNetwork(available: Bool) {
        networkAvailable = available
        networkEpoch = UUID()
        if mode == .trustedProxy { invalidateTrust() }
    }

    private func invalidateTrust() {
        activeProbe?.task.cancel()
        activeProbe = nil
        session = nil
        revision = UUID()
        NotificationCenter.default.post(name: .readerNetworkContextChanged, object: self)
    }

    func authorizedSession() throws -> ReaderProxySession? {
        guard mode == .trustedProxy else { return nil }
        guard networkAvailable, let session, session.networkEpoch == networkEpoch else { throw ReaderProxyError.trustRequired }
        return session
    }

    var isAuthorized: Bool { (try? authorizedSession()) != nil }

    func isCurrent(_ candidate: ReaderProxySession) -> Bool {
        mode == .trustedProxy && networkAvailable && session?.id == candidate.id && candidate.networkEpoch == networkEpoch
    }

    func trust(endpoint: ReaderProxyEndpoint, username: String, password: String) async throws {
        guard mode == .trustedProxy, networkAvailable else { throw ReaderProxyError.trustRequired }
        let epoch = networkEpoch, version = revision
        let value: ReaderProxyCredentials
        if password.isEmpty {
            guard let saved = await credentials.read(endpoint.credentialAccount),
                  let decoded = try? JSONDecoder().decode(ReaderProxyCredentials.self, from: Data(saved.utf8)),
                  decoded.username == username, decoded.isValid else { throw ReaderProxyError.credentialsRequired }
            value = decoded
        } else {
            value = ReaderProxyCredentials(username: username, password: password)
            guard value.isValid else { throw ReaderProxyError.credentialsRequired }
            let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            guard await credentials.save(encoded, endpoint.credentialAccount) else { throw ReaderProxyError.storageFailed }
        }
        guard epoch == networkEpoch, version == revision, mode == .trustedProxy, networkAvailable else { throw ReaderProxyError.contextChanged }
        invalidateTrust()
        self.endpoint = endpoint
        defaults.set(try JSONEncoder().encode(endpoint), forKey: "readerProxyEndpoint")
        session = ReaderProxySession(id: UUID(), endpoint: endpoint, networkEpoch: epoch, credentials: value)
    }

    /// Explicit user action only. Fixed public metadata endpoint, no AI call,
    /// no redirect and no fallback to an unproxied URLSession.
    func probeConnection() async throws {
        guard let session = try authorizedSession() else { throw ReaderProxyError.trustRequired }
        activeProbe?.task.cancel()
        let id = UUID()
        let task = Task { try await ReaderProxyProbe.check(session: session) }
        activeProbe = (id, task)
        defer { if activeProbe?.id == id { activeProbe = nil } }
        do {
            try await task.value
            guard isCurrent(session) else { throw ReaderProxyError.contextChanged }
        } catch {
            if !isCurrent(session) || task.isCancelled { throw ReaderProxyError.contextChanged }
            throw error as? ReaderProxyError ?? ReaderProxyError.unavailable
        }
    }
}

private final class ReaderProxyProbe: NSObject, URLSessionTaskDelegate {
    static func check(session: ReaderProxySession) async throws {
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations = [session.configuration]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 12
        let client = URLSession(configuration: configuration, delegate: ReaderProxyProbe(), delegateQueue: nil)
        defer { client.invalidateAndCancel() }
        guard let url = URL(string: "https://www.apple.com/library/test/success.html") else { throw ReaderProxyError.unavailable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await client.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4096,
              String(decoding: data, as: UTF8.self).contains("Success") else { throw ReaderProxyError.unavailable }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
