import Foundation
import Network
import os

struct ReaderImageNetworkContext: Sendable {
    let proxy: ReaderProxySession?
    let resolve: @Sendable (URL) async -> ReaderNavigationPolicy.DestinationResolution
    let allowsFakeIP: @Sendable () async -> Bool
    let isCurrent: @Sendable () async -> Bool

    @MainActor
    static func live() throws -> Self {
        let controller = ReaderProxyController.shared
        let proxy = try controller.authorizedSession()
        let revision = controller.revision
        let networkID = controller.networkContextID
        return Self(
            proxy: proxy,
            resolve: { await ReaderNavigationPolicy.resolveDestination($0) },
            allowsFakeIP: { await ReaderProxyController.shared.allowsFakeIPDestination() },
            isCurrent: {
                await MainActor.run {
                    let current = ReaderProxyController.shared
                    if let proxy { return current.isCurrent(proxy) }
                    return current.mode == .strict && current.revision == revision
                        && current.networkContextID == networkID
                }
            }
        )
    }
}

/// Bounded, non-transcoding reader image fetches with per-hop privacy checks.
actor ReaderModeImageLoader {
    static let shared = ReaderModeImageLoader()
    static let maxBytes = 8 * 1024 * 1024
    private static let maxConcurrentPerHost = 4

    private struct WaitingRequest {
        let id: UUID
        let host: String
        let continuation: CheckedContinuation<Void, Error>
    }

    private let limit: Int
    private let makeConfiguration: () -> URLSessionConfiguration
    private let cache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 0)
    private var activeByHost: [String: Int] = [:]
    private var waiting: [WaitingRequest] = []

    init(maxBytes: Int = ReaderModeImageLoader.maxBytes,
         configuration: @escaping () -> URLSessionConfiguration = { .ephemeral }) {
        self.limit = max(0, maxBytes)
        self.makeConfiguration = configuration
    }

    func load(
        _ url: URL, cookies: [HTTPCookie], referer: String?, network: ReaderImageNetworkContext? = nil
    ) async throws -> Data {
        let context: ReaderImageNetworkContext
        if let network {
            context = network
        } else {
            context = try await MainActor.run { try ReaderImageNetworkContext.live() }
        }
        guard await context.isCurrent() else { throw ReaderModeImageError.networkChanged }
        guard ReaderNavigationPolicy.allowedURL(url.absoluteString) != nil,
              let host = url.host?.lowercased() else { throw ReaderModeImageError.invalidURL }
        try await acquireSlot(for: host)
        defer { releaseSlot(for: host) }
        try Task.checkCancellation()
        guard await context.isCurrent() else { throw ReaderModeImageError.networkChanged }
        guard await ReaderImageFetchPolicy.allows(
            url, proxyResolves: context.proxy != nil, resolve: context.resolve, allowsFakeIP: context.allowsFakeIP
        ) else { throw ReaderModeImageError.invalidURL }
        try Task.checkCancellation()
        guard await context.isCurrent() else { throw ReaderModeImageError.networkChanged }

        let configuration = makeConfiguration()
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = cache
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        if let proxy = context.proxy { configuration.proxyConfigurations = [proxy.configuration] }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(
            "image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8,*/*;q=0.5",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(ReaderUserAgent.value(), forHTTPHeaderField: "User-Agent")
        request = ReaderImageFetchPolicy.prepare(request, cookies: cookies, article: referer)

        let transfer = ReaderImageTransfer(limit: limit, cookies: cookies, article: referer, network: context)
        let data = try await transfer.load(request: request, configuration: configuration)
        try Task.checkCancellation()
        guard await context.isCurrent() else { throw ReaderModeImageError.networkChanged }
        return data
    }

    private func acquireSlot(for host: String) async throws {
        try Task.checkCancellation()
        if activeByHost[host, default: 0] < Self.maxConcurrentPerHost {
            activeByHost[host, default: 0] += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting.append(WaitingRequest(id: id, host: host, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaitingRequest(id: id) }
        }
    }

    private func cancelWaitingRequest(id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func releaseSlot(for host: String) {
        if let index = waiting.firstIndex(where: { $0.host == host }) {
            waiting.remove(at: index).continuation.resume()
        } else if let count = activeByHost[host] {
            if count <= 1 { activeByHost.removeValue(forKey: host) }
            else { activeByHost[host] = count - 1 }
        }
    }
}

enum ReaderModeImageError: Error, Equatable {
    case invalidURL
    case networkChanged
    case http
    case tooLarge
}

/// One request per session keeps redirect and byte-count state isolated. The
/// lock also protects cancellation, which can arrive from any executor.
private final class ReaderImageTransfer: NSObject, URLSessionDataDelegate {
    private struct State {
        var continuation: CheckedContinuation<Data, Error>?
        var session: URLSession?
        var task: URLSessionDataTask?
        var bytes = Data()
        var cancelled = false
        var finished = false
        var redirects = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let limit: Int
    private let cookies: [HTTPCookie]
    private let article: String?
    private let network: ReaderImageNetworkContext

    init(limit: Int, cookies: [HTTPCookie], article: String?, network: ReaderImageNetworkContext) {
        self.limit = limit
        self.cookies = cookies
        self.article = article
        self.network = network
    }

    func load(request: URLRequest, configuration: URLSessionConfiguration) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                let task = session.dataTask(with: request)
                let started = state.withLock { state in
                    guard !state.cancelled else { return false }
                    state.continuation = continuation
                    state.session = session
                    state.task = task
                    return true
                }
                if started {
                    task.resume()
                } else {
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let task = self.state.withLock { state in
                state.cancelled = true
                return state.task
            }
            task?.cancel()
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        let pending = state.withLock { state -> (CheckedContinuation<Data, Error>, URLSession?)? in
            guard !state.finished, let continuation = state.continuation else { return nil }
            state.finished = true
            let session = state.session
            state.continuation = nil
            state.session = nil
            state.task = nil
            return (continuation, session)
        }
        guard let (continuation, session) = pending else { return }
        session?.finishTasksAndInvalidate()
        continuation.resume(with: result)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(.failure(ReaderModeImageError.http))
            return
        }
        guard http.expectedContentLength < 0 || http.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel)
            finish(.failure(ReaderModeImageError.tooLarge))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooLarge = state.withLock { state in
            guard !state.finished else { return false }
            guard data.count <= limit - state.bytes.count else { return true }
            state.bytes.append(data)
            return false
        }
        if tooLarge {
            dataTask.cancel()
            finish(.failure(ReaderModeImageError.tooLarge))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let snapshot = state.withLock { ($0.cancelled, $0.bytes) }
        if snapshot.0 { finish(.failure(CancellationError())) }
        else if let error { finish(.failure(error)) }
        else { finish(.success(snapshot.1)) }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        let mayRedirect = state.withLock { state in
            guard !state.cancelled, !state.finished, state.redirects < 5 else { return false }
            state.redirects += 1
            return true
        }
        guard mayRedirect, let url = request.url, await network.isCurrent(),
              await ReaderImageFetchPolicy.allows(
                url, proxyResolves: network.proxy != nil, resolve: network.resolve, allowsFakeIP: network.allowsFakeIP
              ), await network.isCurrent() else { return nil }
        guard !state.withLock({ $0.cancelled || $0.finished }) else { return nil }
        return ReaderImageFetchPolicy.prepare(request, cookies: cookies, article: article)
    }
}
