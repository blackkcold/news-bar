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

    /// Normalize known publisher feed aliases without routing through a third-party proxy.
    /// 36kr's apex `/feed` endpoint serves an HTML anti-bot page, while the canonical
    /// `www` host serves the publisher's RSS feed.
    static func canonicalRSSURL(_ urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == allowedScheme,
              components.host?.lowercased() == "36kr.com",
              components.path == "/feed" || components.path == "/feed/" else {
            return trimmed
        }

        components.host = "www.36kr.com"
        components.path = "/feed"
        return components.url?.absoluteString ?? trimmed
    }

    /// Detect an HTML landing/challenge response from a small UTF-8-compatible prefix.
    /// This is deliberately a body heuristic, not a Content-Type gate: legitimate feeds
    /// are still accepted when publishers mislabel their XML response.
    static func isLikelyHTMLResponse(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let prefix = String(decoding: data.prefix(4096), as: UTF8.self)
        let trimCharacters = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\u{FEFF}"))
        let normalized = prefix
            .trimmingCharacters(in: trimCharacters)
            .lowercased()

        return normalized.hasPrefix("<!doctype html")
            || normalized.hasPrefix("<html")
            || normalized.hasPrefix("<head")
            || normalized.hasPrefix("<body")
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

    /// Repairs bare `&` (unescaped ampersands) that are NOT part of a valid XML entity or character
    /// reference, replacing them with `&amp;`. Ampersands inside CDATA sections, XML comments, and
    /// processing instructions are left untouched.
    ///
    /// This is a **byte-level single-pass state machine**, deliberately encoding-agnostic (matching
    /// `sanitizeXMLData`). It never converts to `String`, so it is safe for GBK/GB2312/UTF-8 feeds.
    /// All tokens it keys on (`&`, `<`, `>`, `amp;`, `#`) are ASCII and byte-invariant across encodings.
    ///
    /// Some RSS feeds (e.g. ifanr.com) emit a bare `&` — such as a base64 URL ending in `&` before
    /// `</image>` — which triggers `NSXMLParserErrorDomain` error 68 (`xmlParseEntityRef: no name`)
    /// and fails the whole parse. This method tolerates that malformed input client-side.
    ///
    /// - Returns: The repaired `Data`. If no bare `&` is found, the original `Data` is returned
    ///   unchanged (zero-copy fast path).
    static func sanitizeXMLEntities(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return data }

        // States for the single-pass scanner.
        enum State {
            case text
            case tag            // inside <...> but not in an attribute value
            case attributeValue // inside a quoted attribute value
            case comment        // inside <!-- ... -->
            case cdata          // inside <![CDATA[ ... ]]>
            case pi             // inside <? ... ?>
        }

        var state: State = .text
        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        var changed = false
        var i = 0
        let n = bytes.count

        while i < n {
            let b = bytes[i]

            switch state {
            case .text:
                if b == 0x3C { // '<'
                    // Detect comment / CDATA / PI / tag start.
                    if bytes.hasPrefix([0x3C, 0x21, 0x2D, 0x2D], at: i) { // <!--
                        state = .comment
                        output.append(contentsOf: bytes[i..<min(i + 4, n)])
                        i += 4
                    } else if bytes.hasPrefix([0x3C, 0x21, 0x5B, 0x43, 0x44, 0x41, 0x54, 0x41, 0x5B], at: i) { // <![CDATA[
                        state = .cdata
                        output.append(contentsOf: bytes[i..<min(i + 9, n)])
                        i += 9
                    } else if bytes.hasPrefix([0x3C, 0x3F], at: i) { // <?
                        state = .pi
                        output.append(contentsOf: bytes[i..<min(i + 2, n)])
                        i += 2
                    } else {
                        state = .tag
                        output.append(b)
                        i += 1
                    }
                } else if b == 0x26 { // '&'
                    // Try to consume a valid entity. If none, escape it.
                    if let entityEnd = validEntityEnd(in: bytes, from: i) {
                        output.append(contentsOf: bytes[i..<entityEnd])
                        i = entityEnd
                    } else {
                        output.append(contentsOf: [0x26, 0x61, 0x6D, 0x70, 0x3B]) // &amp;
                        changed = true
                        i += 1
                    }
                } else {
                    output.append(b)
                    i += 1
                }

            case .tag:
                if b == 0x22 || b == 0x27 { // " or '
                    state = .attributeValue
                    output.append(b)
                    i += 1
                } else if b == 0x3E { // '>'
                    state = .text
                    output.append(b)
                    i += 1
                } else {
                    output.append(b)
                    i += 1
                }

            case .attributeValue:
                if b == 0x22 || b == 0x27 { // closing quote
                    state = .tag
                    output.append(b)
                    i += 1
                } else if b == 0x26 { // '&' inside attribute value must also be escaped
                    if let entityEnd = validEntityEnd(in: bytes, from: i) {
                        output.append(contentsOf: bytes[i..<entityEnd])
                        i = entityEnd
                    } else {
                        output.append(contentsOf: [0x26, 0x61, 0x6D, 0x70, 0x3B]) // &amp;
                        changed = true
                        i += 1
                    }
                } else {
                    output.append(b)
                    i += 1
                }

            case .comment:
                if bytes.hasPrefix([0x2D, 0x2D, 0x3E], at: i) { // -->
                    state = .text
                    output.append(contentsOf: bytes[i..<min(i + 3, n)])
                    i += 3
                } else {
                    output.append(b)
                    i += 1
                }

            case .cdata:
                if bytes.hasPrefix([0x5D, 0x5D, 0x3E], at: i) { // ]]>
                    state = .text
                    output.append(contentsOf: bytes[i..<min(i + 3, n)])
                    i += 3
                } else {
                    output.append(b)
                    i += 1
                }

            case .pi:
                if bytes.hasPrefix([0x3F, 0x3E], at: i) { // ?>
                    state = .text
                    output.append(contentsOf: bytes[i..<min(i + 2, n)])
                    i += 2
                } else {
                    output.append(b)
                    i += 1
                }
            }
        }

        return changed ? Data(output) : data
    }

    /// If `bytes[i]` is `&` and a valid XML entity or character reference follows, returns the index
    /// just past the terminating `;`. Otherwise returns `nil`.
    ///
    /// Handles named entities (`&amp; &lt; &gt; &quot; &apos;` and any `&name;`), decimal character
    /// references (`&#NNN;`), and hex character references (`&#xNN;`). Consumes the longest valid
    /// entity so a legitimate `&amp;` is never double-escaped.
    private static func validEntityEnd(in bytes: [UInt8], from start: Int) -> Int? {
        let n = bytes.count
        guard start < n, bytes[start] == 0x26 else { return nil } // '&'

        var j = start + 1

        // Character reference: &#NNN; or &#xNN;
        if j < n, bytes[j] == 0x23 { // '#'
            j += 1
            if j < n, (bytes[j] == 0x78 || bytes[j] == 0x58) { // 'x' or 'X'
                j += 1
                var hexCount = 0
                while j < n, isHexDigit(bytes[j]) {
                    j += 1
                    hexCount += 1
                }
                guard hexCount > 0, j < n, bytes[j] == 0x3B else { return nil } // ';'
                return j + 1
            } else {
                var decCount = 0
                while j < n, bytes[j] >= 0x30 && bytes[j] <= 0x39 { // 0-9
                    j += 1
                    decCount += 1
                }
                guard decCount > 0, j < n, bytes[j] == 0x3B else { return nil } // ';'
                return j + 1
            }
        }

        // Only the five XML 1.0 predefined entities are valid. HTML entities (&nbsp;, &copy;, …)
        // are not predefined in XML and would fail parsing as undeclared entities if let through;
        // escaping them to &amp;name; keeps the text loadable (and &nbsp; is later normalized back
        // to a space in sanitizeHTMLContent).
        let predefined: Set<[UInt8]> = [
            [0x61, 0x6D, 0x70],       // amp
            [0x6C, 0x74],             // lt
            [0x67, 0x74],             // gt
            [0x71, 0x75, 0x6F, 0x74], // quot
            [0x61, 0x70, 0x6F, 0x73]  // apos
        ]
        var nameBytes = [UInt8]()
        while j < n, isNameChar(bytes[j]) {
            nameBytes.append(bytes[j])
            j += 1
        }
        guard !nameBytes.isEmpty, j < n, bytes[j] == 0x3B else { return nil } // ';'
        guard predefined.contains(nameBytes) else { return nil }
        return j + 1
    }

    private static func isNameChar(_ b: UInt8) -> Bool {
        (b >= 0x61 && b <= 0x7A) || // a-z
        (b >= 0x41 && b <= 0x5A) || // A-Z
        (b >= 0x30 && b <= 0x39) || // 0-9
        b == 0x5F || b == 0x2D || b == 0x2E // _ - .
    }

    private static func isHexDigit(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || // 0-9
        (b >= 0x61 && b <= 0x66) || // a-f
        (b >= 0x41 && b <= 0x46)    // A-F
    }
}

private extension Array where Element == UInt8 {
    /// Returns true if `self[i...]` begins with `prefix`.
    func hasPrefix(_ prefix: [UInt8], at i: Int) -> Bool {
        guard i >= 0, i + prefix.count <= count else { return false }
        for (offset, p) in prefix.enumerated() {
            if self[i + offset] != p { return false }
        }
        return true
    }
}
