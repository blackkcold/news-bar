import AppKit
import Foundation
import NewsBarAgentProtocol

/// Headless commands for agents and scripts.
///
/// They run before `NSApplication`, before the single-instance check and
/// before any store is touched, so a check never disturbs the copy that is
/// already running. Inputs are explicit files or stdin; nothing is written.
enum AgentHeadless {
    static let usage = """
    NewsBarAgent <command>

    COMMANDS
      check                     Run the built-in comment invariants.
      parse-comments <file|->   Parse a Weibo comment payload (desktop or
                                mobile shape) and print styled runs as JSON.
      store-summary [--root <dir>]
                                Read a copy of a monitor store and print
                                counts. The given store is never written.
      render-reader <fixture> [--out <png>] [--width <pt>] [--height <pt>]
                              [--theme modern|retroEditorial] [--language zh|en]
                                Render the reader off-screen to a PNG.
      doctor                    Print identity and isolation facts as JSON.
      help                      Show this help.

    The headless mode opens no window, sends no request and writes no store.
    """

    /// Runs one agent command. The executable calls this directly; there is no
    /// `--agent` guard because the agent process never launches AppKit's loop.
    static func run(
        arguments: [String],
        stdout: (String) -> Void = { print($0) },
        stderr: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) async -> Int32 {
        let rest = Array(arguments.dropFirst())
        let command = rest.first ?? "help"
        let commandArguments = Array(rest.dropFirst())

        switch command {
        case "check":
            return runChecks(stdout: stdout, stderr: stderr)
        case "parse-comments":
            return parseComments(commandArguments, stdout: stdout, stderr: stderr)
        case "store-summary":
            return await AgentStoreSummary.run(commandArguments, stdout: stdout, stderr: stderr)
        case "render-reader":
            return await AgentReaderRender.run(commandArguments, stdout: stdout, stderr: stderr)
        case "doctor":
            return doctor(stdout: stdout, stderr: stderr)
        case "help", "--help", "-h":
            stdout(usage)
            return 0
        default:
            stderr("Unknown agent command: \(command)")
            stderr(usage)
            return 2
        }
    }

    // MARK: - check

    private static func runChecks(
        stdout: (String) -> Void,
        stderr: (String) -> Void
    ) -> Int32 {
        let checks = AgentChecks.run()
        let report = AgentCheckReport(ok: checks.allSatisfy(\.passed), checks: checks)
        do {
            stdout(String(decoding: try encodeJSON(report), as: UTF8.self))
            return report.ok ? 0 : 2
        } catch {
            stderr("Could not encode result: \(error.localizedDescription)")
            return 2
        }
    }

    // MARK: - parse-comments

    private static func parseComments(
        _ arguments: [String],
        stdout: (String) -> Void,
        stderr: (String) -> Void
    ) -> Int32 {
        guard let path = arguments.first else {
            stderr("parse-comments wants a file path or - for stdin")
            return 2
        }

        let data: Data
        do {
            data = try readInput(path)
        } catch {
            stderr("Cannot read \(path): \(error.localizedDescription)")
            return 2
        }

        let fetchedAt = Date()
        var page: WeiboCommentPage?
        var firstError: Error?
        for tier in [WeiboCommentTier.desktop, .mobile] {
            do {
                page = try WeiboCommentParser.parse(
                    data,
                    mid: "agent",
                    tier: tier,
                    fetchedAt: fetchedAt
                )
                break
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        guard let page else {
            stderr("Could not parse comment payload: \(firstError?.localizedDescription ?? "unknown")")
            return 2
        }

        let output = Output(
            mid: "agent",
            tier: page.tier,
            total: page.total,
            comments: page.comments
        )
        do {
            stdout(String(decoding: try encodeJSON(output), as: UTF8.self))
            return 0
        } catch {
            stderr("Could not encode result: \(error.localizedDescription)")
            return 2
        }
    }

    private struct Output: Encodable {
        let mid: String
        let tier: WeiboCommentTier
        let total: Int?
        let comments: [WeiboComment]
    }

    private static func readInput(_ path: String) throws -> Data {
        if path == "-" { return FileHandle.standardInput.readDataToEndOfFile() }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    // MARK: - doctor

    private static func doctor(
        stdout: (String) -> Void,
        stderr: (String) -> Void
    ) -> Int32 {
        let bundleID = AgentPaths.bundleIdentifier
        let report = DoctorReport(
            bundleIdentifier: bundleID,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            agentProtocolVersion: AgentProtocol.version,
            agentRoot: AgentPaths.root.path,
            testIsolation: TestIsolation.isActive,
            storeRoot: WeiboMonitorStore.applicationRoot().path,
            effectiveRoot: WeiboMonitorStore.defaultRoot().path,
            runningInstances: NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count
        )
        do {
            stdout(String(decoding: try encodeJSON(report), as: UTF8.self))
            return 0
        } catch {
            stderr("Could not encode report: \(error.localizedDescription)")
            return 2
        }
    }

    private struct DoctorReport: Encodable {
        let bundleIdentifier: String
        let appVersion: String
        let agentProtocolVersion: Int
        let agentRoot: String
        let testIsolation: Bool
        let storeRoot: String
        let effectiveRoot: String
        let runningInstances: Int
    }

    // MARK: - Shared

    static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    static func emit<T: Encodable>(
        _ value: T,
        stdout: (String) -> Void,
        stderr: (String) -> Void
    ) -> Int32 {
        do {
            stdout(String(decoding: try encodeJSON(value), as: UTF8.self))
            return 0
        } catch {
            stderr("Could not encode result: \(error.localizedDescription)")
            return 2
        }
    }
}

struct AgentCheckReport: Encodable {
    let ok: Bool
    let checks: [AgentChecks.Check]
}
