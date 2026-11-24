import Foundation

/// Maps the security policy's English reason strings to localized copy.
/// Shared by the add sheet and the recommendation path so both say the same
/// thing instead of drifting.
enum RSSSecurityCopy {
    static func localized(_ reason: String, language: AppLanguage) -> String {
        switch reason {
        case "Invalid URL or scheme":
            return L10n.string("rss.security.invalidURL", language: language)
        default:
            if reason.hasPrefix("Blocked host: ") {
                return L10n.string(
                    "rss.security.blockedHost",
                    language: language,
                    reason.replacingOccurrences(of: "Blocked host: ", with: "")
                )
            }
            if reason.hasPrefix("Private IP range: ") {
                return L10n.string(
                    "rss.security.privateIP",
                    language: language,
                    reason.replacingOccurrences(of: "Private IP range: ", with: "")
                )
            }
            return reason
        }
    }
}
