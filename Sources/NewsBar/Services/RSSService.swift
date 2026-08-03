import Foundation

enum RSSFetchResult: Sendable {
    case modified(items: [NewsItem], eTag: String?, lastModified: String?)
    case notModified(eTag: String?, lastModified: String?)
}

enum RSSService {

    static func fetch(url rssURL: String, sourceName: String) async throws -> [NewsItem] {
        let result = try await fetchConditional(url: rssURL, sourceName: sourceName)
        switch result {
        case .modified(let items, _, _):
            return items
        case .notModified:
            throw NewsBarError.requestFailed
        }
    }

    static func fetchConditional(
        url rssURL: String,
        sourceName: String,
        eTag: String? = nil,
        lastModified: String? = nil
    ) async throws -> RSSFetchResult {
        guard let url = URL(string: rssURL) else {
            throw NewsBarError.invalidURL
        }

        let headers = conditionalHeaders(eTag: eTag, lastModified: lastModified)

        let (data, response) = try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            group.addTask {
                try await HTTPClient.data(
                    for: url,
                    config: .rss,
                    additionalHeaders: headers,
                    allowsNotModified: true
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw URLError(.timedOut)
            }
            guard let result = try await group.next() else {
                throw URLError(.timedOut)
            }
            group.cancelAll()
            return result
        }

        let responseETag = response.value(forHTTPHeaderField: "ETag") ?? eTag
        let responseLastModified = response.value(forHTTPHeaderField: "Last-Modified") ?? lastModified
        if response.statusCode == 304 {
            return .notModified(eTag: responseETag, lastModified: responseLastModified)
        }

        return .modified(
            items: try parseRSSFeed(data: data, sourceName: sourceName, sourceURL: rssURL),
            eTag: responseETag,
            lastModified: responseLastModified
        )
    }

    static func validate(_ urlString: String) async throws -> Bool {
        if case .blocked = SecurityPolicies.validateRSSURL(urlString) {
            return false
        }
        guard let url = URL(string: urlString) else {
            return false
        }

        let (data, _) = try await HTTPClient.data(for: url, config: .rss)

        return isRSSOrAtom(data: data)
    }

    static func conditionalHeaders(eTag: String?, lastModified: String?) -> [String: String] {
        var headers: [String: String] = [:]
        if let eTag, !eTag.isEmpty {
            headers["If-None-Match"] = eTag
        }
        if let lastModified, !lastModified.isEmpty {
            headers["If-Modified-Since"] = lastModified
        }
        return headers
    }

    private static func isRSSOrAtom(data: Data) -> Bool {
        let parser = XMLParser(data: data)
        SecurityPolicies.configureXMLParser(parser)
        let delegate = RSSRootDetector()
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.isRSSOrAtom
    }

    private static func parseRSSFeed(data: Data, sourceName: String, sourceURL: String) throws -> [NewsItem] {
        let cleanData = SecurityPolicies.sanitizeXMLData(data)
        let parser = XMLParser(data: cleanData)
        SecurityPolicies.configureXMLParser(parser)

        let delegate = RSSParserDelegate()
        parser.delegate = delegate

        guard parser.parse(), !delegate.items.isEmpty else {
            if let parseError = delegate.parseError {
                throw NewsBarError.parseFailedWithDetail(parseError.localizedDescription)
            }
            throw NewsBarError.parseFailed
        }

        return delegate.items.map { item in
            let rawLink = item.link.isEmpty ? sourceURL : item.link
            let validatedLink = SecurityPolicies.validateURL(rawLink)?.absoluteString ?? rawLink
            let validatedImageURL: String? = {
                guard let rawImageURL = item.imageURL else { return nil }
                if case .valid = SecurityPolicies.validateRSSURL(rawImageURL) {
                    return rawImageURL
                }
                return nil
            }()
            return NewsItem(
                title: SecurityPolicies.sanitizeHTMLContent(item.title),
                url: validatedLink,
                source: .rss(name: sourceName, url: sourceURL),
                imageURL: validatedImageURL
            )
        }
    }
}

private final class RSSRootDetector: NSObject, XMLParserDelegate {
    var isRSSOrAtom = false

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if elementName == "rss" || elementName == "feed" || elementName == "rdf:RDF" {
            isRSSOrAtom = true
        }
        parser.abortParsing()
    }
}

final class RSSParserDelegate: NSObject, XMLParserDelegate {

    struct Item {
        var title: String = ""
        var link: String = ""
        var imageURL: String? = nil
    }

    private(set) var items: [Item] = []
    private(set) var parseError: Error?
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

        if elementName == "enclosure" {
            if let url = attributes["url"],
               let type = attributes["type"],
               type.hasPrefix("image/") {
                currentItem?.imageURL = url
            }
        }

        let mediaNS = "http://search.yahoo.com/mrss/"
        if namespaceURI == mediaNS,
           (elementName == "content" || elementName == "thumbnail") {
            if let url = attributes["url"], currentItem?.imageURL == nil {
                currentItem?.imageURL = url
            }
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

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard isInItem else { return }
        guard let string = String(data: CDATABlock, encoding: .utf8) else { return }
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
            if currentItem?.imageURL == nil {
                if let extractedURL = SecurityPolicies.extractFirstImageURL(from: trimmed) {
                    currentItem?.imageURL = extractedURL
                }
            }
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
        self.parseError = error
        NSLog("[RSSParserDelegate] XML parse error at line \(parser.lineNumber), column \(parser.columnNumber): \(error.localizedDescription)")
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
