import XCTest
@testable import NewsBar

final class LocalizationParityTests: XCTestCase {
    func testChineseAndEnglishTablesCoverTheSameKeys() {
        let parity = L10n.keyParity
        XCTAssertTrue(
            parity.missingInEnglish.isEmpty,
            "Missing in en: \(parity.missingInEnglish.sorted().joined(separator: ", "))"
        )
        XCTAssertTrue(
            parity.missingInChinese.isEmpty,
            "Missing in zh: \(parity.missingInChinese.sorted().joined(separator: ", "))"
        )
    }

    func testEveryStaticallyReferencedKeyIsDefined() throws {
        // Parity only compares the two tables. A key missing from both passes
        // parity and renders raw in the UI, so scan the call sites too.
        let sources = try Self.sourceFiles()
        let pattern = try NSRegularExpression(
            pattern: #""([a-z][A-Za-z0-9_.]+)"\.localized|L10n\.string\("([a-z][A-Za-z0-9_.]+)"#
        )
        var used: Set<String> = []
        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in pattern.matches(in: text, range: range) {
                for group in 1...2 {
                    guard let valueRange = Range(match.range(at: group), in: text) else { continue }
                    let key = String(text[valueRange])
                    // `"research.status.\(raw)"` is a dynamic family; its
                    // prefix is not a key. Dynamic families are covered by
                    // their own exhaustive-enum tests.
                    guard !key.hasSuffix(".") else { continue }
                    used.insert(key)
                }
            }
        }
        let undefined = used.subtracting(L10n.allKeys)
        XCTAssertTrue(
            undefined.isEmpty,
            "Used but undefined: \(undefined.sorted().joined(separator: ", "))"
        )
    }

    private static func sourceFiles() throws -> [URL] {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NewsBarTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
        let root = packageRoot.appendingPathComponent("Sources/NewsBar")
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        )
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            files.append(url)
        }
        XCTAssertFalse(files.isEmpty, "source scan found no Swift files")
        return files
    }

    func testUsageFormatsAcceptIntegerArguments() {
        // A `%@` specifier with Int arguments crashes at runtime; lock the
        // card's usage lines to integer specifiers.
        XCTAssertEqual(
            L10n.string("research.settings.usageDay", language: .zh, 12, 100),
            "今日 12/100 次"
        )
        XCTAssertEqual(
            L10n.string("research.settings.usageMonth", language: .en, 3, 500),
            "3/500 this month"
        )
    }
}
