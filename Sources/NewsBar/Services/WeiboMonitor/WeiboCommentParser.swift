import Foundation

/// Tolerant parser for Weibo's comment payloads. The desktop and mobile
/// endpoints have different envelopes, and both have changed field names
/// before. Every field falls back explicitly; a malformed entry is skipped
/// instead of failing the whole page.
enum WeiboCommentParser {
    static func parse(
        _ data: Data,
        mid: String,
        authorUID: String? = nil,
        tier: WeiboCommentTier,
        fetchedAt: Date,
        calendar: Calendar = .current
    ) throws -> WeiboCommentPage {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw WeiboCommentParserError.invalidJSON
        }

        var items: [[String: Any]] = []
        var total: Int?
        var nextCursor: String?

        if let array = root as? [[String: Any]] {
            // The normalized shape used by the free mobile/MCP path.
            items = array
        } else if let dict = root as? [String: Any] {
            if let ok = dict["ok"], !isOK(ok) {
                throw WeiboCommentParserError.notOK
            }
            total = count(dict["total_number"] ?? dict["totalNumber"] ?? dict["total"])
            nextCursor = cursor(from: dict)

            if let array = dict["data"] as? [[String: Any]] {
                items = array
            } else if let payload = dict["data"] as? [String: Any] {
                if let array = payload["comments"] as? [[String: Any]] {
                    items = array
                } else if let array = payload["data"] as? [[String: Any]] {
                    items = array
                } else {
                    throw WeiboCommentParserError.shapeChanged
                }
            } else if let array = dict["comments"] as? [[String: Any]] {
                items = array
            } else {
                throw WeiboCommentParserError.shapeChanged
            }
        } else {
            throw WeiboCommentParserError.shapeChanged
        }

        var seen = Set<String>()
        var comments: [WeiboComment] = []
        for item in items {
            guard let id = identifier(item["idstr"] ?? item["id"] ?? item["mid"]) else { continue }
            guard let user = item["user"] as? [String: Any] else { continue }
            let uid = identifier(user["id"]) ?? ""
            let rawName = (user["screen_name"] as? String) ?? ""
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uid.isEmpty || !name.isEmpty else { continue }
            guard seen.insert(id).inserted else { continue }

            let rawText = (item["text_raw"] as? String) ?? (item["text"] as? String) ?? ""
            let avatar = (user["profile_image_url"] as? String)
                ?? (user["avatar_large"] as? String)
                ?? (user["avatar_hd"] as? String)
            let replyName = ((item["reply_comment"] as? [String: Any])?["user"] as? [String: Any])?["screen_name"] as? String

            comments.append(
                WeiboComment(
                    id: id,
                    mid: mid,
                    uid: uid,
                    screenName: name.isEmpty ? "微博用户" : name,
                    avatarURL: avatar,
                    text: cleanText(rawText),
                    createdAt: date(item["created_at"] as? String, now: fetchedAt, calendar: calendar) ?? fetchedAt,
                    likeCount: count(item["like_counts"] ?? item["like_count"]),
                    replyToName: replyName?.trimmingCharacters(in: .whitespacesAndNewlines),
                    isAuthor: authorUID.map { !uid.isEmpty && uid == $0 } ?? false
                )
            )
        }

        return WeiboCommentPage(
            comments: comments,
            total: total,
            nextCursor: nextCursor,
            fetchedAt: fetchedAt,
            tier: tier
        )
    }

    // MARK: - Envelope helpers

    private static func isOK(_ value: Any) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.intValue == 1
        }
        if let string = value as? String { return string == "1" || string.lowercased() == "true" }
        return false
    }

    private static func cursor(from dict: [String: Any]) -> String? {
        if boolTrue(dict["is_end"]) || boolTrue(dict["isEnd"]) { return nil }
        let raw = dict["max_id"] ?? dict["max_id_str"] ?? dict["next_cursor"]
        guard let value = identifier(raw), !value.isEmpty, value != "0", value != "0.0" else {
            return nil
        }
        return value
    }

    private static func boolTrue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.intValue == 1
        }
        if let string = value as? String { return string == "1" || string.lowercased() == "true" }
        return false
    }

    private static func identifier(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.stringValue
        }
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

    // MARK: - Text

    static func cleanText(_ raw: String) -> String {
        var text = raw
        // Emoji arrive as <img alt="[吃瓜]">. Keep the alt text before tags go.
        text = replacingImagesWithAltText(text)
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
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

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
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacingImagesWithAltText(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "<img[^>]*alt=[\"']([^\"']*)[\"'][^>]*>",
            options: [.caseInsensitive]
        ) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: result),
                  let altRange = Range(match.range(at: 1), in: text) else { continue }
            result.replaceSubrange(whole, with: String(text[altRange]))
        }
        return result
    }

    private static func decodeNumericEntities(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: "&#([0-9]{1,7});") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let whole = Range(match.range, in: result),
                      let digits = Range(match.range(at: 1), in: result),
                      let scalar = UInt32(result[digits]),
                      let unicode = UnicodeScalar(scalar) else { continue }
                result.replaceSubrange(whole, with: String(unicode))
            }
        }
        if let regex = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]{1,7});") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let whole = Range(match.range, in: result),
                      let digits = Range(match.range(at: 1), in: result),
                      let scalar = UInt32(result[digits], radix: 16),
                      let unicode = UnicodeScalar(scalar) else { continue }
                result.replaceSubrange(whole, with: String(unicode))
            }
        }
        return result
    }

    // MARK: - Dates

    private static func date(_ raw: String?, now: Date, calendar: Calendar) -> Date? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.contains("T") {
            let iso = ISO8601DateFormatter()
            if let parsed = iso.date(from: value) { return parsed }
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = iso.date(from: value) { return parsed }
        }

        let patterns = [
            "EEE MMM dd HH:mm:ss Z yyyy",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "MM-dd HH:mm",
            "MM-dd",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        for pattern in patterns {
            formatter.dateFormat = pattern
            guard let parsed = formatter.date(from: value) else { continue }
            if pattern.hasPrefix("MM-dd") {
                var components = calendar.dateComponents([.month, .day, .hour, .minute], from: parsed)
                components.year = calendar.component(.year, from: now)
                components.second = 0
                guard var adjusted = calendar.date(from: components) else { return parsed }
                if adjusted > now.addingTimeInterval(24 * 60 * 60) {
                    components.year = (components.year ?? 0) - 1
                    adjusted = calendar.date(from: components) ?? adjusted
                }
                return adjusted
            }
            return parsed
        }

        if value.contains("刚刚") { return now }
        if let minutes = relativeNumber(value, suffix: "分钟前") {
            return now.addingTimeInterval(-Double(minutes) * 60)
        }
        if let hours = relativeNumber(value, suffix: "小时前") {
            return now.addingTimeInterval(-Double(hours) * 3600)
        }
        if value.contains("昨天") || value.contains("今天") {
            let base = value.contains("昨天")
                ? calendar.date(byAdding: .day, value: -1, to: now) ?? now
                : now
            if let time = timeComponents(value) {
                return calendar.date(
                    bySettingHour: time.hour,
                    minute: time.minute,
                    second: 0,
                    of: base
                )
            }
            return base
        }
        return nil
    }

    private static func relativeNumber(_ value: String, suffix: String) -> Int? {
        guard let range = value.range(of: suffix) else { return nil }
        let prefix = value[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        guard let number = Int(prefix) else { return nil }
        return number
    }

    private static func timeComponents(_ value: String) -> (hour: Int, minute: Int)? {
        guard let regex = try? NSRegularExpression(pattern: "([0-9]{1,2}):([0-9]{2})") else { return nil }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              let hourRange = Range(match.range(at: 1), in: value),
              let minuteRange = Range(match.range(at: 2), in: value),
              let hour = Int(value[hourRange]),
              let minute = Int(value[minuteRange]) else { return nil }
        return (hour, minute)
    }
}
