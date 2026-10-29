import Foundation

/// Tavily search. Its free tier returns inline `raw_content`, which saves a
/// Firecrawl scrape for the highest-value pages.
struct TavilySearchProvider: SearchProvider {
    let id: SearchProviderID = .tavily

    private let transport: SearchHTTPTransport
    private let endpoint: URL

    init(
        endpoint: URL = URL(string: "https://api.tavily.com/search")!,
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
        if key.isEmpty {
            // Tavily's keyless tier is selected by a header, not by omission.
            request.setValue("keyless", forHTTPHeaderField: "X-Tavily-Access-Mode")
        } else {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 20

        var body: [String: Any] = [
            "query": text,
            "search_depth": "basic",
            "include_answer": false,
            "include_raw_content": true,
            "max_results": query.maxResults,
            "topic": query.recency == .all ? "general" : "news",
        ]
        if let days = query.recency.days {
            body["days"] = days
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(request)
        try SearchHTTPMapping.validate(response, data: data)

        struct TavilyResponse: Decodable {
            struct Result: Decodable {
                let title: String?
                let url: String?
                let content: String?
                let rawContent: String?
                let publishedDate: String?

                enum CodingKeys: String, CodingKey {
                    case title, url, content
                    case rawContent = "raw_content"
                    case publishedDate = "published_date"
                }
            }
            let results: [Result]
        }

        guard let decoded = try? JSONDecoder().decode(TavilyResponse.self, from: data) else {
            throw SearchProviderError.malformedResponse
        }

        return decoded.results.enumerated().compactMap { index, result in
            guard let url = result.url, !url.isEmpty else { return nil }
            let snippet = result.content ?? ""
            let inline = result.rawContent.flatMap { $0.count >= 400 ? $0 : nil }
            return SearchHit(
                url: url,
                title: result.title ?? url,
                snippet: snippet,
                publishedAt: SearchHTTPMapping.date(from: result.publishedDate),
                inlineContent: inline,
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
