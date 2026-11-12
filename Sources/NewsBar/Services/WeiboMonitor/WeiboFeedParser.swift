import Foundation
import CoreFoundation

struct WeiboParsedPage: Sendable, Equatable {
    var posts: [WeiboPost]
    var screenName: String?
    var avatarURL: String?
    var sinceMid: String?
    var rawCount: Int
    var dateMissing: Bool
    /// Mids whose date could not be parsed. The rest of the page is still
    /// trustworthy and must not be suppressed with them.
    var missingDateMids: Set<String> = []

    static let empty = WeiboParsedPage(
        posts: [],
        screenName: nil,
        avatarURL: nil,
        sinceMid: nil,
        rawCount: 0,
        dateMissing: false
    )
}

enum WeiboFeedParserError: Error, Equatable {
    case invalidJSON
    case notOK
}

/// Defensive parser for the two JSON shapes Weibo has used. The field names
/// have changed before and will change again, so every read is optional and
/// every missing field has a documented fallback. The parser never trusts the
/// network shape to be stable.
enum WeiboFeedParser {
    static func parseT0(
        _ data: Data,
        uid: String,
        fallbackScreenName: String,
        fetchedAt: Date
    ) throws -> WeiboParsedPage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WeiboFeedParserError.invalidJSON
        }
        guard integer(root["ok"]) == 1 else {
            throw WeiboFeedParserError.notOK
        }

        guard let payload = root["data"] as? [String: Any],
              let list = payload["list"] as? [[String: Any]] else {
            throw WeiboFeedParserError.invalidJSON
        }
        var posts: [WeiboPost] = []
        var resolvedName = fallbackScreenName
        var resolvedAvatar: String?
        var dateMissing = false
        var missingDateMids = Set<String>()

        for item in list {
            guard let mid = firstString(item, keys: ["idstr", "mid"]) ?? numberString(item["id"]) else {
                continue
            }

            if let user = item["user"] as? [String: Any] {
                if let name = user["screen_name"] as? String, !name.isEmpty {
                    resolvedName = name
                }
                if let avatar = firstString(user, keys: ["profile_image_url", "avatar_large", "avatar_hd"]) {
                    resolvedAvatar = avatar
                }
            }

            let rawText = firstString(item, keys: ["text_raw", "text"]) ?? ""
            let cleaned = cleanText(rawText)
            let retweeted = item["retweeted_status"] as? [String: Any]
            let retweetText = retweeted.flatMap {
                firstString($0, keys: ["text_raw", "text"]).map(cleanText)
            }
            let isRetweet = retweeted != nil && cleaned.isEmpty
            let bid = item["bid"] as? String
            let isTop = boolValue(item["isTop"]) || boolValue(item["is_top"])
            let isLongText = boolValue(item["isLongText"]) || boolValue(item["is_long_text"])

            let createdAt: Date
            if let rawDate = firstString(item, keys: ["created_at"]),
               let parsed = parseDate(rawDate, fetchedAt: fetchedAt, now: fetchedAt) {
                createdAt = parsed
            } else {
                // Weibo's mid timestamp encoding is not part of its public API.
                // A wrong fallback would create false positives, so use the
                // fetch time and record the anomaly instead of guessing.
                createdAt = fetchedAt
                dateMissing = true
                missingDateMids.insert(mid)
            }

            let post = WeiboPost(
                mid: mid,
                bid: bid,
                uid: uid,
                screenName: resolvedName,
                text: cleaned,
                createdAt: createdAt,
                fetchedAt: fetchedAt,
                isLongText: isLongText,
                isRetweet: isRetweet,
                retweetText: retweetText,
                imageURLs: imageURLs(from: item),
                url: WeiboPost.makeURL(uid: uid, bid: bid, mid: mid),
                read: false,
                isTop: isTop,
                commentCount: count(item["comments_count"]),
                repostCount: count(item["reposts_count"]),
                likeCount: count(item["attitudes_count"])
            )
            posts.append(post)
        }

        return WeiboParsedPage(
            posts: posts,
            screenName: resolvedName,
            avatarURL: resolvedAvatar,
            sinceMid: posts.first?.mid,
            rawCount: list.count,
            dateMissing: dateMissing,
            missingDateMids: missingDateMids
        )
    }

    static func parseT1(
        _ data: Data,
        uid: String,
        fallbackScreenName: String,
        fetchedAt: Date,
        now: Date,
        calendar: Calendar = .current
    ) throws -> WeiboParsedPage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WeiboFeedParserError.invalidJSON
        }
        guard integer(root["ok"]) == 1 else {
            throw WeiboFeedParserError.notOK
        }

        guard let payload = root["data"] as? [String: Any],
              let cards = payload["cards"] as? [[String: Any]] else {
            throw WeiboFeedParserError.invalidJSON
        }
        let mblogs = collectMblogs(from: cards)
        var posts: [WeiboPost] = []
        var resolvedName = fallbackScreenName
        var resolvedAvatar: String?
        var dateMissing = false
        var missingDateMids = Set<String>()

        for item in mblogs {
            guard let mid = firstString(item, keys: ["idstr", "mid"]) ?? numberString(item["id"]) else {
                continue
            }

            if let user = item["user"] as? [String: Any] {
                if let name = user["screen_name"] as? String, !name.isEmpty {
                    resolvedName = name
                }
                if let avatar = firstString(user, keys: ["profile_image_url", "avatar_large", "avatar_hd"]) {
                    resolvedAvatar = avatar
                }
            }

            let rawText = firstString(item, keys: ["text_raw", "text"]) ?? ""
            let cleaned = cleanText(rawText)
            let retweeted = item["retweeted_status"] as? [String: Any]
            let retweetText = retweeted.flatMap {
                firstString($0, keys: ["text_raw", "text"]).map(cleanText)
            }
            let isRetweet = retweeted != nil && cleaned.isEmpty
            let bid = item["bid"] as? String
            let isLongText = boolValue(item["isLongText"]) || boolValue(item["is_long_text"])

            let createdAt: Date
            if let rawDate = firstString(item, keys: ["created_at"]),
               let parsed = parseShortDate(rawDate, now: now, calendar: calendar) {
                createdAt = parsed
            } else {
                createdAt = fetchedAt
                dateMissing = true
                missingDateMids.insert(mid)
            }

            posts.append(
                WeiboPost(
                    mid: mid,
                    bid: bid,
                    uid: uid,
                    screenName: resolvedName,
                    text: cleaned,
                    createdAt: createdAt,
                    fetchedAt: fetchedAt,
                    isLongText: isLongText,
                    isRetweet: isRetweet,
                    retweetText: retweetText,
                    imageURLs: imageURLs(from: item),
                    url: WeiboPost.makeURL(uid: uid, bid: bid, mid: mid),
                    commentCount: count(item["comments_count"]),
                    repostCount: count(item["reposts_count"]),
                    likeCount: count(item["attitudes_count"])
                )
            )
        }

        let since = firstString(payload, keys: ["since_id"])
            ?? (payload["cardlistInfo"] as? [String: Any]).flatMap { firstString($0, keys: ["since_id"]) }

        return WeiboParsedPage(
            posts: posts,
            screenName: resolvedName,
            avatarURL: resolvedAvatar,
            sinceMid: since ?? posts.first?.mid,
            rawCount: mblogs.count,
            dateMissing: dateMissing,
            missingDateMids: missingDateMids
        )
    }

    /// Long-form posts are fetched only when the feed post is marked long and
    /// the account is P0 or the post matched a keyword. The result is cached in
    /// the feed record and never fetched twice.
    static func parseLongText(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let payload = root["data"] as? [String: Any]
        let raw = (payload?["longTextContent"] as? String)
            ?? (payload?["long_text_content"] as? String)
            ?? (root["longTextContent"] as? String)
        guard let raw else { return nil }
        let cleaned = cleanText(raw)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func parseDate(_ raw: String, fetchedAt: Date, now: Date) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        if let date = formatter.date(from: trimmed) {
            return date
        }

        formatter.dateFormat = "EEE MMM dd HH:mm:ss z yyyy"
        if let date = formatter.date(from: trimmed) {
            return date
        }

        return parseShortDate(trimmed, now: now, calendar: .current)
    }

    static func parseShortDate(_ raw: String, now: Date, calendar: Calendar) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let patterns = ["MM-dd HH:mm", "MM-dd"]
        for pattern in patterns {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = pattern
            if let partial = formatter.date(from: trimmed) {
                var components = calendar.dateComponents([.month, .day, .hour, .minute], from: partial)
                let current = calendar.dateComponents([.year], from: now)
                components.year = current.year
                components.second = 0
                guard var date = calendar.date(from: components) else { continue }
                // A December post read in January belongs to the previous year.
                if date > now.addingTimeInterval(24 * 60 * 60) {
                    components.year = (current.year ?? 0) - 1
                    date = calendar.date(from: components) ?? date
                }
                return date
            }
        }

        if trimmed.contains("刚刚") {
            return now
        }
        if let minutes = relativeNumber(in: trimmed, suffix: "分钟前") {
            return now.addingTimeInterval(-Double(minutes) * 60)
        }
        if let hours = relativeNumber(in: trimmed, suffix: "小时前") {
            return now.addingTimeInterval(-Double(hours) * 3600)
        }
        if trimmed.contains("昨天") {
            return now.addingTimeInterval(-24 * 60 * 60)
        }

        return nil
    }

    /// Removes tags, decodes the entities Weibo actually emits, and collapses
    /// whitespace. It deliberately does not try to be an HTML renderer.
    static func cleanText(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(
            of: "<br\\s*/?>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "</p\\s*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        let entities: [String: String] = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&nbsp;": " ",
            "&hellip;": "…",
            "&mdash;": "—",
            "&ndash;": "–",
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = decodeNumericEntities(text)
        text = text.replacingOccurrences(of: "\u{200B}", with: "")
        text = text.replacingOccurrences(of: "\u{FEFF}", with: "")
        text = text.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func collectMblogs(from cards: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for card in cards {
            if let mblog = card["mblog"] as? [String: Any] {
                result.append(mblog)
            }
            if let group = card["card_group"] as? [[String: Any]] {
                result.append(contentsOf: collectMblogs(from: group))
            }
        }
        return result
    }

    private static func imageURLs(from item: [String: Any]) -> [String] {
        var urls: [String] = []
        if let pics = item["pics"] as? [[String: Any]] {
            for pic in pics {
                let nested = pic["large"] as? [String: Any]
                if let url = firstString(nested ?? [:], keys: ["url", "bmiddle", "thumbnail"]) {
                    appendImageURL(url, to: &urls)
                } else if let url = firstString(pic, keys: ["url", "bmiddle_pic", "thumbnail_pic"]) {
                    appendImageURL(url, to: &urls)
                }
            }
        }
        if urls.isEmpty, let ids = item["pic_ids"] as? [String] {
            for id in ids.prefix(9) {
                appendImageURL("https://wx1.sinaimg.cn/large/\(id).jpg", to: &urls)
            }
        }
        return Array(urls.prefix(9))
    }

    private static func appendImageURL(_ raw: String, to urls: inout [String]) {
        let normalized = raw.hasPrefix("//") ? "https:\(raw)" : raw
        guard normalized.hasPrefix("https://"),
              let host = URL(string: normalized)?.host?.lowercased(),
              host.hasSuffix("sinaimg.cn") || host.hasSuffix("sinaimg.com"),
              !urls.contains(normalized) else { return }
        urls.append(normalized)
    }

    private static func decodeNumericEntities(_ text: String) -> String {
        guard text.contains("&#") else { return text }
        let pattern = "&#(x?[0-9A-Fa-f]+);"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let matches = regex.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        )
        for match in matches.reversed() {
            guard match.numberOfRanges == 2,
                  let whole = Range(match.range(at: 0), in: result),
                  let body = Range(match.range(at: 1), in: result) else { continue }
            let token = String(result[body])
            let scalarValue: UInt32?
            if token.lowercased().hasPrefix("x") {
                scalarValue = UInt32(token.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(token, radix: 10)
            }
            if let scalarValue, let scalar = Unicode.Scalar(scalarValue) {
                result.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return result
    }

    private static func relativeNumber(in text: String, suffix: String) -> Int? {
        guard text.hasSuffix(suffix) else { return nil }
        let prefix = text.dropLast(suffix.count)
        return Int(prefix.trimmingCharacters(in: .whitespaces))
    }

    private static func firstString(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func numberString(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func count(_ value: Any?) -> Int? {
        let raw: String
        if let string = value as? String {
            raw = string
        } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            raw = number.stringValue
        } else {
            return nil
        }
        guard let result = Int(raw), result >= 0 else { return nil }
        return result
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            return value == "1" || value.lowercased() == "true"
        }
        return false
    }
}
