import Foundation

enum WeiboHotService {

    // Tier 1: Weibo web JSON API
    private static let hotSearchAPI = "https://weibo.com/ajax/side/hotSearch"

    // Tier 2: HTML page fallback
    private static let summaryURL = "https://s.weibo.com/top/summary"

    static func fetch() async throws -> [NewsItem] {
        // Tier 1: Try the web JSON API first
        if let items = try? await fetchFromAjaxAPI() {
            return items
        }

        // Tier 2: Fall back to HTML page parsing
        if let items = try? await fetchFromSummaryPage() {
            return items
        }

        throw NewsBarError.requestFailed
    }

    // MARK: - Tier 1: weibo.com/ajax/side/hotSearch

    private static func fetchFromAjaxAPI() async throws -> [NewsItem] {
        guard let url = URL(string: hotSearchAPI) else {
            throw NewsBarError.invalidURL
        }

        let (data, _) = try await HTTPClient.data(for: url, config: .weibo)

        return try parseAjaxResponse(data: data)
    }

    private static func parseAjaxResponse(data: Data) throws -> [NewsItem] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataBlock = json["data"] as? [String: Any],
              let realtime = dataBlock["realtime"] as? [[String: Any]] else {
            throw NewsBarError.parseFailed
        }

        var items: [NewsItem] = []

        for entry in realtime {
            guard let word = entry["word"] as? String, !word.isEmpty else { continue }

            let title = SecurityPolicies.sanitizeUserInput(word)

            // word_scheme is a topic identifier (e.g. "#topic#" or "plain text"), NOT a URL.
            // Construct a proper search URL with Refer=top to point to hot search landing.
            let encodedQuery = word.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? word
            let url = "https://s.weibo.com/weibo?q=\(encodedQuery)&Refer=top"

            items.append(NewsItem(
                title: title,
                url: url,
                source: .weibo,
                rank: nil
            ))
        }

        guard !items.isEmpty else {
            throw NewsBarError.parseFailed
        }

        return Array(items.prefix(5)).enumerated().map { index, item in
            NewsItem(
                title: item.title,
                url: item.url,
                source: .weibo,
                rank: index + 1
            )
        }
    }

    // MARK: - Tier 2: s.weibo.com/top/summary (HTML parsing fallback)

    private static func fetchFromSummaryPage() async throws -> [NewsItem] {
        guard let url = URL(string: summaryURL) else {
            throw NewsBarError.invalidURL
        }

        let (data, _) = try await HTTPClient.data(for: url, config: .weibo)

        guard let html = String(data: data, encoding: .utf8) else {
            throw NewsBarError.parseFailed
        }

        return try parseSummaryHTML(html)
    }

    private static func parseSummaryHTML(_ html: String) throws -> [NewsItem] {
        // Match: <a href="/weibo?q=..." ...>title</a>
        let pattern = #"<a\s+href="(/weibo\?q=[^"]+)"[^>]*>([^<]+)</a>"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            throw NewsBarError.parseFailed
        }

        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, options: [], range: range)

        var items: [NewsItem] = []

        for match in matches {
            guard match.numberOfRanges >= 3,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else {
                continue
            }

            let href = String(html[hrefRange])
            let title = SecurityPolicies.sanitizeUserInput(String(html[titleRange]))

            guard !title.isEmpty, !title.contains("热搜榜"), !title.contains("微博") else { continue }

            let url = "https://s.weibo.com\(href)"

            items.append(NewsItem(
                title: title,
                url: url,
                source: .weibo,
                rank: nil
            ))

            if items.count >= 5 { break }
        }

        guard !items.isEmpty else {
            throw NewsBarError.parseFailed
        }

        return items.enumerated().map { index, item in
            NewsItem(
                title: item.title,
                url: item.url,
                source: .weibo,
                rank: index + 1
            )
        }
    }
}
