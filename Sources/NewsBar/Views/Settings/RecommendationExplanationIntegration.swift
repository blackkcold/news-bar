import Foundation

/// The single seam where the settings explanation consumes Task B (ranking
/// trace) and Task D (bundled guide). The UI never re-ranks and never invents
/// trace or guide content: absent inputs stay explicitly unavailable.
enum RecommendationExplanationIntegration {
    /// Task D's bundled guide is the only prose source. An empty list means the
    /// resource is missing or malformed, which the UI renders as unavailable.
    static func guideSections(language: AppLanguage) -> [ExplanationGuideSection] {
        RecommendationGuide.sections(language: language).map {
            ExplanationGuideSection(id: $0.id, title: $0.title, body: $0.body)
        }
    }

    /// Task B's trace is copied 1:1. `nil` stays `nil`; there is deliberately no
    /// arithmetic fallback from raw components.
    static func trace(for recommendation: ScoredRecommendation) -> RecommendationExplanationTrace? {
        guard let trace = recommendation.trace else { return nil }
        return RecommendationExplanationTrace(
            contributions: trace.contributions,
            personalScore: trace.personalScore,
            baselineScore: trace.baselineScore,
            confidence: trace.confidence,
            readPenalty: trace.readPenalty,
            feedbackPenalty: trace.feedbackPenalty,
            rawScore: trace.rawScore,
            selectionScore: trace.selectionScore,
            sourcePenalty: trace.sourcePenalty,
            topicPenalty: trace.topicPenalty,
            diversityPenalty: trace.diversityPenalty,
            rankBeforeDiversity: trace.rankBeforeDiversity,
            finalRank: trace.finalRank,
            selectionPolicy: trace.selectionPolicy,
            rotationSourceUseCount: trace.rotationSourceUseCount,
            rotationOffset: trace.rotationOffset,
            rotationCandidateIndex: trace.rotationCandidateIndex,
            rotationCandidateCount: trace.rotationCandidateCount
        )
    }
}
