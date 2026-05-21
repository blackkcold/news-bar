import Foundation

enum RSSService {

    private static let userAgent = "NewsBar/1.0 (macOS; RSS Reader)"
    private static let timeout: TimeInterval = 8

    static func fetch(url rssURL: String, sourceName: String) async throws -> [NewsItem] {
        guard let url = URL(string: rssURL) else {
            throw NewsBarError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NewsBarError.requestFailed
        }

        return try parseRSSFeed(data: data, sourceName: sourceName, sourceURL: rssURL)
    }

    static func validate(_ urlString: String) async throws -> Bool {
        guard SecurityPolicies.validateRSSURL(urlString),
              let url = URL(string: urlString) else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return false
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        let validTypes = ["application/rss+xml", "application/atom+xml", "text/xml", "application/xml"]
        return validTypes.contains { contentType.contains($0) }
    }

    private static func parseRSSFeed(data: Data, sourceName: String, sourceURL: String) throws -> [NewsItem] {
        let parser = XMLParser(data: data)
        SecurityPolicies.configureXMLParser(parser)

        let delegate = RSSParserDelegate()
        parser.delegate = delegate

        guard parser.parse(), !delegate.items.isEmpty else {
            throw NewsBarError.parseFailed
        }

        return delegate.items.map { item in
            NewsItem(
                title: SecurityPolicies.sanitizeHTMLContent(item.title),
                url: item.link.isEmpty ? sourceURL : item.link,
                source: .rss(name: sourceName, url: sourceURL)
            )
        }
    }
}

final class RSSParserDelegate: NSObject, XMLParserDelegate {

    struct Item {
        var title: String = ""
        var link: String = ""
    }

    private(set) var items: [Item] = []
    private var currentElement = ""
    private var currentItem: Item?
    private var isInItem = false

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentElement = elementName

        if elementName == "item" || elementName == "entry" {
            isInItem = true
            currentItem = Item()
        }

        if elementName == "link", let href = attributes["href"] {
            currentItem?.link = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInItem else { return }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch currentElement {
        case "title":
            currentItem?.title += trimmed
        case "link":
            if currentItem?.link.isEmpty ?? true {
                currentItem?.link += trimmed
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if elementName == "item" || elementName == "entry", let item = currentItem {
            if !item.title.isEmpty {
                items.append(item)
            }
            isInItem = false
            currentItem = nil
        }
    }
}
