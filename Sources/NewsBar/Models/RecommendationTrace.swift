import Foundation

/// One truthful record of how a candidate was scored and selected in a single
/// ranking pass. It is produced by `RecommendationEngine.rank` itself; it is not
/// a second approximate scorer.
struct RecommendationTrace: Sendable, Equatable {
    /// Actual additive terms of `rawScore`: `personal.*` terms are scaled by
    /// profile confidence, `baseline.*` terms by its complement. Their sum minus
    /// `readPenalty` and `negativePenalty` equals `rawScore`.
    /// Unknown features are absent keys; known-but-zero features are present with
    /// value `0` (e.g. `personal.*` at cold start).
    let contributions: [String: Double]
    /// The raw personal score, **before** multiplying by `confidence`.
    /// `rawScore` already includes `confidence * personalScore`; do not apply the
    /// profile weight twice.
    let personalScore: Double
    /// The public/cold-start baseline used when the personal profile is weak.
    let baselineScore: Double
    /// Profile confidence used to mix `personalScore` and `baselineScore`.
    let confidence: Double
    /// Penalty for content already read (0 or 0.15).
    let readPenalty: Double
    /// Sum of the three soft-negative terms below, capped at 0.40.
    let negativePenalty: Double
    /// "Less like this event" term, cap 0.25.
    let negativeContentPenalty: Double
    /// "Less like this topic" term, cap 0.20.
    let negativeTopicPenalty: Double
    /// "Less like this source" term, cap 0.15.
    let negativeSourcePenalty: Double
    /// `confidence * personalScore + (1 - confidence) * baselineScore` after the
    /// read/negative penalties. Equals `sum(contributions) - readPenalty -
    /// negativePenalty`, and is the `ScoredRecommendation.score` value.
    let rawScore: Double
    /// The actual ordering key of the slot that selected this item, after the
    /// penalties applied in that slot:
    /// - `"score"`: `rawScore - sourcePenalty - topicPenalty - diversityPenalty`;
    /// - `"publicHeat"`: public heat minus the same penalties;
    /// - `"publicFresh"`: recency minus the same penalties;
    /// - `"sourceRotation"`: this is only `rawScore` (penalties are not applied);
    ///   the real decision is lexicographic, see the `rotation*` fields.
    let selectionScore: Double
    /// Same-source count penalty applied when selecting this item (0 when
    /// source filtering is on or the slot is source rotation).
    let sourcePenalty: Double
    /// Repeated-topic count penalty applied when selecting this item.
    let topicPenalty: Double
    /// Hard same-source cap penalty (0 or 1 when the source cap was reached).
    let diversityPenalty: Double
    /// 1-based rank in the score order after URL de-duplication and hard blocks,
    /// but **before exact-title cluster de-duplication**. A higher-scoring
    /// candidate dropped as a duplicate cluster still occupies a rank, so this
    /// value can be larger than the number of returned items; gaps are expected.
    /// It is a candidate-pool rank, not a position inside the snapshot.
    let rankBeforeDiversity: Int
    /// 1-based position in the returned snapshot.
    let finalRank: Int
    /// The actual rule that placed this item:
    /// - `"score"`: blended personal/baseline score minus penalties.
    /// - `"publicHeat"`: public chart heat minus penalties.
    /// - `"publicFresh"`: public slot with no public heat, ordered by recency.
    /// - `"sourceRotation"`: lexicographic least-used-source choice with a
    ///   seed-rotated tiebreak. This is not an additive score.
    let selectionPolicy: String
    /// Source-rotation evidence, `nil` for every other policy. Reconstruct the
    /// decision by choosing the remaining candidate with the smallest
    /// `(rotationSourceUseCount, (rotationCandidateIndex + rotationOffset) %
    /// rotationCandidateCount)`; `rotationCandidateIndex` is 0-based in the
    /// remaining candidate list at selection time.
    var rotationSourceUseCount: Int? = nil
    var rotationOffset: Int? = nil
    var rotationCandidateIndex: Int? = nil
    var rotationCandidateCount: Int? = nil
}
