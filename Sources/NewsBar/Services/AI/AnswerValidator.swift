import Foundation

/// App-side citation validation. The model writes `[n]`; only this type decides
/// whether the number points at a source the app actually adopted.
enum AnswerValidator {
    struct Result: Equatable, Sendable {
        let validCitations: [Int]
        let invalidCitations: Int
        let uncitedFactualSentences: Int
    }

    static func validate(
        blocks: [AnswerBlock],
        sources: [AISearchSource]
    ) -> Result {
        let allowed = allowedIndices(sources)
        var ordered: [Int] = []
        var seen: Set<Int> = []
        var invalid = 0
        var uncited = 0

        for block in blocks {
            for segment in AnswerCitationScanner.segments(
                in: block.body,
                sourceCount: sources.count
            ) {
                guard case .citation(let index) = segment else { continue }
                if allowed.contains(index) {
                    if seen.insert(index).inserted { ordered.append(index) }
                } else {
                    invalid += 1
                }
            }

            for sentence in factualSentences(in: block.body) {
                let hasCitation = AnswerCitationScanner
                    .segments(in: sentence, sourceCount: sources.count)
                    .contains { segment in
                        if case .citation = segment { return true }
                        return false
                    }
                if !hasCitation { uncited += 1 }
            }
        }

        return Result(
            validCitations: ordered,
            invalidCitations: invalid,
            uncitedFactualSentences: uncited
        )
    }

    /// The only basis the app can defend. A single secondary or unassessed
    /// source is `externalLimited`; it never becomes "supported".
    static func basis(
        sources: [AISearchSource],
        blocks: [AnswerBlock],
        validation: Result
    ) -> AnswerBasis {
        guard !sources.isEmpty, !blocks.isEmpty else { return .insufficientMaterial }

        let external = sources.filter { $0.origin == .web }
        let adopted = external.filter { $0.assessment?.adoption != .rejected }
        let hasCurrentPage = sources.contains { $0.origin == .currentPage }

        if !validation.validCitations.isEmpty {
            if !adopted.isEmpty {
                let hasPrimary = adopted.contains { $0.assessment?.adoption == .primary }
                let independent = adopted.filter {
                    $0.assessment?.independence == .independent
                }.count
                return (hasPrimary || independent >= 2) ? .externalSupported : .externalLimited
            }
            if hasCurrentPage { return .currentPageOnly }
            return .insufficientMaterial
        }

        if hasCurrentPage, adopted.isEmpty { return .noVerifiedCitations }
        if !adopted.isEmpty { return .noVerifiedCitations }
        return .insufficientMaterial
    }

    /// `nil` assessment means "no assessment information", not "rejected".
    /// That keeps current-page and legacy documents citable.
    static func allowedIndices(_ sources: [AISearchSource]) -> Set<Int> {
        guard sources.contains(where: { $0.assessment != nil }) else {
            return Set(sources.map(\.index))
        }
        return Set(
            sources
                .filter { $0.assessment?.adoption != .rejected }
                .map(\.index)
        )
    }

    /// A sentence with a number, a percentage, or a quotation is a factual
    /// claim. It gets the diagnostic count only; it never blanks the answer.
    static func factualSentences(in body: String) -> [String] {
        let normalized = body.replacingOccurrences(
            of: "\\.\\s+",
            with: "。",
            options: .regularExpression
        )
        return normalized
            .components(separatedBy: CharacterSet(charactersIn: "。！？!?\n"))
            .map { line in
                var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    trimmed = String(trimmed.dropFirst(2))
                        .trimmingCharacters(in: .whitespaces)
                }
                return trimmed
            }
            .filter { sentence in
                guard !sentence.isEmpty else { return false }
                if sentence.unicodeScalars.contains(where: {
                    CharacterSet.decimalDigits.contains($0)
                }) {
                    return true
                }
                if sentence.contains("%") { return true }
                if sentence.contains("\"") || sentence.contains("“") || sentence.contains("”") {
                    return true
                }
                return false
            }
    }
}
