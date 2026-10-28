import XCTest
@testable import NewsBar

final class AIKeySettingsTests: XCTestCase {
    func testSaveFeedbackIsSuccessOnlyForARealSuccess() {
        XCTAssertTrue(AIKeyFeedback.saved.isSuccess)
        XCTAssertTrue(AIKeyFeedback.keyDeleted.isSuccess)
        XCTAssertFalse(AIKeyFeedback.saveFailed.isSuccess)
        XCTAssertFalse(AIKeyFeedback.deleteFailed.isSuccess)
    }

    /// The old UI chose red/green by searching the rendered string for a
    /// localized fragment, so a failure whose text happened to contain the
    /// success text flipped colour. Tone must come from the case, not the text.
    func testToneComesFromTheCaseNotTheRenderedText() {
        XCTAssertEqual(AIKeyFeedback.saved.tone, .success)
        XCTAssertEqual(AIKeyFeedback.saveFailed.tone, .error)
        for feedback in AIKeyFeedback.allCases {
            let isKnownSuccess = feedback == .saved || feedback == .keyDeleted || feedback == .loaded
            XCTAssertEqual(feedback.tone == .success, isKnownSuccess, "\(feedback)")
        }
        XCTAssertFalse(AIKeyFeedback.saveFailed.text(language: .zh).isEmpty)
        XCTAssertFalse(AIKeyFeedback.saveFailed.text(language: .en).isEmpty)
    }

    func testOnePasswordReferenceIsScopedPerProviderAccount() {
        let first = AIProvider.deepseek.apiKeyAccount()
        let second = AIProvider.minimaxAPI.apiKeyAccount()
        XCTAssertNotEqual(first, second)

        var refs: [String: String] = [:]
        refs = AIKeyReferenceScope.assign("op://Personal/DeepSeek/key", to: first, in: refs)
        refs = AIKeyReferenceScope.assign("op://Personal/MiniMax/key", to: second, in: refs)

        XCTAssertEqual(refs[first], "op://Personal/DeepSeek/key")
        XCTAssertEqual(refs[second], "op://Personal/MiniMax/key")

        // Saving a key for one provider must not overwrite another provider's
        // reference, which is exactly what a single global value used to do.
        refs = AIKeyReferenceScope.assign("op://Personal/MiniMax/key2", to: second, in: refs)
        XCTAssertEqual(refs[first], "op://Personal/DeepSeek/key")
        XCTAssertEqual(refs[second], "op://Personal/MiniMax/key2")

        refs = AIKeyReferenceScope.assign("", to: second, in: refs)
        XCTAssertNil(refs[second])
        XCTAssertEqual(refs[first], "op://Personal/DeepSeek/key")
    }

    func testKeyStatusDistinguishesMissingFromAStaleFlag() {
        XCTAssertEqual(AIKeyStatus.resolve(stored: nil, hasFlag: false), .missing)
        XCTAssertEqual(AIKeyStatus.resolve(stored: "sk-test", hasFlag: false), .saved)
        XCTAssertEqual(AIKeyStatus.resolve(stored: nil, hasFlag: true), .flagWithoutSecret)
    }
}
