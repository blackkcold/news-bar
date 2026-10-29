import Foundation

/// Parallel Search. It takes an objective plus keyword queries and returns
/// ranked URLs with compressed excerpts. Keyless access exists only through
/// Parallel's MCP server, so the REST path always needs a key.
struct ParallelSearchProvider: SearchProvider {
    let id: SearchProviderID = .parallel

    private let transport: SearchHTTPTransport
    private let endpoint: URL

    init(
        endpoint: URL = URL(string: "https://api.parallel.ai/v1/search")!,
        transport: @escaping SearchHTTPTransport = SearchHTTP.transport
    ) {
        self.endpoint = endpoint
        self.transport = transport
    }

    func search(_ query: SearchQuery, key: String) async throws -> [SearchHit] {
        guard !key.isEmpty else { throw SearchProviderError.missingKey }
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SearchProviderError.emptyQuery }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 20

        // `fast` keeps latency close to the other providers; the default
        // `advanced` mode can take several seconds per call.
        let body: [String: Any] = [
            "objective": text,
            "search_queries": [text],
            "mode": "fast",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(request)
        try SearchHTTPMapping.validate(response, data: data)

        struct ParallelResponse: Decodable {
            struct Result: Decodable {
                let url: String?
                let title: String?
                let publishDate: String?
                let excerpts: [String]?

                enum CodingKeys: String, CodingKey {
                    case url, title, excerpts
                    case publishDate = "publish_date"
                }
            }
            let results: [Result]
        }

        guard let decoded = try? JSONDecoder().decode(ParallelResponse.self, from: data) else {
            throw SearchProviderError.malformedResponse
        }

        return decoded.results.enumerated().compactMap { index, result in
            guard let url = result.url, !url.isEmpty else { return nil }
            let snippet = (result.excerpts ?? []).joined(separator: "\n\n")
            return SearchHit(
                url: url,
                title: result.title ?? url,
                snippet: snippet,
                publishedAt: SearchHTTPMapping.date(from: result.publishDate),
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
