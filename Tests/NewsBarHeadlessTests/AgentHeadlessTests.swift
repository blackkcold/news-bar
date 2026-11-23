import XCTest
@testable import NewsBar

/// Exercises the headless agent surface. Nothing here opens a window, hits the
/// network or writes the real stores: the suite is safe to run while the app
/// is in use.
final class AgentHeadlessTests: XCTestCase {
    func testNormalLaunchIsNotIntercepted() {
        XCTAssertNil(AgentHeadless.runIfRequested(arguments: ["/Applications/NewsBar.app/Contents/MacOS/NewsBar"]))
        XCTAssertNil(AgentHeadless.runIfRequested(arguments: ["NewsBar", "--help"]))
    }

    func testHelpListsTheCommands() throws {
        var out: [String] = []
        let status = try XCTUnwrap(AgentHeadless.runIfRequested(
            arguments: ["NewsBar", "--agent", "help"],
            stdout: { out.append($0) },
            stderr: { _ in }
        ))
        XCTAssertEqual(status, 0)
        let text = try XCTUnwrap(out.first)
        XCTAssertTrue(text.contains("parse-comments"))
        XCTAssertTrue(text.contains("doctor"))
    }

    func testParseCommentsPrintsRunsAndKeepsWhitespace() throws {
        let payload = #"""
        {"ok":1,"data":[{"idstr":"1","text_raw":"Nice shot <a href='https://example.com/a'>this</a> is great","user":{"screen_name":"A"}}]}
        """#
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-comments-\(UUID().uuidString).json")
        try Data(payload.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        var out: [String] = []
        var err: [String] = []
        let status = try XCTUnwrap(AgentHeadless.runIfRequested(
            arguments: ["NewsBar", "--agent", "parse-comments", file.path],
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

    func testParseCommentsRejectsUnreadableInput() throws {
        var err: [String] = []
        let status = try XCTUnwrap(AgentHeadless.runIfRequested(
            arguments: ["NewsBar", "--agent", "parse-comments", "/nonexistent/\(UUID().uuidString).json"],
            stdout: { _ in },
            stderr: { err.append($0) }
        ))
        XCTAssertEqual(status, 2)
        XCTAssertFalse(err.isEmpty)
    }

    func testParseCommentsRejectsMalformedJSON() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-bad-\(UUID().uuidString).json")
        try Data("not-json".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        var err: [String] = []
        let status = try XCTUnwrap(AgentHeadless.runIfRequested(
            arguments: ["NewsBar", "--agent", "parse-comments", file.path],
            stdout: { _ in },
            stderr: { err.append($0) }
        ))
        XCTAssertEqual(status, 2)
        XCTAssertFalse(err.isEmpty)
    }

    func testDoctorReportsIsolation() throws {
        var out: [String] = []
        let status = try XCTUnwrap(AgentHeadless.runIfRequested(
            arguments: ["NewsBar", "--agent", "doctor"],
            stdout: { out.append($0) },
            stderr: { _ in }
        ))
        XCTAssertEqual(status, 0)

        let data = try XCTUnwrap(out.first?.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["agentProtocolVersion"] as? Int, 1)
        XCTAssertEqual(json["testIsolation"] as? Bool, true, "XCTest must resolve to the isolated root")
        let storeRoot = try XCTUnwrap(json["storeRoot"] as? String)
        XCTAssertTrue(storeRoot.contains("NewsBarTestIsolation"))
        XCTAssertNotNil(json["bundleIdentifier"] as? String)
        XCTAssertNotNil(json["runningInstances"] as? Int)
    }

    func testUnknownCommandFailsWithUsage() throws {
        var err: [String] = []
        let status = try XCTUnwrap(AgentHeadless.runIfRequested(
            arguments: ["NewsBar", "--agent", "nope"],
            stdout: { _ in },
            stderr: { err.append($0) }
        ))
        XCTAssertEqual(status, 2)
        XCTAssertTrue(err.joined().contains("parse-comments"))
    }
}
