import Foundation

typealias SearchHTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

protocol SearchProvider: Sendable {
    var id: SearchProviderID { get }
    func search(_ query: SearchQuery, key: String) async throws -> [SearchHit]
}

extension SearchProvider {
    /// Derived from the provider registry so a provider file cannot disagree
    /// with the settings UI about whether a key is required.
    var authMode: SearchAuthMode { id.authMode }
}

struct SearchRouterConfiguration: Sendable, Equatable {
    var enabled: Set<SearchProviderID>
    var keys: [SearchProviderID: String]

    init(
        enabled: Set<SearchProviderID> = Set(SearchProviderID.allCases),
        keys: [SearchProviderID: String] = [:]
    ) {
        self.enabled = enabled
        self.keys = keys
    }

    func key(for provider: SearchProviderID) -> String {
        (keys[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum SearchHTTP {
    static let transport: SearchHTTPTransport = { request in
        try await PrivateHTTP.data(
            for: request,
            maxBytes: PrivateHTTP.defaultMaxBytes,
            timeout: 20
        )
    }
}

enum SearchHTTPMapping {
    static func validate(_ response: URLResponse, data: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SearchProviderError.malformedResponse
        }
        switch http.statusCode {
        case 200...299:
            // Some providers report a limit in a 200 envelope.
            if let data, let error = bodyError(in: data) {
                throw error
            }
            return
        case 401:
            throw SearchProviderError.unauthorized
        case 403:
            throw SearchProviderError.forbidden
        case 402:
            throw SearchProviderError.quotaExhausted
        case 429:
            throw SearchProviderError.rateLimited(retryAfter: retryAfter(in: http))
        case 408:
            throw SearchProviderError.timeout
        default:
            throw SearchProviderError.server(http.statusCode)
        }
    }

    /// `Retry-After` is either delta-seconds or an HTTP date. An unparseable
    /// value returns nil so the router can fall back to its backoff ladder.
    static func retryAfter(in response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(raw), seconds.isFinite {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    /// Conservative 200-with-error detection. Only explicit numeric codes or
    /// unmistakable limit wording qualify; anything else stays a decode error
    /// so a schema change is not silently reported as a rate limit.
    static func bodyError(in data: Data) -> SearchProviderError? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["error"] else {
            return nil
        }
        var code: Int?
        var message: String?
        if let dictionary = raw as? [String: Any] {
            code = (dictionary["code"] as? Int) ?? (dictionary["status"] as? Int)
            message = (dictionary["message"] as? String) ?? (dictionary["error"] as? String)
        } else if let text = raw as? String {
            message = text
        }
        switch code {
        case 429: return .rateLimited(retryAfter: nil)
        case 402: return .quotaExhausted
        default: break
        }
        let lower = (message ?? "").lowercased()
        if lower.contains("rate limit") || lower.contains("too many requests") {
            return .rateLimited(retryAfter: nil)
        }
        if lower.contains("quota") || lower.contains("insufficient credit")
            || lower.contains("allowance") || lower.contains("out of credits") {
            return .quotaExhausted
        }
        return nil
    }

    static func map(_ error: Error) -> SearchProviderError {
        if let error = error as? SearchProviderError { return error }
        if error is CancellationError { return .transport("cancelled") }
        guard let urlError = error as? URLError else {
            return .transport(error.localizedDescription)
        }
        switch urlError.code {
        case .timedOut: return .timeout
        case .cancelled: return .transport("cancelled")
        default: return .transport(urlError.localizedDescription)
        }
    }

    /// Accepts the date shapes the three providers return: ISO 8601, RFC 1123,
    /// and bare `YYYY-MM-DD`.
    static func date(from raw: String?) -> Date? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return TimelineDateParser.parse(raw)?.date
    }
}
