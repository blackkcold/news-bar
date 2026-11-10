import Darwin
import Foundation

/// Shared, dependency-free contract between NewsBar and `newsbarctl`.
///
/// The app and the CLI are separate processes. They never share memory and the
/// CLI never writes `UserDefaults` (the running app owns that state). Instead
/// the CLI drops a command file into `Agent/inbox` and the app writes a result
/// file into `Agent/outbox`. This module owns the file names, envelopes and
/// owner-only I/O both sides use.
public enum AgentProtocol {
    public static let version = 1
    public static let clientName = "newsbarctl/1.0"
    public static let maxCommandBytes = 2 * 1024 * 1024
    public static let maxResultBytes = 2 * 1024 * 1024
    public static let maxAuditBytes = 512 * 1024
}

// MARK: - Paths

public enum AgentPaths {
    public static let bundleIdentifier = "com.newsbar.app"

    /// `NEWSBAR_AGENT_ROOT` exists so development builds and tests never touch
    /// the real application-support queue.
    public static var root: URL {
        if let raw = ProcessInfo.processInfo.environment["NEWSBAR_AGENT_ROOT"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Agent", isDirectory: true)
    }

    public static var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    public static var outbox: URL { root.appendingPathComponent("outbox", isDirectory: true) }
    public static var processed: URL { root.appendingPathComponent("processed", isDirectory: true) }
    public static var quarantine: URL { root.appendingPathComponent("quarantine", isDirectory: true) }
    public static var auditLog: URL { root.appendingPathComponent("audit.log.jsonl") }

    public static func ensureDirectories() throws {
        for directory in [root, inbox, outbox, processed, quarantine] {
            try AgentFile.ensureDirectory(directory)
        }
    }

    public static func commandURL(id: String) -> URL {
        inbox.appendingPathComponent("\(id).json")
    }

    public static func resultURL(id: String) -> URL {
        outbox.appendingPathComponent("\(id).json")
    }
}

// MARK: - Envelope

public struct AgentCommand: Codable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var command: AgentCommandName
    public var issuedAt: String
    public var client: String
    public var payload: Payload

    public init(
        schemaVersion: Int = AgentProtocol.version,
        id: String = UUID().uuidString,
        command: AgentCommandName,
        issuedAt: String = AgentTimestamp.now(),
        client: String = AgentProtocol.clientName,
        payload: Payload = Payload()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.command = command
        self.issuedAt = issuedAt
        self.client = client
        self.payload = payload
    }

    public struct Payload: Codable, Sendable {
        public var url: String?
        public var urls: [String]?
        public var name: String?
        public var displayMode: String?
        public var select: Bool?
        public var format: String?
        public var content: String?
        public var dryRun: Bool?
        public var scope: String?
        public var refresh: Bool?
        public var query: String?

        public init(
            url: String? = nil,
            urls: [String]? = nil,
            name: String? = nil,
            displayMode: String? = nil,
            select: Bool? = nil,
            format: String? = nil,
            content: String? = nil,
            dryRun: Bool? = nil,
            scope: String? = nil,
            refresh: Bool? = nil,
            query: String? = nil
        ) {
            self.url = url
            self.urls = urls
            self.name = name
            self.displayMode = displayMode
            self.select = select
            self.format = format
            self.content = content
            self.dryRun = dryRun
            self.scope = scope
            self.refresh = refresh
            self.query = query
        }
    }
}

public enum AgentCommandName: String, Codable, Sendable, CaseIterable {
    case status
    case rssList = "rss.list"
    case rssAdd = "rss.add"
    case rssRemove = "rss.remove"
    case rssSelect = "rss.select"
    case rssDeselect = "rss.deselect"
    case rssImport = "rss.import"
    case rssExport = "rss.export"
    case refresh
}

public struct AgentResult: Codable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var ok: Bool
    public var command: String
    public var completedAt: String
    public var data: DataPayload?
    public var error: ErrorPayload?

    public init(
        schemaVersion: Int = AgentProtocol.version,
        id: String,
        ok: Bool,
        command: String,
        completedAt: String = AgentTimestamp.now(),
        data: DataPayload? = nil,
        error: ErrorPayload? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.ok = ok
        self.command = command
        self.completedAt = completedAt
        self.data = data
        self.error = error
    }

    public struct DataPayload: Codable, Sendable {
        public var sources: [AgentSource]?
        public var preview: [AgentSource]?
        public var added: Int?
        public var skipped: Int?
        public var removed: Int?
        public var selected: Int?
        public var content: String?
        public var running: Bool?
        public var appVersion: String?
        public var agentEnabled: Bool?

        public init(
            sources: [AgentSource]? = nil,
            preview: [AgentSource]? = nil,
            added: Int? = nil,
            skipped: Int? = nil,
            removed: Int? = nil,
            selected: Int? = nil,
            content: String? = nil,
            running: Bool? = nil,
            appVersion: String? = nil,
            agentEnabled: Bool? = nil
        ) {
            self.sources = sources
            self.preview = preview
            self.added = added
            self.skipped = skipped
            self.removed = removed
            self.selected = selected
            self.content = content
            self.running = running
            self.appVersion = appVersion
            self.agentEnabled = agentEnabled
        }
    }

    public struct ErrorPayload: Codable, Sendable {
        public var code: AgentErrorCode
        public var message: String

        public init(code: AgentErrorCode, message: String) {
            self.code = code
            self.message = message
        }
    }
}

public struct AgentSource: Codable, Sendable, Equatable {
    public var name: String
    public var url: String
    public var selected: Bool
    public var displayMode: String
    public var supportsImage: Bool

    public init(name: String, url: String, selected: Bool, displayMode: String, supportsImage: Bool) {
        self.name = name
        self.url = url
        self.selected = selected
        self.displayMode = displayMode
        self.supportsImage = supportsImage
    }
}

public enum AgentErrorCode: String, Codable, Sendable {
    case appUnavailable = "app_unavailable"
    case agentDisabled = "agent_disabled"
    case invalidCommand = "invalid_command"
    case schemaUnsupported = "schema_unsupported"
    case urlBlocked = "url_blocked"
    case duplicate
    case notFound = "not_found"
    case limitExceeded = "limit_exceeded"
    case parseFailed = "parse_failed"
    case ioError = "io_error"
    case timeout
    case internalError = "internal_error"
}

public enum AgentTimestamp {
    public static func now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

// MARK: - Owner-only file I/O

public enum AgentFileError: Error, Equatable {
    case notRegularFile
    case tooLarge
    case openFailed(Int32)
    case writeFailed(Int32)
    case renameFailed(Int32)
    case readFailed(Int32)
}

public enum AgentFile {
    private static let temporaryPrefix = ".newsbar-agent-tmp-"

    public static func ensureDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    /// Atomic write: a 0600 temp file in the destination directory is renamed
    /// into place, so a watcher never sees a half-written command.
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try ensureDirectory(directory)
        let temporaryURL = directory.appendingPathComponent(temporaryPrefix + UUID().uuidString)

        var descriptor: Int32 = -1
        do {
            descriptor = temporaryURL.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.open(
                    path,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o600)
                )
            }
            guard descriptor >= 0 else { throw AgentFileError.openFailed(errno) }
            try writeAll(data, to: descriptor)
            guard Darwin.close(descriptor) == 0 else { throw AgentFileError.writeFailed(errno) }
            descriptor = -1
            let result = temporaryURL.withUnsafeFileSystemRepresentation { sourcePath in
                url.withUnsafeFileSystemRepresentation { destinationPath in
                    guard let sourcePath, let destinationPath else { return Int32(-1) }
                    return Darwin.rename(sourcePath, destinationPath)
                }
            }
            guard result == 0 else { throw AgentFileError.renameFailed(errno) }
        } catch {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            _ = temporaryURL.withUnsafeFileSystemRepresentation { path in
                path.map { Darwin.unlink($0) }
            }
            throw error
        }
    }

    public static func read(_ url: URL, maxBytes: Int = AgentProtocol.maxCommandBytes) throws -> Data {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &info)
        }
        guard result == 0 else { throw AgentFileError.readFailed(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw AgentFileError.notRegularFile }
        guard info.st_size >= 0, info.st_size <= maxBytes else { throw AgentFileError.tooLarge }

        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw AgentFileError.readFailed(errno)
        }
    }

    /// Pending commands, oldest first. Hidden temp files are ignored.
    public static func pendingCommands(in directory: URL = AgentPaths.inbox) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func appendAuditLine(_ data: Data, to url: URL = AgentPaths.auditLog) {
        var existing = (try? read(url, maxBytes: AgentProtocol.maxAuditBytes)) ?? Data()
        if existing.count + data.count > AgentProtocol.maxAuditBytes {
            existing = Data()
        }
        var combined = existing
        combined.append(data)
        if !combined.isEmpty, combined.last != 0x0A { combined.append(0x0A) }
        try? write(combined, to: url)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AgentFileError.writeFailed(errno)
                }
                if written == 0 { throw AgentFileError.writeFailed(EIO) }
                offset += written
            }
        }
    }
}

// MARK: - Audit

public struct AgentAuditEntry: Codable, Sendable {
    public var at: String
    public var id: String
    public var command: String
    public var client: String
    public var ok: Bool
    public var detail: String?

    public init(
        at: String = AgentTimestamp.now(),
        id: String,
        command: String,
        client: String,
        ok: Bool,
        detail: String? = nil
    ) {
        self.at = at
        self.id = id
        self.command = command
        self.client = client
        self.ok = ok
        self.detail = detail
    }
}
