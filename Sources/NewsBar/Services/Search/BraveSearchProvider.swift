import Foundation

/// Brave Web Search API. Requires a subscription token; returns `page_age`
/// when the index knows a publish date.
struct BraveSearchProvider: SearchProvider {
    let id: SearchProviderID = .brave

    private let transport: SearchHTTPTransport
    private let endpoint: URL

    init(
        endpoint: URL = URL(string: "https://api.search.brave.com/res/v1/web/search")!,
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
        var items = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "count", value: String(query.maxResults)),
            URLQueryItem(name: "text_decorations", value: "false"),
        ]
        if let freshness = query.recency.braveFreshness {
            items.append(URLQueryItem(name: "freshness", value: freshness))
        }
        components.queryItems = items
        guard let url = components.url else { throw SearchProviderError.malformedResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        request.timeoutInterval = 20

        let (data, response) = try await send(request)
        try SearchHTTPMapping.validate(response, data: data)

        struct BraveResponse: Decodable {
            struct Web: Decodable {
                struct Result: Decodable {
                    let title: String?
                    let url: String?
                    let description: String?
                    let pageAge: String?

                    enum CodingKeys: String, CodingKey {
                        case title, url, description
                        case pageAge = "page_age"
                    }
                }
                let results: [Result]?
            }
            let web: Web?
        }

        guard let decoded = try? JSONDecoder().decode(BraveResponse.self, from: data) else {
            throw SearchProviderError.malformedResponse
        }
        let results = decoded.web?.results ?? []

        return results.enumerated().compactMap { index, result in
            guard let url = result.url, !url.isEmpty else { return nil }
            let snippet = SecurityPolicies.sanitizeHTMLContent(result.description ?? "")
            return SearchHit(
                url: url,
                title: result.title ?? url,
                snippet: snippet,
                publishedAt: SearchHTTPMapping.date(from: result.pageAge),
                inlineContent: nil,
                provider: id,
                providerRank: index + 1
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
