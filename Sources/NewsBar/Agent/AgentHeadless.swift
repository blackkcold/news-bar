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
    NewsBar --agent <command>

    COMMANDS
      parse-comments <file|->   Parse a Weibo comment payload (desktop or
                                mobile shape) and print styled runs as JSON.
      doctor                    Print identity and isolation facts as JSON.
      help                      Show this help.

    The headless mode opens no window, sends no request and writes no store.
    """

    /// Returns nil for a normal launch, leaving startup untouched.
    static func runIfRequested(
        arguments: [String],
        stdout: (String) -> Void = { print($0) },
        stderr: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) -> Int32? {
        guard arguments.dropFirst().first == "--agent" else { return nil }
        let rest = Array(arguments.dropFirst(2))
        let command = rest.first ?? "help"

        switch command {
        case "parse-comments":
            return parseComments(Array(rest.dropFirst()), stdout: stdout, stderr: stderr)
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
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            stdout(String(decoding: try encoder.encode(output), as: UTF8.self))
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
            storeRoot: WeiboMonitorStore.defaultRoot().path,
            runningInstances: NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            stdout(String(decoding: try encoder.encode(report), as: UTF8.self))
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
        let runningInstances: Int
    }
}
