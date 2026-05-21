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

    static func validateRSSURL(_ urlString: String) -> Bool {
        guard let url = validateURL(urlString),
              let host = url.host else {
            return false
        }

        let blockedDomains: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1"]
        if blockedDomains.contains(host.lowercased()) {
            return false
        }

        return true
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
}
