import XCTest
@testable import NewsBar

final class WeiboCorpusRecorderTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeiboCorpusRecorderTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        super.tearDown()
    }

    func testEnvironmentFlagGatesTheRecorder() {
        XCTAssertNil(WeiboCorpusRecorder.fromEnvironment([:]))
        XCTAssertNil(WeiboCorpusRecorder.fromEnvironment(["WEIBO_CORPUS_DUMP": "0"]))
        XCTAssertNotNil(WeiboCorpusRecorder.fromEnvironment(["WEIBO_CORPUS_DUMP": "1"]))
    }

    func testAppendWritesDecodableJSONLines() async throws {
        let url = root.appendingPathComponent("posts.jsonl")
        let recorder = WeiboCorpusRecorder(fileURL: url)
        let now = WeiboMonitorTestSupport.date(2026, 11, 7, 12, 0)

        var post = WeiboMonitorTestSupport.post(mid: "1", createdAt: now)
        post.relevance = WeiboPostRelevance(
            adScore: 0.72,
            interestScore: 0.31,
            verdict: .lowConfidence,
            reasons: ["lottery"],
            decider: "rules",
            decidedAt: now
        )
        await recorder.append(posts: [post], now: now)
        await recorder.append(
            posts: [WeiboMonitorTestSupport.post(mid: "2", createdAt: now)],
            now: now
        )

        let data = try Data(contentsOf: url)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(lines.count, 2)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let first = try decoder.decode(WeiboCorpusRecord.self, from: Data(lines[0].utf8))
        XCTAssertEqual(first.mid, "1")
        XCTAssertEqual(first.adScore, 0.72)
        XCTAssertEqual(first.verdict, "lowConfidence")
        XCTAssertEqual(first.reasons, ["lottery"])
        let second = try decoder.decode(WeiboCorpusRecord.self, from: Data(lines[1].utf8))
        XCTAssertEqual(second.mid, "2")
        XCTAssertNil(second.verdict)
    }

    func testAppendIsSilentOnAnUnwritablePath() async {
        // A directory where the file should be: appending must fail without
        // throwing into the monitor path.
        let url = root.appendingPathComponent("directory", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let recorder = WeiboCorpusRecorder(fileURL: url)
        await recorder.append(
            posts: [WeiboMonitorTestSupport.post(createdAt: Date())],
            now: Date()
        )
        // Reaching this line is the assertion: no crash, no thrown error.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
