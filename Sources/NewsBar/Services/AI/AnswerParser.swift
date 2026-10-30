import Foundation

/// Parses the model's line-tagged answer.
///
/// The contract is deliberately not JSON. Long Chinese prose inside a JSON
/// string has to escape every newline, and one stray newline used to cost the
/// whole answer; here a broken line costs one line. The first line is a small
/// JSON meta object (short, easy to validate), everything after it is plain
/// text with `##` section headings.
///
/// ```
/// @@ {"kind":"event","oneLine":"一句话"}
/// ## 时间线
/// 3 月 4 日发布。[1]
/// ```
enum AnswerParser {
    static let maxBlocks = 8
    static let maxBlockCharacters = 1_400
    static let maxTotalCharacters = 5_000
    static let maxOneLineCharacters = 120

    struct Output: Equatable {
        var kind: AnswerKind
        var oneLine: String
        var blocks: [AnswerBlock]
    }

    static func parse(_ raw: String, fallbackKind: AnswerKind) -> Output {
        let lines = stripFence(raw).components(separatedBy: .newlines)
        var meta = Meta()
        var index = 0

        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            index += 1
        }
        if index < lines.count {
            let first = lines[index].trimmingCharacters(in: .whitespaces)
            if first.hasPrefix("@@") {
                meta = decodeMeta(String(first.dropFirst(2)))
                index += 1
            }
        }

        var blocks: [AnswerBlock] = []
        var total = 0
        var heading: String?
        var bodyLines: [String] = []
        var isOpen = false

        func closeSection() {
            guard isOpen else { return }
            isOpen = false
            let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            bodyLines.removeAll(keepingCapacity: true)
            let currentHeading = heading
            heading = nil
            guard !body.isEmpty, blocks.count < maxBlocks, total < maxTotalCharacters else { return }
            let budget = min(maxBlockCharacters, maxTotalCharacters - total)
            let capped = String(body.prefix(budget)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !capped.isEmpty else { return }
            total += capped.count
            blocks.append(AnswerBlock(id: blocks.count, heading: currentHeading, body: capped))
        }

        while index < lines.count {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A second meta line is a model artifact, never content.
            if trimmed.hasPrefix("@@") { continue }
            if trimmed.hasPrefix("##") {
                closeSection()
                let title = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                heading = title.isEmpty ? nil : String(title.prefix(60))
                isOpen = true
                continue
            }
            if !isOpen {
                isOpen = true
                heading = nil
            }
            bodyLines.append(line)
        }
        closeSection()

        let oneLine = meta.oneLine?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? deriveOneLine(from: blocks.first?.body)
            ?? ""
        return Output(
            kind: meta.kind ?? fallbackKind,
            oneLine: String(oneLine.prefix(maxOneLineCharacters)),
            blocks: blocks
        )
    }

    // MARK: - Meta

    private struct Meta {
        var kind: AnswerKind?
        var oneLine: String?
    }

    private static func decodeMeta(_ raw: String) -> Meta {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Meta()
        }
        return Meta(
            kind: (object["kind"] as? String).flatMap(AnswerKind.init(rawValue:)),
            oneLine: object["oneLine"] as? String
        )
    }

    private static func deriveOneLine(from body: String?) -> String? {
        guard let body else { return nil }
        let firstLine = body
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces)
        guard let firstLine, !firstLine.isEmpty else { return nil }
        if let end = firstLine.firstIndex(where: { "。！？.!?".contains($0) }) {
            return String(firstLine[...end])
        }
        return String(firstLine.prefix(maxOneLineCharacters))
    }

    private static func stripFence(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        if let firstBreak = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstBreak)...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("```") {
            text = String(text.dropLast(3))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// One run of answer text: either prose or a citation the app can resolve.
enum AnswerCitationSegment: Equatable {
    case text(String)
    case citation(Int)
}

/// Finds `[n]` markers and decides which of them are real citations.
///
/// A number outside `1...sourceCount` is not evidence — it is a model mistake —
/// so it stays on screen as literal text. Hiding it would silently rewrite the
/// answer; turning it into a chip would invent a source.
enum AnswerCitationScanner {
    private static let expression = try? NSRegularExpression(pattern: "\\[(\\d{1,3})\\]")

    static func segments(in text: String, sourceCount: Int) -> [AnswerCitationSegment] {
        guard !text.isEmpty, let expression else { return text.isEmpty ? [] : [.text(text)] }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return [.text(text)] }

        var result: [AnswerCitationSegment] = []
        var buffer = ""
        var cursor = text.startIndex

        for match in matches {
            guard let range = Range(match.range, in: text),
                  let numberRange = Range(match.range(at: 1), in: text),
                  let number = Int(text[numberRange]) else { continue }
            buffer += String(text[cursor..<range.lowerBound])
            if number >= 1, number <= sourceCount {
                if !buffer.isEmpty {
                    result.append(.text(buffer))
                    buffer = ""
                }
                result.append(.citation(number))
            } else {
                buffer += String(text[range])
            }
            cursor = range.upperBound
        }
        buffer += String(text[cursor...])
        if !buffer.isEmpty { result.append(.text(buffer)) }
        return result
    }
}
