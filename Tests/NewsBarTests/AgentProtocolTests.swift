import XCTest
import NewsBarAgentProtocol

final class AgentProtocolTests: XCTestCase {

    func test_commandEnvelopeRoundTrips() throws {
        let command = AgentCommand(
            command: .rssAdd,
            client: "newsbarctl/1.0",
            payload: .init(
                url: "https://example.com/feed.xml",
                name: "Example",
                displayMode: "text",
                select: true,
                refresh: false
            )
        )
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(AgentCommand.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, AgentProtocol.version)
        XCTAssertEqual(decoded.id, command.id)
        XCTAssertEqual(decoded.command, .rssAdd)
        XCTAssertEqual(decoded.payload.url, "https://example.com/feed.xml")
        XCTAssertEqual(decoded.payload.name, "Example")
        XCTAssertEqual(decoded.payload.select, true)
    }

    func test_unknownCommandFailsDecoding() {
        let json = """
        {"schemaVersion":1,"id":"x","command":"rss.explode","issuedAt":"2026-11-10T00:00:00Z","client":"test","payload":{}}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(AgentCommand.self, from: Data(json.utf8)))
    }

    func test_fileWriteIsOwnerOnlyAndReadable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentProtocolTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("command.json")
        let payload = Data("{\"ok\":true}".utf8)
        try AgentFile.write(payload, to: url)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)

        let readBack = try AgentFile.read(url)
        XCTAssertEqual(readBack, payload)
    }

    func test_pendingCommands_ignoresHiddenAndNonJSONFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentPendingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try AgentFile.ensureDirectory(directory)

        try AgentFile.write(Data("{}".utf8), to: directory.appendingPathComponent("b.json"))
        try AgentFile.write(Data("{}".utf8), to: directory.appendingPathComponent("a.json"))
        try AgentFile.write(Data("{}".utf8), to: directory.appendingPathComponent("note.txt"))
        try AgentFile.write(Data("{}".utf8), to: directory.appendingPathComponent(".hidden.json"))

        let pending = AgentFile.pendingCommands(in: directory)
        XCTAssertEqual(pending.map(\.lastPathComponent), ["a.json", "b.json"])
    }

    func test_auditAppendKeepsLines() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentAuditTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("audit.log.jsonl")

        AgentFile.appendAuditLine(Data("{\"n\":1}".utf8), to: url)
        AgentFile.appendAuditLine(Data("{\"n\":2}".utf8), to: url)

        let data = try AgentFile.read(url)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(text.split(separator: "\n").count, 2)
    }

    func test_resultEnvelopeEncodesError() throws {
        let result = AgentResult(
            id: "abc",
            ok: false,
            command: "rss.add",
            error: .init(code: .urlBlocked, message: "scheme")
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(AgentResult.self, from: data)
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.error?.code, .urlBlocked)
    }
}
