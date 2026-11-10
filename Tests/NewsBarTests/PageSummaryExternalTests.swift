import XCTest
@testable import NewsBar

final class PageSummaryExternalTests: XCTestCase {
    private func input() -> PageSummaryInput {
        .article(
            title: "Test article",
            url: "https://current.example/story",
            text: String(repeating: "正文内容", count: 300),
            language: .zh,
            isPrivate: false
        )
    }

    private func configuration() -> ValidatedAIConfiguration {
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

    private func externalSource(
        _ index: Int = 2,
        adoption: SourceAdoption = .supporting,
        type: SourceType = .secondary
    ) -> AISearchSource {
        var source = AISearchSource(
            index: index,
            url: "https://source\(index).example/story",
            title: "外部来源 \(index)",
            text: String(repeating: "外部正文内容", count: 100)
        )
        source.assessment = SourceAssessment(
            type: type,
            independence: adoption == .rejected ? .unknown : .independent,
            adoption: adoption,
            reason: adoption == .rejected ? .modelRejected : .assessed
        )
        return source
    }

    private func evidence(
        sources: [AISearchSource],
        basis: PageSummaryBasis,
        adoptedCount: Int = 1
    ) -> PageSummaryEvidence {
        PageSummaryEvidence(
            sources: sources,
            conflicts: [],
            basis: basis,
            retrieval: PageSummaryRetrieval(
                foundCount: sources.count,
                readCount: sources.count,
                adoptedCount: adoptedCount,
                queryCount: 2,
                httpAttempts: 2
            ),
            searchAttempted: true
        )
    }

    private func parse(
        _ raw: String,
        evidence: PageSummaryEvidence
    ) -> PageSummary? {
        PageSummaryService.parse(
            raw,
            input: input(),
            rows: [],
            configuration: configuration(),
            providerName: "Test",
            inputCharacters: 100,
            wasTruncated: false,
            evidence: evidence
        )
    }

    func testArticlePrepareIncludesAdoptedSourcesOnly() throws {
        let adopted = externalSource(2, adoption: .supporting)
        let rejected = externalSource(3, adoption: .rejected)
        let prepared = try PageSummaryService.prepare(
            input(),
            language: .zh,
            evidence: evidence(sources: [adopted, rejected], basis: .externalLimited)
        )
        XCTAssertTrue(prepared.userPrompt.contains("<source index=\"2\""))
        XCTAssertFalse(prepared.userPrompt.contains("<source index=\"3\""))
        XCTAssertTrue(prepared.userPrompt.contains("[2]"))
        XCTAssertTrue(prepared.userPrompt.contains("来源 1"))
        XCTAssertTrue(prepared.userPrompt.contains("<untrusted_page>"))
    }

    func testArticleParseMapsExternalCitationAndSources() {
        let raw = "【概览】一句话\n【要点】\n- 第一个要点[2]\n- 第二个要点"
        let summary = parse(
            raw,
            evidence: evidence(sources: [externalSource(2)], basis: .externalLimited)
        )
        XCTAssertEqual(summary?.points.first?.citationIndices, [2])
        XCTAssertEqual(summary?.points.first?.text, "第一个要点")
        XCTAssertEqual(summary?.sources?.map(\.index), [1, 2])
        XCTAssertEqual(summary?.sources?.first?.kind, .currentPage)
        XCTAssertEqual(summary?.sources?.last?.adoption, .supporting)
        XCTAssertEqual(summary?.basis, .externalLimited)
        XCTAssertFalse(summary?.retrieval?.notes.contains(.externalNotCited) ?? true)
    }

    func testRejectedExternalCitationStaysPlainText() {
        let raw = "【概览】一句话\n【要点】\n- 事实[2]"
        let summary = parse(
            raw,
            evidence: evidence(
                sources: [externalSource(2, adoption: .rejected)],
                basis: .pageOnly,
                adoptedCount: 0
            )
        )
        XCTAssertNil(summary?.points.first?.citationIndices)
        XCTAssertTrue(summary?.points.first?.text.contains("[2]") ?? false)
        XCTAssertEqual(summary?.sources?.last?.adoption, .rejected)
        XCTAssertEqual(summary?.basis, .pageOnly)
    }

    func testAdoptedButUncitedExternalSetsLimitedAndNote() {
        let raw = "【概览】一句话\n【要点】\n- 没有引用外部来源"
        let summary = parse(
            raw,
            evidence: evidence(sources: [externalSource(2)], basis: .externalSupported)
        )
        XCTAssertEqual(summary?.basis, .externalLimited)
        XCTAssertTrue(summary?.retrieval?.notes.contains(.externalNotCited) ?? false)
    }

    func testArticleWithoutExternalSourcesKeepsNoCitationRule() {
        let raw = "【概览】一句话\n【要点】\n- 事实[#1]"
        let summary = parse(raw, evidence: .pageOnly)
        XCTAssertNil(summary?.points.first?.citationIndex)
        XCTAssertNil(summary?.points.first?.citationIndices)
        XCTAssertEqual(summary?.sources?.map(\.index), [1])
        XCTAssertEqual(summary?.basis, .pageOnly)
    }

    func testOldPageSummaryJSONStillDecodes() throws {
        let old = PageSummary(
            scope: .article,
            oneLine: "旧概览",
            points: [
                PageSummaryPoint(text: "旧要点", citationIndex: 1),
            ],
            citations: [],
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            model: "m",
            providerID: "p",
            providerName: "n",
            inputCharacters: 10,
            wasTruncated: false
        )
        let data = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(PageSummary.self, from: data)
        XCTAssertEqual(decoded.oneLine, "旧概览")
        XCTAssertNil(decoded.sources)
        XCTAssertNil(decoded.basis)
        XCTAssertNil(decoded.retrieval)
        XCTAssertNil(decoded.points[0].citationIndices)
        XCTAssertEqual(decoded.points[0].resolvedCitationIndices, [1])
    }

    func testCacheKeySeparatesWebSupplementAndProviders() {
        let input = input()
        let base = input.cacheKey(
            model: "m",
            providerID: "p",
            promptVersion: "v3",
            thinking: .medium,
            thinkingStyle: .deepseekToggle
        )
        let web = input.cacheKey(
            model: "m",
            providerID: "p",
            promptVersion: "v3",
            thinking: .medium,
            thinkingStyle: .deepseekToggle,
            webSupplement: true,
            searchProviderIDs: ["tavily"]
        )
        let otherProvider = input.cacheKey(
            model: "m",
            providerID: "p",
            promptVersion: "v3",
            thinking: .medium,
            thinkingStyle: .deepseekToggle,
            webSupplement: true,
            searchProviderIDs: ["exa"]
        )
        XCTAssertNotEqual(base, web)
        XCTAssertNotEqual(web, otherProvider)
    }

    func testCacheStoreHonorsPerEntryTTL() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageSummaryTTL-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PageSummaryCacheStore(fileURL: directory.appendingPathComponent("cache.json"))
        let summary = PageSummary(
            scope: .article,
            oneLine: "概览",
            points: [PageSummaryPoint(text: "要点", citationIndex: nil)],
            citations: [],
            generatedAt: Date(),
            model: "m",
            providerID: "p",
            providerName: "n",
            inputCharacters: 10,
            wasTruncated: false
        )
        let now = Date()
        await store.save(summary, key: "short", now: now, ttl: 1)
        let hit = await store.load(key: "short", now: now.addingTimeInterval(0.5))
        XCTAssertEqual(hit?.oneLine, "概览")
        let miss = await store.load(key: "short", now: now.addingTimeInterval(2))
        XCTAssertNil(miss)

        await store.save(summary, key: "long", now: now, ttl: PageSummaryCacheStore.retention)
        let longHit = await store.load(key: "long", now: now.addingTimeInterval(24 * 3600))
        XCTAssertEqual(longHit?.oneLine, "概览")
    }

    func testCacheStoreLoadsOldEntryWithoutExpiresAt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageSummaryLegacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let summary = PageSummary(
            scope: .article,
            oneLine: "旧缓存",
            points: [PageSummaryPoint(text: "要点", citationIndex: nil)],
            citations: [],
            generatedAt: Date(),
            model: "m",
            providerID: "p",
            providerName: "n",
            inputCharacters: 10,
            wasTruncated: false
        )
        let summaryData = try JSONEncoder().encode(summary)
        let summaryObject = try JSONSerialization.jsonObject(with: summaryData)
        let now = Date()
        let root: [String: Any] = [
            "key": [
                "summary": summaryObject,
                "lastUsedAt": now.timeIntervalSinceReferenceDate,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: root)
        let url = directory.appendingPathComponent("cache.json")
        try data.write(to: url)

        let store = PageSummaryCacheStore(fileURL: url)
        let loaded = await store.load(key: "key", now: now)
        XCTAssertEqual(loaded?.oneLine, "旧缓存")
    }
}
