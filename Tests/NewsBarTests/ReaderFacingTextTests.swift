import XCTest
@testable import NewsBar

final class ReaderFacingTextTests: XCTestCase {

    func testDetectsInternalVocabularyInReaderFields() {
        XCTAssertTrue(ReaderFacingText.containsInternalTerm("现有证据卡支持的时间线"))
        XCTAssertTrue(ReaderFacingText.containsInternalTerm("种子文章试图回看这次发布"))
        XCTAssertTrue(ReaderFacingText.containsInternalTerm("来源档案仅作背景"))
        XCTAssertTrue(ReaderFacingText.containsInternalTerm("evidence cards were not returned"))
        XCTAssertTrue(ReaderFacingText.containsInternalTerm("the model returned no timeline"))
    }

    /// A news report may legitimately be about seeds, models or clients. Only
    /// this app's machinery phrases may trip the guard.
    func testDoesNotFlagLegitimateNewsSubjects() {
        XCTAssertFalse(ReaderFacingText.containsInternalTerm("该模型将于明年发布"))
        XCTAssertFalse(ReaderFacingText.containsInternalTerm("公司完成种子轮融资"))
        XCTAssertFalse(ReaderFacingText.containsInternalTerm("客户端下载量突破一亿"))
        XCTAssertFalse(ReaderFacingText.containsInternalTerm("研究人员记录了种子发芽率"))
    }

    func testFindingsNameTheOffendingField() {
        var draft = ResearchDraft()
        draft.summary = "正常概要"
        draft.overview = "本次种子来自热搜。"
        draft.timeline = [
            TimelineNode(date: "2026-01-01", title: "发布会", detail: "证据卡显示销量回升"),
        ]
        draft.limitations = "公开来源有限"

        let findings = ReaderFacingText.findings(in: draft)
        XCTAssertEqual(findings.map(\.field), ["overview", "timeline[0].detail"])
    }

    func testEnforceHidesDirtyProseAndKeepsCleanContent() {
        var report = BurstResearch()
        report.summary = "正常概要"
        report.overview = "现有证据卡支持的时间线集中在 2018 年。"
        report.timeline = [
            TimelineNode(date: "2026-01-01", title: "发布会", detail: "干净的事实细节"),
            TimelineNode(date: "2026-02-01", title: "证据卡显示", detail: "干净的细节"),
            TimelineNode(date: "2026-03-01", title: "收购完成", detail: "模型没有返回更多信息"),
        ]
        report.limitations = "公开来源有限\n证据卡覆盖不足"

        let cleaned = ReaderFacingText.enforce(report)

        XCTAssertEqual(cleaned.summary, "正常概要")
        XCTAssertEqual(cleaned.overview, "")
        XCTAssertEqual(cleaned.limitations, "公开来源有限")
        XCTAssertEqual(cleaned.timeline.count, 2)
        XCTAssertEqual(cleaned.timeline.first?.title, "发布会")
        XCTAssertEqual(cleaned.timeline.first?.detail, "干净的事实细节")
        XCTAssertEqual(cleaned.timeline.last?.title, "收购完成")
        XCTAssertEqual(cleaned.timeline.last?.detail, "")
    }

    func testEnforceClearsDirtyClaimNotes() {
        var report = BurstResearch()
        report.verification = VerificationReport(
            verdict: .confirmed,
            strength: 2,
            independentSources: 2,
            claims: [
                ClaimCheck(
                    claim: "销量回升",
                    status: .supports,
                    evidenceIDs: ["E1"],
                    note: "证据卡支持"
                ),
            ],
            conflicts: ["来源档案存在分歧"],
            missing: ["公开资料有限"]
        )

        let cleaned = ReaderFacingText.enforce(report)

        XCTAssertEqual(cleaned.verification?.claims.first?.note, "")
        XCTAssertEqual(cleaned.verification?.conflicts, [])
        XCTAssertEqual(cleaned.verification?.missing, ["公开资料有限"])
        XCTAssertEqual(cleaned.verification?.claims.first?.evidenceIDs, ["E1"])
    }

    func testSynthesisPromptsRequireReaderLanguage() {
        let zh = ResearchPrompts.synthesisSystemPrompt(language: .zh, hasEvidence: true)
        XCTAssertTrue(zh.contains("普通读者"))
        XCTAssertTrue(zh.contains("证据卡"))
        XCTAssertTrue(zh.contains("任何正文都不得出现 E 编号"))

        let en = ResearchPrompts.synthesisSystemPrompt(language: .en, hasEvidence: true)
        XCTAssertTrue(en.contains("ordinary readers"))
        XCTAssertTrue(en.contains("evidence card"))
        XCTAssertTrue(en.contains("no prose may contain E-numbers"))

        let zhEmpty = ResearchPrompts.synthesisSystemPrompt(language: .zh, hasEvidence: false)
        XCTAssertFalse(zhEmpty.contains("不要描绘"))
        XCTAssertTrue(zhEmpty.contains("不要描述研究过程"))
    }

    func testUserPromptSchemaDescribesReaderFacingOverview() {
        let seed = ResearchPrompts.SeedContext(
            title: "测试事件",
            summary: "摘要",
            sourceName: "微博",
            url: nil,
            publishedAt: nil
        )
        let zh = ResearchPrompts.synthesisUserPrompt(
            seed: seed,
            claims: [],
            evidence: [],
            dossier: [],
            trendContext: "",
            language: .zh
        )
        XCTAssertTrue(zh.contains("面向读者的 2–4 段事件脉络"))
        XCTAssertTrue(zh.contains("已核实引文"))
        XCTAssertFalse(zh.contains("证据卡（可引用"))

        let en = ResearchPrompts.synthesisUserPrompt(
            seed: seed,
            claims: [],
            evidence: [],
            dossier: [],
            trendContext: "",
            language: .en
        )
        XCTAssertTrue(en.contains("Verified quotes"))
        XCTAssertTrue(en.contains("2–4 reader-facing paragraphs"))
    }

    func testRewritePromptProtectsStructure() {
        let zh = ResearchPrompts.readerRewriteUserPrompt(rawOutput: "{}", language: .zh)
        XCTAssertTrue(zh.contains("不得改变事实、日期、evidenceIDs"))
        XCTAssertTrue(zh.contains("不得增删事件"))

        let en = ResearchPrompts.readerRewriteUserPrompt(rawOutput: "{}", language: .en)
        XCTAssertTrue(en.contains("Do not change facts, dates, evidenceIDs"))
    }
}
