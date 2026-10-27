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
    static let defaultMaxBytes = 4 * 1024 * 1024

    static func data(
        for request: URLRequest,
        maxBytes: Int = defaultMaxBytes,
        allowedContentTypes: Set<String>? = nil,
        timeout: TimeInterval? = nil,
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
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpCookieAcceptPolicy = .never
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = request.timeoutInterval
            configuration.timeoutIntervalForResource = max(request.timeoutInterval, 30)
            active = URLSession(configuration: configuration)
        }
        defer {
            if ownedSession { active.invalidateAndCancel() }
        }

        let (bytes, response) = try await active.bytes(
            for: request,
            delegate: RedirectDenier()
        )
        guard let http = response as? HTTPURLResponse else {
            throw PrivateHTTPError.invalidResponse
        }

        if let declared = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
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

/// Refuses every redirect and hands the 3xx response back to the caller, which
/// can validate the `Location` target before following it.
private final class RedirectDenier: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
