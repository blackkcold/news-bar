import Foundation

enum AISummaryService {

    struct SummaryResult {
        let summary: String
        let isTruncated: Bool
        let requestCount: Int
    }

    private static let timeout: TimeInterval = 30
    private static let initialMaxTokens = 1024
    private static let retryMaxTokens = 2048

    // MARK: - Transient Error Retry

    /// Thrown internally for 429/5xx responses to trigger retry logic.
    private struct TransientHTTPError: Error {
        let statusCode: Int
    }

    /// Retries the operation up to `maxRetries` times on `TransientHTTPError`,
    /// with exponential backoff (1s, 2s). Non-transient errors propagate immediately.
    private static func withRetry<T>(
        maxRetries: Int = 2,
        _ operation: () async throws -> T
    ) async throws -> T {
        var lastTransientError: TransientHTTPError?
        for attempt in 0...maxRetries {
            do {
                return try await operation()
            } catch let error as TransientHTTPError {
                lastTransientError = error
                if attempt < maxRetries {
                    let delaySeconds: UInt64 = 1 << attempt
                    try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                    continue
                }
            } catch {
                throw error
            }
        }
        throw NewsBarError.parseFailedWithDetail(
            "HTTP \(lastTransientError?.statusCode ?? 0) — 重试 \(maxRetries + 1) 次后仍然失败"
        )
    }

    static func summarize(
        items: [NewsItem],
        maxWords: Int = 150,
        provider: AIProvider,
        model: String,
        apiKey: String
    ) async throws -> SummaryResult {
        let titles = items.enumerated().map { index, item in
            "[#\(index)] \(item.title)"
        }.joined(separator: "\n")

        let prompt = """
        以下是最新新闻标题列表，每条有引用编号 [#N]，请在「引用：」行标注来源：

        \(titles)

        请从以上新闻中挑选 3–5 个最重要的话题，用中文写成简报。总字数不超过 \(maxWords) 字。

        输出框架（严格使用【】标记）：

        【话题标题】
        一段自然概述。
        引用：[#N]

        【话题标题】
        一段自然概述。
        引用：[#N]

        规则：
        - 只写 3–5 个话题，不是全部；自主判断哪些最重要
        - 每个话题「【标题】」独占一行，下接一段概述，再下接「引用：[#N]」
        - 概述为自然段落（不要列表），内容精炼
        - 每段只标 1 条最相关新闻的编号
        - **加粗**仅限爆火/突发热点
        - 不输出来源名称
        - 总字数严格 ≤ \(maxWords) 字
        """

        guard let url = URL(string: provider.baseURL) else {
            throw NewsBarError.invalidURL
        }

        let result = try await withRetry {
            try await makeRequest(
                url: url,
                provider: provider,
                apiKey: apiKey,
                model: model,
                systemPrompt: systemPrompt(),
                userPrompt: prompt,
                maxTokens: initialMaxTokens
            )
        }
        if !result.isTruncated {
            return SummaryResult(summary: result.summary, isTruncated: false, requestCount: 1)
        }
        let retryResult = try await withRetry {
            try await makeRequest(
                url: url,
                provider: provider,
                apiKey: apiKey,
                model: model,
                systemPrompt: systemPrompt(),
                userPrompt: prompt,
                maxTokens: retryMaxTokens
            )
        }
        return SummaryResult(summary: retryResult.summary, isTruncated: retryResult.isTruncated, requestCount: 2)
    }

    private static func makeRequest(
        url: URL,
        provider: AIProvider,
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int
    ) async throws -> (summary: String, isTruncated: Bool) {
        switch provider.responseFormat {
        case .openAI:
            return try await makeOpenAIRequest(
                url: url, provider: provider, apiKey: apiKey, model: model,
                systemPrompt: systemPrompt, userPrompt: userPrompt, maxTokens: maxTokens
            )
        case .anthropic:
            return try await makeAnthropicRequest(
                url: url, provider: provider, apiKey: apiKey, model: model,
                systemPrompt: systemPrompt, userPrompt: userPrompt, maxTokens: maxTokens
            )
        }
    }

    // MARK: - OpenAI-format request

    private static func makeOpenAIRequest(
        url: URL,
        provider: AIProvider,
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int
    ) async throws -> (summary: String, isTruncated: Bool) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(provider.authHeaderPrefix)\(apiKey)", forHTTPHeaderField: provider.authHeaderName)
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
            if httpResponse.statusCode == 429 || (500...599).contains(httpResponse.statusCode) {
                throw TransientHTTPError(statusCode: httpResponse.statusCode)
            }
            throw NewsBarError.requestFailed
        }
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard contentType.contains("application/json") || contentType.contains("text/event-stream") else {
            throw NewsBarError.requestFailed
        }

        struct OAIResponse: Decodable {
            struct Choice: Decodable {
                let finish_reason: String?
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }

        let decoded = try JSONDecoder().decode(OAIResponse.self, from: data)
        guard let choice = decoded.choices.first else {
            throw NewsBarError.parseFailed
        }

        let content = choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let truncated = choice.finish_reason == "length"
        return (content, truncated)
    }

    // MARK: - Anthropic-format request

    private static func makeAnthropicRequest(
        url: URL,
        provider: AIProvider,
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int
    ) async throws -> (summary: String, isTruncated: Bool) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(provider.authHeaderPrefix)\(apiKey)", forHTTPHeaderField: provider.authHeaderName)
        if let version = provider.apiVersion {
            request.setValue(version, forHTTPHeaderField: "anthropic-version")
        }
        request.timeoutInterval = timeout

        let body: [String: Any] = [
            "model": model,
            "system": systemPrompt,
            "messages": [
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
            if httpResponse.statusCode == 429 || (500...599).contains(httpResponse.statusCode) {
                throw TransientHTTPError(statusCode: httpResponse.statusCode)
            }
            throw NewsBarError.requestFailed
        }
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard contentType.contains("application/json") || contentType.contains("text/event-stream") else {
            throw NewsBarError.requestFailed
        }

        struct AnthropicResponse: Decodable {
            struct ContentBlock: Decodable {
                let type: String
                let text: String?
            }
            let content: [ContentBlock]
            let stop_reason: String?
        }

        let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        guard let textBlock = decoded.content.first(where: { $0.type == "text" }),
              let text = textBlock.text else {
            throw NewsBarError.parseFailed
        }

        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let truncated = decoded.stop_reason == "max_tokens"
        return (content, truncated)
    }

    private static func systemPrompt() -> String {
        """
        你是一个专业的新闻摘要助手。请严格遵循以下原则：
        1. 简要：只保留核心信息，删除冗余修饰词
        2. 准确：严格基于提供的标题，不添加推测或外部知识
        3. 结构化：按主题归类，使用「标题+段落」格式概述内容，不要仅列出标题
        4. 克制：不要加粗普通关键词，仅对爆火/突发/重大热点事件使用 **加粗**；输出中不提及来源（微博/B站/RSS等）
        5. 引用：每个主题末尾用「引用：[#N]」标注来源编号，不要遗漏
        """
    }
}
