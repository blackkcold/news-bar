import Foundation

enum PrivateHTTPError: Error, Equatable {
    case tooLarge(Int)
    case unsupportedContentType(String)
    case invalidResponse
}

/// One HTTP path for every outbound request the app makes on the user's
/// behalf. It always uses an ephemeral session, denies redirects so callers
/// can validate each hop, and enforces the body ceiling *while* the response
/// is streaming instead of after it has been buffered.
enum PrivateHTTP {
    /// One ephemeral session for outbound feed traffic. Reusing it keeps the
    /// connection pool, TLS session cache and resolver cache warm; each task
    /// still carries its own redirect delegate.
    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    enum RedirectPolicy: Sendable {
        /// Hand the 3xx response back to the caller, which validates the
        /// `Location` target itself.
        case deny
        /// Follow a hop only after the target passes the public-URL and DNS
        /// checks.
        case followValidatedPublic(RSSDestinationPolicy)
    }

    static let defaultMaxBytes = 4 * 1024 * 1024

    /// Streaming variant of `data(for:)`. The body stays open, so the resource
    /// timeout is the generation ceiling rather than the request timeout. The
    /// body ceiling is still enforced while reading, and the session is
    /// cancelled as soon as the consumer stops.
    static func stream(
        for request: URLRequest,
        maxBytes: Int = defaultMaxBytes,
        timeout: TimeInterval? = nil,
        redirectPolicy: RedirectPolicy = .deny
    ) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        var request = request
        if let timeout { request.timeoutInterval = timeout }

        let session = sharedSession

        let (bytes, response) = try await session.bytes(
            for: request,
            delegate: RequestDelegate(policy: redirectPolicy)
        )
        guard let http = response as? HTTPURLResponse else {
            throw PrivateHTTPError.invalidResponse
        }
        if let declared = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           declared > maxBytes {
            throw PrivateHTTPError.tooLarge(maxBytes)
        }

        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var line = Data()
                var total = 0
                do {
                    for try await byte in bytes {
                        line.append(byte)
                        total += 1
                        if total > maxBytes { throw PrivateHTTPError.tooLarge(maxBytes) }
                        if byte == 0x0A {
                            continuation.yield(line)
                            line.removeAll(keepingCapacity: true)
                        }
                    }
                    if !line.isEmpty { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
        return (stream, http)
    }

    static func data(
        for request: URLRequest,
        maxBytes: Int = defaultMaxBytes,
        allowedContentTypes: Set<String>? = nil,
        timeout: TimeInterval? = nil,
        redirectPolicy: RedirectPolicy = .deny,
        session: URLSession? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = request
        if let timeout {
            request.timeoutInterval = timeout
        }

        let ownedSession = session == nil
        let active: URLSession
        if let session {
            active = session
        } else {
            active = sharedSession
        }
        defer {
            // The shared session is reused; a caller-provided session stays
            // owned by the caller.
            _ = ownedSession
        }

        let (bytes, response) = try await active.bytes(
            for: request,
            delegate: RequestDelegate(policy: redirectPolicy)
        )
        guard let http = response as? HTTPURLResponse else {
            throw PrivateHTTPError.invalidResponse
        }

        if http.statusCode != 304,
           let declared = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           declared > maxBytes {
            throw PrivateHTTPError.tooLarge(maxBytes)
        }

        if let allowedContentTypes {
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
                .split(separator: ";", maxSplits: 1)
                .first
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            guard allowedContentTypes.contains(contentType) else {
                throw PrivateHTTPError.unsupportedContentType(contentType)
            }
        }

        var data = Data()
        data.reserveCapacity(min(maxBytes, 256 * 1024))
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes {
                throw PrivateHTTPError.tooLarge(maxBytes)
            }
        }
        return (data, http)
    }
}

private final class RequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let policy: PrivateHTTP.RedirectPolicy

    init(policy: PrivateHTTP.RedirectPolicy) {
        self.policy = policy
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        switch policy {
        case .deny:
            return nil
        case .followValidatedPublic(let destinationPolicy):
            guard let url = request.url,
                  url.scheme?.lowercased() == "https",
                  (try? await destinationPolicy.allows(url)) == true else {
                return nil
            }
            return request
        }
    }
}
