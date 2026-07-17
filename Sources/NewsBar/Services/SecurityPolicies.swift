import Foundation

enum SecurityPolicies {

    static let forbiddenTags: Set<String> = ["script", "iframe", "img", "style", "object", "embed", "link", "meta", "noscript", "svg"]

    static let allowedScheme = "https"

    static func sanitizeHTMLContent(_ html: String) -> String {
        guard !html.isEmpty else { return "" }

        var result = html

        for tag in forbiddenTags {
            let openPattern = "<\(tag)[^>]*>"
            let closePattern = "</\(tag)>"

            if let openRegex = try? NSRegularExpression(pattern: openPattern, options: .caseInsensitive) {
                result = openRegex.stringByReplacingMatches(
                    in: result, range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
            }
            if let closeRegex = try? NSRegularExpression(pattern: closePattern, options: .caseInsensitive) {
                result = closeRegex.stringByReplacingMatches(
                    in: result, range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
            }
        }

        // Defense-in-depth: strip on* event attributes explicitly
        let eventAttrPattern = "\\s+on\\w+\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]*)"
        if let eventRegex = try? NSRegularExpression(pattern: eventAttrPattern, options: .caseInsensitive) {
            result = eventRegex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        let tagPattern = "<[^>]+>"
        if let tagRegex = try? NSRegularExpression(pattern: tagPattern, options: []) {
            result = tagRegex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")

        let whitespacePattern = "\\s+"
        if let wsRegex = try? NSRegularExpression(pattern: whitespacePattern, options: []) {
            result = wsRegex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: " "
            )
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validateURL(_ urlString: String) -> URL? {
        guard let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              scheme == allowedScheme,
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        return components.url
    }

    enum RSSURLValidation {
        case valid
        case blocked(reason: String)
        case warning(reason: String)
    }

    static func validateRSSURL(_ urlString: String) -> RSSURLValidation {
        guard let url = validateURL(urlString),
              let host = url.host else {
            return .blocked(reason: "Invalid URL or scheme")
        }

        let blockedDomains: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1"]
        let lowerHost = host.lowercased()
        if blockedDomains.contains(lowerHost) {
            return .blocked(reason: "Blocked host: \(host)")
        }

        if isPrivateIP(host) {
            return .warning(reason: "Private IP range: \(host)")
        }

        return .valid
    }

    private static func isPrivateIP(_ host: String) -> Bool {
        // IPv4 private ranges
        let ipv4Patterns: [(String, String)] = [
            (// 10.0.0.0/8
                "^10\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$",
                "10.0.0.0/8"
            ),
            (// 172.16.0.0/12
                "^172\\.(1[6-9]|2[0-9]|3[01])\\.\\d{1,3}\\.\\d{1,3}$",
                "172.16.0.0/12"
            ),
            (// 192.168.0.0/16
                "^192\\.168\\.\\d{1,3}\\.\\d{1,3}$",
                "192.168.0.0/16"
            ),
            (// 169.254.0.0/16 (link-local)
                "^169\\.254\\.\\d{1,3}\\.\\d{1,3}$",
                "169.254.0.0/16"
            ),
        ]

        for (pattern, _) in ipv4Patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: host, options: [], range: NSRange(host.startIndex..., in: host)) != nil {
                return true
            }
        }

        // IPv6 private/link-local ranges
        let ipv6Patterns: [(String, String)] = [
            (// fc00::/7
                "^(fc|fd)[0-9a-fA-F]{0,2}:",
                "fc00::/7"
            ),
            (// fe80::/10
                "^fe[89abAB][0-9a-fA-F]{0,1}:",
                "fe80::/10"
            ),
        ]

        for (pattern, _) in ipv6Patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: host, options: [], range: NSRange(host.startIndex..., in: host)) != nil {
                return true
            }
        }

        return false
    }

    static func configureXMLParser(_ parser: XMLParser) {
        parser.shouldResolveExternalEntities = false
        if #available(macOS 15.0, *) {
            parser.externalEntityResolvingPolicy = .never
        }
    }

    static func sanitizeUserInput(_ input: String) -> String {
        let controlCharacters = CharacterSet.controlCharacters
            .union(CharacterSet.illegalCharacters)
        return input.components(separatedBy: controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractFirstImageURL(from html: String) -> String? {
        let pattern = "<img[^>]+src\\s*=\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }

        let url = String(html[range]).trimmingCharacters(in: .whitespaces)
        if case .valid = validateRSSURL(url) {
            return url
        }
        return nil
    }

    /// Strips bytes that represent invalid XML 1.0 characters from raw data.
    ///
    /// XML 1.0 只允许以下字符范围: #x9 | #xA | #xD | [#x20-#xD7FF] | [#xE000-#xFFFD] | [#x10000-#x10FFFF]
    /// 某些 RSS feed（如爱范儿 ifanr.com）的 `<content:encoded>` CDATA 中可能包含非法控制字符（如 0x05 ENQ），
    /// 会直接导致 `XMLParser.parse()` 返回 false → "数据解析失败"。
    ///
    /// - Returns: 清洗后的 Data，如果原数据没有非法字符，返回原数据避免内存拷贝。
    static func sanitizeXMLData(_ data: Data) -> Data {
        let hasInvalid = data.contains { byte in
            byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D
        }
        guard hasInvalid else { return data }

        return data.filter { byte in
            byte >= 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }
    }
}
