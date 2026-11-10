import Foundation

struct OPMLSubscription: Identifiable, Hashable, Sendable {
    var id: String { url }
    let title: String
    let url: String
    /// Folder path from the source OPML, joined with " / ". Export nests the
    /// feed again under the same path; NewsBar itself does not use folders.
    var group: String? = nil
}

enum OPMLError: Error, Equatable {
    case unreadable
    case tooLarge
    case tooManyEntries
    case notOPML
}

/// Minimal, offline OPML import/export. Import never contacts the network and
/// never applies subscriptions by itself; the caller previews the result first.
enum OPMLService {
    static let maxBytes = 1_048_576
    static let maxEntries = 500

    static func parse(_ data: Data) throws -> [OPMLSubscription] {
        guard data.count <= maxBytes else { throw OPMLError.tooLarge }
        let parser = XMLParser(data: SecuredXML.data(data))
        SecurityPolicies.configureXMLParser(parser)
        let delegate = OPMLParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else { throw OPMLError.notOPML }
        guard delegate.sawOPML else { throw OPMLError.notOPML }
        guard delegate.subscriptions.count <= maxEntries else { throw OPMLError.tooManyEntries }
        return delegate.subscriptions
    }

    static func export(_ subscriptions: [OPMLSubscription]) -> Data {
        let grouped = Dictionary(grouping: subscriptions) { $0.group }
        let groups = grouped.keys.compactMap { $0 }.sorted()
        var lines: [String] = []

        // Ungrouped feeds first, then one nested outline per folder. The order
        // inside a folder follows the caller's order.
        if let ungrouped = grouped[nil] {
            lines.append(contentsOf: ungrouped.map { outline(for: $0, indent: 4) })
        }
        for group in groups {
            guard let feeds = grouped[group] else { continue }
            lines.append("    <outline text=\"\(xmlEscape(group))\" title=\"\(xmlEscape(group))\">")
            lines.append(contentsOf: feeds.map { outline(for: $0, indent: 6) })
            lines.append("    </outline>")
        }

        let body = lines.joined(separator: "\n")
        let text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head><title>NewsBar subscriptions</title></head>
          <body>
        \(body)
          </body>
        </opml>
        """
        return Data(text.utf8)
    }

    private static func outline(for subscription: OPMLSubscription, indent: Int) -> String {
        let padding = String(repeating: " ", count: indent)
        let title = xmlEscape(subscription.title)
        let url = xmlEscape(subscription.url)
        return "\(padding)<outline text=\"\(title)\" title=\"\(title)\" type=\"rss\" xmlUrl=\"\(url)\"/>"
    }

    private static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private enum SecuredXML {
    static func data(_ data: Data) -> Data {
        SecurityPolicies.sanitizeXMLEntities(SecurityPolicies.sanitizeXMLData(data))
    }
}

private final class OPMLParserDelegate: NSObject, XMLParserDelegate {
    private(set) var subscriptions: [OPMLSubscription] = []
    private(set) var sawOPML = false
    private var seen = Set<String>()

    /// Folder labels currently open, outermost first.
    private var folderStack: [String] = []
    /// One entry per open <outline> that identifies whether it contributed a
    /// folder label, so the matching end tag pops the right stack.
    private var outlineScopes: [Bool] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        let name = elementName.lowercased()
        if name == "opml" { sawOPML = true }
        guard name == "outline" else { return }

        if let raw = attributes["xmlUrl"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            outlineScopes.append(false)
            let canonical = SecurityPolicies.canonicalRSSURL(raw)
            guard isHTTPURL(canonical), seen.insert(canonical).inserted else { return }
            let title = (attributes["title"] ?? attributes["text"] ?? canonical)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            subscriptions.append(OPMLSubscription(
                title: title.isEmpty ? canonical : title,
                url: canonical,
                group: folderStack.isEmpty ? nil : folderStack.joined(separator: " / ")
            ))
            return
        }

        // An outline without xmlUrl is a folder label.
        let label = (attributes["title"] ?? attributes["text"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty {
            outlineScopes.append(false)
        } else {
            folderStack.append(label)
            outlineScopes.append(true)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        guard elementName.lowercased() == "outline", let contributedFolder = outlineScopes.popLast() else { return }
        if contributedFolder, !folderStack.isEmpty {
            folderStack.removeLast()
        }
    }

    private func isHTTPURL(_ value: String) -> Bool {
        guard let scheme = URLComponents(string: value)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
