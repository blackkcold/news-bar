import XCTest
@testable import NewsBar

/// Guards the contract between a localized format string and its call site.
///
/// A `%@` fed an `Int` is not a formatting glitch: CoreFoundation dereferences
/// the integer as an object and the process dies with SIGSEGV. This test walks
/// every `L10n.string("key", …, args)` call in `Sources/NewsBar` and checks the
/// argument count and the obvious type mismatches against the Chinese table.
final class LocalizationFormatContractTests: XCTestCase {
    func testEveryFormatCallMatchesItsArguments() throws {
        let files = try Self.sourceFiles()
        var problems: [String] = []

        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            var searchStart = text.startIndex

            while let range = text.range(of: "L10n.string(", range: searchStart..<text.endIndex) {
                guard let body = Self.parenthesizedBody(in: text, from: range.upperBound) else {
                    break
                }
                let params = Self.splitTopLevel(body.text)
                if let key = Self.stringLiteral(params.first),
                   let format = L10n.testFormats[key] {
                    let args = params.dropFirst().filter {
                        !$0.trimmingCharacters(in: .whitespaces).hasPrefix("language:")
                    }
                    let line = text[text.startIndex..<range.lowerBound]
                        .filter { $0 == "\n" }
                        .count + 1
                    let where_ = "\(url.lastPathComponent):\(line) \(key)"
                    let specs = Self.specifiers(in: format)

                    if args.count != specs.count {
                        problems.append(
                            "\(where_): \(args.count) args for \(specs.count) specifiers — \(format)"
                        )
                    } else {
                        for (spec, arg) in zip(specs, args) {
                            if spec == "@", Self.isIntegerLike(arg) {
                                problems.append(
                                    "\(where_): %@ receives an integer (\(arg)) — \(format)"
                                )
                            }
                        }
                    }
                }
                searchStart = body.end
            }
        }

        XCTAssertTrue(
            problems.isEmpty,
            "Format contract violations:\n" + problems.joined(separator: "\n")
        )
    }

    // MARK: - Parsing

    private struct Body {
        let text: String
        let end: String.Index
    }

    private static func parenthesizedBody(
        in text: String,
        from start: String.Index
    ) -> Body? {
        var depth = 1
        var index = start
        var quote: Character?
        var escaped = false
        while index < text.endIndex {
            let ch = text[index]
            if let current = quote {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == current { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "(" {
                depth += 1
            } else if ch == ")" {
                depth -= 1
                if depth == 0 {
                    return Body(text: String(text[start..<index]), end: text.index(after: index))
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func splitTopLevel(_ body: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var escaped = false
        for ch in body {
            if let active = quote {
                current.append(ch)
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == active { quote = nil }
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                current.append(ch)
                continue
            }
            if "([{".contains(ch) { depth += 1 }
            if ")]}".contains(ch) { depth -= 1 }
            if ch == ",", depth == 0 {
                result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                continue
            }
            current.append(ch)
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    private static func stringLiteral(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 else {
            return nil
        }
        return String(trimmed.dropFirst().dropLast())
    }

    /// Returns the ordered specifier types. Positional formats (`%1$@`) are
    /// expanded to their maximum index; sequential formats keep their order.
    private static func specifiers(in format: String) -> [Character] {
        let positional = matches(in: format, pattern: #"%(\d+)\$l?([@difs])"#)
        if !positional.isEmpty {
            let indexed = positional.compactMap { groups -> (Int, Character)? in
                guard groups.count == 2,
                      let index = Int(groups[0]),
                      let type = groups[1].first else { return nil }
                return (index, type)
            }
            let maximum = indexed.map(\.0).max() ?? 0
            var output = Array(repeating: Character("?"), count: maximum)
            for (index, type) in indexed where index >= 1 && index <= maximum {
                output[index - 1] = type
            }
            return output
        }
        return matches(in: format, pattern: #"%(?!%)(?:l)?([@difs])"#)
            .compactMap { $0.first?.first }
    }

    private static func matches(in text: String, pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).map { index in
                guard let r = Range(match.range(at: index), in: text) else { return "" }
                return String(text[r])
            }
        }
    }

    private static func isIntegerLike(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: #"^-?\d+$"#, options: .regularExpression) != nil { return true }
        return value.contains("Int(") || value.contains("Int64(")
    }

    private static func sourceFiles() throws -> [URL] {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = packageRoot.appendingPathComponent("Sources/NewsBar")
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            XCTFail("cannot enumerate \(root.path)")
            return []
        }
        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            files.append(url)
        }
        XCTAssertFalse(files.isEmpty, "source scan found no Swift files")
        return files
    }
}
