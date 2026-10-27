import Foundation

/// Firecrawl search, usable without a key (IP rate-limited) or with one for
/// higher limits. It returns snippets only; page bodies come from `PageReader`.
struct FirecrawlSearchProvider: SearchProvider {
    let id: SearchProviderID = .firecrawl
    let requiresKey = false

    private let transport: SearchHTTPTransport
    private let endpoint: URL

    init(
        endpoint: URL = URL(string: "https://api.firecrawl.dev/v2/search")!,
        transport: @escaping SearchHTTPTransport = SearchHTTP.transport
    ) {
        self.endpoint = endpoint
        self.transport = transport
    }

    func search(_ query: SearchQuery, key: String) async throws -> [SearchHit] {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SearchProviderError.emptyQuery }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 20

        var body: [String: Any] = [
            "query": text,
            "limit": query.maxResults,
        ]
        if let tbs = query.recency.firecrawlTBS {
            body["tbs"] = tbs
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(request)
        try SearchHTTPMapping.validate(response)

        struct FirecrawlResponse: Decodable {
            struct Result: Decodable {
                let url: String?
                let title: String?
                let description: String?
            }
            struct DataObject: Decodable {
                let web: [Result]?
            }
            let data: DataObject?
            let web: [Result]?
        }

        guard let decoded = try? JSONDecoder().decode(FirecrawlResponse.self, from: data) else {
            throw SearchProviderError.malformedResponse
        }
        let results = decoded.data?.web ?? decoded.web ?? []

        return results.enumerated().compactMap { index, result in
            guard let url = result.url, !url.isEmpty else { return nil }
            return SearchHit(
                url: url,
                title: result.title ?? url,
                snippet: result.description ?? "",
                publishedAt: nil,
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
