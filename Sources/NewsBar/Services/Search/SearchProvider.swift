import Foundation

typealias SearchHTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

protocol SearchProvider: Sendable {
    var id: SearchProviderID { get }
    /// `false` for Firecrawl's keyless free tier.
    var requiresKey: Bool { get }
    func search(_ query: SearchQuery, key: String) async throws -> [SearchHit]
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
    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SearchProviderError.malformedResponse
        }
        switch http.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw SearchProviderError.unauthorized
        case 402, 429:
            throw SearchProviderError.quotaExhausted
        case 408:
            throw SearchProviderError.timeout
        default:
            throw SearchProviderError.server(http.statusCode)
        }
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
