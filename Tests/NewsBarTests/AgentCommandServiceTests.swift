import XCTest
import NewsBarAgentProtocol
@testable import NewsBar

final class AgentCommandServiceTests: XCTestCase {

    private var root: URL!
    private var service: AgentCommandService?
    private var settings: AppSettings!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCommandServiceTests-\(UUID().uuidString)", isDirectory: true)
        setenv("NEWSBAR_AGENT_ROOT", root.path, 1)
        try AgentPaths.ensureDirectories()

        settings = AppSettings()
        settings.agentAccessEnabled = true
        settings.rssSources = []
        settings.selectedRSSSourceIDs = []
    }

    override func tearDownWithError() throws {
        service?.stop()
        service = nil
        unsetenv("NEWSBAR_AGENT_ROOT")
        try? FileManager.default.removeItem(at: root)
        TestIsolation.defaults.removeObject(forKey: "rssSources")
        TestIsolation.defaults.removeObject(forKey: "selectedRSSSourceIDs")
        TestIsolation.defaults.removeObject(forKey: "agentAccessEnabled")
    }

    func test_addListRemoveRoundTrip() throws {
        let add = AgentCommand(
            command: .rssAdd,
            payload: .init(
                url: "https://example.com/feed.xml",
                name: "Example",
                displayMode: "text",
                select: true
            )
        )
        let addResult = try run(add)
        XCTAssertTrue(addResult.ok)
        XCTAssertEqual(addResult.data?.added, 1)
        XCTAssertEqual(settings.rssSources.map(\.name), ["Example"])
        XCTAssertTrue(settings.selectedRSSSourceIDs.contains("https://example.com/feed.xml"))

        let list = AgentCommand(command: .rssList, payload: .init(scope: "all"))
        let listResult = try run(list)
        XCTAssertEqual(listResult.data?.sources?.map(\.url), ["https://example.com/feed.xml"])

        let remove = AgentCommand(
            command: .rssRemove,
            payload: .init(url: "https://example.com/feed.xml")
        )
        let removeResult = try run(remove)
        XCTAssertTrue(removeResult.ok)
        XCTAssertEqual(removeResult.data?.removed, 1)
        XCTAssertTrue(settings.rssSources.isEmpty)
    }

    func test_importDryRunDoesNotMutate() throws {
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0"><body>
          <outline text="A" type="rss" xmlUrl="https://example.com/a.xml"/>
          <outline text="B" type="rss" xmlUrl="https://example.com/b.xml"/>
        </body></opml>
        """
        let command = AgentCommand(
            command: .rssImport,
            payload: .init(select: true, format: "opml", content: opml, dryRun: true)
        )
        let result = try run(command)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.data?.preview?.count, 2)
        XCTAssertTrue(settings.rssSources.isEmpty)
    }

    func test_disabledAgentRejectsCommands() throws {
        settings.agentAccessEnabled = false
        let command = AgentCommand(
            command: .rssAdd,
            payload: .init(url: "https://example.com/feed.xml", select: true)
        )
        let result = try run(command)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error?.code, .agentDisabled)
        XCTAssertTrue(settings.rssSources.isEmpty)
    }

    // MARK: - Research

    /// Without a live orchestrator there is nothing to run a pass, and the
    /// bridge must say so instead of queueing into a void. This is also the
    /// path an older app build takes when a newer CLI asks for research.
    func test_researchStartWithoutHooksIsAppUnavailable() throws {
        let result = try run(
            AgentCommand(command: .researchStart, payload: .init(topic: "双十一手机销量"))
        )
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error?.code, .appUnavailable)
    }

    func test_researchStartRejectsAnEmptyTopic() throws {
        let hooks = stubMediaHooks()
        let result = try run(
            AgentCommand(command: .researchStart, payload: .init(topic: "   ")),
            research: hooks
        )
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error?.code, .invalidCommand)
    }

    /// The depth is a preference, not an identity: an unknown value must not
    /// fail the command, or a typo would silently cost a research pass.
    func test_researchStartFallsBackToStandardDepth() throws {
        let hooks = stubHooks { topic, depth in
            .started(recordID: "R1", topic: topic, depth: depth)
        }
        let result = try run(
            AgentCommand(
                command: .researchStart,
                payload: .init(topic: "双十一手机销量", depth: "gigantic")
            ),
            research: hooks
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.data?.depth, "standard")
        XCTAssertEqual(result.data?.recordID, "R1")
    }

    /// A report that is already running must report the existing record rather
    /// than start a second pass over the same topic.
    func test_researchStartOnActiveRecordReportsItAsRunning() throws {
        let hooks = stubHooks { _, _ in .alreadyActive(recordID: "R-active") }
        let result = try run(
            AgentCommand(command: .researchStart, payload: .init(topic: "事件")),
            research: hooks
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.data?.recordID, "R-active")
        XCTAssertEqual(result.data?.running, true)
    }

    func test_researchStatusReportsCountsAndVerdict() throws {
        let snapshot = ResearchAgentSnapshot(
            recordID: "R1",
            topic: "双十一手机销量",
            depth: .deep,
            status: .ready,
            phase: .done,
            summary: "摘要。",
            evidenceCount: 6,
            timelineCount: 4,
            commentaryCount: 2,
            verdict: .mostlyConfirmed,
            verdictStrength: 3,
            searchCalls: 9,
            aiCalls: 5,
            pagesRead: 6,
            queries: ["q1", "q2"],
            limitations: "",
            lastError: nil,
            isPartial: false,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let hooks = ResearchAgentHooks(
            start: { _, _ in .unavailable },
            snapshot: { _, _ in snapshot }
        )
        let result = try run(
            AgentCommand(command: .researchStatus, payload: .init(recordID: "R1")),
            research: hooks
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.data?.evidenceCount, 6)
        XCTAssertEqual(result.data?.timelineCount, 4)
        XCTAssertEqual(result.data?.commentaryCount, 2)
        XCTAssertEqual(result.data?.verdict, "mostlyConfirmed")
        XCTAssertEqual(result.data?.verdictStrength, 3)
        XCTAssertEqual(result.data?.queries, ["q1", "q2"])
    }

    /// A missing record is `not_found`, not an empty success: a poll loop has to
    /// be able to tell "no such record" from "not started yet".
    func test_researchStatusOnMissingRecordIsNotFound() throws {
        let hooks = ResearchAgentHooks(
            start: { _, _ in .unavailable },
            snapshot: { _, _ in nil }
        )
        let result = try run(
            AgentCommand(command: .researchStatus, payload: .init(recordID: "nope")),
            research: hooks
        )
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error?.code, .notFound)
    }

    func test_researchStatusNeedsARecordOrTopic() throws {
        let hooks = stubMediaHooks()
        let result = try run(
            AgentCommand(command: .researchStatus),
            research: hooks
        )
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error?.code, .invalidCommand)
    }

    private func stubMediaHooks() -> ResearchAgentHooks {
        stubHooks { topic, depth in .started(recordID: "R1", topic: topic, depth: depth) }
    }

    /// A command that arrives while another one is still being handled must
    /// still be answered.
    ///
    /// `handle` became async so research could run through it, and
    /// `processPending` now starts a `Task` and returns immediately. The
    /// `isProcessing` guard therefore drops a rescan that lands mid-flight, and
    /// nothing rescans after the task finishes — so the command sat in the inbox
    /// until some later write happened to pick it up along with itself.
    func testCommandArrivingDuringProcessingIsStillAnswered() throws {
        let slowStart = stubHooks { topic, depth in
            // Long enough that a second command definitely arrives mid-flight,
            // short enough to keep the test fast.
            try? await Task.sleep(nanoseconds: 600_000_000)
            return .started(recordID: "R1", topic: topic, depth: depth)
        }
        service = AgentCommandService(settings: settings, research: slowStart) {}
        service?.start()

        let first = AgentCommand(command: .researchStart, payload: .init(topic: "第一个"))
        try AgentFile.write(try JSONEncoder().encode(first), to: AgentPaths.commandURL(id: first.id))

        // The first command must already be inside its await before the second
        // arrives, otherwise this only tests the sequential path.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: AgentPaths.commandURL(id: first.id).path),
            "the first command must still be in the inbox; it is mid-flight"
        )

        let second = AgentCommand(command: .status)
        try AgentFile.write(try JSONEncoder().encode(second), to: AgentPaths.commandURL(id: second.id))

        XCTAssertNotNil(waitForResult(id: first.id, timeout: 4), "the first command must be answered")
        XCTAssertNotNil(
            waitForResult(id: second.id, timeout: 4),
            "a command queued while another was in flight was left in the inbox"
        )
    }

    private func waitForResult(id: String, timeout: TimeInterval) -> AgentResult? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? AgentFile.read(
                AgentPaths.resultURL(id: id),
                maxBytes: AgentProtocol.maxResultBytes
            ), let result = try? JSONDecoder().decode(AgentResult.self, from: data) {
                return result
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return nil
    }

    private func stubHooks(
        start: @escaping @MainActor @Sendable (String, ResearchDepth) async -> ResearchAgentStartResult
    ) -> ResearchAgentHooks {
        ResearchAgentHooks(
            start: start,
            snapshot: { _, _ in nil }
        )
    }

    private func run(_ command: AgentCommand) throws -> AgentResult {
        try run(command, research: nil)
    }

    private func run(_ command: AgentCommand, research: ResearchAgentHooks?) throws -> AgentResult {
        if service == nil || research != nil {
            service?.stop()
            service = AgentCommandService(settings: settings, research: research) {}
            service?.start()
        }
        try AgentFile.write(
            try JSONEncoder().encode(command),
            to: AgentPaths.commandURL(id: command.id)
        )
        // `start()` scans synchronously; a later command arrives through the
        // directory watcher, which answers on the main queue. Give it a moment.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let data = try? AgentFile.read(AgentPaths.resultURL(id: command.id), maxBytes: AgentProtocol.maxResultBytes),
               let result = try? JSONDecoder().decode(AgentResult.self, from: data) {
                return result
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("Timed out waiting for \(command.command.rawValue)")
        throw AgentFileError.readFailed(0)
    }
}
