import XCTest
@testable import NewsBar

final class PageSummaryTests: XCTestCase {
    private actor SummaryTestClient: AIChatClienting {
        private(set) var requests: [AIChatRequest] = []
        private let text: String

        init(text: String) {
            self.text = text
        }

        func complete(_ request: AIChatRequest) async throws -> AIChatResponse {
            requests.append(request)
            return AIChatResponse(text: text, truncated: false)
        }
    }

    func testSummarizeUsesInjectedClient() async throws {
        let client = SummaryTestClient(text: "【概览】一句话\n【要点】\n- 要点一")
        let summary = try await PageSummaryService.summarize(
            input: .article(
                title: "T",
                url: "https://example.com/a",
                text: String(repeating: "正文", count: 300),
                language: .zh,
                isPrivate: false
            ),
            configuration: makeConfiguration(),
            providerName: "Test",
            quotaPolicy: .unlimited,
            thinking: nil,
            client: client
        )
        XCTAssertEqual(summary.oneLine, "一句话")
        let requestCount = await client.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    func testArticleInputIsTruncatedAndMarked() throws {
        let text = String(repeating: "a", count: PageSummaryService.maxArticleCharacters + 250)
        let input = PageSummaryInput.article(
            title: "Long article",
            url: "https://example.com/a",
            text: text,
            language: .zh,
            isPrivate: false
        )
        let prepared = try PageSummaryService.prepare(input, language: .zh)

        XCTAssertTrue(prepared.wasTruncated)
        XCTAssertEqual(prepared.inputCharacters, PageSummaryService.maxArticleCharacters)
        XCTAssertTrue(prepared.userPrompt.contains("<untrusted_page>"))
        XCTAssertTrue(prepared.userPrompt.contains("</untrusted_page>"))
    }

    func testListPromptUsesNumberedTitlesAndNeverArticleBodies() throws {
        let rows = [
            PageSummaryListRow(position: 2, item: NewsItem(
                title: "第一件事",
                url: "https://example.com/1",
                source: .rss(name: "来源甲", url: "https://example.com/feed")
            )),
            PageSummaryListRow(position: 5, item: NewsItem(
                title: "第二件事",
                url: "https://example.com/2",
                source: .bilibili
            )),
        ]
        let input = PageSummaryInput.list(
            title: "为你推荐",
            rows: rows,
            language: .zh,
            isPrivate: false
        )
        let prepared = try PageSummaryService.prepare(input, language: .zh)

        XCTAssertFalse(prepared.wasTruncated)
        XCTAssertTrue(prepared.userPrompt.contains("[#1] 第一件事"))
        XCTAssertTrue(prepared.userPrompt.contains("[#2] 第二件事"))
        XCTAssertTrue(prepared.userPrompt.contains("仅标题"))
    }

    func testArticleOverviewParsesPointsAndDropsCitations() throws {
        let input = PageSummaryInput.article(
            title: "Article",
            url: "https://example.com/article",
            text: "Body",
            language: .zh,
            isPrivate: false
        )
        let summary = PageSummaryService.parse(
            """
            【概览】这是一句话概览。
            【要点】
            - 第一个要点 [#1]
            - 第二个要点
            - 第三个要点
            """,
            input: input,
            rows: [],
            configuration: makeConfiguration(),
            providerName: "Test Provider",
            inputCharacters: 4,
            wasTruncated: false
        )

        let value = try XCTUnwrap(summary)
        XCTAssertEqual(value.oneLine, "这是一句话概览。")
        XCTAssertEqual(value.points.count, 3)
        XCTAssertEqual(value.points[0].text, "第一个要点")
        XCTAssertNil(value.points[0].citationIndex)
        XCTAssertTrue(value.citations.isEmpty)
    }

    func testListOverviewMapsCitationToOriginalPosition() throws {
        let rows = [
            PageSummaryListRow(position: 3, item: NewsItem(
                title: "第一条",
                url: "https://example.com/1",
                source: .weibo
            )),
            PageSummaryListRow(position: 11, item: NewsItem(
                title: "第二条",
                url: "https://example.com/2",
                source: .weibo
            )),
        ]
        let input = PageSummaryInput.list(
            title: "为你推荐",
            rows: rows,
            language: .zh,
            isPrivate: false
        )
        let summary = PageSummaryService.parse(
            """
            【概览】两条消息值得看。
            【要点】
            - 第一条的消息 [#1]
            - 第二条的消息 [#2]
            - 共同背景
            """,
            input: input,
            rows: rows,
            configuration: makeConfiguration(),
            providerName: "Test Provider",
            inputCharacters: 20,
            wasTruncated: false
        )

        let value = try XCTUnwrap(summary)
        XCTAssertEqual(value.points.count, 3)
        XCTAssertEqual(value.points[0].citationIndex, 1)
        XCTAssertEqual(value.points[1].citationIndex, 2)
        XCTAssertEqual(value.citations.map(\.position), [3, 11])
        XCTAssertEqual(value.citations.map(\.item.title), ["第一条", "第二条"])
    }

    func testMalformedOverviewIsRejectedRatherThanShownRaw() {
        let input = PageSummaryInput.list(
            title: "Empty",
            rows: [],
            language: .zh,
            isPrivate: false
        )
        let summary = PageSummaryService.parse(
            "这不是约定的结构。",
            input: input,
            rows: [],
            configuration: makeConfiguration(),
            providerName: "Test Provider",
            inputCharacters: 8,
            wasTruncated: false
        )
        XCTAssertNil(summary)
    }

    func testCacheKeySeparatesContentModelLanguageAndThinking() {
        let first = PageSummaryInput.article(
            title: "A",
            url: "https://example.com/a",
            text: "first body",
            language: .zh,
            isPrivate: false
        )
        let second = PageSummaryInput.article(
            title: "A",
            url: "https://example.com/a",
            text: "second body",
            language: .zh,
            isPrivate: false
        )
        let firstKey = first.cacheKey(
            model: "m1", providerID: "p", promptVersion: "v1",
            thinking: .medium, thinkingStyle: .deepseekToggle
        )
        XCTAssertNotEqual(firstKey, second.cacheKey(
            model: "m1", providerID: "p", promptVersion: "v1",
            thinking: .medium, thinkingStyle: .deepseekToggle
        ))
        XCTAssertNotEqual(firstKey, first.cacheKey(
            model: "m2", providerID: "p", promptVersion: "v1",
            thinking: .medium, thinkingStyle: .deepseekToggle
        ))
        XCTAssertNotEqual(firstKey, first.cacheKey(
            model: "m1", providerID: "p", promptVersion: "v2",
            thinking: .medium, thinkingStyle: .deepseekToggle
        ))
        XCTAssertNotEqual(firstKey, first.cacheKey(
            model: "m1", providerID: "p", promptVersion: "v1",
            thinking: .high, thinkingStyle: .deepseekToggle
        ))
        XCTAssertNotEqual(firstKey, first.cacheKey(
            model: "m1", providerID: "p", promptVersion: "v1",
            thinking: .medium, thinkingStyle: .anthropicBudget
        ))
    }

    func testCacheStoreRoundTripsAndClears() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageSummaryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PageSummaryCacheStore(fileURL: directory.appendingPathComponent("cache.json"))
        let summary = PageSummary(
            scope: .list,
            oneLine: "概览",
            points: [PageSummaryPoint(text: "要点", citationIndex: 1)],
            citations: [],
            generatedAt: Date(),
            model: "test",
            providerID: "test",
            providerName: "Test",
            inputCharacters: 10,
            wasTruncated: false
        )
        await store.save(summary, key: "key")
        let loaded = await store.load(key: "key")
        XCTAssertEqual(loaded?.oneLine, "概览")

        await store.clear()
        let cleared = await store.load(key: "key")
        XCTAssertNil(cleared)
    }

    private func makeConfiguration() -> ValidatedAIConfiguration {
        let connection = ResolvedAIConnection(
            baseURL: "https://api.example.com/v1/chat/completions",
            responseFormat: .openAI,
            authHeaderName: "Authorization",
            authHeaderPrefix: "Bearer "
        )
        return ValidatedAIConfiguration(
            providerID: "test",
            connection: connection,
            model: "test-model",
            apiKey: "test-key",
            revision: UUID()
        )
    }
}
