import Foundation

/// Scrapes a single URL into LLM-ready markdown via Firecrawl's /v2/scrape.
/// Only used by the research pipeline; URLs are validated as public HTTPS
/// before any request, and the response body is bounded and type-checked.
enum WebScrapeService {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let maxResponseBytes = 4 * 1024 * 1024

    static func scrape(urlString: String, apiKey: String) async throws -> String {
        try await scrape(
            urlString: urlString,
            apiKey: apiKey,
            transport: { request in try await SearchHTTP.session.data(for: request) }
        )
    }

    static func scrape(
        urlString: String,
        apiKey: String,
        transport: Transport
    ) async throws -> String {
        let validatedURL: URL
        switch SecurityPolicies.validatePublicHTTPURL(urlString) {
        case .valid(let url):
            validatedURL = url
        case .blocked:
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
        request.timeoutInterval = DepthProfile.pageTimeout
        let body: [String: Any] = [
            "url": validatedURL.absoluteString,
            "formats": ["markdown"],
            "onlyMainContent": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else { throw NewsBarError.requestFailed }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw NewsBarError.apiKeyInvalid }
            if http.statusCode == 402 || http.statusCode == 429 { throw NewsBarError.rateLimited }
            throw NewsBarError.requestFailed
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
            .split(separator: ";", maxSplits: 1)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard contentType == "application/json" || contentType == "text/json" else {
            throw NewsBarError.requestFailed
        }

        let declaredLength = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int($0) }
        guard HTTPClient.validateResponseSize(
            declaredContentLength: declaredLength,
            receivedByteCount: data.count,
            maxBodySize: maxResponseBytes
        ) else {
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
        return String(markdown.prefix(DepthProfile.maxPageCharacters))
    }
}
