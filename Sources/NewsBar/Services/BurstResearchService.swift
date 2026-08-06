import Foundation
import os

/// Orchestrates the burst-topic research pipeline:
///   1. If web search is configured, stage search results locally.
///   2. Ask the AI to produce a grounded summary/overview/timeline from them.
///   3. If the AI flags insufficient/erroneous info, scrape selected pages and
///      re-ask — the self-healing loop. Without search, degrade to a pure-AI
///      generation strictly grounded on the topic title + local trend history.
enum BurstResearchService {

    /// Separate daily request accounting so burst research does not consume the
    /// shared AI-summary quota. Kept atomic across concurrent research tasks.
    /// The count is keyed to the calendar day so it self-resets at midnight,
    /// independent of callers remembering to invoke `resetDailyCount`.
    private static let budgetLock = OSAllocatedUnfairLock<(day: Int, count: Int)>(
        initialState: (day: Self.currentDay, count: 0)
    )

    private static var currentDay: Int {
        Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
    }

    static func resetDailyCount() {
        budgetLock.withLock { state in
            state.day = currentDay
            state.count = 0
        }
    }

    static func readDailyCount() -> Int {
        budgetLock.withLock { state in
            Self.rollIfNeeded(&state)
            return state.count
        }
    }

    /// Attempts to reserve one AI request against the independent burst cap.
    /// Returns `false` (and does not increment) when the cap is exhausted.
    static func tryReserveRequest(cap: Int) -> Bool {
        budgetLock.withLock { state in
            Self.rollIfNeeded(&state)
            guard state.count < cap else { return false }
            state.count += 1
            return true
        }
    }

    private static func rollIfNeeded(_ state: inout (day: Int, count: Int)) {
        let today = currentDay
        if state.day != today {
            state.day = today
            state.count = 0
        }
    }

    struct ResearchInput {
        let item: NewsItem
        let trendContext: String
        let apiKey: String
        let connection: ResolvedAIConnection
        let model: String
        let summaryLanguage: AppLanguage
        let disableDeepSeekThinking: Bool
        /// When nil, search is disabled and the pipeline degrades to pure-AI.
        let searchConfig: WebSearchService.Config?
        let dailyCap: Int
        let maxRefetchURLs: Int
    }

    private typealias Staged = (url: String, title: String, desc: String, body: String)

    /// Number of top search results whose full page bodies are proactively
    /// scraped (not just snippets) so the AI has enough material for a timeline.
    private static let proactiveScrapeCount = 4

    static func research(_ input: ResearchInput) async -> BurstResearch {
        if let config = input.searchConfig {
            do {
                let title = input.item.title
                let results = try await WebSearchService.searchMulti(
                    queryVariants: [
                        "\(title) 事件 来龙去脉 时间线",
                        "\(title) 事件 起因 经过 结果",
                        "\(title) news timeline latest update"
                    ],
                    config: config
                )
                var staged = results.prefix(8).map { (url: $0.url, title: $0.title, desc: $0.description, body: "") }
                let scraped = await scrapePages(results.prefix(proactiveScrapeCount).map(\.url), input: input)
                for i in staged.indices {
                    if staged[i].body.isEmpty, let idx = scraped.firstIndex(where: { $0.url == staged[i].url }) {
                        staged[i].body = scraped[idx].body
                    }
                }
                return await runResearch(input: input, searchMode: true, staged: staged, searchStatus: .succeeded)
            } catch {
                NSLog("[BurstResearchService] search failed, degrading to pure-AI: %@", error.localizedDescription)
                // Surface the failure so the UI/log can explain why the result
                // lacks web-grounded content instead of silently degrading.
                return await runResearch(input: input, searchMode: false, staged: [], searchStatus: .failed)
            }
        }
        return await runResearch(input: input, searchMode: false, staged: [], searchStatus: .none)
    }

    /// Scrapes the given URLs into staged bodies. Failures are skipped so one
    /// bad page never aborts the whole research pass.
    private static func scrapePages(_ urls: [String], input: ResearchInput) async -> [Staged] {
        let apiKey = input.searchConfig?.apiKey ?? ""
        let limited = Array(urls.prefix(max(1, proactiveScrapeCount)))
        var scraped: [Staged] = []
        await withTaskGroup(of: Staged?.self) { group in
            for url in limited {
                group.addTask {
                    do {
                        let body = try await WebScrapeService.scrape(urlString: url, apiKey: apiKey)
                        return (url: url, title: "", desc: "", body: body)
                    } catch {
                        NSLog("[BurstResearchService] proactive scrape failed for %@: %@", url, error.localizedDescription)
                        return nil
                    }
                }
            }
            for await result in group {
                if let result { scraped.append(result) }
            }
        }
        return scraped
    }

    private static func runResearch(
        input: ResearchInput,
        searchMode: Bool,
        staged: [Staged],
        searchStatus: BurstSearchStatus
    ) async -> BurstResearch {
        var results = staged
        for attempt in 0...1 {
            guard tryReserveRequest(cap: input.dailyCap) else { return BurstResearch(searchStatus: searchStatus) }
            let prompt = buildPrompt(input: input, searchMode: searchMode, staged: results)
            do {
                let raw = try await requestRaw(input: input, prompt: prompt)
                if let research = BurstResearchParser.parse(raw, searchStatus: searchStatus),
                   BurstResearchParser.hasUsableContent(research) {
                    if research.needsRefetch, attempt == 0, !research.refetchURLs.isEmpty {
                        let refetched = await refetchPages(research.refetchURLs, input: input)
                        if !refetched.isEmpty {
                            results = refetched
                            continue
                        }
                    }
                    return research
                }
            } catch {
                NSLog("[BurstResearchService] AI research attempt %d failed: %@", attempt, error.localizedDescription)
            }
        }
        return BurstResearch(searchStatus: searchStatus)
    }

    private static func refetchPages(_ urls: [String], input: ResearchInput) async -> [Staged] {
        let limited = urls.prefix(max(1, input.maxRefetchURLs))
        var staged: [Staged] = []
        for url in limited {
            do {
                let body = try await WebScrapeService.scrape(urlString: url, apiKey: input.searchConfig?.apiKey ?? "")
                staged.append((url: url, title: "", desc: "", body: body))
            } catch {
                NSLog("[BurstResearchService] scrape failed for %@: %@", url, error.localizedDescription)
            }
        }
        return staged
    }

    private static func requestRaw(input: ResearchInput, prompt: String) async throws -> String {
        switch input.connection.responseFormat {
        case .openAI:
            return try await openAIRequest(input: input, prompt: prompt)
        case .anthropic:
            return try await anthropicRequest(input: input, prompt: prompt)
        }
    }

    private static func openAIRequest(input: ResearchInput, prompt: String) async throws -> String {
        guard let url = URL(string: input.connection.baseURL) else { throw NewsBarError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(input.connection.authHeaderPrefix)\(input.apiKey)", forHTTPHeaderField: input.connection.authHeaderName)
        request.timeoutInterval = 60

        var body: [String: Any] = [
            "model": input.model,
            "messages": [
                ["role": "system", "content": researchSystemPrompt(language: input.summaryLanguage)],
                ["role": "user", "content": prompt],
            ],
            "max_tokens": 8192,
            "temperature": 0.3,
        ]
        if input.disableDeepSeekThinking, input.model.contains("deepseek") {
            body["thinking"] = ["type": "disabled"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NewsBarError.requestFailed }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw NewsBarError.apiKeyInvalid }
            if http.statusCode == 429 || (500...599).contains(http.statusCode) { throw NewsBarError.rateLimited }
            throw NewsBarError.requestFailed
        }
        struct OpenAI: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let decoded = try? JSONDecoder().decode(OpenAI.self, from: data),
              let content = decoded.choices.first?.message.content else {
            throw NewsBarError.parseFailed
        }
        return content
    }

    private static func anthropicRequest(input: ResearchInput, prompt: String) async throws -> String {
        guard let url = URL(string: input.connection.baseURL) else { throw NewsBarError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(input.connection.authHeaderPrefix)\(input.apiKey)", forHTTPHeaderField: input.connection.authHeaderName)
        if let version = input.connection.apiVersion {
            request.setValue(version, forHTTPHeaderField: "anthropic-version")
        }
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": input.model,
            "system": researchSystemPrompt(language: input.summaryLanguage),
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 8192,
            "temperature": 0.3,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NewsBarError.requestFailed }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw NewsBarError.apiKeyInvalid }
            if http.statusCode == 429 || (500...599).contains(http.statusCode) { throw NewsBarError.rateLimited }
            throw NewsBarError.requestFailed
        }
        struct Anthropic: Decodable {
            struct ContentBlock: Decodable {
                let type: String
                let text: String?
            }
            let content: [ContentBlock]
        }
        guard let decoded = try? JSONDecoder().decode(Anthropic.self, from: data),
              let text = decoded.content.first(where: { $0.type == "text" })?.text else {
            throw NewsBarError.parseFailed
        }
        return text
    }

    private static func researchSystemPrompt(language: AppLanguage) -> String {
        if language == .en {
            return """
            You are a careful news-research assistant. Your output must be grounded ONLY in the provided source material (search results, scraped page text, or the topic title + trend history). Never invent facts, dates, names, or causal links. If the material is insufficient, say so via needsRefetch and list URLs, or keep the overview short rather than fabricate. Respond with a single JSON object only, using this exact schema:
            {"summary": string, "overview": string, "timeline": [{"date": string, "title": string, "detail": string}], "sources": [string], "needsRefetch": boolean, "refetchURLs": [string]}
            - "summary": one to two sentences.
            - "overview": the chain of events (来龙去脉), concise.
            - "timeline": chronological nodes; may be an empty array when material lacks dates.
            - "needsRefetch": true only when the snippets are too thin/possibly wrong and page content would help.
            - "refetchURLs": when needsRefetch, up to 3 URLs from the provided results whose pages should be scraped.
            Do not output anything outside the JSON object.
            """
        }
        return """
        你是一名严谨的新闻调研助手。你的输出必须完全基于给定的信息源（搜索结果、抓取的网页正文，或话题标题+热搜历史）。绝不编造事实、日期、人名或因果。若信息不足，通过 needsRefetch 说明并列出的 URL；宁可概要简短也绝不虚构。只输出一个 JSON 对象，严格使用如下 schema：
        {"summary": string, "overview": string, "timeline": [{"date": string, "title": string, "detail": string}], "sources": [string], "needsRefetch": boolean, "refetchURLs": [string]}
        - "summary": 一到两句话的快速总结。
        - "overview": 事件的来龙去脉，简洁。
        - "timeline": 按时间排序的节点；若素材没有日期则返回空数组。
        - "needsRefetch": 仅当搜索摘要过少/疑似有误、抓取正文会有帮助时为 true。
        - "refetchURLs": 当 needsRefetch 为 true 时，从给定结果中选最多 3 个需要抓取正文的 URL。
        除 JSON 对象外不要输出任何其他内容。
        """
    }

    private static func buildPrompt(
        input: ResearchInput,
        searchMode: Bool,
        staged: [Staged]
    ) -> String {
        let lang = input.summaryLanguage
        let title = input.item.title
        let trend = input.trendContext.isEmpty ? (lang == .en ? "No trend history available." : "无热搜历史。") : input.trendContext

        if searchMode {
            let results = staged.enumerated().map { index, r in
                let body = r.body.isEmpty
                    ? (r.title.isEmpty ? "" : "[\(index)] \(r.title) — \(r.desc)")
                    : "[\(index)] URL: \(r.url)\nCONTENT:\n\(String(r.body.prefix(2000)))"
                return body
            }.filter { !$0.isEmpty }.joined(separator: "\n\n")

            if lang == .en {
                return """
                Research this trending topic: \(title)

                Recent local trend history (reference only):
                \(trend)

                Web search results / scraped content:
                \(results.isEmpty ? "(none)" : results)

                Produce a grounded JSON research output. Only use the material above; never fabricate. Timeline may be empty if no dates are present.
                """
            }
            return """
            调研以下热搜话题：\(title)

            本地近况热搜历史（仅供参考）：
            \(trend)

            网页搜索结果 / 抓取内容：
            \(results.isEmpty ? "(无)" : results)

            基于以上素材生成有依据的 JSON 调研结果。只使用上述素材，绝不编造。若无日期则时间线可返回空数组。
            """
        }

        if lang == .en {
            return """
            Research this trending topic using ONLY the title and local trend history below (no web search). Be brief and honest: if you cannot ground dates or causes, keep timeline empty and the overview short. Never fabricate.
            Topic: \(title)
            Trend history: \(trend)
            """
        }
        return """
        仅依据以下标题和热搜历史调研该话题（无联网搜索）。保持简短与诚实：若无法给出有依据的日期或因果，时间线返回空数组且概述从简。绝不编造。
        话题：\(title)
        热搜历史：\(trend)
        """
    }
}
