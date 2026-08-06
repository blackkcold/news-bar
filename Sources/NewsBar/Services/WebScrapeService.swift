import Foundation

/// Scrapes a single URL into LLM-ready markdown via Firecrawl's /v2/scrape.
/// Only used in the self-healing research loop when the AI reports it needs
/// page content. URLs are validated (https-only) before any request.
enum WebScrapeService {

    static func scrape(urlString: String, apiKey: String) async throws -> String {
        guard let url = SecurityPolicies.validateURL(urlString) else {
            throw NewsBarError.invalidURL
        }
        guard let endpoint = URL(string: "https://api.firecrawl.dev/v2/scrape") else {
            throw NewsBarError.invalidURL
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 25
        let body: [String: Any] = [
            "url": url.absoluteString,
            "formats": ["markdown"],
            "onlyMainContent": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NewsBarError.requestFailed }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw NewsBarError.apiKeyInvalid }
            throw NewsBarError.requestFailed
        }

        struct ScrapeResponse: Decodable {
            struct Data: Decodable {
                let markdown: String?
            }
            let data: Data?
        }
        guard let decoded = try? JSONDecoder().decode(ScrapeResponse.self, from: data),
              let markdown = decoded.data?.markdown,
              !markdown.isEmpty else {
            throw NewsBarError.parseFailed
        }
        return String(markdown.prefix(12_000))
    }
}
