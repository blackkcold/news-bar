import Foundation

struct OPMLSubscription: Identifiable, Hashable, Sendable {
    var id: String { url }
    let title: String
    let url: String
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
        let body = subscriptions.map { subscription in
            let title = xmlEscape(subscription.title)
            let url = xmlEscape(subscription.url)
            return "    <outline text=\"\(title)\" title=\"\(title)\" type=\"rss\" xmlUrl=\"\(url)\"/>"
        }.joined(separator: "\n")
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

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        if elementName.lowercased() == "opml" { sawOPML = true }
        guard elementName.lowercased() == "outline",
              let raw = attributes["xmlUrl"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return }
        let canonical = SecurityPolicies.canonicalRSSURL(raw)
        guard seen.insert(canonical).inserted else { return }
        let title = (attributes["title"] ?? attributes["text"] ?? canonical)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        subscriptions.append(OPMLSubscription(
            title: title.isEmpty ? canonical : title,
            url: canonical
        ))
    }
}
