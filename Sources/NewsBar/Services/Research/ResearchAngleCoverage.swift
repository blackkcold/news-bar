import Foundation

/// What the extraction pass actually covered, in the terms the gap round needs.
struct ResearchAngleCoverageResult: Sendable, Equatable {
    /// Angles with at least `factsPerAngle` distinct verified facts.
    var covered: Set<ResearchAngle> = []
    /// Angles with at least one verified fact but not enough to count. These are
    /// still gaps, and they are the cheapest ones to close: one more source
    /// finishes the angle.
    var partial: Set<ResearchAngle> = []
    /// How many verified facts carried a determinate angle (labelled by the
    /// model, or inferred from the claim). Zero means the report has no angle
    /// signal at all, and the gap round must not spend anything: every angle
    /// would look empty, and the round would be guessing.
    var labelledFacts = 0
}

/// Turns a flat evidence list into angle coverage.
///
/// The rule is deliberately strict: an angle is covered only when at least two
/// *distinct* verified facts answer it. One quote is a data point; two is a
/// finding. That threshold is what stops the report from claiming a dimension
/// it only touched once.
///
/// Nothing here searches. The pages are already fetched and already quoted, so
/// coverage is computed from what the extraction stage produced — labelling
/// costs zero network requests.
enum ResearchAngleCoverage {
    /// The minimum number of verified facts that make an angle worth showing.
    static let factsPerAngle = 2

    static func evaluate(
        _ candidates: [EvidenceCandidate],
        documents: [String: ResearchDocument]
    ) -> ResearchAngleCoverageResult {
        var seenQuotes: Set<String> = []
        var counts: [ResearchAngle: Int] = [:]
        var result = ResearchAngleCoverageResult()

        for candidate in candidates {
            let canonical = ContentIdentity.canonicalURL(candidate.url)
            guard let document = documents[canonical] else { continue }
            // A quote the page does not literally contain proves nothing, so it
            // cannot cover an angle. Same verifier as `quoteVerified`.
            guard QuoteVerifier.verified(quote: candidate.quote, in: document.text) else { continue }

            let normalized = QuoteVerifier.normalize(candidate.quote)
            guard !normalized.isEmpty, seenQuotes.insert(normalized).inserted else { continue }

            guard let angle = candidate.angle ?? inferAngle(claim: candidate.claim) else { continue }
            counts[angle, default: 0] += 1
            result.labelledFacts += 1
        }

        for (angle, count) in counts {
            if count >= factsPerAngle {
                result.covered.insert(angle)
            } else {
                result.partial.insert(angle)
            }
        }
        return result
    }

    /// Angles the evidence actually covers, in a stable order.
    static func covered(
        _ candidates: [EvidenceCandidate],
        documents: [String: ResearchDocument]
    ) -> Set<ResearchAngle> {
        evaluate(candidates, documents: documents).covered
    }

    /// Angles with at least one verified fact but not enough to count. These
    /// are the gap list a second search round targets; keeping them separate
    /// from "not covered" is what makes the gap actionable.
    static func partial(
        _ candidates: [EvidenceCandidate],
        documents: [String: ResearchDocument]
    ) -> Set<ResearchAngle> {
        evaluate(candidates, documents: documents).partial
    }

    /// Reads an unlabelled fact as whichever angle its claim asks about.
    ///
    /// Keyword matching is crude on purpose: the alternative is discarding the
    /// fact, and a wrongly inferred angle costs one slot in a tally while a
    /// discarded fact costs a source. Nil when nothing matches — an honest
    /// "unknown" rather than a guess that inflates coverage.
    static func inferAngle(claim: String) -> ResearchAngle? {
        let text = claim.lowercased()
        guard !text.isEmpty else { return nil }
        for angle in ResearchAngle.allCases {
            if angle.keywords.contains(where: { text.contains($0.lowercased()) }) {
                return angle
            }
        }
        return nil
    }
}
