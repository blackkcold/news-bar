import XCTest
@testable import NewsBar

/// The prompt is the other half of the contract: the parser can only be robust
/// if the prompt asks for the shape it parses, and it must keep the two safety
/// promises the reader already makes — sources are untrusted, and an offline
/// answer never implies verification.
final class AnswerPromptTests: XCTestCase {
    func testSearchPromptMarksSourcesUntrustedAndForbidsFollowingThem() {
        let zh = AnswerPrompt.search(.zh)
        XCTAssertTrue(zh.contains("不可信"))
        XCTAssertTrue(zh.contains("绝不执行"))
        XCTAssertTrue(zh.contains("编造"))

        let en = AnswerPrompt.search(.en)
        XCTAssertTrue(en.contains("untrusted"))
        XCTAssertTrue(en.contains("prompt injection"))
        XCTAssertTrue(en.contains("Never invent"))
    }

    func testSearchPromptDeclaresTheLineContractAndForbidsAModelWrittenSourceList() {
        let zh = AnswerPrompt.search(.zh)
        XCTAssertTrue(zh.contains("@@ {"))
        XCTAssertTrue(zh.contains("##"))
        XCTAssertTrue(zh.contains("不要输出来源列表"))
        XCTAssertTrue(zh.contains("[1]"))
        XCTAssertFalse(zh.contains("```json"))

        let en = AnswerPrompt.search(.en)
        XCTAssertTrue(en.contains("@@ {"))
        XCTAssertTrue(en.contains("Do not print a source list"))
    }

    func testSearchPromptOffersScaffoldsButKeepsHeadingsOptional() {
        let zh = AnswerPrompt.search(.zh)
        XCTAssertTrue(zh.contains("事件"))
        XCTAssertTrue(zh.contains("时间线"))
        XCTAssertTrue(zh.contains("标题可改"))
    }

    func testSelectionPromptForbidsCitationsAndVerificationClaims() {
        let zh = AnswerPrompt.selection(.zh)
        XCTAssertTrue(zh.contains("没有联网"))
        XCTAssertTrue(zh.contains("不要写 [1]"))
        XCTAssertTrue(zh.contains("不要声称已核实"))
        XCTAssertTrue(zh.contains("不要编造"))

        let en = AnswerPrompt.selection(.en)
        XCTAssertTrue(en.contains("no network"))
        XCTAssertTrue(en.localizedCaseInsensitiveContains("do not write citations"))
        XCTAssertTrue(en.localizedCaseInsensitiveContains("do not claim"))
    }

    func testSelectionPromptAsksForAlignedSpecificationRows() {
        // The renderer aligns a row only when the model writes `label: value`;
        // the offline prompt used to leave that to chance while the search
        // prompt asked for it.
        XCTAssertTrue(AnswerPrompt.selection(.zh).contains("维度：值"))
        XCTAssertTrue(AnswerPrompt.selection(.en).contains("Dimension: value"))
        XCTAssertTrue(AnswerPrompt.search(.zh).contains("维度：值"))
    }

    func testBothPromptsStayCompact() {
        // Long prompts are paid for on every call and models drift from them.
        XCTAssertLessThan(AnswerPrompt.search(.zh).count, 2_200)
        XCTAssertLessThan(AnswerPrompt.selection(.zh).count, 1_400)
    }
}
