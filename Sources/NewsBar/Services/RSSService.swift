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
        lastModified: String? = nil,
        allowEmpty: Bool = false
    ) async throws -> RSSFetchResult {
        let canonicalURLString = SecurityPolicies.canonicalRSSURL(rssURL)
        guard let url = URL(string: canonicalURLString) else {
            throw NewsBarError.invalidURL
        }

        let headers = conditionalHeaders(eTag: eTag, lastModified: lastModified)

        let firstResponse = try await fetchResponse(
            for: url,
            additionalHeaders: headers
        )
        let responsePayload: (data: Data, response: HTTPURLResponse)

        if firstResponse.response.statusCode == 304 {
            responsePayload = firstResponse
        } else if SecurityPolicies.isLikelyHTMLResponse(firstResponse.data) {
            let retryHeaders = headers.merging(HTTPClient.Config.rssBrowserHeaders) { _, browserValue in
                browserValue
            }
            do {
                let retryResponse = try await fetchResponse(
                    for: url,
                    additionalHeaders: retryHeaders
                )
                if SecurityPolicies.isLikelyHTMLResponse(retryResponse.data) {
                    throw nonRSSResponseError(data: retryResponse.data, response: retryResponse.response)
                }
                responsePayload = retryResponse
            } catch let error as NewsBarError {
                throw error
            } catch {
                throw nonRSSResponseError(data: firstResponse.data, response: firstResponse.response)
            }
        } else {
            responsePayload = firstResponse
        }

        let data = responsePayload.data
        let response = responsePayload.response

        let responseETag = response.value(forHTTPHeaderField: "ETag") ?? eTag
        let responseLastModified = response.value(forHTTPHeaderField: "Last-Modified") ?? lastModified
        if response.statusCode == 304 {
            return .notModified(eTag: responseETag, lastModified: responseLastModified)
        }

        return .modified(
            items: try parseRSSFeed(
                data: data,
                sourceName: sourceName,
                sourceURL: canonicalURLString,
                allowEmpty: allowEmpty
            ),
            eTag: responseETag,
            lastModified: responseLastModified
        )
    }

    static func validate(_ urlString: String) async throws -> Bool {
        if case .blocked = SecurityPolicies.validateRSSURL(urlString) {
            return false
        }

        let result = try await fetchConditional(
            url: urlString,
            sourceName: "RSS",
            allowEmpty: true
        )
        if case .modified = result {
            return true
        }
        return false
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
        let cleanData = SecurityPolicies.sanitizeXMLEntities(data)
        let parser = XMLParser(data: cleanData)
        SecurityPolicies.configureXMLParser(parser)
        let delegate = RSSRootDetector()
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.isRSSOrAtom
    }

    static func parseRSSFeed(
        data: Data,
        sourceName: String,
        sourceURL: String,
        allowEmpty: Bool = false
    ) throws -> [NewsItem] {
        let cleanData = SecurityPolicies.sanitizeXMLEntities(SecurityPolicies.sanitizeXMLData(data))

        // Some feeds are protected by an anti-bot/WAF page that answers with HTML (Content-Type:
        // text/html) instead of RSS/Atom XML. Parsing that HTML as XML surfaces a confusing
        // NSXMLParserErrorDomain error 68 ("xmlParseEntityRef: no name"). Detect the root element
        // first and reject non-RSS/Atom responses with a readable message.
        guard isRSSOrAtom(data: cleanData) else {
            throw NewsBarError.parseFailedWithDetail("error.rssNotXml".localized)
        }

        let parser = XMLParser(data: cleanData)
        SecurityPolicies.configureXMLParser(parser)

        let delegate = RSSParserDelegate()
        parser.delegate = delegate

        guard parser.parse() else {
            if let parseError = delegate.parseError {
                throw NewsBarError.parseFailedWithDetail(parseError.localizedDescription)
            }
            throw NewsBarError.parseFailed
        }

        guard allowEmpty || !delegate.items.isEmpty else {
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

    private static func fetchResponse(
        for url: URL,
        additionalHeaders: [String: String]
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            group.addTask {
                try await HTTPClient.data(
                    for: url,
                    config: .rss,
                    additionalHeaders: additionalHeaders,
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
    }

    private static func nonRSSResponseError(
        data: Data,
        response: HTTPURLResponse
    ) -> NewsBarError {
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
        let responseKind = SecurityPolicies.isLikelyHTMLResponse(data) ? "HTML" : "non-RSS/XML"
        let detail = "error.rssNotXml".localized + " " + L10n.string(
            "error.rssResponseDetail",
            response.statusCode,
            contentType,
            responseKind,
            data.count
        )
        return .parseFailedWithDetail(detail)
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
