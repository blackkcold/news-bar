import Foundation

/// TinyFish web search. The endpoint is a GET with an `X-API-Key` header and
/// has no keyless mode; the free allowance is per account.
struct TinyFishSearchProvider: SearchProvider {
    let id: SearchProviderID = .tinyfish

    private let transport: SearchHTTPTransport
    private let endpoint: URL

    init(
        endpoint: URL = URL(string: "https://api.search.tinyfish.ai")!,
        transport: @escaping SearchHTTPTransport = SearchHTTP.transport
    ) {
        self.endpoint = endpoint
        self.transport = transport
    }

    func search(_ query: SearchQuery, key: String) async throws -> [SearchHit] {
        guard !key.isEmpty else { throw SearchProviderError.missingKey }
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SearchProviderError.emptyQuery }

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw SearchProviderError.malformedResponse
        }
        var items = [URLQueryItem(name: "query", value: text)]
        if let language = query.language, !language.isEmpty {
            // TinyFish wants a bare language code, not a full BCP-47 tag.
            items.append(URLQueryItem(name: "language", value: String(language.prefix(2))))
        }
        if let minutes = query.recency.tinyfishRecencyMinutes {
            items.append(URLQueryItem(name: "recency_minutes", value: String(minutes)))
            items.append(URLQueryItem(name: "domain_type", value: "news"))
        }
        components.queryItems = items
        guard let url = components.url else { throw SearchProviderError.malformedResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 20

        let (data, response) = try await send(request)
        try SearchHTTPMapping.validate(response, data: data)

        struct TinyFishResponse: Decodable {
            struct Result: Decodable {
                let position: Int?
                let title: String?
                let url: String?
                let snippet: String?
                let date: String?
            }
            let results: [Result]
        }

        guard let decoded = try? JSONDecoder().decode(TinyFishResponse.self, from: data) else {
            throw SearchProviderError.malformedResponse
        }

        return decoded.results.enumerated().compactMap { index, result in
            guard let url = result.url, !url.isEmpty else { return nil }
            return SearchHit(
                url: url,
                title: result.title ?? url,
                snippet: result.snippet ?? "",
                publishedAt: SearchHTTPMapping.date(from: result.date),
                inlineContent: nil,
                provider: id,
                providerRank: result.position ?? (index + 1)
            )
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await transport(request)
        } catch {
            throw SearchHTTPMapping.map(error)
        }
    }
}
