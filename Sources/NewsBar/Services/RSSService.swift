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
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
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
        // The caller has already run the byte-level sanitizers; running them
        // again here copied and rescanned the whole document per refresh.
        let parser = XMLParser(data: data)
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

        let feedURL = URL(string: sourceURL)
        return delegate.items.map { item in
            let rawLink = item.link.isEmpty ? sourceURL : item.link
            let absoluteLink = URL(string: rawLink, relativeTo: feedURL)?.absoluteURL
            let validatedLink = absoluteLink.flatMap { SecurityPolicies.validateURL($0.absoluteString)?.absoluteString }
                ?? rawLink
            // `url` stays the feed's byte-preserved identity. A resolved
            // absolute destination is exposed separately so old bookmarks and
            // feedback keep matching after feeds start using relative links.
            let readerURL: String? = validatedLink == rawLink ? nil : validatedLink
            let validatedImageURL: String? = {
                guard let rawImageURL = item.imageURL else { return nil }
                let absolute = URL(string: rawImageURL, relativeTo: feedURL)?.absoluteURL.absoluteString
                    ?? rawImageURL
                if case .valid = SecurityPolicies.validateRSSURL(absolute) {
                    return absolute
                }
                return nil
            }()
            return NewsItem(
                title: SecurityPolicies.sanitizeHTMLContent(item.title),
                // Keep the feed's original link bytes as identity. Rewriting a
                // relative link to an absolute one would change every bookmark,
                // hide rule and interest key for that item.
                url: rawLink,
                source: .rss(name: sourceName, url: sourceURL),
                imageURL: validatedImageURL,
                publishedAt: parsePublicationDate(item.publicationDate),
                readerURL: readerURL
            )
        }
    }

    static func parsePublicationDate(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
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
                    allowsNotModified: true,
                    restrictToPublicDestinations: true
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
        var imagePriority = 0
        var publicationDate: String = ""
        var descriptionText: String = ""
    }

    private(set) var items: [Item] = []
    private(set) var parseError: Error?
    private var currentItem: Item?
    private var isInItem = false
    /// Parallel element/text stacks preserve spaces across entity and nested
    /// element boundaries, so "A &amp; B" and "x <em>y</em> z" stay intact.
    private var elementStack: [String] = []
    private var textStack: [String] = []
    private var itemDepth = 0

    private static let descriptionElements: Set<String> = [
        "description", "summary", "content", "content:encoded", "encoded"
    ]

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        elementStack.append(elementName)
        textStack.append("")

        if elementName == "item" || elementName == "entry" {
            isInItem = true
            itemDepth += 1
            currentItem = Item()
        }
        guard isInItem else { return }

        switch elementName {
        case "link":
            guard let href = attributes["href"] else { break }
            let rel = (attributes["rel"] ?? "alternate").lowercased()
            if rel == "alternate" || rel.isEmpty {
                if currentItem?.link.isEmpty ?? true { currentItem?.link = href }
            } else if rel == "enclosure" {
                if let type = attributes["type"], type.lowercased().hasPrefix("image/") {
                    setImage(href, priority: 4)
                }
            }

        case "enclosure":
            if let url = attributes["url"] {
                let type = (attributes["type"] ?? "").lowercased()
                if type.isEmpty {
                    let ext = URL(string: url)?.pathExtension.lowercased() ?? ""
                    if ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic"].contains(ext) {
                        setImage(url, priority: 4)
                    }
                } else if type.hasPrefix("image/") {
                    setImage(url, priority: 4)
                }
            }

        case "media:thumbnail":
            if let url = attributes["url"] { setImage(url, priority: 1) }

        case "media:content":
            let type = (attributes["type"] ?? attributes["medium"] ?? "").lowercased()
            let medium = (attributes["medium"] ?? "").lowercased()
            if medium == "image" || type.hasPrefix("image/") || (type.isEmpty && medium.isEmpty) {
                if let url = attributes["url"] { setImage(url, priority: 2) }
            }

        case "itunes:image":
            if let href = attributes["href"] { setImage(href, priority: 3) }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !textStack.isEmpty else { return }
        textStack[textStack.count - 1] += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !textStack.isEmpty, let string = String(data: CDATABlock, encoding: .utf8) else { return }
        textStack[textStack.count - 1] += string
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
        self.parseError = error
        NSLog("[RSSParserDelegate] XML parse error at line \(parser.lineNumber), column \(parser.columnNumber): \(error.localizedDescription)")
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let raw = textStack.popLast() ?? ""
        if !elementStack.isEmpty { elementStack.removeLast() }
        // Preserve nested text for the parent element.
        if !textStack.isEmpty { textStack[textStack.count - 1] += raw }
        guard isInItem else { return }

        switch elementName {
        case "title":
            currentItem?.title += raw
        case "pubDate", "published", "updated", "dc:date":
            if currentItem?.publicationDate.isEmpty ?? true {
                currentItem?.publicationDate = raw
            }
        case "link":
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, currentItem?.link.isEmpty ?? true {
                currentItem?.link = trimmed
            }
        default:
            if Self.descriptionElements.contains(elementName) {
                currentItem?.descriptionText += raw
                if currentItem?.imageURL == nil,
                   let extracted = SecurityPolicies.extractFirstImageURL(from: raw) {
                    setImage(extracted, priority: 5)
                }
            }
        }

        if elementName == "item" || elementName == "entry" {
            if let item = currentItem,
               !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var finished = item
                finished.title = finished.title.trimmingCharacters(in: .whitespacesAndNewlines)
                items.append(finished)
            }
            isInItem = false
            itemDepth = max(0, itemDepth - 1)
            currentItem = nil
        }
    }

    private func setImage(_ url: String, priority: Int) {
        guard let current = currentItem else { return }
        if current.imageURL == nil || priority < current.imagePriority {
            currentItem?.imageURL = url
            currentItem?.imagePriority = priority
        }
    }
}
