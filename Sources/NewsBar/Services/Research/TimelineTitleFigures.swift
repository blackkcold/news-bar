import Foundation

/// Checks the one thing a quantitative timeline title can lie about: its
/// numbers.
///
/// The popup's first screen shows capsule titles, so a title like "销量降 17%"
/// is the highest-value line in the report — and the easiest one for a model to
/// invent. Every number in a title must appear verbatim in one of the quotes
/// that node cites. Anything else is reported to the reader as a limitation.
///
/// Nothing is deleted and no ID is cleared: an unsupported number is a reason
/// to warn, not a reason to throw away the node and its citations. The same
/// verbatim principle already governs quotes elsewhere in the report.
enum TimelineTitleFigures {
    /// Titles that claim a number their own citations do not contain.
    ///
    /// `extraQuotesByCanonicalURL` carries quotes from the cited pages that the
    /// report itself folded away. `mergeSameURL` keeps one row per page, so a
    /// figure may sit in a quote that is no longer its own row while the title
    /// legitimately cites that page. Without these, the check accused correct
    /// titles of inventing figures — measured on a real deep run, 2 of 8 titles.
    static func unsupportedTitles(
        in report: BurstResearch,
        extraQuotesByCanonicalURL: [String: [String]] = [:]
    ) -> [String] {
        let quotesByID = Dictionary(
            report.evidence.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return report.timeline.compactMap { node -> String? in
            let figures = numbers(in: node.title)
            guard !figures.isEmpty else { return nil }
            // A node with no citations is already reported as unsourced. Saying
            // it again as a numeric problem would describe one defect twice.
            guard !node.evidenceIDs.isEmpty else { return nil }

            let cited = node.evidenceIDs.compactMap { quotesByID[$0] }
            guard !cited.isEmpty else { return nil }

            // A cited page vouches with everything it said, not only with the
            // one quote that survived merging.
            var texts = cited.map(\.quote)
            for item in cited {
                texts.append(contentsOf: extraQuotesByCanonicalURL[item.canonicalURL] ?? [])
            }

            let supported = Set(texts.flatMap { numbers(in: $0) })
            return figures.allSatisfy { supported.contains($0) } ? nil : node.title
        }
    }

    /// Every number in a string, normalized so formatting differences do not
    /// read as different values: "2,840", "2840" and "２８４０" are one number.
    ///
    /// Only ASCII digits count. `Character.isNumber` is true for CJK numerals
    /// too — "一" in "另一件事" would read as the number 1 — which would accuse
    /// correct Chinese titles of inventing figures. Chinese numerals are
    /// deliberately not parsed: "前三名" makes a claim this check cannot
    /// verify, and mapping it would manufacture false accusations.
    /// The shortest figure worth checking.
    ///
    /// A single digit cannot be told apart from a label that happens to contain
    /// one — "Q3", "5G", "第一名" — so checking it produces accusations a reader
    /// cannot act on. A warning that fires on correct reports is worse than an
    /// unchecked one-digit claim: it teaches the reader to skip the line that
    /// also carries the real warnings.
    static let minimumCheckedDigits = 2

    static func numbers(in text: String) -> [String] {
        let normalized = Array(text.folding(
            options: [.widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ))
        var figures: [String] = []
        var current = ""
        var index = 0
        while index < normalized.count {
            let character = normalized[index]
            if character.isASCII, character.isNumber {
                current.append(character)
                index += 1
                continue
            }
            if (character == "," || character == "，"),
               !current.isEmpty,
               Self.groupsExactlyThreeDigits(normalized, from: index + 1) {
                // A comma continues a figure only when it groups three digits.
                // Skipping every separator merged separate figures: "Q3 17%"
                // parsed as the single number 317, so the quote's 17 could never
                // support it and a correct title was reported as inventing a
                // figure. A space is not a thousands separator at all — it ends
                // the figure.
                index += 1
                continue
            }
            if !current.isEmpty {
                figures.append(current)
                current = ""
            }
            index += 1
        }
        if !current.isEmpty { figures.append(current) }
        return figures.filter { $0.count >= Self.minimumCheckedDigits }
    }

    /// Whether the run of digits starting at `index` is exactly three long.
    /// "2,840" groups, "增长，17%" does not, and "2,8400" is not a grouping.
    private static func groupsExactlyThreeDigits(
        _ characters: [Character],
        from index: Int
    ) -> Bool {
        var count = 0
        var position = index
        while position < characters.count,
              characters[position].isASCII,
              characters[position].isNumber {
            count += 1
            position += 1
        }
        return count == 3
    }
}
