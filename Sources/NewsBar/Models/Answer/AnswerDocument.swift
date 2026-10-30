import Foundation

/// What kind of thing the user asked about. The kind never changes layout on
/// its own: it picks the section scaffold in the prompt and labels the evidence
/// row. Everything the canvas draws comes from `blocks`.
enum AnswerKind: String, Codable, Sendable, CaseIterable, Equatable {
    case term
    case event
    case number
    case comparison
    case howto

    static let fallback: AnswerKind = .term

    func label(_ language: AppLanguage) -> String {
        L10n.string("answer.kind.\(rawValue)", language: language)
    }
}

/// How the answer was produced. This is a fact about the run, not a claim by
/// the model, and it is the only thing the badge row is allowed to say.
enum AnswerMode: String, Codable, Sendable, Equatable {
    /// No network lookup: the model's own knowledge only.
    case offline
    /// The article open in the reader, and nothing else.
    case currentPage
    /// Pages found and read for this question.
    case web

    var isOffline: Bool { self == .offline }
}

/// Counts the app can verify without trusting the model: how many pages it
/// actually read, and how many of them the answer points at.
struct AnswerEvidence: Equatable, Sendable {
    let mode: AnswerMode
    let sourceCount: Int
    let citedCount: Int

    var hasSources: Bool { sourceCount > 0 }
}

/// One titled section of an answer. `body` keeps the model's line breaks: the
/// renderer classifies them (paragraph, bullet, definition, quote) so a
/// half-formatted answer still reads well.
struct AnswerBlock: Identifiable, Equatable, Sendable {
    let id: Int
    var heading: String?
    var body: String
}

/// The single answer shape shared by reader AI search and selected-text
/// explanation.
///
/// Invariants:
/// - `sources` only contains pages this run actually read. The model can never
///   add one; it can only point at them by number.
/// - A citation number outside `1...sources.count` is not a citation. The
///   renderer prints it as plain text instead of inventing a chip.
/// - `oneLine` is a summary of `blocks`, never a substitute for them.
struct AnswerDocument: Equatable, Sendable {
    var kind: AnswerKind
    var oneLine: String
    var blocks: [AnswerBlock]
    var sources: [AISearchSource]
    var mode: AnswerMode
    var model: String
    var thinking: AIThinkingLevel
    var generatedAt: Date
    var question: String?
    /// True when the provider stopped at the token ceiling. The canvas says so
    /// rather than letting a cut-off answer look complete.
    var truncated: Bool = false

    var isOffline: Bool { mode.isOffline }

    /// Distinct source numbers the answer actually points at, in reading order.
    var citationIndices: [Int] {
        Self.citedIndices(in: blocks, sourceCount: sources.count)
    }

    static func citedIndices(in blocks: [AnswerBlock], sourceCount: Int) -> [Int] {
        var seen: Set<Int> = []
        var ordered: [Int] = []
        for block in blocks {
            for segment in AnswerCitationScanner.segments(in: block.body, sourceCount: sourceCount) {
                guard case .citation(let index) = segment else { continue }
                guard seen.insert(index).inserted else { continue }
                ordered.append(index)
            }
        }
        return ordered
    }

    var evidence: AnswerEvidence {
        AnswerEvidence(mode: mode, sourceCount: sources.count, citedCount: citationIndices.count)
    }

    /// The document as a typewriter would have revealed it: blocks in order,
    /// each body cut to its share of the budget. Pure, so the reveal rule is
    /// tested without a timer.
    func revealed(upTo limit: Int) -> AnswerDocument {
        guard limit > 0 else {
            var empty = self
            empty.blocks = []
            return empty
        }
        var remaining = limit
        var shown: [AnswerBlock] = []
        for block in blocks {
            guard remaining > 0 else { break }
            let body = String(block.body.prefix(remaining))
            guard !body.isEmpty else { continue }
            remaining -= body.count
            shown.append(AnswerBlock(id: block.id, heading: block.heading, body: body))
        }
        var copy = self
        copy.blocks = shown
        return copy
    }

    /// Text the copy button puts on the pasteboard. Structure is preserved as
    /// headings and citations; source URLs stay readable as plain text.
    func plainText(_ language: AppLanguage) -> String {
        var parts: [String] = []
        if !oneLine.isEmpty { parts.append(oneLine) }
        for block in blocks {
            var section = ""
            if let heading = block.heading, !heading.isEmpty {
                section += "## \(heading)\n"
            }
            section += block.body
            parts.append(section)
        }
        var text = parts.joined(separator: "\n\n")
        if !sources.isEmpty {
            let header = L10n.string("answer.sources", language: language)
            let rows = sources.map { source in
                "[\(source.index)] \(source.title) — \(source.url)"
            }
            text += "\n\n" + header + "\n" + rows.joined(separator: "\n")
        }
        return text
    }
}

/// Splits a block body into the shapes the canvas knows how to draw.
enum AnswerLine: Equatable {
    case paragraph(String)
    case bullet(String)
    case definition(String, String)
    case quote(String)
}

enum AnswerFormatter {
    /// A definition row is short and noun-like. Anything that reads like a
    /// sentence stays a bullet: a wrong grid is worse than a plain list.
    private static let definitionLabelLimit = 12
    private static let definitionValueLimit = 40

    static func lines(_ body: String) -> [AnswerLine] {
        var result: [AnswerLine] = []
        var paragraph = ""

        func flushParagraph() {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(.paragraph(trimmed)) }
            paragraph = ""
        }

        for rawLine in body.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                continue
            }
            if line.hasPrefix("> ") || line == ">" {
                flushParagraph()
                let quoted = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if !quoted.isEmpty { result.append(.quote(quoted)) }
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                let item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                guard !item.isEmpty else { continue }
                if let pair = definition(from: item) {
                    result.append(.definition(pair.label, pair.value))
                } else {
                    result.append(.bullet(item))
                }
                continue
            }
            paragraph = paragraph.isEmpty ? line : join(paragraph, line)
        }
        flushParagraph()
        return result
    }

    /// Joins two wrapped lines. Chinese needs no space, Latin words do, so the
    /// boundary decides instead of the UI language.
    private static func join(_ head: String, _ tail: String) -> String {
        guard let last = head.unicodeScalars.last, let first = tail.unicodeScalars.first else {
            return head + tail
        }
        let latin = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        if latin.contains(last) && latin.contains(first) {
            return head + " " + tail
        }
        return head + tail
    }

    private static func definition(from item: String) -> (label: String, value: String)? {
        guard let separator = item.firstIndex(where: { $0 == "：" || $0 == ":" }) else { return nil }
        let label = String(item[item.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
        let value = String(item[item.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, !value.isEmpty else { return nil }
        guard label.count <= definitionLabelLimit, value.count <= definitionValueLimit else { return nil }
        guard !label.contains(where: { "。！？；!?;".contains($0) }) else { return nil }
        guard !value.contains(where: { "。！？!?".contains($0) }) else { return nil }
        return (label, value)
    }
}
