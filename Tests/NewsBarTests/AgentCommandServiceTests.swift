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

    private func run(_ command: AgentCommand) throws -> AgentResult {
        if service == nil {
            service = AgentCommandService(settings: settings) {}
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
