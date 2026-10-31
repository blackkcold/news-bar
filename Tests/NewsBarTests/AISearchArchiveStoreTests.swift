import XCTest
@testable import NewsBar

final class AISearchArchiveStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testArchiveRoundTripDoesNotPersistSourceText() throws {
        let source = AISearchSource(
            index: 1,
            url: "https://source.example/story?edition=zh#top",
            title: "Source title",
            text: "PRIVATE_SOURCE_BODY_93A2 " + String(repeating: "source excerpt ", count: 30)
        )
        let original = answer(sources: [source])
        let entry = makeEntry(query: "question", answer: original)

        let data = try JSONEncoder().encode(entry)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("PRIVATE_SOURCE_BODY_93A2"))
        XCTAssertFalse(json.contains("source excerpt"))

        let restoredEntry = try JSONDecoder().decode(AISearchArchiveEntry.self, from: data)
        let restored = restoredEntry.answerDocument()
        XCTAssertEqual(restored.kind, original.kind)
        XCTAssertEqual(restored.oneLine, original.oneLine)
        XCTAssertEqual(restored.blocks, original.blocks)
        XCTAssertEqual(restored.mode, original.mode)
        XCTAssertEqual(restored.model, original.model)
        XCTAssertEqual(restored.thinking, original.thinking)
        XCTAssertEqual(restored.generatedAt, original.generatedAt)
        XCTAssertEqual(restored.truncated, original.truncated)
        XCTAssertEqual(restored.sources.map(\.index), [1])
        XCTAssertEqual(restored.sources.map(\.title), ["Source title"])
        XCTAssertEqual(restored.sources.map(\.url), ["https://source.example/story?edition=zh"])
        XCTAssertEqual(restored.sources.first?.text, "")
        XCTAssertEqual(restored.sources.first?.excerpt, "")
    }

    func testRecordPrunesAfter90DaysAndKeepsNewest200() async throws {
        let persistence = MemoryAISearchArchivePersistence()
        let store = AISearchArchiveStore(persistence: persistence)
        let tooOld = makeEntry(query: "old", createdAt: now.addingTimeInterval(-91 * 24 * 60 * 60))
        try await store.record(tooOld, now: now)

        for offset in 0..<201 {
            let entry = makeEntry(
                query: "query-\(offset)",
                createdAt: now.addingTimeInterval(-Double(offset))
            )
            try await store.record(entry, now: now)
        }

        let entries = await store.all()
        XCTAssertEqual(entries.count, 200)
        XCTAssertEqual(entries.first?.query, "query-0")
        XCTAssertEqual(entries.last?.query, "query-199")
        XCTAssertFalse(entries.contains { $0.id == tooOld.id })
        XCTAssertTrue(entries.allSatisfy { $0.createdAt >= now.addingTimeInterval(-90 * 24 * 60 * 60) })
    }

    func testDuplicateQueriesRemainSeparateEntries() async throws {
        let store = AISearchArchiveStore(persistence: MemoryAISearchArchivePersistence())
        let first = makeEntry(query: "same question", pageURL: "https://reader.example/article")
        let second = makeEntry(query: "same question", pageURL: "https://reader.example/article")

        try await store.record(first, now: now)
        try await store.record(second, now: now)

        let entries = await store.all()
        XCTAssertEqual(entries.count, 2)
        XCTAssertNotEqual(entries[0].id, entries[1].id)
    }

    func testURLSanitizationStripsUserInfoAndFragmentAndRejectsUnsafeSchemes() {
        let answer = answer(sources: [
            AISearchSource(
                index: 1,
                url: "https://user:pass@source.example/story?q=keep#remove",
                title: "Safe source",
                text: "source body"
            ),
            AISearchSource(index: 2, url: "http://source.example/story", title: "HTTP", text: "body"),
            AISearchSource(index: 3, url: "https://127.0.0.1/private", title: "Private IP", text: "body"),
            AISearchSource(index: 4, url: "file:///private/secret", title: "File", text: "body"),
        ])

        let entry = makeEntry(
            query: "question",
            pageURL: "https://user:pass@reader.example/article?q=keep#remove",
            answer: answer
        )

        XCTAssertEqual(entry.pageURL, "https://reader.example/article?q=keep")
        XCTAssertEqual(entry.answer.sources.map(\.url), [
            "https://source.example/story?q=keep", nil, nil, nil,
        ])
        let restored = entry.answerDocument()
        XCTAssertEqual(restored.sources.map(\.url), [
            "https://source.example/story?q=keep", "", "", "",
        ])
        XCTAssertEqual(restored.sources.map(\.index), [1, 2, 3, 4])
    }

    func testUnsupportedArchiveVersionDoesNotOverwriteExistingBytes() async throws {
        let original = Data(#"{"version":99,"entries":[]}"#.utf8)
        let persistence = MemoryAISearchArchivePersistence(data: original)
        let store = AISearchArchiveStore(persistence: persistence)

        await store.prepare(now: now)
        let loadError = await store.loadError
        XCTAssertNotNil(loadError)
        do {
            try await store.record(makeEntry(query: "new"), now: now)
            XCTFail("an unsupported archive must remain read-only")
        } catch {
            XCTAssertEqual(error as? AISearchArchiveStoreError, .readOnlyArchive)
        }
        let savedBytes = await persistence.bytes()
        XCTAssertEqual(savedBytes, original)
    }

    func testCorruptArchiveIsNotOverwrittenByRecord() async throws {
        let original = Data("not-json".utf8)
        let persistence = MemoryAISearchArchivePersistence(data: original)
        let store = AISearchArchiveStore(persistence: persistence)

        await store.prepare(now: now)
        do {
            try await store.record(makeEntry(query: "new"), now: now)
            XCTFail("a corrupt archive must remain read-only")
        } catch {
            XCTAssertEqual(error as? AISearchArchiveStoreError, .readOnlyArchive)
        }
        let savedBytes = await persistence.bytes()
        XCTAssertEqual(savedBytes, original)
    }

    func testExplicitClearRecoversCorruptArchive() async throws {
        let persistence = MemoryAISearchArchivePersistence(data: Data("broken".utf8))
        let store = AISearchArchiveStore(persistence: persistence)
        await store.prepare(now: now)

        try await store.clear()
        try await store.record(makeEntry(query: "recovered"), now: now)

        let entries = await store.all()
        XCTAssertEqual(entries.map(\.query), ["recovered"])
        let storedData = await persistence.bytes()
        let data = try XCTUnwrap(storedData)
        let snapshot = try JSONDecoder.archiveDecoder.decode(AISearchArchiveSnapshot.self, from: data)
        XCTAssertEqual(snapshot.version, 1)
        XCTAssertEqual(snapshot.entries.map(\.query), ["recovered"])
        let loadError = await store.loadError
        XCTAssertNil(loadError)
    }

    func testRemoveDeletesOnlyRequestedEntry() async throws {
        let store = AISearchArchiveStore(persistence: MemoryAISearchArchivePersistence())
        let first = makeEntry(query: "first")
        let second = makeEntry(query: "second")
        let third = makeEntry(query: "third")
        try await store.record(first, now: now)
        try await store.record(second, now: now)
        try await store.record(third, now: now)

        try await store.remove(id: second.id)

        let entries = await store.all()
        XCTAssertEqual(Set(entries.map(\.id)), Set([first.id, third.id]))
    }

    func testStoreUsesVersionedISO8601SortedJSON() async throws {
        let persistence = MemoryAISearchArchivePersistence()
        let store = AISearchArchiveStore(persistence: persistence)
        try await store.record(makeEntry(query: "stable"), now: now)

        let storedData = await persistence.bytes()
        let data = try XCTUnwrap(storedData)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.hasPrefix("{\"entries\":"))
        XCTAssertTrue(json.contains("\"version\":1"))
        XCTAssertTrue(json.contains(ISO8601DateFormatter().string(from: now)))
    }

    private func answer(sources: [AISearchSource] = []) -> AnswerDocument {
        AnswerDocument(
            kind: .event,
            oneLine: "One line summary",
            blocks: [AnswerBlock(id: 4, heading: "Heading", body: "Answer body [#1]")],
            sources: sources,
            mode: .web,
            model: "search-model",
            thinking: .off,
            generatedAt: now,
            question: "question",
            truncated: true
        )
    }

    private func makeEntry(
        query: String,
        createdAt: Date? = nil,
        pageURL: String? = nil,
        answer: AnswerDocument? = nil
    ) -> AISearchArchiveEntry {
        AISearchArchiveEntry(
            createdAt: createdAt ?? now,
            query: query,
            scope: .web,
            origin: .readerSearch,
            pageTitle: "Reader page",
            pageURL: pageURL,
            providerName: "Provider display name",
            answer: answer ?? self.answer()
        )
    }
}

private actor MemoryAISearchArchivePersistence: AISearchArchivePersisting {
    private var data: Data?

    init(data: Data? = nil) {
        self.data = data
    }

    func load() async throws -> Data? { data }
    func save(_ data: Data) async throws { self.data = data }
    func clear() async throws { data = nil }
    func bytes() -> Data? { data }
}

private extension JSONDecoder {
    static var archiveDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
