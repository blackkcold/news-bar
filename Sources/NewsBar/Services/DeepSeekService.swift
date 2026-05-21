import Foundation

enum DeepSeekService {

    private static let endpoint = "https://api.deepseek.com/chat/completions"
    private static let timeout: TimeInterval = 30
    private static let initialMaxTokens = 1024
    private static let retryMaxTokens = 2048

    static func summarize(
        items: [NewsItem],
        maxWords: Int = 150,
        model: String = "deepseek-v4-flash",
        apiKey: String
    ) async throws -> (summary: String, isTruncated: Bool) {
        let titles = items.map { item in
            "\(item.source.displayName): \(item.title)"
        }.joined(separator: "\n")

        let prompt = """
        以下是最新新闻标题列表，请用中文做一个简洁的总结（不超过\(maxWords)字），抓住重点：
        
        \(titles)
        """

        guard let url = URL(string: endpoint) else {
            throw NewsBarError.invalidURL
        }

        // First attempt
        do {
            let result = try await makeRequest(
                url: url,
                apiKey: apiKey,
                model: model,
                systemPrompt: systemPrompt(),
                userPrompt: prompt,
                maxTokens: initialMaxTokens
            )
            if !result.isTruncated {
                return result
            }
            // Truncated — retry once with larger token limit
            return try await makeRequest(
                url: url,
                apiKey: apiKey,
                model: model,
                systemPrompt: systemPrompt(),
                userPrompt: prompt,
                maxTokens: retryMaxTokens
            )
        } catch {
            throw error
        }
    }

    private static func makeRequest(
        url: URL,
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int
    ) async throws -> (summary: String, isTruncated: Bool) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
            "max_tokens": maxTokens,
            "temperature": 0.3,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NewsBarError.requestFailed
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw NewsBarError.apiKeyInvalid
            }
            throw NewsBarError.requestFailed
        }

        struct DSResponse: Decodable {
            struct Choice: Decodable {
                let finish_reason: String?
                struct Message: Decodable {
                    let content: String
                }
                let message: Message
            }
            let choices: [Choice]
        }

        let decoded = try JSONDecoder().decode(DSResponse.self, from: data)
        guard let choice = decoded.choices.first else {
            throw NewsBarError.parseFailed
        }

        let content = choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let truncated = choice.finish_reason == "length"

        return (content, truncated)
    }

    private static func systemPrompt() -> String {
        "你是一个专业的新闻摘要助手。请严格遵循以下原则：\n1. 简要：只保留核心信息，删除冗余修饰词\n2. 准确：严格基于提供的标题，不添加推测或外部知识\n3. 结构化：按主题归类，突出最重要的 3-5 条新闻"
    }
}
