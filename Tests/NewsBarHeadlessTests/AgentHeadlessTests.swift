import XCTest
@testable import NewsBar

/// Exercises the headless agent surface. Nothing here opens a visible window,
/// hits the network or writes the real stores: the suite is safe to run while
/// the app is in use.
final class AgentHeadlessTests: XCTestCase {
    func testHelpListsTheCommands() async throws {
        var out: [String] = []
        let status = try required(await AgentHeadless.run(
            arguments: ["NewsBarAgent", "help"],
            stdout: { out.append($0) },
            stderr: { _ in }
        ))
        XCTAssertEqual(status, 0)
        let text = try XCTUnwrap(out.first)
        XCTAssertTrue(text.contains("parse-comments"))
        XCTAssertTrue(text.contains("doctor"))
        XCTAssertTrue(text.contains("render-reader"))
    }

    func testParseCommentsPrintsRunsAndKeepsWhitespace() async throws {
        let payload = #"""
        {"ok":1,"data":[{"idstr":"1","text_raw":"Nice shot <a href='https://example.com/a'>this</a> is great","user":{"screen_name":"A"}}]}
        """#
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-comments-\(UUID().uuidString).json")
        try Data(payload.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        var out: [String] = []
        var err: [String] = []
        let status = try required(await AgentHeadless.run(
            arguments: ["NewsBarAgent", "parse-comments", file.path],
            stdout: { out.append($0) },
            stderr: { err.append($0) }
        ))

        XCTAssertEqual(status, 0)
        XCTAssertTrue(err.isEmpty)
        let data = try XCTUnwrap(out.first?.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let comments = try XCTUnwrap(json["comments"] as? [[String: Any]])
        let comment = try XCTUnwrap(comments.first)
        XCTAssertEqual(comment["text"] as? String, "Nice shot this is great")

        let runs = try XCTUnwrap(comment["runs"] as? [[String: Any]])
        let joined = runs.compactMap { $0["text"] as? String }.joined()
        XCTAssertEqual(joined, "Nice shot this is great")
        XCTAssertTrue(runs.contains { $0["kind"] as? String == "link" })
    }

    func testParseCommentsRejectsUnreadableInput() async throws {
        var err: [String] = []
        let status = try required(await AgentHeadless.run(
            arguments: ["NewsBarAgent", "parse-comments", "/nonexistent/\(UUID().uuidString).json"],
            stdout: { _ in },
            stderr: { err.append($0) }
        ))
        XCTAssertEqual(status, 2)
        XCTAssertFalse(err.isEmpty)
    }

    func testParseCommentsRejectsMalformedJSON() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-bad-\(UUID().uuidString).json")
        try Data("not-json".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        var err: [String] = []
        let status = try required(await AgentHeadless.run(
            arguments: ["NewsBarAgent", "parse-comments", file.path],
            stdout: { _ in },
            stderr: { err.append($0) }
        ))
        XCTAssertEqual(status, 2)
        XCTAssertFalse(err.isEmpty)
    }

    func testDoctorReportsIsolation() async throws {
        var out: [String] = []
        let status = try required(await AgentHeadless.run(
            arguments: ["NewsBarAgent", "doctor"],
            stdout: { out.append($0) },
            stderr: { _ in }
        ))
        XCTAssertEqual(status, 0)

        let data = try XCTUnwrap(out.first?.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["agentProtocolVersion"] as? Int, 1)
        XCTAssertEqual(json["testIsolation"] as? Bool, true, "XCTest must resolve to the isolated root")
        let storeRoot = try XCTUnwrap(json["storeRoot"] as? String)
        let effectiveRoot = try XCTUnwrap(json["effectiveRoot"] as? String)
        XCTAssertFalse(
            storeRoot.contains("NewsBarTestIsolation"),
            "storeRoot must be the real application root"
        )
        XCTAssertTrue(
            effectiveRoot.contains("NewsBarTestIsolation"),
            "effectiveRoot must be the isolated root"
        )
        XCTAssertNotNil(json["bundleIdentifier"] as? String)
        XCTAssertNotNil(json["runningInstances"] as? Int)
    }

    func testUnknownCommandFailsWithUsage() async throws {
        var err: [String] = []
        let status = try required(await AgentHeadless.run(
            arguments: ["NewsBarAgent", "nope"],
            stdout: { _ in },
            stderr: { err.append($0) }
        ))
        XCTAssertEqual(status, 2)
        XCTAssertTrue(err.joined().contains("parse-comments"))
    }

    // MARK: - check

    func testCheckPassesAllInvariants() async throws {
        var out: [String] = []
        var err: [String] = []
        let status = try required(await AgentHeadless.run(
            arguments: ["NewsBarAgent", "check"],
            stdout: { out.append($0) },
            stderr: { err.append($0) }
        ))
        XCTAssertEqual(status, 0, err.joined(separator: "\n"))

        let data = try XCTUnwrap(out.first?.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["ok"] as? Bool, true)
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        XCTAssertEqual(checks.count, 6)
        XCTAssertTrue(checks.allSatisfy { $0["passed"] as? Bool == true })
    }

    // MARK: - store-summary

    func testStoreSummaryHandlesMissingRoot() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-store-\(UUID().uuidString)", isDirectory: true)
        var out: [String] = []
        let status = try required(await AgentHeadless.run(
            arguments: ["NewsBarAgent", "store-summary", "--root", missing.path],
            stdout: { out.append($0) },
            stderr: { _ in }
        ))
        XCTAssertEqual(status, 0)

        let data = try XCTUnwrap(out.first?.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["exists"] as? Bool, false)
        XCTAssertEqual(json["posts"] as? Int, 0)
    }

    func testStoreSummaryReadsACopyWithoutChangingTheSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let store = WeiboMonitorStore(root: root)
        let user = WeiboMonitorUser(
            uid: "1",
            screenName: "读者",
            priority: .p0,
            addedAt: now,
            nextDueAt: now.addingTimeInterval(3600)
        )
        try await store.save(users: [user], now: now)
        let post = WeiboPost(
            mid: "100",
            bid: nil,
            uid: "1",
            screenName: "读者",
            text: "hello",
            createdAt: now,
            fetchedAt: now,
            url: "https://m.weibo.cn/detail/100"
        )
        try await store.savePosts(uid: "1", posts: [post], now: now)

        var out: [String] = []
        let status = try required(await AgentHeadless.run(
            arguments: ["NewsBarAgent", "store-summary", "--root", root.path],
            stdout: { out.append($0) },
            stderr: { _ in }
        ))
        XCTAssertEqual(status, 0)

        let data = try XCTUnwrap(out.first?.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["exists"] as? Bool, true)
        XCTAssertEqual(json["users"] as? Int, 1)
        XCTAssertEqual(json["posts"] as? Int, 1)
        XCTAssertEqual(json["unread"] as? Int, 1)
        XCTAssertEqual(json["latestMid"] as? String, "100")

        // The original is still readable with the same post; the copy was the
        // only thing `load()` could have touched.
        let reloaded = await WeiboMonitorStore(root: root).load()
        XCTAssertEqual(reloaded.postsByUID["1"]?.count, 1)
    }

    // MARK: - render-reader

    @MainActor
    func testRenderReaderWritesAPNG() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/reader.json")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-render-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }

        var outLines: [String] = []
        var err: [String] = []
        let status = try required(await AgentHeadless.run(
            arguments: [
                "NewsBarAgent", "render-reader", fixture.path,
                "--out", out.path, "--width", "558", "--height", "900",
            ],
            stdout: { outLines.append($0) },
            stderr: { err.append($0) }
        ))
        XCTAssertEqual(status, 0, err.joined(separator: "\n"))

        let png = try Data(contentsOf: out)
        XCTAssertGreaterThan(png.count, 3_000)

        let data = try XCTUnwrap(outLines.first?.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual((json["width"] as? NSNumber)?.doubleValue, 558)
        XCTAssertEqual(json["theme"] as? String, "modern")
        XCTAssertEqual(json["comments"] as? Int, 3)
    }

    func testRenderReaderRejectsMalformedFixture() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-reader-bad-\(UUID().uuidString).json")
        try Data("{\"post\":{}}".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        var err: [String] = []
        let status = try required(await AgentHeadless.run(
            arguments: ["NewsBarAgent", "render-reader", file.path],
            stdout: { _ in },
            stderr: { err.append($0) }
        ))
        XCTAssertEqual(status, 2)
        XCTAssertFalse(err.isEmpty)
    }

    /// `XCTUnwrap` takes an autoclosure, which cannot contain `await`. This
    /// evaluates the async call first and then unwraps the result.
    private func required<T>(_ value: T?) throws -> T {
        try XCTUnwrap(value)
    }
}
