import Foundation

/// Turns a finished report into the single line shown in a notification.
/// The summary is model output, so markup and links are stripped and the
/// result is capped before it can reach the lock screen.
enum ResearchNotificationSummary {
    static let maxCharacters = 80

    static func make(report: BurstResearch, language: AppLanguage) -> String {
        let source = report.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? report.overview
            : report.summary
        let cleaned = sanitize(firstSentence(of: source))
        guard !cleaned.isEmpty else {
            return L10n.string("research.notif.fallback", language: language)
        }
        return truncate(cleaned, to: maxCharacters)
    }

    static func firstSentence(of text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: " ")
        for separator in ["。", "！", "？", ". ", "! ", "? "] {
            if let range = normalized.range(of: separator) {
                let end = normalized.index(range.lowerBound, offsetBy: separator.count)
                return String(normalized[..<end])
            }
        }
        return normalized
    }

    static func sanitize(_ text: String) -> String {
        var value = text
        value = value.replacingOccurrences(
            of: #"!?\[([^\]]*)\]\([^)]*\)"#,
            with: "$1",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"https?://\S+"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"[*_`#>]+"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: max(0, limit - 1))
        return String(text[..<end]).trimmingCharacters(in: .whitespaces) + "…"
    }
}
