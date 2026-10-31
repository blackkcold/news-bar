import Foundation

struct ProviderModelEndpoint: Sendable {
    let url: URL
    let format: ProviderModelFormat
}

/// Metadata GET requests only. Exact provider-returned model IDs are cached;
/// API keys and authentication headers never enter persistence or diagnostics.
actor ProviderModelService {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    static let shared = ProviderModelService()
    private let fileURL: URL
    private let transport: Transport
    private var snapshots: [String: ProviderModelSnapshot] = [:]
    private var didLoad = false
    private var inFlight: [String: Task<ProviderModelSnapshot, Error>] = [:]
    private var failures: [String: (Date, ProviderModelError)] = [:]
    private let freshness: TimeInterval = 6 * 3600
    private let maximumAge: TimeInterval = 24 * 3600

    init(fileURL: URL? = nil, transport: @escaping Transport = { request in try await ProviderModelHTTPTransport.data(request) }) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.newsbar.app/provider-models-v1.json")
        self.transport = transport
    }

    nonisolated static func identity(providerID: String, connection: ResolvedAIConnection, apiKey: String) -> String {
        ContentIdentity.digest([providerID, connection.baseURL, connection.responseFormat.rawValue, connection.authHeaderName,
                                connection.authHeaderPrefix, connection.apiVersion ?? "", ContentIdentity.digest(apiKey)].joined(separator: "\n"))
    }

    nonisolated static func endpoints(providerID: String, connection: ResolvedAIConnection) throws -> [ProviderModelEndpoint] {
        guard var parts = URLComponents(string: connection.baseURL), parts.scheme?.lowercased() == "https",
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil else { throw ProviderModelError.invalidEndpoint }
        parts.query = nil
        parts.fragment = nil
        if providerID == AIProvider.opencodeGo.rawValue {
            // Go exposes a single OpenAI-format catalog at the gateway root;
            // deriving it from the chat path would hit a 404.
            parts.path = "/inference/go/v1/models"
            guard let url = parts.url else { throw ProviderModelError.invalidEndpoint }
            return [ProviderModelEndpoint(url: url, format: .openAI)]
        }
        if providerID == AIProvider.opencodeZen.rawValue {
            // Pay-as-you-go shares one catalog across every API family. The
            // catalog carries `cost` and `api` metadata used to hide models
            // this client cannot call.
            parts.path = "/inference/v1/models"
            guard let url = parts.url else { throw ProviderModelError.invalidEndpoint }
            return [ProviderModelEndpoint(url: url, format: .openAI)]
        }
        if providerID == AIProvider.ollamaCloud.rawValue {
            parts.path = "/api/tags"
            guard let url = parts.url else { throw ProviderModelError.invalidEndpoint }
            return [ProviderModelEndpoint(url: url, format: .ollama)]
        }
        if providerID == AIProvider.googleAIStudio.rawValue {
            parts.path = "/v1beta/models"
            guard let url = parts.url else { throw ProviderModelError.invalidEndpoint }
            return [ProviderModelEndpoint(url: url, format: .google)]
        }
        var path = parts.path
        let endings = ["/chat/completions", "/messages", "/responses", "/completions"]
        if let suffix = endings.first(where: path.hasSuffix) { path = String(path.dropLast(suffix.count)) }
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/models") { parts.path = path } else { parts.path = path + "/models" }
        guard let first = parts.url else { throw ProviderModelError.invalidEndpoint }
        var result = [ProviderModelEndpoint(url: first, format: connection.responseFormat == .anthropic ? .anthropic : .openAI)]
        if connection.responseFormat == .anthropic, path.contains("/anthropic") {
            parts.path = path.replacingOccurrences(of: "/anthropic", with: "") + "/models"
            if let url = parts.url, url != first { result.append(ProviderModelEndpoint(url: url, format: .openAI)) }
        }
        return result
    }

    func catalog(providerID: String, connection: ResolvedAIConnection, apiKey: String, force: Bool = false, now: Date = Date()) async throws -> ProviderModelResult {
        loadIfNeeded()
        let key = Self.identity(providerID: providerID, connection: connection, apiKey: apiKey)
        let previous = snapshots[key].flatMap { snapshot in
            now.timeIntervalSince(snapshot.fetchedAt) >= -300 && now.timeIntervalSince(snapshot.fetchedAt) <= maximumAge ? snapshot : nil
        }
        if !force, let previous, now.timeIntervalSince(previous.fetchedAt) < freshness, failures[key] == nil {
            return ProviderModelResult(snapshot: previous, source: .cache)
        }
        if !force, let (attemptedAt, failure) = failures[key], now.timeIntervalSince(attemptedAt) < 60 {
            if let previous, !failure.invalidatesCache { return ProviderModelResult(snapshot: previous, source: .stale, refreshError: failure) }
            throw failure
        }
        let task: Task<ProviderModelSnapshot, Error>
        if let existing = inFlight[key] { task = existing }
        else {
            let transport = transport
            task = Task {
                let endpoints = try Self.endpoints(providerID: providerID, connection: connection)
                for (index, endpoint) in endpoints.enumerated() {
                    do {
                        let models = try await Self.fetch(endpoint: endpoint, providerID: providerID, connection: connection, apiKey: apiKey, transport: transport)
                        guard !models.isEmpty else { throw ProviderModelError.emptyCatalog }
                        return ProviderModelSnapshot(identity: key, models: models, fetchedAt: now)
                    } catch ProviderModelError.unsupportedEndpoint {
                        if index == endpoints.count - 1 { throw ProviderModelError.unsupportedEndpoint }
                    }
                }
                throw ProviderModelError.unsupportedEndpoint
            }
            inFlight[key] = task
        }
        do {
            let snapshot = try await task.value
            inFlight[key] = nil
            failures[key] = nil
            snapshots[key] = snapshot
            persist(now: now)
            return ProviderModelResult(snapshot: snapshot, source: .live)
        } catch {
            inFlight[key] = nil
            let failure = error as? ProviderModelError ?? .network
            failures[key] = (now, failure)
            if failure.invalidatesCache {
                snapshots[key] = nil
                persist(now: now)
            } else if let previous {
                return ProviderModelResult(snapshot: previous, source: .stale, refreshError: failure)
            }
            throw failure
        }
    }

    private nonisolated static func fetch(endpoint: ProviderModelEndpoint, providerID: String, connection: ResolvedAIConnection, apiKey: String, transport: Transport) async throws -> [ProviderModel] {
        var cursor: String?
        var seenCursors: Set<String> = []
        var models: [ProviderModel] = []
        var ids: Set<String> = []
        for _ in 0..<10 {
            try Task.checkCancellation()
            guard var parts = URLComponents(url: endpoint.url, resolvingAgainstBaseURL: false) else { throw ProviderModelError.invalidEndpoint }
            switch endpoint.format {
            case .google:
                parts.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
                if let cursor { parts.queryItems?.append(URLQueryItem(name: "pageToken", value: cursor)) }
            case .anthropic:
                parts.queryItems = [URLQueryItem(name: "limit", value: "1000")]
                if let cursor { parts.queryItems?.append(URLQueryItem(name: "after_id", value: cursor)) }
            default:
                if let cursor { parts.queryItems = [URLQueryItem(name: "after_id", value: cursor)] }
            }
            guard let url = parts.url else { throw ProviderModelError.invalidEndpoint }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 12
            for (name, value) in connection.additionalHeaders {
                request.setValue(value, forHTTPHeaderField: name)
            }
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if !apiKey.isEmpty {
                switch endpoint.format {
                case .google: request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                case .anthropic:
                    request.setValue(connection.authHeaderPrefix + apiKey, forHTTPHeaderField: connection.authHeaderName)
                    request.setValue(connection.apiVersion ?? "2023-06-01", forHTTPHeaderField: "anthropic-version")
                case .ollama: request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
                case .openAI:
                    let anthropicFallback = connection.responseFormat == .anthropic
                    request.setValue((anthropicFallback ? "Bearer " : connection.authHeaderPrefix) + apiKey,
                                     forHTTPHeaderField: anthropicFallback ? "Authorization" : connection.authHeaderName)
                }
            }
            let payload: (Data, HTTPURLResponse)
            do {
                payload = try await transport(request)
            } catch let error as URLError {
                throw Self.mapTransportError(error, host: url.host ?? "")
            }
            let (data, response) = payload
            switch response.statusCode {
            case 200...299: break
            case 401, 403: throw ProviderModelError.unauthorized
            case 404, 405, 501: throw ProviderModelError.unsupportedEndpoint
            default: throw ProviderModelError.server(response.statusCode)
            }
            guard HTTPClient.validateResponseSize(declaredContentLength: Int(response.value(forHTTPHeaderField: "Content-Length") ?? ""), receivedByteCount: data.count, maxBodySize: 1024 * 1024) else { throw ProviderModelError.responseTooLarge }
            let page = try ProviderModelParser.parse(data, format: endpoint.format)
            for model in Self.eligible(page.models, providerID: providerID) where ids.insert(model.id).inserted {
                models.append(model)
            }
            guard models.count <= 5000 else { throw ProviderModelError.responseTooLarge }
            guard let next = page.nextCursor else { return models }
            guard next.utf8.count <= 2048, seenCursors.insert(next).inserted else { throw ProviderModelError.incompletePagination }
            cursor = next
        }
        throw ProviderModelError.incompletePagination
    }

    /// OpenCode's catalog lists models for every API family. Zen's free tier
    /// is rejected (403) for non-OpenCode clients, and System One models do
    /// not speak chat at all, so neither may reach the picker.
    private nonisolated static func eligible(_ models: [ProviderModel], providerID: String) -> [ProviderModel] {
        switch providerID {
        case AIProvider.opencodeZen.rawValue:
            return models.filter { !$0.isFree && $0.isChatCompatible }
        case AIProvider.opencodeGo.rawValue:
            return models.filter(\.isChatCompatible)
        default:
            return models
        }
    }

    /// Keeps the catalog's failure message actionable: a retired host, a TLS
    /// interception and a slow provider need different fixes.
    private nonisolated static func mapTransportError(_ error: URLError, host: String) -> ProviderModelError {
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed:
            return .cannotResolveHost(host)
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            return .tlsFailure(host)
        case .timedOut:
            return .timedOut
        default:
            return .network
        }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL), data.count <= 8 * 1024 * 1024,
              let saved = try? JSONDecoder().decode([ProviderModelSnapshot].self, from: data) else { return }
        for snapshot in saved.prefix(32) { snapshots[snapshot.identity] = snapshot }
    }

    private func persist(now: Date) {
        let values = snapshots.values.filter { now.timeIntervalSince($0.fetchedAt) <= maximumAge }.sorted { $0.fetchedAt > $1.fetchedAt }.prefix(32)
        snapshots = Dictionary(uniqueKeysWithValues: values.map { ($0.identity, $0) })
        do {
            let data = try JSONEncoder().encode(Array(values))
            guard data.count <= 8 * 1024 * 1024 else { return }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch { /* Catalog caching is optional; a failed cache never authorizes a model. */ }
    }
}

private final class ProviderModelHTTPTransport: NSObject, URLSessionTaskDelegate {
    static func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: ProviderModelHTTPTransport(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ProviderModelError.malformedResponse }
        return (data, response)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward provider credentials through a redirected catalog URL.
        completionHandler(nil)
    }
}
