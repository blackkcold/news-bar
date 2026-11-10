import Foundation
import NewsBarAgentProtocol

/// Local, file-based bridge between `newsbarctl` and the running app.
///
/// Commands are ordinary JSON files written 0600 and renamed into place, so the
/// watcher never sees a partial write. Every mutation is applied to the
/// in-memory `AppSettings` on the main thread, preserving the app's existing
/// persistence and refresh behaviour. The CLI never writes UserDefaults.
final class AgentCommandService {
    private let settings: AppSettings
    private let refreshAction: () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var inboxDescriptor: Int32 = -1
    private var isProcessing = false
    private var pendingScan: DispatchWorkItem?
    private var recentCommandTimes: [Date] = []

    init(settings: AppSettings, refreshAction: @escaping () -> Void) {
        self.settings = settings
        self.refreshAction = refreshAction
    }

    // MARK: - Lifecycle

    func start() {
        do {
            try AgentPaths.ensureDirectories()
        } catch {
            return
        }
        pruneArchives()
        startWatching()
        processPending()
    }

    func stop() {
        pendingScan?.cancel()
        pendingScan = nil
        source?.cancel()
        source = nil
        // The cancel handler owns the descriptor; closing it here as well would
        // risk closing an unrelated descriptor that reused the number.
        inboxDescriptor = -1
    }

    private func startWatching() {
        let descriptor = open(AgentPaths.inbox.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        inboxDescriptor = descriptor

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.pendingScan?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.processPending() }
            self.pendingScan = work
            // Coalesce the write/rename burst that one command produces.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    // MARK: - Queue

    private func processPending() {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        for url in AgentFile.pendingCommands().prefix(50) {
            processCommand(at: url)
        }
    }

    private func processCommand(at url: URL) {
        let fileID = url.deletingPathExtension().lastPathComponent
        do {
            let data = try AgentFile.read(url)
            let command = try JSONDecoder().decode(AgentCommand.self, from: data)
            let result = handle(command)
            persist(result, id: command.id)
            archive(url, id: command.id)
            audit(command, result)
        } catch {
            let result = AgentResult(
                id: fileID,
                ok: false,
                command: "unknown",
                error: .init(code: .invalidCommand, message: Self.describe(error))
            )
            persist(result, id: fileID)
            archive(url, id: fileID)
        }
    }

    // MARK: - Dispatch

    private func handle(_ command: AgentCommand) -> AgentResult {
        guard command.schemaVersion == AgentProtocol.version else {
            return failure(command, .schemaUnsupported, "Unsupported schema version \(command.schemaVersion)")
        }
        guard settings.agentAccessEnabled else {
            return failure(command, .agentDisabled, "Agent interface is disabled in Settings")
        }
        guard allowRate() else {
            return failure(command, .limitExceeded, "Too many commands; try again in a minute")
        }

        switch command.command {
        case .status:
            return statusResult(command)
        case .rssList:
            return listResult(command)
        case .rssAdd:
            return addResult(command)
        case .rssRemove:
            return removeResult(command)
        case .rssSelect, .rssDeselect:
            return selectionResult(command)
        case .rssImport:
            return importResult(command)
        case .rssExport:
            return exportResult(command)
        case .refresh:
            return refreshResult(command)
        }
    }

    private func statusResult(_ command: AgentCommand) -> AgentResult {
        success(
            command,
            data: .init(
                selected: settings.selectedRSSSourceIDs.count,
                running: true,
                appVersion: appVersion,
                agentEnabled: settings.agentAccessEnabled
            )
        )
    }

    private func listResult(_ command: AgentCommand) -> AgentResult {
        let includeAll = command.payload.scope != "selected"
        let sources = settings.rssSources.filter {
            includeAll || settings.selectedRSSSourceIDs.contains($0.id)
        }
        return success(command, data: .init(sources: sources.map(sourcePayload)))
    }

    private func addResult(_ command: AgentCommand) -> AgentResult {
        guard let rawURL = command.payload.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty else {
            return failure(command, .invalidCommand, "Missing url")
        }

        let canonical = SecurityPolicies.canonicalRSSURL(rawURL)
        switch SecurityPolicies.validateRSSURL(canonical) {
        case .blocked(let reason):
            return failure(command, .urlBlocked, reason)
        case .warning, .valid:
            break
        }

        guard !settings.rssSources.contains(where: { $0.id == canonical }) else {
            return success(command, data: .init(added: 0, skipped: 1))
        }

        let sanitized = SecurityPolicies.sanitizeUserInput(command.payload.name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = sanitized.isEmpty
            ? (URL(string: canonical)?.host ?? canonical)
            : String(sanitized.prefix(80))
        let mode = RSSSourceConfig.DisplayMode(rawValue: (command.payload.displayMode ?? "").lowercased()) ?? .text
        let source = RSSSourceConfig(name: name, url: canonical, displayMode: mode)
        let added = settings.addRSSSources([source], select: command.payload.select ?? true)

        if let first = added.first {
            NotificationCenter.default.post(
                name: .rssSourceAdded,
                object: nil,
                userInfo: ["url": first.url, "name": first.name]
            )
            if command.payload.refresh == true { refreshAction() }
        }

        return success(command, data: .init(added: added.count, skipped: added.isEmpty ? 1 : 0))
    }

    private func removeResult(_ command: AgentCommand) -> AgentResult {
        guard let rawURL = command.payload.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty else {
            return failure(command, .invalidCommand, "Missing url")
        }
        let canonical = SecurityPolicies.canonicalRSSURL(rawURL)
        guard let index = settings.rssSources.firstIndex(where: { $0.id == canonical }) else {
            return failure(command, .notFound, "No source with that URL")
        }
        settings.rssSources.remove(at: index)
        settings.selectedRSSSourceIDs.remove(canonical)
        return success(command, data: .init(removed: 1))
    }

    private func selectionResult(_ command: AgentCommand) -> AgentResult {
        let rawURLs = (command.payload.urls ?? []) + (command.payload.url.map { [$0] } ?? [])
        let known = Set(settings.rssSources.map(\.id))
        let ids = rawURLs
            .map(SecurityPolicies.canonicalRSSURL)
            .filter { known.contains($0) }

        if command.command == .rssSelect {
            settings.selectedRSSSourceIDs.formUnion(ids)
        } else {
            settings.selectedRSSSourceIDs.subtract(ids)
        }
        return success(command, data: .init(selected: settings.selectedRSSSourceIDs.count))
    }

    private func importResult(_ command: AgentCommand) -> AgentResult {
        guard let content = command.payload.content,
              let data = content.data(using: .utf8) else {
            return failure(command, .invalidCommand, "Missing content")
        }
        guard data.count <= RSSImportService.maxBytes else {
            return failure(command, .limitExceeded, "Import content is too large")
        }

        let format = importFormat(command.payload.format, data: data)
        do {
            let candidates = try RSSImportService.parse(data: data, format: format)
            let plan = RSSImportService.plan(candidates: candidates, existing: settings.rssSources)

            if command.payload.dryRun == true {
                return success(
                    command,
                    data: .init(
                        preview: plan.accepted.map {
                            AgentSource(
                                name: $0.name,
                                url: $0.url,
                                selected: true,
                                displayMode: $0.displayMode.rawValue,
                                supportsImage: true
                            )
                        },
                        added: 0,
                        skipped: plan.rejections.count
                    )
                )
            }

            let sources = plan.accepted.map {
                RSSSourceConfig(name: $0.name, url: $0.url, displayMode: $0.displayMode)
            }
            let added = settings.addRSSSources(sources, select: command.payload.select ?? true)
            for source in added.prefix(20) {
                NotificationCenter.default.post(
                    name: .rssSourceAdded,
                    object: nil,
                    userInfo: ["url": source.url, "name": source.name]
                )
            }
            if command.payload.refresh ?? false { refreshAction() }
            return success(
                command,
                data: .init(added: added.count, skipped: plan.rejections.count)
            )
        } catch {
            return failure(command, .parseFailed, "Unable to parse the import content")
        }
    }

    private func exportResult(_ command: AgentCommand) -> AgentResult {
        let scope = command.payload.scope ?? "selected"
        let sources = scope == "all"
            ? settings.rssSources
            : settings.rssSources.filter { settings.selectedRSSSourceIDs.contains($0.id) }

        let format = (command.payload.format ?? "opml").lowercased()
        let content: String
        if format == "json" {
            content = String(data: RSSImportService.exportJSON(sources: sources), encoding: .utf8) ?? ""
        } else {
            let subscriptions = sources.map { OPMLSubscription(title: $0.name, url: $0.url) }
            content = String(data: OPMLService.export(subscriptions), encoding: .utf8) ?? ""
        }
        return success(command, data: .init(selected: settings.selectedRSSSourceIDs.count, content: content))
    }

    private func refreshResult(_ command: AgentCommand) -> AgentResult {
        refreshAction()
        return success(command, data: .init(running: true))
    }

    // MARK: - Results

    private func success(_ command: AgentCommand, data: AgentResult.DataPayload? = nil) -> AgentResult {
        AgentResult(id: command.id, ok: true, command: command.command.rawValue, data: data)
    }

    private func failure(_ command: AgentCommand, _ code: AgentErrorCode, _ message: String) -> AgentResult {
        AgentResult(
            id: command.id,
            ok: false,
            command: command.command.rawValue,
            error: .init(code: code, message: message)
        )
    }

    private func persist(_ result: AgentResult, id: String) {
        guard let data = try? JSONEncoder().encode(result) else { return }
        try? AgentFile.write(data, to: AgentPaths.resultURL(id: id))
    }

    private func archive(_ url: URL, id: String) {
        let destination = AgentPaths.processed.appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Processed commands are useful for a short audit window, not forever.
    private func pruneArchives(olderThan days: Int = 7) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for directory in [AgentPaths.processed, AgentPaths.quarantine] {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in urls {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if modified < cutoff {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    private func audit(_ command: AgentCommand, _ result: AgentResult) {
        let entry = AgentAuditEntry(
            id: command.id,
            command: command.command.rawValue,
            client: command.client,
            ok: result.ok,
            detail: result.error?.message
        )
        guard let data = try? JSONEncoder().encode(entry) else { return }
        AgentFile.appendAuditLine(data)
    }

    // MARK: - Helpers

    private func sourcePayload(_ source: RSSSourceConfig) -> AgentSource {
        AgentSource(
            name: source.name,
            url: source.url,
            selected: settings.selectedRSSSourceIDs.contains(source.id),
            displayMode: source.displayMode.rawValue,
            supportsImage: source.supportsImage
        )
    }

    private func allowRate() -> Bool {
        let now = Date()
        recentCommandTimes.removeAll { now.timeIntervalSince($0) > 60 }
        guard recentCommandTimes.count < 60 else { return false }
        recentCommandTimes.append(now)
        return true
    }

    private func importFormat(_ raw: String?, data: Data) -> RSSImportFormat {
        switch raw?.lowercased() {
        case "opml": return .opml
        case "json": return .json
        case "csv": return .csv
        case "txt", "text": return .text
        default:
            let prefix = String(decoding: data.prefix(128), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix.hasPrefix("{") || prefix.hasPrefix("[") { return .json }
            if prefix.hasPrefix("<?xml") || prefix.hasPrefix("<opml") { return .opml }
            if prefix.contains(",") && !prefix.contains("://") { return .csv }
            return .text
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private static func describe(_ error: Error) -> String {
        if error is AgentFileError { return "Unable to read the command file" }
        if error is DecodingError { return "Invalid command JSON" }
        return "Unable to read the command"
    }
}
