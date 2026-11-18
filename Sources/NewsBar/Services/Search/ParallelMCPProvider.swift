import Foundation

/// Anonymous, opt-in Parallel MCP adapter. It deliberately exposes only the
/// hosted server's read-only web_search and web_fetch tools.
struct ParallelMCPSearchProvider: SearchProvider {
    let id: SearchProviderID = .parallelMCP
    private let client: ParallelMCPClient

    init(client: ParallelMCPClient = ParallelMCPClient()) {
        self.client = client
    }

    func search(_ query: SearchQuery, key: String) async throws -> [SearchHit] {
        guard key.isEmpty else { throw SearchProviderError.malformedResponse }
        return try await client.search(query)
    }
}

struct ParallelMCPClient: Sendable {
    private let endpoint: URL
    private let transport: SearchHTTPTransport

    init(
        endpoint: URL = URL(string: "https://mcp.parallel.ai/mcp?tools=web_search,web_fetch")!,
        transport: @escaping SearchHTTPTransport = SearchHTTP.transport
    ) {
        self.endpoint = endpoint
        self.transport = transport
    }

    func search(_ query: SearchQuery) async throws -> [SearchHit] {
        let objective = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else { throw SearchProviderError.emptyQuery }
        let result = try await call(
            tool: "web_search",
            arguments: [
                "objective": objective,
                "search_queries": [objective],
            ]
        )
        let candidates = Self.searchRows(in: result)
        return candidates.prefix(query.maxResults).enumerated().compactMap { index, row in
            guard let rawURL = Self.string(row, keys: ["url", "link", "canonical_url"]),
                  SecurityPolicies.validatePublicHTTPURL(rawURL).url != nil else { return nil }
            let title = Self.string(row, keys: ["title", "name"]) ?? rawURL
            let snippet = Self.excerpt(row)
            let date = Self.string(row, keys: ["publish_date", "published_at", "date"])
                .flatMap(SearchHTTPMapping.date(from:))
            return SearchHit(
                url: rawURL,
                title: SecurityPolicies.sanitizeHTMLContent(title),
                snippet: SecurityPolicies.sanitizeHTMLContent(snippet),
                publishedAt: date,
                inlineContent: nil,
                provider: .parallelMCP,
                providerRank: index + 1
            )
        }
    }

    func fetch(url: String, title: String) async throws -> String {
        guard SecurityPolicies.validatePublicHTTPURL(url).url != nil else {
            throw SearchProviderError.forbidden
        }
        let objective = "Read the public source page for: \(String(title.prefix(240))). Return source text only."
        let result = try await call(
            tool: "web_fetch",
            arguments: [
                "urls": [url],
                "objective": objective,
                "search_queries": [],
                "full_content": true,
            ]
        )
        let text = Self.fetchText(in: result)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SearchProviderError.malformedResponse }
        return String(SecurityPolicies.sanitizeHTMLContent(text).prefix(DepthProfile.maxPageCharacters))
    }

    private func call(tool: String, arguments: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2026-07-28", forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue("tools/call", forHTTPHeaderField: "Mcp-Method")
        request.setValue(tool, forHTTPHeaderField: "Mcp-Name")
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": "tools/call",
            "params": [
                "name": tool,
                "arguments": arguments,
                "_meta": [
                    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                    "io.modelcontextprotocol/clientInfo": ["name": "NewsBar", "version": "3.2.0"],
                    "io.modelcontextprotocol/clientCapabilities": [String: String](),
                ],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw SearchHTTPMapping.map(error)
        }
        try SearchHTTPMapping.validate(response, data: data)
        guard let object = Self.rpcObject(from: data, response: response) else {
            throw SearchProviderError.malformedResponse
        }
        if let error = object["error"] as? [String: Any] {
            let code = error["code"] as? Int
            let message = (error["message"] as? String ?? "MCP tool failed").lowercased()
            if code == 429 || message.contains("rate limit") || message.contains("too many") {
                throw SearchProviderError.rateLimited(retryAfter: nil)
            }
            if code == 402 || message.contains("quota") || message.contains("credit") {
                throw SearchProviderError.quotaExhausted
            }
            throw SearchProviderError.transport("Parallel MCP tool call failed")
        }
        guard let result = object["result"] as? [String: Any] else {
            throw SearchProviderError.malformedResponse
        }
        if result["isError"] as? Bool == true {
            throw SearchProviderError.transport("Parallel MCP returned a tool error")
        }
        return result
    }

    private static func rpcObject(from data: Data, response: URLResponse) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if let parsed = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
                return parsed
            }
        }
        return nil
    }

    private static func searchRows(in result: [String: Any]) -> [[String: Any]] {
        if let structured = result["structuredContent"] as? [String: Any],
           let rows = rows(in: structured) { return rows }
        if let rows = rows(in: result) { return rows }
        guard let content = result["content"] as? [[String: Any]] else { return [] }
        for item in content {
            guard let text = item["text"] as? String else { continue }
            if let data = text.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rows = rows(in: object) { return rows }
            let urls = Self.urls(in: text)
            if !urls.isEmpty {
                return urls.enumerated().map { index, url in
                    ["url": url, "title": "Search result \(index + 1)", "snippet": text]
                }
            }
        }
        return []
    }

    private static func rows(in object: [String: Any]) -> [[String: Any]]? {
        if let rows = object["results"] as? [[String: Any]] { return rows }
        if let rows = object["data"] as? [[String: Any]] { return rows }
        if let nested = object["result"] as? [String: Any] { return rows(in: nested) }
        return nil
    }

    private static func fetchText(in result: [String: Any]) -> String {
        if let structured = result["structuredContent"] as? [String: Any] {
            for key in ["content", "text", "body", "markdown"] {
                if let text = structured[key] as? String, !text.isEmpty { return text }
            }
            if let documents = structured["results"] as? [[String: Any]] {
                return documents.compactMap { row in
                    string(row, keys: ["content", "text", "body", "markdown", "excerpt"])
                }.joined(separator: "\n\n")
            }
        }
        if let content = result["content"] as? [[String: Any]] {
            return content.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
        }
        return ""
    }

    private static func excerpt(_ row: [String: Any]) -> String {
        if let excerpts = row["excerpts"] as? [String] {
            return excerpts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        return string(row, keys: ["snippet", "description", "excerpt", "summary", "text"]) ?? ""
    }

    private static func string(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        }
        return nil
    }

    private static func urls(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "https://[^\\s<>\\])}]+", options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'"))
        }
    }
}
