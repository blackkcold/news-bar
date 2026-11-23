import XCTest

/// Guards the app entry against the v3.4.0 regression: a top-level `await`
/// turns the entry into a main-actor task, and `NSApplication.run()` then
/// starves every `Task { @MainActor }` in the app. This test is deliberately
/// syntactic and cheap; the launch probe covers the runtime behavior.
final class MainEntryInvariantTests: XCTestCase {
    func testAppEntryStaysSynchronous() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let main = root.appendingPathComponent("Sources/NewsBar/main.swift")
        let text = try String(contentsOf: main, encoding: .utf8)
        let code = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertFalse(code.contains("await "), "The app entry must not be async")
        XCTAssertFalse(code.contains("AgentHeadless"), "Agent commands must not run in the app entry")
        XCTAssertFalse(code.contains("Task {"), "No top-level Task in the app entry")
        XCTAssertTrue(code.contains("LaunchProbe"), "The launch probe must stay wired")
    }
}
