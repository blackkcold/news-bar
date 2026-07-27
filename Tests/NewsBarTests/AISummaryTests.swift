import XCTest
@testable import NewsBar

// MARK: - AISummaryParser Tests

final class AISummaryParserTests: XCTestCase {

    // MARK: - Dual Parser: Category Separation

    func testParseDualSummary_separatesCategories() {
        let text = """
        【趋势概览】
        【热点话题】这是一个微博热点。
        引用：[#0]
        【每日精选】
        【深度分析】这是一个深度分析。
        引用：[#5]
        """
        // Items: indices 0-4 = Weibo/Bilibili, 5+ = RSS
        let result = AISummaryParser.parseDualSummary(text, itemCount: 10, weiboBilibiliRange: 0..<5)
        XCTAssertFalse(result.isLegacyFallback)
        XCTAssertEqual(result.trendOverview.count, 1)
        XCTAssertEqual(result.trendOverview[0].title, "热点话题")
        XCTAssertEqual(result.dailyEssentials.count, 1)
        XCTAssertEqual(result.dailyEssentials[0].title, "深度分析")
    }

    func testParseDualSummary_trendOnlyWeiboBilibiliIndices() {
        let text = """
        【趋势概览】
        【微博热点】微博内容。
        引用：[#0]
        【B站热点】B站内容。
        引用：[#3]
        【每日精选】
        【精选】精选内容。
        引用：[#5]
        """
        // Items: indices 0-2 = Weibo, 3-4 = Bilibili, 5+ = RSS
        let result = AISummaryParser.parseDualSummary(text, itemCount: 10, weiboBilibiliRange: 0..<5)
        XCTAssertEqual(result.trendOverview.count, 2)
        XCTAssertEqual(result.trendOverview[0].title, "微博热点")
        XCTAssertEqual(result.trendOverview[1].title, "B站热点")
    }

    // MARK: - Source Filtering: RSS-citing sections moved from trend to daily

    func testParseDualSummary_movesRSSCitationFromTrendToDaily() {
        let text = """
        【趋势概览】
        【RSS误入】这条引用了RSS。
        引用：[#7]
        【每日精选】
        【正常精选】正常内容。
        引用：[#0]
        """
        let result = AISummaryParser.parseDualSummary(text, itemCount: 10, weiboBilibiliRange: 0..<5)
        // RSS-citing section should be moved out of trend
        XCTAssertEqual(result.trendOverview.count, 0)
        // Should appear in daily essentials
        XCTAssertTrue(result.dailyEssentials.contains(where: { $0.title == "RSS误入" }))
        XCTAssertTrue(result.dailyEssentials.contains(where: { $0.title == "正常精选" }))
    }

    func testParseDualSummary_omitsTrendSectionWithNoCitation() {
        let text = """
        【趋势概览】
        【无引用】这段没有引用编号。
        【有引用】这段有引用。
        引用：[#0]
        【每日精选】
        【精选】精选内容。
        引用：[#5]
        """
        let result = AISummaryParser.parseDualSummary(text, itemCount: 10, weiboBilibiliRange: 0..<5)
        // Section without citation should be omitted from trend
        XCTAssertEqual(result.trendOverview.count, 1)
        XCTAssertEqual(result.trendOverview[0].title, "有引用")
    }

    // MARK: - Legacy Fallback

    func testParseDualSummary_legacyFallbackWhenNoLabels() {
        let text = """
        【热点一】这是第一个热点。
        引用：[#0]
        【热点二】这是第二个热点。
        引用：[#1]
        """
        let result = AISummaryParser.parseDualSummary(text, itemCount: 5, weiboBilibiliRange: 0..<3)
        XCTAssertTrue(result.isLegacyFallback)
        XCTAssertEqual(result.trendOverview.count, 2)
        XCTAssertEqual(result.dailyEssentials.count, 0)
    }

    func testParseDualSummary_legacyFallbackWithOnlyTrendLabel() {
        let text = """
        【趋势概览】
        【热点】只有一个板块。
        引用：[#0]
        """
        let result = AISummaryParser.parseDualSummary(text, itemCount: 5, weiboBilibiliRange: 0..<3)
        XCTAssertTrue(result.isLegacyFallback)
        XCTAssertEqual(result.trendOverview.count, 1)
    }

    func testParseDualSummary_legacyFallbackWithOnlyDailyLabel() {
        let text = """
        【每日精选】
        【精选】只有一个板块。
        引用：[#0]
        """
        let result = AISummaryParser.parseDualSummary(text, itemCount: 5, weiboBilibiliRange: 0..<3)
        XCTAssertTrue(result.isLegacyFallback)
        XCTAssertEqual(result.trendOverview.count, 1)
    }

    // MARK: - Malformed / Edge Cases

    func testParseDualSummary_emptyText() {
        let result = AISummaryParser.parseDualSummary("", itemCount: 5, weiboBilibiliRange: 0..<3)
        XCTAssertTrue(result.isLegacyFallback)
        XCTAssertEqual(result.trendOverview.count, 0)
        XCTAssertEqual(result.dailyEssentials.count, 0)
    }

    func testParseDualSummary_emptyDailySection() {
        let text = """
        【趋势概览】
        【热点】热点内容。
        引用：[#0]
        【每日精选】
        """
        let result = AISummaryParser.parseDualSummary(text, itemCount: 5, weiboBilibiliRange: 0..<3)
        XCTAssertFalse(result.isLegacyFallback)
        XCTAssertEqual(result.trendOverview.count, 1)
        XCTAssertEqual(result.trendOverview[0].title, "热点")
        XCTAssertEqual(result.dailyEssentials.count, 0)
    }

    func testParseDualSummary_outOfBoundsCitationIgnored() {
        let text = """
        【趋势概览】
        【越界】
        引用：[#999]
        【每日精选】
        【精选】内容。
        引用：[#0]
        """
        let result = AISummaryParser.parseDualSummary(text, itemCount: 5, weiboBilibiliRange: 0..<3)
        // Index 999 is out of bounds, so primaryIndex is nil → omitted from trend
        XCTAssertEqual(result.trendOverview.count, 0)
        XCTAssertEqual(result.dailyEssentials.count, 1)
    }

    func testParseDualSummary_negativeCitationIgnored() {
        let text = """
        【趋势概览】
        【负索引】
        引用：[#-1]
        【每日精选】
        【精选】内容。
        引用：[#0]
        """
        let result = AISummaryParser.parseDualSummary(text, itemCount: 5, weiboBilibiliRange: 0..<3)
        // Negative index is out of bounds → primaryIndex is nil → omitted from trend
        XCTAssertEqual(result.trendOverview.count, 0)
        XCTAssertEqual(result.dailyEssentials.count, 1)
    }

    // MARK: - parseSections (used internally by parseDualSummary)

    func testParseSections_extractsTitlesAndBodies() {
        let text = """
        【标题一】正文内容。
        更多正文。
        引用：[#0]
        【标题二】另一段正文。
        引用：[#1]
        """
        let sections = AISummaryParser.parseSections(text, itemCount: 5)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].title, "标题一")
        XCTAssertEqual(sections[0].body, "正文内容。\n更多正文。")
        XCTAssertEqual(sections[0].primaryIndex, 0)
        XCTAssertEqual(sections[1].title, "标题二")
        XCTAssertEqual(sections[1].body, "另一段正文。")
        XCTAssertEqual(sections[1].primaryIndex, 1)
    }

    func testParseSections_markdownTitles() {
        let text = """
        # Markdown标题
        正文内容。
        引用：[#0]
        """
        let sections = AISummaryParser.parseSections(text, itemCount: 5)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].title, "Markdown标题")
    }

    func testParseSections_inlineBodyAfterTitle() {
        let text = "【标题】内联正文。引用：[#0]"
        let sections = AISummaryParser.parseSections(text, itemCount: 5)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].title, "标题")
        // Citation [#0] is inline in body, not on a separate 引用： line,
        // so it's treated as body text and primaryIndex is nil
        XCTAssertTrue(sections[0].body.contains("内联正文"))
        XCTAssertNil(sections[0].primaryIndex)
    }

    func testParseSections_emptyBodySkipped() {
        let text = "【空标题】"
        let sections = AISummaryParser.parseSections(text, itemCount: 5)
        XCTAssertEqual(sections.count, 0)
    }

    // MARK: - stripMarkdown / stripCitations

    func testStripMarkdown_removesBold() {
        let result = AISummaryParser.stripMarkdown("**加粗** 普通")
        XCTAssertEqual(result, "加粗 普通")
    }

    func testStripMarkdown_removesCitations() {
        let result = AISummaryParser.stripMarkdown("内容 [#0] 更多")
        // stripMarkdown replaces [#0] with empty string, leaving double space
        XCTAssertEqual(result, "内容  更多")
    }

    func testStripCitations_removesCitationBrackets() {
        let result = AISummaryParser.stripCitations("内容 [#0] 更多")
        // stripCitations replaces [#0] with empty string, leaving double space
        XCTAssertEqual(result, "内容  更多")
    }

    func testStripCitations_noChangeWithoutCitations() {
        let result = AISummaryParser.stripCitations("普通文本")
        XCTAssertEqual(result, "普通文本")
    }
}

// MARK: - AppSettings Budget Cap Tests

final class AppSettingsBudgetCapTests: XCTestCase {

    /// Snapshot the raw object for a UserDefaults key so we can restore it in defer.
    private func snapshotObject(forKey key: String) -> Any? {
        UserDefaults.standard.object(forKey: key)
    }

    /// Restore a previously snapshotted raw object (or remove if it was nil).
    private func restoreObject(_ object: Any?, forKey key: String) {
        if let obj = object {
            UserDefaults.standard.set(obj, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func testValidAICaps_containsExpectedValues() {
        XCTAssertTrue(AppSettings.validAICaps.contains(20))
        XCTAssertTrue(AppSettings.validAICaps.contains(50))
        XCTAssertTrue(AppSettings.validAICaps.contains(100))
        XCTAssertEqual(AppSettings.validAICaps.count, 3)
    }

    func testInit_usesValidCapFromUserDefaults() {
        let prior = snapshotObject(forKey: "aiDailyCap")
        defer { restoreObject(prior, forKey: "aiDailyCap") }

        UserDefaults.standard.set(100, forKey: "aiDailyCap")
        let settings = AppSettings()
        XCTAssertEqual(settings.aiDailyCap, 100)
    }

    func testInit_fallsBackTo50ForInvalidCap() {
        let prior = snapshotObject(forKey: "aiDailyCap")
        defer { restoreObject(prior, forKey: "aiDailyCap") }

        UserDefaults.standard.set(42, forKey: "aiDailyCap")
        let settings = AppSettings()
        XCTAssertEqual(settings.aiDailyCap, 50, "Invalid cap 42 should fall back to 50")
    }

    func testInit_fallsBackTo50ForMissingCap() {
        let prior = snapshotObject(forKey: "aiDailyCap")
        defer { restoreObject(prior, forKey: "aiDailyCap") }

        UserDefaults.standard.removeObject(forKey: "aiDailyCap")
        let settings = AppSettings()
        XCTAssertEqual(settings.aiDailyCap, 50, "Missing cap should default to 50")
    }

    func testInit_accepts20() {
        let prior = snapshotObject(forKey: "aiDailyCap")
        defer { restoreObject(prior, forKey: "aiDailyCap") }

        UserDefaults.standard.set(20, forKey: "aiDailyCap")
        let settings = AppSettings()
        XCTAssertEqual(settings.aiDailyCap, 20)
    }

    func testInit_accepts100() {
        let prior = snapshotObject(forKey: "aiDailyCap")
        defer { restoreObject(prior, forKey: "aiDailyCap") }

        UserDefaults.standard.set(100, forKey: "aiDailyCap")
        let settings = AppSettings()
        XCTAssertEqual(settings.aiDailyCap, 100)
    }

    func testInit_rejectsNegativeCap() {
        let prior = snapshotObject(forKey: "aiDailyCap")
        defer { restoreObject(prior, forKey: "aiDailyCap") }

        UserDefaults.standard.set(-1, forKey: "aiDailyCap")
        let settings = AppSettings()
        XCTAssertEqual(settings.aiDailyCap, 50, "Negative cap should fall back to 50")
    }

    func testInit_rejectsZeroCap() {
        let prior = snapshotObject(forKey: "aiDailyCap")
        defer { restoreObject(prior, forKey: "aiDailyCap") }

        UserDefaults.standard.set(0, forKey: "aiDailyCap")
        let settings = AppSettings()
        XCTAssertEqual(settings.aiDailyCap, 50, "Zero cap should fall back to 50")
    }

    func testRecordAIRequests_incrementsCount() {
        let priorCap = snapshotObject(forKey: "aiDailyCap")
        let priorCount = snapshotObject(forKey: "todayAIRequestCount")
        let priorDay = snapshotObject(forKey: "statsDayTimestamp")
        defer {
            restoreObject(priorCap, forKey: "aiDailyCap")
            restoreObject(priorCount, forKey: "todayAIRequestCount")
            restoreObject(priorDay, forKey: "statsDayTimestamp")
        }

        UserDefaults.standard.set(50, forKey: "aiDailyCap")
        let settings = AppSettings()
        let before = settings.todayAIRequestCount
        settings.recordAIRequests(3)
        XCTAssertEqual(settings.todayAIRequestCount, before + 3)
    }

    func testRecordAIRequests_ignoresNonPositive() {
        let priorCap = snapshotObject(forKey: "aiDailyCap")
        let priorCount = snapshotObject(forKey: "todayAIRequestCount")
        let priorDay = snapshotObject(forKey: "statsDayTimestamp")
        defer {
            restoreObject(priorCap, forKey: "aiDailyCap")
            restoreObject(priorCount, forKey: "todayAIRequestCount")
            restoreObject(priorDay, forKey: "statsDayTimestamp")
        }

        UserDefaults.standard.set(50, forKey: "aiDailyCap")
        let settings = AppSettings()
        let before = settings.todayAIRequestCount
        settings.recordAIRequests(0)
        XCTAssertEqual(settings.todayAIRequestCount, before)
        settings.recordAIRequests(-1)
        XCTAssertEqual(settings.todayAIRequestCount, before)
    }

    func testAiUsageText_format() {
        let priorCap = snapshotObject(forKey: "aiDailyCap")
        let priorCount = snapshotObject(forKey: "todayAIRequestCount")
        let priorDay = snapshotObject(forKey: "statsDayTimestamp")
        defer {
            restoreObject(priorCap, forKey: "aiDailyCap")
            restoreObject(priorCount, forKey: "todayAIRequestCount")
            restoreObject(priorDay, forKey: "statsDayTimestamp")
        }

        UserDefaults.standard.set(50, forKey: "aiDailyCap")
        let settings = AppSettings()
        settings.todayAIRequestCount = 3
        XCTAssertTrue(settings.aiUsageText.contains("3"))
        XCTAssertTrue(settings.aiUsageText.contains("50"))
    }
}

// MARK: - AISummaryService Budget Boundary Tests

final class AISummaryServiceBudgetTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Reset budget state before each test
        AISummaryService.initBudget(baseline: 0, cap: 50)
    }

    // MARK: - initBudget

    func testInitBudget_setsBaselineAndCap() {
        AISummaryService.initBudget(baseline: 10, cap: 20)
        XCTAssertEqual(AISummaryService.readGenerationAttempts(), 0)
    }

    // MARK: - consumeAttemptBudget

    func testConsumeAttemptBudget_incrementsOnSuccess() {
        XCTAssertEqual(AISummaryService.readGenerationAttempts(), 0)
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget())
        XCTAssertEqual(AISummaryService.readGenerationAttempts(), 1)
    }

    func testConsumeAttemptBudget_tracksMultipleAttempts() {
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget())
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget())
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget())
        XCTAssertEqual(AISummaryService.readGenerationAttempts(), 3)
    }

    // MARK: - Boundary: baseline + attempts + 1 <= cap

    func testConsumeAttemptBudget_allowsAtCapBoundary() {
        // baseline=0, cap=5 → attempts 0..4 should succeed (5 total)
        AISummaryService.initBudget(baseline: 0, cap: 5)
        for i in 0..<5 {
            XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(),
                             "Attempt \(i) should succeed")
        }
        XCTAssertEqual(AISummaryService.readGenerationAttempts(), 5)
    }

    func testConsumeAttemptBudget_throwsWhenExceedingCap() {
        AISummaryService.initBudget(baseline: 0, cap: 3)
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget())
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget())
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget())
        XCTAssertThrowsError(try AISummaryService.consumeAttemptBudget()) { error in
            XCTAssertTrue(error is NewsBarError)
            if case NewsBarError.rateLimited = error {
                // Expected
            } else {
                XCTFail("Expected rateLimited, got \(error)")
            }
        }
    }

    func testConsumeAttemptBudget_doesNotIncrementOnDenied() {
        AISummaryService.initBudget(baseline: 0, cap: 2)
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget())
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget())
        // Third attempt should throw
        XCTAssertThrowsError(try AISummaryService.consumeAttemptBudget())
        // Count should still be 2 (not incremented on denied)
        XCTAssertEqual(AISummaryService.readGenerationAttempts(), 2)
    }

    // MARK: - Boundary with non-zero baseline

    func testConsumeAttemptBudget_withBaseline() {
        // baseline=8, cap=10 → 2 attempts allowed
        AISummaryService.initBudget(baseline: 8, cap: 10)
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget())
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget())
        XCTAssertThrowsError(try AISummaryService.consumeAttemptBudget())
        XCTAssertEqual(AISummaryService.readGenerationAttempts(), 2)
    }

    func testConsumeAttemptBudget_baselineAtCap() {
        // baseline=10, cap=10 → 0 attempts allowed
        AISummaryService.initBudget(baseline: 10, cap: 10)
        XCTAssertThrowsError(try AISummaryService.consumeAttemptBudget())
        XCTAssertEqual(AISummaryService.readGenerationAttempts(), 0)
    }

    func testConsumeAttemptBudget_baselineExceedsCap() {
        // baseline=15, cap=10 → 0 attempts allowed
        AISummaryService.initBudget(baseline: 15, cap: 10)
        XCTAssertThrowsError(try AISummaryService.consumeAttemptBudget())
        XCTAssertEqual(AISummaryService.readGenerationAttempts(), 0)
    }

    // MARK: - readGenerationAttempts

    func testReadGenerationAttempts_initialZero() {
        AISummaryService.initBudget(baseline: 0, cap: 50)
        XCTAssertEqual(AISummaryService.readGenerationAttempts(), 0)
    }

    func testReadGenerationAttempts_afterMultipleCalls() {
        AISummaryService.initBudget(baseline: 0, cap: 50)
        XCTAssertEqual(AISummaryService.readGenerationAttempts(), 0)
        try? AISummaryService.consumeAttemptBudget()
        XCTAssertEqual(AISummaryService.readGenerationAttempts(), 1)
        try? AISummaryService.consumeAttemptBudget()
        XCTAssertEqual(AISummaryService.readGenerationAttempts(), 2)
    }

    // MARK: - readGenerationCap

    func testReadGenerationCap_returnsSetCap() {
        AISummaryService.initBudget(baseline: 0, cap: 100)
        XCTAssertEqual(AISummaryService.readGenerationCap(), 100)
    }

    func testReadGenerationCap_defaultIs50() {
        // After setUp, cap should be 50
        XCTAssertEqual(AISummaryService.readGenerationCap(), 50)
    }

    // MARK: - Isolation: different initBudget calls reset state

    func testInitBudget_resetsAttempts() {
        try? AISummaryService.consumeAttemptBudget()
        try? AISummaryService.consumeAttemptBudget()
        XCTAssertEqual(AISummaryService.readGenerationAttempts(), 2)
        AISummaryService.initBudget(baseline: 0, cap: 50)
        XCTAssertEqual(AISummaryService.readGenerationAttempts(), 0)
    }
}

// MARK: - Truncation Hash & Consecutive Truncation Tests

@MainActor
final class TruncationHashTests: XCTestCase {

    func testMaxConsecutiveTruncationsConstant() {
        let orchestrator = NewsOrchestrator()
        XCTAssertGreaterThan(orchestrator.maxConsecutiveTruncations, 0)
    }

    func testClearCacheResetsTruncationHashes() async {
        let orchestrator = NewsOrchestrator()
        let settings = AppSettings()

        await orchestrator.clearCache()

        XCTAssertNil(orchestrator.popupLastHash)
        XCTAssertNil(orchestrator.dashboardLastHash)
        XCTAssertNil(orchestrator.popupLastTruncatedHash)
        XCTAssertNil(orchestrator.dashboardLastTruncatedHash)
        XCTAssertEqual(orchestrator.consecutiveTruncationCount, 0)

        _ = settings
    }

    func testTruncatedHashGuardsPopupRegeneration() {
        let orchestrator = NewsOrchestrator()

        orchestrator.popupLastTruncatedHash = "hash-A"
        let newHash = "hash-A"

        let shouldSkip = newHash == orchestrator.popupLastTruncatedHash
        XCTAssertTrue(shouldSkip, "Same hash as truncated hash should skip regeneration")
    }

    func testTruncatedHashGuardsDashboardRegeneration() {
        let orchestrator = NewsOrchestrator()

        orchestrator.dashboardLastTruncatedHash = "hash-D"
        let newHash = "hash-D"

        let shouldSkip = newHash == orchestrator.dashboardLastTruncatedHash
        XCTAssertTrue(shouldSkip, "Same hash as dashboard truncated hash should skip regeneration")
    }

    func testNewHashTriggersGenerationWhenDifferentFromBothHashes() {
        let orchestrator = NewsOrchestrator()

        orchestrator.popupLastHash = "hash-old-success"
        orchestrator.popupLastTruncatedHash = "hash-old-truncated"
        let newHash = "hash-new"

        let shouldGenerate = newHash != orchestrator.popupLastHash
            && newHash != orchestrator.popupLastTruncatedHash
        XCTAssertTrue(shouldGenerate, "New hash different from both should generate")
    }

    func testSuccessHashBlocksRegeneration() {
        let orchestrator = NewsOrchestrator()

        orchestrator.popupLastHash = "hash-success"
        orchestrator.popupLastTruncatedHash = nil
        let newHash = "hash-success"

        let shouldSkip = newHash == orchestrator.popupLastHash
        XCTAssertTrue(shouldSkip, "Same hash as success hash should skip regeneration")
    }

    func testConsecutiveTruncationCounterResetsOnSuccess() {
        let orchestrator = NewsOrchestrator()

        orchestrator.consecutiveTruncationCount = 2
        XCTAssertLessThan(orchestrator.consecutiveTruncationCount, orchestrator.maxConsecutiveTruncations)

        orchestrator.consecutiveTruncationCount = 0
        XCTAssertEqual(orchestrator.consecutiveTruncationCount, 0)
    }

    func testConsecutiveTruncationBlocksAtThreshold() {
        let orchestrator = NewsOrchestrator()

        orchestrator.consecutiveTruncationCount = orchestrator.maxConsecutiveTruncations
        let shouldBlock = orchestrator.consecutiveTruncationCount >= orchestrator.maxConsecutiveTruncations

        XCTAssertTrue(shouldBlock, "At threshold, auto-regeneration should be blocked")
    }

    func testClearCacheResetsConsecutiveTruncationCount() async {
        let orchestrator = NewsOrchestrator()

        orchestrator.consecutiveTruncationCount = 5
        await orchestrator.clearCache()

        XCTAssertEqual(orchestrator.consecutiveTruncationCount, 0)
    }
}

// MARK: - Dashboard Summary Needs Generation Tests

final class DashboardSummaryNeedsGenerationTests: XCTestCase {

    func testNeedsGenerationReturnsTrueForTruncated() {
        let panel = DashboardSummaryNeedsGenerationProbe()
        XCTAssertTrue(panel.needsGeneration(for: .truncated("partial text")))
    }

    func testNeedsGenerationReturnsTrueForIdle() {
        let panel = DashboardSummaryNeedsGenerationProbe()
        XCTAssertTrue(panel.needsGeneration(for: .idle))
    }

    func testNeedsGenerationReturnsTrueForError() {
        let panel = DashboardSummaryNeedsGenerationProbe()
        XCTAssertTrue(panel.needsGeneration(for: .error("test error")))
    }

    func testNeedsGenerationReturnsFalseForDone() {
        let panel = DashboardSummaryNeedsGenerationProbe()
        XCTAssertFalse(panel.needsGeneration(for: .done("complete text")))
    }

    func testNeedsGenerationReturnsFalseForFetching() {
        let panel = DashboardSummaryNeedsGenerationProbe()
        XCTAssertFalse(panel.needsGeneration(for: .fetching))
    }

    func testNeedsGenerationReturnsFalseForSummarizing() {
        let panel = DashboardSummaryNeedsGenerationProbe()
        XCTAssertFalse(panel.needsGeneration(for: .summarizing))
    }

    func testNeedsGenerationReturnsFalseForNoKey() {
        let panel = DashboardSummaryNeedsGenerationProbe()
        XCTAssertFalse(panel.needsGeneration(for: .noKey))
    }
}

private struct DashboardSummaryNeedsGenerationProbe {
    func needsGeneration(for state: AISummaryState) -> Bool {
        switch state {
        case .idle, .error, .truncated:
            return true
        default:
            return false
        }
    }
}

// MARK: - Prompt Topic Count Tests

final class PromptTopicCountTests: XCTestCase {

    func testTopicCountDefaultsToTwoToThree() {
        XCTAssertEqual(AISummaryService.promptTopicHint(range: 2...3), "2–3")
    }

    func testTopicCountFourToFiveForDashboard() {
        XCTAssertEqual(AISummaryService.promptTopicHint(range: 4...5), "4–5")
    }

    func testTopicCountSingleValueNoDash() {
        XCTAssertEqual(AISummaryService.promptTopicHint(range: 3...3), "3")
    }
}
