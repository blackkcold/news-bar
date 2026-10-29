import Foundation

/// Exa semantic search. The REST endpoint always needs a key; the keyless
/// route only exists through Exa's hosted MCP server, which is not wired up.
struct ExaSearchProvider: SearchProvider {
    let id: SearchProviderID = .exa

    private let transport: SearchHTTPTransport
    private let endpoint: URL
    private let now: @Sendable () -> Date

    init(
        endpoint: URL = URL(string: "https://api.exa.ai/search")!,
        transport: @escaping SearchHTTPTransport = SearchHTTP.transport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoint = endpoint
        self.transport = transport
        self.now = now
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

        var body: [String: Any] = [
            "query": text,
            "type": "auto",
            "numResults": query.maxResults,
            "contents": ["highlights": true],
        ]
        if let days = query.recency.days {
            let start = now().addingTimeInterval(-Double(days) * 24 * 3600)
            body["startPublishedDate"] = ISO8601DateFormatter().string(from: start)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(request)
        try SearchHTTPMapping.validate(response, data: data)

        struct ExaResponse: Decodable {
            struct Result: Decodable {
                let title: String?
                let url: String?
                let publishedDate: String?
                let highlights: [String]?
                let text: String?
            }
            let results: [Result]
        }

        guard let decoded = try? JSONDecoder().decode(ExaResponse.self, from: data) else {
            throw SearchProviderError.malformedResponse
        }

        return decoded.results.enumerated().compactMap { index, result in
            guard let url = result.url, !url.isEmpty else { return nil }
            let highlightText = (result.highlights ?? []).joined(separator: " ")
            let snippet = highlightText.isEmpty ? (result.text ?? "") : highlightText
            return SearchHit(
                url: url,
                title: result.title ?? url,
                snippet: snippet,
                publishedAt: SearchHTTPMapping.date(from: result.publishedDate),
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
