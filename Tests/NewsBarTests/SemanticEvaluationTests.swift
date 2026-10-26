import XCTest
@testable import NewsBar

final class SemanticEvaluationTests: XCTestCase {
    func testCosineRejectsInvalidVectorsInsteadOfFabricatingSimilarity() {
        XCTAssertNil(SemanticEvaluation.cosine([0, 0], [1, 2]))
        XCTAssertNil(SemanticEvaluation.cosine([1], [1, 2]))
        XCTAssertNil(SemanticEvaluation.cosine([.nan, 2], [1, 2]))
        XCTAssertEqual(SemanticEvaluation.cosine([1, 0], [1, 0]), 1)
        XCTAssertEqual(SemanticEvaluation.cosine([1, 0], [0, 1]), 0)
    }

    func testAvailabilityAloneDoesNotPassQualityGate() {
        let partial = SemanticEvaluationReport(providerID: "test", total: 12, covered: 6, chineseCovered: 0,
                                               chineseTotal: 6, correct: 6, baselineCorrect: 5)
        XCTAssertFalse(partial.isEligible)
        let noImprovement = SemanticEvaluationReport(providerID: "test", total: 12, covered: 12, chineseCovered: 6,
                                                     chineseTotal: 6, correct: 10, baselineCorrect: 10)
        XCTAssertFalse(noImprovement.isEligible)
    }

    func testInstalledSystemModelOnPrelabelledBilingualTriplets() async {
        let provider = SystemSentenceEmbeddingProvider()
        let report = await SemanticEvaluation.evaluate(provider: provider, triplets: SemanticEvaluation.acceptanceTriplets)
        XCTAssertEqual(report.total, 12)
        if report.covered < report.total || report.chineseCovered < report.chineseTotal { XCTAssertFalse(report.isEligible) }
        print("SEMANTIC_EVALUATION " + report.description)
    }
}
