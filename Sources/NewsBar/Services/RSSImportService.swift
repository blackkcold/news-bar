import Foundation

enum RSSImportFormat: String, CaseIterable, Sendable {
    case opml
    case json
    case text
    case csv

    var displayName: String {
        switch self {
        case .opml: return "OPML"
        case .json: return "JSON"
        case .text: return "TXT"
        case .csv: return "CSV"
        }
    }
}

struct RSSImportCandidate: Identifiable, Hashable, Sendable {
    var id: String { url }
    let name: String
    let url: String
    var displayMode: RSSSourceConfig.DisplayMode = .text
    var group: String? = nil
}

struct RSSImportRejection: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case invalidURL
        case blocked(reason: String)
        case duplicate
        case overLimit
    }

    var id: String { "\(kind)-\(url)" }
    let name: String
    let url: String
    let kind: Kind
}

struct RSSImportPlan: Sendable {
    var accepted: [RSSImportCandidate] = []
    var rejections: [RSSImportRejection] = []

    var duplicateCount: Int {
        rejections.filter { $0.kind == .duplicate }.count
    }

    var blockedCount: Int {
        rejections.filter {
            if case .blocked = $0.kind { return true }
            return false
        }.count
    }

    var invalidCount: Int {
        rejections.filter {
            switch $0.kind {
            case .invalidURL, .overLimit: return true
            default: return false
            }
        }.count
    }

    var total: Int { accepted.count + rejections.count }
}

enum RSSImportError: Error, Equatable {
    case empty
    case invalidJSON
    case unreadable
}

/// Offline parsers for every batch-import format NewsBar accepts. The service
/// never touches the network and never mutates settings; it produces a plan
/// that the caller previews and applies.
enum RSSImportService {
    static let maxBytes = OPMLService.maxBytes
    static let maxFeeds = OPMLService.maxEntries

    // MARK: - Parsing

    static func parse(data: Data, format: RSSImportFormat) throws -> [RSSImportCandidate] {
        guard data.count <= maxBytes else { throw OPMLError.tooLarge }
        switch format {
        case .opml:
            return try OPMLService.parse(data).map {
                RSSImportCandidate(name: $0.title, url: $0.url, group: $0.group)
            }
        case .json:
            return try parseJSON(data)
        case .text:
            return try parseText(data)
        case .csv:
            return try parseCSV(data)
        }
    }

    static func detectFormat(for url: URL, data: Data? = nil) -> RSSImportFormat {
        switch url.pathExtension.lowercased() {
        case "opml": return .opml
        case "json": return .json
        case "csv": return .csv
        case "txt", "text": return .text
        default:
            if let data, String(decoding: data.prefix(256), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("{") {
                return .json
            }
            return .opml
        }
    }

    private static func parseJSON(_ data: Data) throws -> [RSSImportCandidate] {
        let object = try? JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]
        if let array = object as? [[String: Any]] {
            rows = array
        } else if let dictionary = object as? [String: Any],
                  let sources = dictionary["sources"] as? [[String: Any]] {
            rows = sources
        } else {
            throw RSSImportError.invalidJSON
        }

        return rows.compactMap { row in
            let url = firstString(in: row, keys: ["url", "xmlUrl", "feed", "link"])?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !url.isEmpty else { return nil }
            let name = firstString(in: row, keys: ["name", "title"])?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rawMode = firstString(in: row, keys: ["displayMode", "mode"])?.lowercased()
            let mode = RSSSourceConfig.DisplayMode(rawValue: rawMode ?? "") ?? .text
            return RSSImportCandidate(
                name: name.isEmpty ? defaultName(for: url) : name,
                url: url,
                displayMode: mode
            )
        }
    }

    private static func parseText(_ data: Data) throws -> [RSSImportCandidate] {
        guard let text = String(data: data, encoding: .utf8) else { throw RSSImportError.unreadable }
        var candidates: [RSSImportCandidate] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let name: String
            let url: String
            if parts.count == 2 {
                name = String(parts[0]).trimmingCharacters(in: .whitespaces)
                url = String(parts[1]).trimmingCharacters(in: .whitespaces)
            } else {
                name = ""
                url = line
            }
            guard !url.isEmpty else { continue }
            candidates.append(RSSImportCandidate(
                name: name.isEmpty ? defaultName(for: url) : name,
                url: url
            ))
        }
        guard !candidates.isEmpty else { throw RSSImportError.empty }
        return candidates
    }

    private static func parseCSV(_ data: Data) throws -> [RSSImportCandidate] {
        guard let text = String(data: data, encoding: .utf8) else { throw RSSImportError.unreadable }
        let rows = parseCSVRows(text)
        guard !rows.isEmpty else { throw RSSImportError.empty }

        let header = rows[0].map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let hasHeader = header.contains { ["url", "xmlurl", "feed", "link"].contains($0) }
        let urlIndex = header.firstIndex { ["url", "xmlurl", "feed", "link"].contains($0) }
        let nameIndex = header.firstIndex { ["name", "title"].contains($0) }
        let modeIndex = header.firstIndex { ["displaymode", "mode"].contains($0) }

        var candidates: [RSSImportCandidate] = []
        for row in rows.dropFirst(hasHeader ? 1 : 0) {
            guard !row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            let url: String
            let name: String
            let mode: RSSSourceConfig.DisplayMode
            if hasHeader {
                url = urlIndex.flatMap { $0 < row.count ? row[$0] : nil } ?? ""
                name = nameIndex.flatMap { $0 < row.count ? row[$0] : nil } ?? ""
                let rawMode = modeIndex.flatMap { $0 < row.count ? row[$0] : nil } ?? ""
                mode = RSSSourceConfig.DisplayMode(rawValue: rawMode.lowercased()) ?? .text
            } else if row.count >= 2, !row[0].lowercased().hasPrefix("http") {
                name = row[0]
                url = row[1]
                mode = .text
            } else {
                name = ""
                url = row.first ?? ""
                mode = .text
            }
            let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedURL.isEmpty else { continue }
            candidates.append(RSSImportCandidate(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? defaultName(for: trimmedURL)
                    : name.trimmingCharacters(in: .whitespacesAndNewlines),
                url: trimmedURL,
                displayMode: mode
            ))
        }
        guard !candidates.isEmpty else { throw RSSImportError.empty }
        return candidates
    }

    // MARK: - Plan

    static func plan(
        candidates: [RSSImportCandidate],
        existing: [RSSSourceConfig]
    ) -> RSSImportPlan {
        var plan = RSSImportPlan()
        var seen = Set(existing.map { SecurityPolicies.canonicalRSSURL($0.url) })
        var acceptedCount = 0

        for candidate in candidates {
            let canonical = SecurityPolicies.canonicalRSSURL(candidate.url)

            // Distinguish "not a URL at all" from "a URL the security policy
            // refuses". The import sheet shows a different reason for each.
            guard let components = URLComponents(string: canonical),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = components.host,
                  !host.isEmpty else {
                plan.rejections.append(.init(name: candidate.name, url: candidate.url, kind: .invalidURL))
                continue
            }

            if seen.contains(canonical) {
                plan.rejections.append(.init(name: candidate.name, url: candidate.url, kind: .duplicate))
                continue
            }
            if acceptedCount >= maxFeeds {
                plan.rejections.append(.init(name: candidate.name, url: candidate.url, kind: .overLimit))
                continue
            }
            switch SecurityPolicies.validateRSSURL(canonical) {
            case .blocked(let reason):
                plan.rejections.append(.init(name: candidate.name, url: candidate.url, kind: .blocked(reason: reason)))
            case .warning, .valid:
                let sanitized = SecurityPolicies.sanitizeUserInput(candidate.name)
                let name = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
                plan.accepted.append(RSSImportCandidate(
                    name: name.isEmpty ? defaultName(for: canonical) : String(name.prefix(80)),
                    url: canonical,
                    displayMode: candidate.displayMode,
                    group: candidate.group
                ))
                seen.insert(canonical)
                acceptedCount += 1
            }
        }
        return plan
    }

    // MARK: - Google News

    /// Google News has no OPML export. Its topic and search feeds are the two
    /// stable entry points; the caller can paste several queries at once.
    static func googleNewsSearchURL(query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents(string: "https://news.google.com/rss/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "hl", value: "zh-CN"),
            URLQueryItem(name: "gl", value: "CN"),
            URLQueryItem(name: "ceid", value: "CN:zh-Hans"),
        ]
        return components?.url?.absoluteString
    }

    static func googleNewsTopicURL() -> String {
        "https://news.google.com/rss?hl=zh-CN&gl=CN&ceid=CN:zh-Hans"
    }

    static func googleNewsCandidates(queries: [String]) -> [RSSImportCandidate] {
        queries.compactMap { raw in
            let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, let url = googleNewsSearchURL(query: query) else { return nil }
            return RSSImportCandidate(
                name: String("Google News · \(query)".prefix(80)),
                url: url,
                displayMode: .text,
                group: "Google News"
            )
        }
    }

    // MARK: - Export

    static func exportJSON(sources: [RSSSourceConfig], exportedAt: Date = Date()) -> Data {
        let formatter = ISO8601DateFormatter()
        let payload = JSONExport(
            schemaVersion: 1,
            exportedAt: formatter.string(from: exportedAt),
            sources: sources.map {
                JSONExport.Source(
                    name: $0.name,
                    url: $0.url,
                    displayMode: $0.displayMode.rawValue,
                    supportsImage: $0.supportsImage
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(payload)) ?? Data()
    }

    private struct JSONExport: Encodable {
        struct Source: Encodable {
            let name: String
            let url: String
            let displayMode: String
            let supportsImage: Bool
        }

        let schemaVersion: Int
        let exportedAt: String
        let sources: [Source]
    }

    // MARK: - Helpers

    private static func firstString(in row: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = row[key] as? String { return value }
        }
        return nil
    }

    private static func defaultName(for url: String) -> String {
        URL(string: url)?.host ?? url
    }

    /// A small RFC 4180 reader: quoted fields, escaped quotes, CRLF and LF.
    private static func parseCSVRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if inQuotes {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                case "\n":
                    row.append(field)
                    rows.append(row)
                    row = []
                    field = ""
                case "\r":
                    break
                default:
                    field.append(character)
                }
            }
            index = text.index(after: index)
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
