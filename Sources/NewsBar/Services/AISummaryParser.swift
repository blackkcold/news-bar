import Foundation

enum AISummaryParser {
    /// Parse markdown text into sections with titles and bodies
    static func parseSections(_ text: String, itemCount: Int) -> [(title: String, body: String, primaryIndex: Int?)] {
        let lines = text.components(separatedBy: "\n")
        var sections: [(title: String, body: String, primaryIndex: Int?)] = []
        var currentTitle = ""
        var currentBody = ""
        var currentIndices: [Int] = []

        func flush() {
            let t = currentTitle.trimmingCharacters(in: .whitespaces)
            let b = currentBody.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !b.isEmpty {
                let primary = currentIndices.first
                sections.append((title: t, body: b, primaryIndex: primary))
            }
            currentTitle = ""
            currentBody = ""
            currentIndices = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("【") {
                flush()
                let (title, inline) = extractTemplateTitle(trimmed)
                currentTitle = title
                if !inline.isEmpty {
                    currentBody = inline
                }
            } else if trimmed.hasPrefix("#") {
                flush()
                currentTitle = extractMarkdownTitle(trimmed)
            } else if trimmed.hasPrefix("引用：") {
                currentIndices = parseCitationNumbers(trimmed, itemCount: itemCount)
            } else if !trimmed.isEmpty, !currentTitle.isEmpty {
                let refs = parseCitationNumbers(trimmed, itemCount: itemCount)
                currentIndices.append(contentsOf: refs)
                currentBody += (currentBody.isEmpty ? "" : "\n") + trimmed
            }
        }
        flush()
        return sections
    }

    static func stripMarkdown(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "\\*\\*(.*?)\\*\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?<!\\*)\\*(?!\\*)(.*?)(?<!\\*)\\*(?!\\*)", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "`(.*?)`", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?m)^#{1,6}\\s+", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?m)^[-*+]\\s+", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?m)^>\\s+", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\[#\\d+\\]", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "【[^】]*】", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?m)^引用：.*$\\n?", with: "", options: .regularExpression)
        return result
    }

    static func stripCitations(_ text: String) -> String {
        text.replacingOccurrences(of: "\\[#\\d+\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func parseCitationNumbers(_ line: String, itemCount: Int) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: "\\[#(\\d+)\\]") else { return [] }
        let range = NSRange(line.startIndex..., in: line)
        return regex.matches(in: line, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: line),
                  let idx = Int(line[r]),
                  idx >= 0, idx < itemCount else { return nil }
            return idx
        }
    }

    // MARK: - Private Helpers

    private static func extractTemplateTitle(_ line: String) -> (title: String, inlineBody: String) {
        guard let start = line.firstIndex(of: "【"),
              let end = line.firstIndex(of: "】"), end > start else {
            return (String(line.dropFirst()), "")
        }
        let title = String(line[line.index(after: start)..<end])
        let after = line.index(after: end)
        let inline = after < line.endIndex ? String(line[after...]).trimmingCharacters(in: .whitespaces) : ""
        return (title, inline)
    }

    private static func extractMarkdownTitle(_ line: String) -> String {
        line.replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
