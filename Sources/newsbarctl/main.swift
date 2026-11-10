import Foundation
import NewsBarAgentProtocol

// MARK: - Usage

private let usageText = """
newsbarctl — local agent bridge for NewsBar

USAGE
  newsbarctl status [--json]
  newsbarctl rss list [--all|--selected] [--json]
  newsbarctl rss add <url> [--name <name>] [--mode text|image]
                          [--no-select] [--refresh] [--json]
  newsbarctl rss remove <url> [--json]
  newsbarctl rss select <url>... [--json]
  newsbarctl rss deselect <url>... [--json]
  newsbarctl rss import <file|-> [--format auto|opml|json|txt|csv]
                          [--dry-run] [--no-select] [--refresh] [--json]
  newsbarctl rss export <file|-> [--format opml|json] [--all] [--json]
  newsbarctl refresh [--json]

OPTIONS
  --json            Print the full result envelope as one JSON object
  --timeout <sec>   How long to wait for the app (default 8)
  --no-wait         Write the command and print its id; do not wait
  --no-launch       Never try to launch NewsBar automatically
  --help            Show this help

EXIT CODES
  0 success   2 usage   3 app unavailable   4 rejected
"""

private enum CLIError: Error {
    case usage(String)
    case appUnavailable
    case rejected(String)
    case io(String)
}

// MARK: - Options

private struct Options {
    var positionals: [String] = []
    var json = false
    var timeout: TimeInterval = 8
    var wait = true
    var launch = true
    var name: String?
    var mode: String?
    var format: String?
    var select = true
    var refresh = false
    var dryRun = false
    var all = false
}

private func parseOptions(_ args: ArraySlice<String>) throws -> Options {
    var options = Options()
    var iterator = args.makeIterator()

    while let arg = iterator.next() {
        switch arg {
        case "--json":
            options.json = true
        case "--all":
            options.all = true
        case "--selected":
            options.all = false
        case "--no-select":
            options.select = false
        case "--refresh":
            options.refresh = true
        case "--dry-run":
            options.dryRun = true
        case "--no-wait":
            options.wait = false
        case "--no-launch":
            options.launch = false
        case "--name":
            guard let value = iterator.next() else { throw CLIError.usage("--name wants a value") }
            options.name = value
        case "--mode":
            guard let value = iterator.next() else { throw CLIError.usage("--mode wants a value") }
            let normalized = value.lowercased()
            guard normalized == "text" || normalized == "image" else {
                throw CLIError.usage("--mode must be text or image")
            }
            options.mode = normalized
        case "--format":
            guard let value = iterator.next() else { throw CLIError.usage("--format wants a value") }
            options.format = value.lowercased()
        case "--timeout":
            guard let value = iterator.next(), let seconds = Double(value), seconds > 0 else {
                throw CLIError.usage("--timeout wants a positive number of seconds")
            }
            options.timeout = seconds
        case "--help", "-h":
            print(usageText)
            exit(0)
        default:
            if arg.hasPrefix("-") {
                throw CLIError.usage("Unknown option: \(arg)")
            }
            options.positionals.append(arg)
        }
    }
    return options
}

// MARK: - Queue

private func send(_ command: AgentCommand, options: Options) throws -> AgentResult {
    do {
        try AgentPaths.ensureDirectories()
        let data = try JSONEncoder().encode(command)
        guard data.count <= AgentProtocol.maxCommandBytes else {
            throw CLIError.io("Command is too large")
        }
        try AgentFile.write(data, to: AgentPaths.commandURL(id: command.id))
    } catch let error as AgentFileError {
        throw CLIError.io("Cannot write the command queue: \(error)")
    } catch {
        throw CLIError.io("Cannot write the command queue")
    }

    guard options.wait else {
        print(command.id)
        exit(0)
    }

    // A running app answers in well under a second. Only launch when it does
    // not, so read-only calls never summon the UI unnecessarily.
    if let result = waitForResult(id: command.id, timeout: 0.9) {
        return result
    }
    if options.launch {
        launchApp()
    }
    if let result = waitForResult(id: command.id, timeout: max(1, options.timeout - 0.9)) {
        return result
    }
    throw CLIError.appUnavailable
}

private func waitForResult(id: String, timeout: TimeInterval) -> AgentResult? {
    let deadline = Date().addingTimeInterval(timeout)
    let url = AgentPaths.resultURL(id: id)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path),
           let data = try? AgentFile.read(url, maxBytes: AgentProtocol.maxResultBytes),
           let result = try? JSONDecoder().decode(AgentResult.self, from: data) {
            return result
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return nil
}

private func launchApp() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    if let path = ProcessInfo.processInfo.environment["NEWSBAR_APP_PATH"], !path.isEmpty {
        process.arguments = ["-g", "-a", path]
    } else {
        process.arguments = ["-g", "-b", AgentPaths.bundleIdentifier]
    }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

// MARK: - Output

private func printResult(_ result: AgentResult, json: Bool) -> Int32 {
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(result), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        return result.ok ? 0 : 4
    }

    guard result.ok else {
        let code = result.error?.code.rawValue ?? "error"
        let message = result.error?.message ?? "Unknown error"
        FileHandle.standardError.write(Data("error: \(code): \(message)\n".utf8))
        return 4
    }

    let data = result.data
    switch result.command {
    case AgentCommandName.status.rawValue:
        let version = data?.appVersion ?? "?"
        let sources = data?.selected ?? 0
        let enabled = (data?.agentEnabled ?? false) ? "on" : "off"
        print("NewsBar \(version) · running · \(sources) selected · agent \(enabled)")
    case AgentCommandName.rssList.rawValue:
        let sources = data?.sources ?? []
        if sources.isEmpty {
            print("No RSS sources.")
        } else {
            for source in sources {
                let mark = source.selected ? "*" : " "
                print("\(mark) \(source.name)\t\(source.url)")
            }
        }
    case AgentCommandName.rssAdd.rawValue:
        let added = data?.added ?? 0
        let skipped = data?.skipped ?? 0
        print("Added \(added), skipped \(skipped).")
    case AgentCommandName.rssRemove.rawValue:
        print("Removed \(data?.removed ?? 0).")
    case AgentCommandName.rssSelect.rawValue, AgentCommandName.rssDeselect.rawValue:
        print("Selected \(data?.selected ?? 0) sources.")
    case AgentCommandName.rssImport.rawValue:
        let preview = data?.preview ?? []
        if !preview.isEmpty {
            for source in preview {
                print("+ \(source.name)\t\(source.url)")
            }
        }
        print("Added \(data?.added ?? 0), skipped \(data?.skipped ?? 0).")
    case AgentCommandName.refresh.rawValue:
        print("Refresh requested.")
    default:
        if let content = data?.content {
            print(content)
        } else {
            print("ok")
        }
    }
    return 0
}

// MARK: - Commands

private func makeCommand(
    _ name: AgentCommandName,
    payload: AgentCommand.Payload = .init()
) -> AgentCommand {
    AgentCommand(command: name, payload: payload)
}

private func runStatus(_ options: Options) throws -> Int32 {
    let result = try send(makeCommand(.status), options: options)
    return printResult(result, json: options.json)
}

private func runList(_ options: Options) throws -> Int32 {
    let result = try send(
        makeCommand(.rssList, payload: .init(scope: options.all ? "all" : "selected")),
        options: options
    )
    return printResult(result, json: options.json)
}

private func runAdd(_ options: Options) throws -> Int32 {
    guard let url = options.positionals.first, !url.isEmpty else {
        throw CLIError.usage("rss add needs a URL")
    }
    let result = try send(
        makeCommand(.rssAdd, payload: .init(
            url: url,
            name: options.name,
            displayMode: options.mode,
            select: options.select,
            refresh: options.refresh
        )),
        options: options
    )
    return printResult(result, json: options.json)
}

private func runRemove(_ options: Options) throws -> Int32 {
    guard let url = options.positionals.first, !url.isEmpty else {
        throw CLIError.usage("rss remove needs a URL")
    }
    let result = try send(
        makeCommand(.rssRemove, payload: .init(url: url)),
        options: options
    )
    return printResult(result, json: options.json)
}

private func runSelection(_ options: Options, select: Bool) throws -> Int32 {
    guard !options.positionals.isEmpty else {
        throw CLIError.usage(select ? "rss select needs at least one URL" : "rss deselect needs at least one URL")
    }
    let result = try send(
        makeCommand(
            select ? .rssSelect : .rssDeselect,
            payload: .init(urls: options.positionals)
        ),
        options: options
    )
    return printResult(result, json: options.json)
}

private func runImport(_ options: Options) throws -> Int32 {
    guard let path = options.positionals.first else {
        throw CLIError.usage("rss import needs a file path or - for stdin")
    }

    let data: Data
    if path == "-" {
        data = FileHandle.standardInput.readDataToEndOfFile()
    } else {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let size = attributes[.size] as? Int64 ?? 0
            guard size <= Int64(AgentProtocol.maxCommandBytes) else {
                throw CLIError.io("File is too large")
            }
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw CLIError.io("Cannot read \(path)")
        }
    }
    guard !data.isEmpty else {
        throw CLIError.io("Import content is empty")
    }
    guard let content = String(data: data, encoding: .utf8) else {
        throw CLIError.io("Import content is not UTF-8 text")
    }

    let format: String?
    if let requested = options.format, requested != "auto" {
        guard ["opml", "json", "txt", "text", "csv"].contains(requested) else {
            throw CLIError.usage("--format must be auto, opml, json, txt or csv")
        }
        format = requested
    } else {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "opml": format = "opml"
        case "json": format = "json"
        case "csv": format = "csv"
        case "txt", "text": format = "txt"
        default: format = nil
        }
    }

    let result = try send(
        makeCommand(.rssImport, payload: .init(
            select: options.select,
            format: format,
            content: content,
            dryRun: options.dryRun,
            refresh: options.refresh
        )),
        options: options
    )
    return printResult(result, json: options.json)
}

private func runExport(_ options: Options) throws -> Int32 {
    guard let destination = options.positionals.first else {
        throw CLIError.usage("rss export needs a file path or - for stdout")
    }
    let format = options.format ?? "opml"
    guard format == "opml" || format == "json" else {
        throw CLIError.usage("--format must be opml or json")
    }

    let result = try send(
        makeCommand(.rssExport, payload: .init(
            format: format,
            scope: options.all ? "all" : "selected"
        )),
        options: options
    )

    if options.json {
        return printResult(result, json: true)
    }
    guard result.ok, let content = result.data?.content else {
        return printResult(result, json: false)
    }

    if destination == "-" {
        print(content, terminator: "")
        return 0
    }

    do {
        try Data(content.utf8).write(to: URL(fileURLWithPath: destination), options: .atomic)
    } catch {
        throw CLIError.io("Cannot write \(destination)")
    }
    print("Wrote \(destination)")
    return 0
}

private func runGoogleNews(_ options: Options) throws -> Int32 {
    guard !options.positionals.isEmpty else {
        throw CLIError.usage("rss google-news needs at least one keyword")
    }

    var sources: [[String: String]] = []
    for raw in options.positionals {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { continue }
        let url: String
        if query.lowercased().hasPrefix("http") {
            url = query
        } else if let built = googleNewsURL(query: query) {
            url = built
        } else {
            continue
        }
        sources.append([
            "name": String("Google News · \(query)".prefix(80)),
            "url": url,
        ])
    }
    guard !sources.isEmpty else {
        throw CLIError.usage("No usable keyword or URL")
    }

    let payload: [String: Any] = ["schemaVersion": 1, "sources": sources]
    guard let json = try? JSONSerialization.data(withJSONObject: payload),
          let content = String(data: json, encoding: .utf8) else {
        throw CLIError.io("Cannot build the import payload")
    }

    let result = try send(
        makeCommand(.rssImport, payload: .init(
            select: options.select,
            format: "json",
            content: content,
            refresh: options.refresh
        )),
        options: options
    )
    return printResult(result, json: options.json)
}

private func googleNewsURL(query: String) -> String? {
    var components = URLComponents(string: "https://news.google.com/rss/search")
    components?.queryItems = [
        URLQueryItem(name: "q", value: query),
        URLQueryItem(name: "hl", value: "zh-CN"),
        URLQueryItem(name: "gl", value: "CN"),
        URLQueryItem(name: "ceid", value: "CN:zh-Hans"),
    ]
    return components?.url?.absoluteString
}

private func runRefresh(_ options: Options) throws -> Int32 {
    let result = try send(makeCommand(.refresh), options: options)
    return printResult(result, json: options.json)
}

// MARK: - Entry point

private func main() -> Int32 {
    var args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else {
        print(usageText)
        return 2
    }

    let command = args.removeFirst()
    if command == "--help" || command == "-h" || command == "help" {
        print(usageText)
        return 0
    }
    if command == "--version" {
        print(AgentProtocol.clientName)
        return 0
    }

    do {
        switch command {
        case "status":
            return try runStatus(parseOptions(args[...]))
        case "refresh":
            return try runRefresh(parseOptions(args[...]))
        case "rss":
            guard !args.isEmpty else { throw CLIError.usage("rss needs a subcommand") }
            let subcommand = args.removeFirst()
            let options = try parseOptions(args[...])
            switch subcommand {
            case "list":
                return try runList(options)
            case "add":
                return try runAdd(options)
            case "remove":
                return try runRemove(options)
            case "select":
                return try runSelection(options, select: true)
            case "deselect":
                return try runSelection(options, select: false)
            case "import":
                return try runImport(options)
            case "export":
                return try runExport(options)
            case "google-news":
                return try runGoogleNews(options)
            default:
                throw CLIError.usage("Unknown rss subcommand: \(subcommand)")
            }
        default:
            throw CLIError.usage("Unknown command: \(command)")
        }
    } catch let CLIError.usage(message) {
        FileHandle.standardError.write(Data("error: \(message)\n\n\(usageText)\n".utf8))
        return 2
    } catch CLIError.appUnavailable {
        FileHandle.standardError.write(Data("error: NewsBar is not running and could not be launched\n".utf8))
        return 3
    } catch let CLIError.io(message) {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        return 3
    } catch let CLIError.rejected(message) {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        return 4
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return 3
    }
}

exit(main())
