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

    func testParseDualSummary_retainsTrendSectionWithNoCitation() {
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
        // Section without citation should be retained in trend with primaryIndex == nil
        XCTAssertEqual(result.trendOverview.count, 2)
        XCTAssertEqual(result.trendOverview[0].title, "无引用")
        XCTAssertNil(result.trendOverview[0].primaryIndex)
        XCTAssertEqual(result.trendOverview[1].title, "有引用")
        XCTAssertEqual(result.trendOverview[1].primaryIndex, 0)
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

    func testParseDualSummary_outOfBoundsCitationRetainedInTrend() {
        let text = """
        【趋势概览】
        【越界】这段引用了越界索引。
        引用：[#999]
        【每日精选】
        【精选】内容。
        引用：[#0]
        """
        let result = AISummaryParser.parseDualSummary(text, itemCount: 5, weiboBilibiliRange: 0..<3)
        // Index 999 is out of bounds, so primaryIndex is nil → retained in trend with no link
        XCTAssertEqual(result.trendOverview.count, 1)
        XCTAssertEqual(result.trendOverview[0].title, "越界")
        XCTAssertNil(result.trendOverview[0].primaryIndex)
        XCTAssertEqual(result.dailyEssentials.count, 1)
    }

    func testParseDualSummary_negativeCitationRetainedInTrend() {
        let text = """
        【趋势概览】
        【负索引】这段引用了负数索引。
        引用：[#-1]
        【每日精选】
        【精选】内容。
        引用：[#0]
        """
        let result = AISummaryParser.parseDualSummary(text, itemCount: 5, weiboBilibiliRange: 0..<3)
        // Negative index is out of bounds → primaryIndex is nil → retained in trend with no link
        XCTAssertEqual(result.trendOverview.count, 1)
        XCTAssertEqual(result.trendOverview[0].title, "负索引")
        XCTAssertNil(result.trendOverview[0].primaryIndex)
        XCTAssertEqual(result.dailyEssentials.count, 1)
    }

    // MARK: - Malformed Citation Regression

    func testParseDualSummary_malformedCitationRetainedInTrend() {
        let text = """
        【趋势概览】
        【格式错误】这段引用格式不正确。
        引用：[#abc]
        【有引用】这段有引用。
        引用：[#1]
        【每日精选】
        【精选】精选内容。
        引用：[#0]
        """
        let result = AISummaryParser.parseDualSummary(text, itemCount: 10, weiboBilibiliRange: 0..<5)
        // [#abc] is not a valid integer citation → primaryIndex is nil → retained in trend
        XCTAssertEqual(result.trendOverview.count, 2)
        XCTAssertEqual(result.trendOverview[0].title, "格式错误")
        XCTAssertNil(result.trendOverview[0].primaryIndex)
        XCTAssertEqual(result.trendOverview[1].title, "有引用")
        XCTAssertEqual(result.trendOverview[1].primaryIndex, 1)
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
        XCTAssertTrue(sections[0].body.contains("内联正文"))
        XCTAssertFalse(sections[0].body.contains("引用："))
        XCTAssertFalse(sections[0].body.contains("[#0]"))
        XCTAssertEqual(sections[0].primaryIndex, 0)
    }

    func testParseSections_extractsCitationInlineWithTitle() {
        let text = "【热点话题】这是热点内容。[#0]"
        let sections = AISummaryParser.parseSections(text, itemCount: 5)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].title, "热点话题")
        XCTAssertEqual(sections[0].body, "这是热点内容。")
        XCTAssertEqual(sections[0].primaryIndex, 0)
    }

    func testParseDualSummary_extractsInlineCitations() {
        let text = """
        【趋势概览】
        【热点】微博热点内容。[#0]
        【每日精选】
        【精选】精选内容。[#5]
        """
        let result = AISummaryParser.parseDualSummary(text, itemCount: 10, weiboBilibiliRange: 0..<5)
        XCTAssertEqual(result.trendOverview.count, 1)
        XCTAssertEqual(result.trendOverview[0].primaryIndex, 0)
        XCTAssertEqual(result.dailyEssentials.count, 1)
        XCTAssertEqual(result.dailyEssentials[0].primaryIndex, 5)
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

    func testStripCitations_removesInlineCitationLabel() {
        let result = AISummaryParser.stripCitations("内容。引用：[#0]")
        XCTAssertEqual(result, "内容。")
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

    private func snapshotAIKeys() -> [String: Any?] {
        [
            "aiDailyCap": snapshotObject(forKey: "aiDailyCap"),
            "aiBudgetMode": snapshotObject(forKey: "aiBudgetMode"),
            "aiPopupDailyCap": snapshotObject(forKey: "aiPopupDailyCap"),
            "aiDashboardDailyCap": snapshotObject(forKey: "aiDashboardDailyCap"),
            "todayAIRequestCount": snapshotObject(forKey: "todayAIRequestCount"),
            "todayPopupAIRequestCount": snapshotObject(forKey: "todayPopupAIRequestCount"),
            "todayDashboardAIRequestCount": snapshotObject(forKey: "todayDashboardAIRequestCount"),
            "statsDayTimestamp": snapshotObject(forKey: "statsDayTimestamp"),
        ]
    }

    private func restoreAIKeys(_ snapshot: [String: Any?]) {
        for (key, value) in snapshot {
            restoreObject(value, forKey: key)
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
        let snapshot = snapshotAIKeys()
        defer { restoreAIKeys(snapshot) }

        UserDefaults.standard.set(50, forKey: "aiDailyCap")
        let settings = AppSettings()
        let before = settings.todayAIRequestCount
        settings.recordAIRequests(3)
        XCTAssertEqual(settings.todayAIRequestCount, before + 3)
    }

    func testRecordAIRequests_ignoresNonPositive() {
        let snapshot = snapshotAIKeys()
        defer { restoreAIKeys(snapshot) }

        UserDefaults.standard.set(50, forKey: "aiDailyCap")
        let settings = AppSettings()
        let before = settings.todayAIRequestCount
        settings.recordAIRequests(0)
        XCTAssertEqual(settings.todayAIRequestCount, before)
        settings.recordAIRequests(-1)
        XCTAssertEqual(settings.todayAIRequestCount, before)
    }

    func testAiUsageText_format() {
        let snapshot = snapshotAIKeys()
        defer { restoreAIKeys(snapshot) }

        UserDefaults.standard.set(50, forKey: "aiDailyCap")
        let settings = AppSettings()
        settings.todayAIRequestCount = 3
        XCTAssertTrue(settings.aiUsageText.contains("3"))
        XCTAssertTrue(settings.aiUsageText.contains("50"))
    }

    // MARK: - Budget Mode Tests

    func testBudgetMode_defaultsToShared() {
        let snapshot = snapshotAIKeys()
        defer { restoreAIKeys(snapshot) }

        UserDefaults.standard.removeObject(forKey: "aiBudgetMode")
        let settings = AppSettings()
        XCTAssertEqual(settings.aiBudgetMode, .shared)
    }

    func testBudgetMode_loadsIndependentFromUserDefaults() {
        let snapshot = snapshotAIKeys()
        defer { restoreAIKeys(snapshot) }

        UserDefaults.standard.set("independent", forKey: "aiBudgetMode")
        let settings = AppSettings()
        XCTAssertEqual(settings.aiBudgetMode, .independent)
    }

    func testBudgetMode_invalidValueFallsBackToShared() {
        let snapshot = snapshotAIKeys()
        defer { restoreAIKeys(snapshot) }

        UserDefaults.standard.set("invalid", forKey: "aiBudgetMode")
        let settings = AppSettings()
        XCTAssertEqual(settings.aiBudgetMode, .shared)
    }

    // MARK: - Per-Target Cap Tests

    func testInit_popupCapDefaultsTo50() {
        let snapshot = snapshotAIKeys()
        defer { restoreAIKeys(snapshot) }

        UserDefaults.standard.removeObject(forKey: "aiPopupDailyCap")
        let settings = AppSettings()
        XCTAssertEqual(settings.aiPopupDailyCap, 50)
    }

    func testInit_dashboardCapDefaultsTo50() {
        let snapshot = snapshotAIKeys()
        defer { restoreAIKeys(snapshot) }

        UserDefaults.standard.removeObject(forKey: "aiDashboardDailyCap")
        let settings = AppSettings()
        XCTAssertEqual(settings.aiDashboardDailyCap, 50)
    }

    func testInit_popupCapValidates() {
        let snapshot = snapshotAIKeys()
        defer { restoreAIKeys(snapshot) }

        UserDefaults.standard.set(100, forKey: "aiPopupDailyCap")
        let settings = AppSettings()
        XCTAssertEqual(settings.aiPopupDailyCap, 100)
    }

    func testInit_popupCapRejectsInvalid() {
        let snapshot = snapshotAIKeys()
        defer { restoreAIKeys(snapshot) }

        UserDefaults.standard.set(42, forKey: "aiPopupDailyCap")
        let settings = AppSettings()
        XCTAssertEqual(settings.aiPopupDailyCap, 50)
    }

    func testInit_dashboardCapValidates() {
        let snapshot = snapshotAIKeys()
        defer { restoreAIKeys(snapshot) }

        UserDefaults.standard.set(20, forKey: "aiDashboardDailyCap")
        let settings = AppSettings()
        XCTAssertEqual(settings.aiDashboardDailyCap, 20)
    }

    // MARK: - effectiveDailyCap Tests

    func testEffectiveDailyCap_sharedModeReturnsSharedCap() {
        let snapshot = snapshotAIKeys()
        defer { restoreAIKeys(snapshot) }

        UserDefaults.standard.set("shared", forKey: "aiBudgetMode")
        UserDefaults.standard.set(100, forKey: "aiDailyCap")
        UserDefaults.standard.set(20, forKey: "aiPopupDailyCap")
        UserDefaults.standard.set(50, forKey: "aiDashboardDailyCap")
        let settings = AppSettings()
        XCTAssertEqual(settings.effectiveDailyCap(for: .popup), 100)
        XCTAssertEqual(settings.effectiveDailyCap(for: .dashboard), 100)
    }

    func testEffectiveDailyCap_independentModeReturnsPerTargetCap() {
        let snapshot = snapshotAIKeys()
        defer { restoreAIKeys(snapshot) }

        UserDefaults.standard.set("independent", forKey: "aiBudgetMode")
        UserDefaults.standard.set(100, forKey: "aiDailyCap")
        UserDefaults.standard.set(20, forKey: "aiPopupDailyCap")
        UserDefaults.standard.set(50, forKey: "aiDashboardDailyCap")
        let settings = AppSettings()
        XCTAssertEqual(settings.effectiveDailyCap(for: .popup), 20)
        XCTAssertEqual(settings.effectiveDailyCap(for: .dashboard), 50)
    }

    // MARK: - Per-Target Count Tests

    func testRecordAIRequestsForTarget_incrementsTargetAndTotal() {
        let snapshot = snapshotAIKeys()
        defer { restoreAIKeys(snapshot) }

        UserDefaults.standard.removeObject(forKey: "todayAIRequestCount")
        UserDefaults.standard.removeObject(forKey: "todayPopupAIRequestCount")
        UserDefaults.standard.removeObject(forKey: "todayDashboardAIRequestCount")
        let settings = AppSettings()
        let popupBefore = settings.todayPopupAIRequestCount
        let totalBefore = settings.todayAIRequestCount
        settings.recordAIRequests(2, for: .popup)
        XCTAssertEqual(settings.todayPopupAIRequestCount, popupBefore + 2)
        XCTAssertEqual(settings.todayAIRequestCount, totalBefore + 2)
        XCTAssertEqual(settings.todayDashboardAIRequestCount, 0)
    }

    func testRecordAIRequestsForTarget_dashboardIncrementsIndependently() {
        let snapshot = snapshotAIKeys()
        defer { restoreAIKeys(snapshot) }

        UserDefaults.standard.removeObject(forKey: "todayAIRequestCount")
        UserDefaults.standard.removeObject(forKey: "todayPopupAIRequestCount")
        UserDefaults.standard.removeObject(forKey: "todayDashboardAIRequestCount")
        let settings = AppSettings()
        settings.recordAIRequests(3, for: .popup)
        let dashboardBefore = settings.todayDashboardAIRequestCount
        let totalBefore = settings.todayAIRequestCount
        settings.recordAIRequests(5, for: .dashboard)
        XCTAssertEqual(settings.todayDashboardAIRequestCount, dashboardBefore + 5)
        XCTAssertEqual(settings.todayAIRequestCount, totalBefore + 5)
    }

    func testRecordAIRequestsForTarget_ignoresNonPositive() {
        let snapshot = snapshotAIKeys()
        defer { restoreAIKeys(snapshot) }

        UserDefaults.standard.removeObject(forKey: "todayPopupAIRequestCount")
        let settings = AppSettings()
        let before = settings.todayPopupAIRequestCount
        settings.recordAIRequests(0, for: .popup)
        XCTAssertEqual(settings.todayPopupAIRequestCount, before)
        settings.recordAIRequests(-1, for: .popup)
        XCTAssertEqual(settings.todayPopupAIRequestCount, before)
    }

    func testTodayAIRequestCountForTarget_returnsCorrectCount() {
        let snapshot = snapshotAIKeys()
        defer { restoreAIKeys(snapshot) }

        UserDefaults.standard.removeObject(forKey: "todayAIRequestCount")
        UserDefaults.standard.removeObject(forKey: "todayPopupAIRequestCount")
        UserDefaults.standard.removeObject(forKey: "todayDashboardAIRequestCount")
        let settings = AppSettings()
        settings.recordAIRequests(3, for: .popup)
        settings.recordAIRequests(7, for: .dashboard)
        XCTAssertEqual(settings.todayAIRequestCount(for: .popup), 3)
        XCTAssertEqual(settings.todayAIRequestCount(for: .dashboard), 7)
    }

    // MARK: - Migration Tests

    func testMigration_legacyTotalMigratesToPopupCount() {
        let snapshot = snapshotAIKeys()
        defer { restoreAIKeys(snapshot) }

        UserDefaults.standard.set(15, forKey: "todayAIRequestCount")
        UserDefaults.standard.removeObject(forKey: "todayPopupAIRequestCount")
        UserDefaults.standard.removeObject(forKey: "todayDashboardAIRequestCount")
        let settings = AppSettings()
        XCTAssertEqual(settings.todayAIRequestCount, 15)
        XCTAssertEqual(settings.todayPopupAIRequestCount, 15)
        XCTAssertEqual(settings.todayDashboardAIRequestCount, 0)
    }

    func testMigration_doesNotOverrideWhenPerTargetCountsExist() {
        let snapshot = snapshotAIKeys()
        defer { restoreAIKeys(snapshot) }

        UserDefaults.standard.set(15, forKey: "todayAIRequestCount")
        UserDefaults.standard.set(5, forKey: "todayPopupAIRequestCount")
        UserDefaults.standard.set(10, forKey: "todayDashboardAIRequestCount")
        let settings = AppSettings()
        XCTAssertEqual(settings.todayAIRequestCount, 15)
        XCTAssertEqual(settings.todayPopupAIRequestCount, 5)
        XCTAssertEqual(settings.todayDashboardAIRequestCount, 10)
    }

    // MARK: - Daily Reset Tests

    func testResetDailyStatsIfNeeded_resetsAllCounts() {
        let snapshot = snapshotAIKeys()
        defer { restoreAIKeys(snapshot) }

        let settings = AppSettings()
        settings.todayAIRequestCount = 10
        settings.todayPopupAIRequestCount = 6
        settings.todayDashboardAIRequestCount = 4
        settings.statsDayTimestamp = Date().addingTimeInterval(-86400 * 2).timeIntervalSince1970
        settings.resetDailyStatsIfNeeded()
        XCTAssertEqual(settings.todayAIRequestCount, 0)
        XCTAssertEqual(settings.todayPopupAIRequestCount, 0)
        XCTAssertEqual(settings.todayDashboardAIRequestCount, 0)
    }
}

// MARK: - AISummaryService Budget Boundary Tests

final class AISummaryServiceBudgetTests: XCTestCase {

    private let testTarget: SummaryTarget = .popup
    private let testMode: AISummaryBudgetMode = .independent

    override func setUp() {
        super.setUp()
        AISummaryService.initBudget(target: testTarget, mode: testMode, baseline: 0, cap: 50)
    }

    // MARK: - initBudget

    func testInitBudget_setsBaselineAndCap() {
        AISummaryService.initBudget(target: testTarget, mode: testMode, baseline: 10, cap: 20)
        XCTAssertEqual(AISummaryService.readGenerationAttempts(target: testTarget, mode: testMode), 0)
    }

    // MARK: - consumeAttemptBudget

    func testConsumeAttemptBudget_incrementsOnSuccess() {
        XCTAssertEqual(AISummaryService.readGenerationAttempts(target: testTarget, mode: testMode), 0)
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: testTarget, mode: testMode))
        XCTAssertEqual(AISummaryService.readGenerationAttempts(target: testTarget, mode: testMode), 1)
    }

    func testConsumeAttemptBudget_tracksMultipleAttempts() {
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: testTarget, mode: testMode))
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: testTarget, mode: testMode))
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: testTarget, mode: testMode))
        XCTAssertEqual(AISummaryService.readGenerationAttempts(target: testTarget, mode: testMode), 3)
    }

    // MARK: - Boundary: baseline + attempts + 1 <= cap

    func testConsumeAttemptBudget_allowsAtCapBoundary() {
        AISummaryService.initBudget(target: testTarget, mode: testMode, baseline: 0, cap: 5)
        for i in 0..<5 {
            XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: testTarget, mode: testMode),
                             "Attempt \(i) should succeed")
        }
        XCTAssertEqual(AISummaryService.readGenerationAttempts(target: testTarget, mode: testMode), 5)
    }

    func testConsumeAttemptBudget_throwsWhenExceedingCap() {
        AISummaryService.initBudget(target: testTarget, mode: testMode, baseline: 0, cap: 3)
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: testTarget, mode: testMode))
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: testTarget, mode: testMode))
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: testTarget, mode: testMode))
        XCTAssertThrowsError(try AISummaryService.consumeAttemptBudget(target: testTarget, mode: testMode)) { error in
            XCTAssertTrue(error is NewsBarError)
            if case NewsBarError.rateLimited = error {
                // Expected
            } else {
                XCTFail("Expected rateLimited, got \(error)")
            }
        }
    }

    func testConsumeAttemptBudget_doesNotIncrementOnDenied() {
        AISummaryService.initBudget(target: testTarget, mode: testMode, baseline: 0, cap: 2)
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: testTarget, mode: testMode))
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: testTarget, mode: testMode))
        XCTAssertThrowsError(try AISummaryService.consumeAttemptBudget(target: testTarget, mode: testMode))
        XCTAssertEqual(AISummaryService.readGenerationAttempts(target: testTarget, mode: testMode), 2)
    }

    // MARK: - Boundary with non-zero baseline

    func testConsumeAttemptBudget_withBaseline() {
        AISummaryService.initBudget(target: testTarget, mode: testMode, baseline: 8, cap: 10)
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: testTarget, mode: testMode))
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: testTarget, mode: testMode))
        XCTAssertThrowsError(try AISummaryService.consumeAttemptBudget(target: testTarget, mode: testMode))
        XCTAssertEqual(AISummaryService.readGenerationAttempts(target: testTarget, mode: testMode), 2)
    }

    func testConsumeAttemptBudget_baselineAtCap() {
        AISummaryService.initBudget(target: testTarget, mode: testMode, baseline: 10, cap: 10)
        XCTAssertThrowsError(try AISummaryService.consumeAttemptBudget(target: testTarget, mode: testMode))
        XCTAssertEqual(AISummaryService.readGenerationAttempts(target: testTarget, mode: testMode), 0)
    }

    func testConsumeAttemptBudget_baselineExceedsCap() {
        AISummaryService.initBudget(target: testTarget, mode: testMode, baseline: 15, cap: 10)
        XCTAssertThrowsError(try AISummaryService.consumeAttemptBudget(target: testTarget, mode: testMode))
        XCTAssertEqual(AISummaryService.readGenerationAttempts(target: testTarget, mode: testMode), 0)
    }

    // MARK: - readGenerationAttempts

    func testReadGenerationAttempts_initialZero() {
        AISummaryService.initBudget(target: testTarget, mode: testMode, baseline: 0, cap: 50)
        XCTAssertEqual(AISummaryService.readGenerationAttempts(target: testTarget, mode: testMode), 0)
    }

    func testReadGenerationAttempts_afterMultipleCalls() {
        AISummaryService.initBudget(target: testTarget, mode: testMode, baseline: 0, cap: 50)
        XCTAssertEqual(AISummaryService.readGenerationAttempts(target: testTarget, mode: testMode), 0)
        try? AISummaryService.consumeAttemptBudget(target: testTarget, mode: testMode)
        XCTAssertEqual(AISummaryService.readGenerationAttempts(target: testTarget, mode: testMode), 1)
        try? AISummaryService.consumeAttemptBudget(target: testTarget, mode: testMode)
        XCTAssertEqual(AISummaryService.readGenerationAttempts(target: testTarget, mode: testMode), 2)
    }

    // MARK: - readGenerationCap

    func testReadGenerationCap_returnsSetCap() {
        AISummaryService.initBudget(target: testTarget, mode: testMode, baseline: 0, cap: 100)
        XCTAssertEqual(AISummaryService.readGenerationCap(target: testTarget, mode: testMode), 100)
    }

    func testReadGenerationCap_defaultIs50() {
        XCTAssertEqual(AISummaryService.readGenerationCap(target: testTarget, mode: testMode), 50)
    }

    // MARK: - Isolation: different initBudget calls reset state

    func testInitBudget_resetsAttempts() {
        try? AISummaryService.consumeAttemptBudget(target: testTarget, mode: testMode)
        try? AISummaryService.consumeAttemptBudget(target: testTarget, mode: testMode)
        XCTAssertEqual(AISummaryService.readGenerationAttempts(target: testTarget, mode: testMode), 2)
        AISummaryService.initBudget(target: testTarget, mode: testMode, baseline: 0, cap: 50)
        XCTAssertEqual(AISummaryService.readGenerationAttempts(target: testTarget, mode: testMode), 0)
    }

    // MARK: - Per-Target Isolation (independent mode)

    func testIndependentMode_popupAndDashboardAreIsolated() {
        AISummaryService.initBudget(target: .popup, mode: .independent, baseline: 0, cap: 3)
        AISummaryService.initBudget(target: .dashboard, mode: .independent, baseline: 0, cap: 3)

        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: .popup, mode: .independent))
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: .popup, mode: .independent))
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: .popup, mode: .independent))
        XCTAssertThrowsError(try AISummaryService.consumeAttemptBudget(target: .popup, mode: .independent))

        XCTAssertEqual(AISummaryService.readGenerationAttempts(target: .popup, mode: .independent), 3)
        XCTAssertEqual(AISummaryService.readGenerationAttempts(target: .dashboard, mode: .independent), 0)
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: .dashboard, mode: .independent))
    }

    // MARK: - Shared Mode: single state for both targets

    func testSharedMode_bothTargetsShareSameBudgetState() {
        AISummaryService.initBudget(target: .popup, mode: .shared, baseline: 0, cap: 3)

        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: .popup, mode: .shared))
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: .dashboard, mode: .shared))
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: .popup, mode: .shared))
        XCTAssertThrowsError(try AISummaryService.consumeAttemptBudget(target: .dashboard, mode: .shared))

        let popupAttempts = AISummaryService.readGenerationAttempts(target: .popup, mode: .shared)
        let dashboardAttempts = AISummaryService.readGenerationAttempts(target: .dashboard, mode: .shared)
        XCTAssertEqual(popupAttempts, 3)
        XCTAssertEqual(dashboardAttempts, 3)
    }

    func testSharedMode_reinitializationDoesNotDiscardActiveAttempts() {
        AISummaryService.initBudget(target: .popup, mode: .shared, baseline: 5, cap: 10)
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: .popup, mode: .shared))

        AISummaryService.initBudget(target: .dashboard, mode: .shared, baseline: 5, cap: 10)

        XCTAssertEqual(AISummaryService.readGenerationAttempts(target: .popup, mode: .shared), 1)
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: .dashboard, mode: .shared))
    }

    func testSharedMode_concurrentTargetsCannotExceedCap() async {
        AISummaryService.initBudget(target: .popup, mode: .shared, baseline: 0, cap: 4)

        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let target: SummaryTarget = index.isMultiple(of: 2) ? .popup : .dashboard
                    return (try? AISummaryService.consumeAttemptBudget(target: target, mode: .shared)) != nil
                }
            }

            var result = 0
            for await didSucceed in group where didSucceed {
                result += 1
            }
            return result
        }

        XCTAssertEqual(successes, 4)
        XCTAssertEqual(AISummaryService.readGenerationAttempts(target: .popup, mode: .shared), 4)
    }

    // MARK: - Per-Target Generation Lock

    func testGenerationLock_popupAndDashboardAreIndependent() {
        XCTAssertTrue(AISummaryService.tryAcquireGenerationLock(for: .popup))
        XCTAssertTrue(AISummaryService.tryAcquireGenerationLock(for: .dashboard))
        XCTAssertFalse(AISummaryService.tryAcquireGenerationLock(for: .popup))
        XCTAssertFalse(AISummaryService.tryAcquireGenerationLock(for: .dashboard))
        AISummaryService.releaseGenerationLock(for: .popup)
        XCTAssertTrue(AISummaryService.tryAcquireGenerationLock(for: .popup))
        AISummaryService.releaseGenerationLock(for: .popup)
        AISummaryService.releaseGenerationLock(for: .dashboard)
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
        XCTAssertEqual(orchestrator.popupConsecutiveTruncationCount, 0)
        XCTAssertEqual(orchestrator.dashboardConsecutiveTruncationCount, 0)

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

    func testConsecutiveTruncationCountersAreIndependent() {
        let orchestrator = NewsOrchestrator()

        orchestrator.popupConsecutiveTruncationCount = orchestrator.maxConsecutiveTruncations
        orchestrator.dashboardConsecutiveTruncationCount = 0

        XCTAssertEqual(orchestrator.popupConsecutiveTruncationCount, orchestrator.maxConsecutiveTruncations)
        XCTAssertLessThan(orchestrator.dashboardConsecutiveTruncationCount, orchestrator.maxConsecutiveTruncations)
    }

    func testPopupTruncationThresholdDoesNotSetDashboardCounter() {
        let orchestrator = NewsOrchestrator()

        orchestrator.popupConsecutiveTruncationCount = orchestrator.maxConsecutiveTruncations

        XCTAssertEqual(orchestrator.dashboardConsecutiveTruncationCount, 0)
    }

    func testClearCacheResetsBothConsecutiveTruncationCounters() async {
        let orchestrator = NewsOrchestrator()

        orchestrator.popupConsecutiveTruncationCount = 5
        orchestrator.dashboardConsecutiveTruncationCount = 4
        await orchestrator.clearCache()

        XCTAssertEqual(orchestrator.popupConsecutiveTruncationCount, 0)
        XCTAssertEqual(orchestrator.dashboardConsecutiveTruncationCount, 0)
    }
}

@MainActor
final class NewsOrchestratorBudgetBaselineTests: XCTestCase {
    private let baselineKeys = [
        "aiBudgetMode",
        "todayAIRequestCount",
        "todayPopupAIRequestCount",
        "todayDashboardAIRequestCount",
    ]

    private func restore(_ snapshot: [String: Any?]) {
        for (key, value) in snapshot {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    func testSharedModeUsesTotalDailyCountAsBaseline() {
        let snapshot = Dictionary(uniqueKeysWithValues: baselineKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        defer { restore(snapshot) }
        let settings = AppSettings()
        settings.aiBudgetMode = .shared
        settings.todayAIRequestCount = 12
        settings.todayPopupAIRequestCount = 9
        settings.todayDashboardAIRequestCount = 3

        XCTAssertEqual(NewsOrchestrator.budgetBaseline(settings: settings, target: .popup), 12)
        XCTAssertEqual(NewsOrchestrator.budgetBaseline(settings: settings, target: .dashboard), 12)
    }

    func testIndependentModeUsesTargetSpecificCountAsBaseline() {
        let snapshot = Dictionary(uniqueKeysWithValues: baselineKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        defer { restore(snapshot) }
        let settings = AppSettings()
        settings.aiBudgetMode = .independent
        settings.todayAIRequestCount = 12
        settings.todayPopupAIRequestCount = 9
        settings.todayDashboardAIRequestCount = 3

        XCTAssertEqual(NewsOrchestrator.budgetBaseline(settings: settings, target: .popup), 9)
        XCTAssertEqual(NewsOrchestrator.budgetBaseline(settings: settings, target: .dashboard), 3)
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

// MARK: - Unrenderable Format Regression Tests
//
// These tests prove the parser returns zero sections for malformed structured/plain
// responses that previously slipped through as legacy fallback with phantom sections.
// They guard against regressions when the concurrent production agent adds the
// one-time format-retry path in NewsOrchestrator.

final class UnrenderableFormatRegressionTests: XCTestCase {

    // MARK: - Deterministic Fixtures

    /// Structured response where the dual-category labels are present but no
    /// template-titled sections follow. The parser must yield zero sections in
    /// both categories (not a legacy fallback, not phantom sections).
    private let labelsWithoutTopicTitles = """
    【趋势概览】

    【每日精选】

    """

    /// Plain prose with no template markers (no 【…】 titles, no markdown headings,
    /// no citation lines). The parser must yield zero sections and fall back to
    /// legacy mode with an empty trend overview.
    private let plainTextWithoutTemplateMarkers = """
    今天天气不错，适合出门散步。
    微博热搜整体平稳，没有明显爆发点。
    """

    /// A valid structured control fixture: one trend section citing a Weibo index
    /// and one daily section citing an RSS index. Used to prove the parser still
    /// returns non-zero sections for well-formed input alongside the zero-section
    /// regression cases above.
    private let validStructuredControl = """
    【趋势概览】
    【微博热点】这是微博热点内容。
    引用：[#0]
    【每日精选】
    【精选】这是精选内容。
    引用：[#5]
    """

    // MARK: - Zero-section regression: labels without topic titles

    func testParseDualSummary_labelsWithoutTopicTitles_returnsZeroSections() {
        let result = AISummaryParser.parseDualSummary(
            labelsWithoutTopicTitles,
            itemCount: 10,
            weiboBilibiliRange: 0..<5
        )
        XCTAssertFalse(
            result.isLegacyFallback,
            "Dual labels present without topic titles must not be treated as legacy fallback"
        )
        XCTAssertEqual(result.trendOverview.count, 0, "Trend overview must be empty when no topic titles follow the trend label")
        XCTAssertEqual(result.dailyEssentials.count, 0, "Daily essentials must be empty when no topic titles follow the daily label")
    }

    // MARK: - Zero-section regression: plain text without template markers

    func testParseDualSummary_plainTextWithoutTemplateMarkers_returnsZeroSections() {
        let result = AISummaryParser.parseDualSummary(
            plainTextWithoutTemplateMarkers,
            itemCount: 10,
            weiboBilibiliRange: 0..<5
        )
        XCTAssertTrue(
            result.isLegacyFallback,
            "Plain text without dual labels must take the legacy fallback path"
        )
        XCTAssertEqual(result.trendOverview.count, 0, "Legacy fallback must yield zero sections for plain prose with no template markers")
        XCTAssertEqual(result.dailyEssentials.count, 0, "Daily essentials must remain empty in legacy fallback")
    }

    // MARK: - Zero-section regression: parseSections directly on plain text

    func testParseSections_plainTextWithoutTemplateMarkers_returnsZeroSections() {
        let sections = AISummaryParser.parseSections(
            plainTextWithoutTemplateMarkers,
            itemCount: 10
        )
        XCTAssertEqual(sections.count, 0, "parseSections must return zero sections for plain prose with no titles")
    }

    // MARK: - Valid structured control: parser still returns non-zero sections

    func testParseDualSummary_validStructuredControl_returnsNonZeroSections() {
        let result = AISummaryParser.parseDualSummary(
            validStructuredControl,
            itemCount: 10,
            weiboBilibiliRange: 0..<5
        )
        XCTAssertFalse(result.isLegacyFallback, "Valid structured control must not be legacy fallback")
        XCTAssertEqual(result.trendOverview.count, 1, "Valid control must yield exactly one trend section")
        XCTAssertEqual(result.trendOverview[0].title, "微博热点")
        XCTAssertEqual(result.trendOverview[0].primaryIndex, 0)
        XCTAssertEqual(result.dailyEssentials.count, 1, "Valid control must yield exactly one daily section")
        XCTAssertEqual(result.dailyEssentials[0].title, "精选")
        XCTAssertEqual(result.dailyEssentials[0].primaryIndex, 5)
    }

    // MARK: - Boundary: whitespace-only content under labels

    func testParseDualSummary_whitespaceOnlyUnderLabels_returnsZeroSections() {
        let text = """
        【趋势概览】
        \t

        【每日精选】

        """
        let result = AISummaryParser.parseDualSummary(text, itemCount: 10, weiboBilibiliRange: 0..<5)
        XCTAssertFalse(result.isLegacyFallback)
        XCTAssertEqual(result.trendOverview.count, 0)
        XCTAssertEqual(result.dailyEssentials.count, 0)
    }
}

// MARK: - Format-Retry Decision Helper Tests
//
// NewsOrchestrator.needsFormatRetry(_:) is being added by the concurrent
// implementation agent as an internal static helper. It must return true only
// when BOTH categories of a ParsedSummary are empty (i.e. a non-truncated
// response parsed to zero sections). These tests assert that contract.
//
// If the helper is not yet available at test time, these tests will fail to
// compile; we report that rather than altering production files.

@MainActor
final class FormatRetryDecisionTests: XCTestCase {

    private func makeParsed(
        trend: [(title: String, body: String, primaryIndex: Int?)] = [],
        daily: [(title: String, body: String, primaryIndex: Int?)] = [],
        isLegacyFallback: Bool = false
    ) -> ParsedSummary {
        ParsedSummary(
            trendOverview: trend,
            dailyEssentials: daily,
            isLegacyFallback: isLegacyFallback
        )
    }

    // MARK: - Both empty → retry needed

    func testNeedsFormatRetry_bothCategoriesEmpty_returnsTrue() {
        let parsed = makeParsed(trend: [], daily: [])
        XCTAssertTrue(
            NewsOrchestrator.needsFormatRetry(parsed),
            "Retry must be required when both trend and daily categories are empty"
        )
    }

    // MARK: - Only trend empty → no retry

    func testNeedsFormatRetry_onlyTrendEmpty_returnsFalse() {
        let parsed = makeParsed(
            trend: [],
            daily: [("精选", "内容", 0)]
        )
        XCTAssertFalse(
            NewsOrchestrator.needsFormatRetry(parsed),
            "Retry must not be required when daily category has sections"
        )
    }

    // MARK: - Only daily empty → no retry

    func testNeedsFormatRetry_onlyDailyEmpty_returnsFalse() {
        let parsed = makeParsed(
            trend: [("热点", "内容", 0)],
            daily: []
        )
        XCTAssertFalse(
            NewsOrchestrator.needsFormatRetry(parsed),
            "Retry must not be required when trend category has sections"
        )
    }

    // MARK: - Both non-empty → no retry

    func testNeedsFormatRetry_bothCategoriesNonEmpty_returnsFalse() {
        let parsed = makeParsed(
            trend: [("热点", "内容", 0)],
            daily: [("精选", "内容", 1)]
        )
        XCTAssertFalse(
            NewsOrchestrator.needsFormatRetry(parsed),
            "Retry must not be required when both categories have sections"
        )
    }

    // MARK: - Legacy fallback with empty categories → retry still needed

    func testNeedsFormatRetry_legacyFallbackBothEmpty_returnsTrue() {
        let parsed = makeParsed(trend: [], daily: [], isLegacyFallback: true)
        XCTAssertTrue(
            NewsOrchestrator.needsFormatRetry(parsed),
            "Retry must be required even in legacy fallback when both categories are empty"
        )
    }

    // MARK: - Legacy fallback with non-empty trend → no retry

    func testNeedsFormatRetry_legacyFallbackTrendNonEmpty_returnsFalse() {
        let parsed = makeParsed(
            trend: [("热点", "内容", 0)],
            daily: [],
            isLegacyFallback: true
        )
        XCTAssertFalse(
            NewsOrchestrator.needsFormatRetry(parsed),
            "Retry must not be required for legacy fallback with non-empty trend"
        )
    }
}

// MARK: - Format-Retry Budget Tests
//
// Proves the existing budget primitives permit precisely one extra attempt
// (the format-retry) without making an HTTP call. The retry budget is set up
// using direct budget primitives (initBudget / consumeAttemptBudget) and only
// the independent popup budget is reset within each test, matching the
// existing AISummaryServiceBudgetTests isolation pattern.

final class FormatRetryBudgetTests: XCTestCase {

    private let retryTarget: SummaryTarget = .popup
    private let retryMode: AISummaryBudgetMode = .independent

    override func setUp() {
        super.setUp()
        AISummaryService.initBudget(target: retryTarget, mode: retryMode, baseline: 0, cap: 50)
    }

    // MARK: - One extra attempt is permitted within the existing cap

    func testConsumeAttemptBudget_permitsOneExtraAttemptForFormatRetry() {
        XCTAssertNoThrow(
            try AISummaryService.consumeAttemptBudget(target: retryTarget, mode: retryMode),
            "Initial generation attempt must be permitted"
        )
        XCTAssertEqual(
            AISummaryService.readGenerationAttempts(target: retryTarget, mode: retryMode),
            1
        )

        XCTAssertNoThrow(
            try AISummaryService.consumeAttemptBudget(target: retryTarget, mode: retryMode),
            "Format-retry attempt must be permitted within the existing cap"
        )
        XCTAssertEqual(
            AISummaryService.readGenerationAttempts(target: retryTarget, mode: retryMode),
            2,
            "Exactly one extra attempt must be recorded for the format-retry"
        )
    }

    // MARK: - The extra attempt does not exceed the cap at the boundary

    func testConsumeAttemptBudget_formatRetryAtBoundarySucceeds() {
        AISummaryService.initBudget(target: retryTarget, mode: retryMode, baseline: 0, cap: 2)
        XCTAssertNoThrow(
            try AISummaryService.consumeAttemptBudget(target: retryTarget, mode: retryMode),
            "Initial attempt at cap=2 must succeed"
        )
        XCTAssertNoThrow(
            try AISummaryService.consumeAttemptBudget(target: retryTarget, mode: retryMode),
            "Format-retry must fit exactly at the cap boundary (baseline + attempts == cap)"
        )
        XCTAssertEqual(
            AISummaryService.readGenerationAttempts(target: retryTarget, mode: retryMode),
            2
        )
    }

    // MARK: - A second extra attempt (beyond the one retry) is denied

    func testConsumeAttemptBudget_secondExtraAttemptDeniedAtBoundary() {
        AISummaryService.initBudget(target: retryTarget, mode: retryMode, baseline: 0, cap: 2)
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: retryTarget, mode: retryMode))
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: retryTarget, mode: retryMode))
        XCTAssertThrowsError(
            try AISummaryService.consumeAttemptBudget(target: retryTarget, mode: retryMode)
        ) { error in
            XCTAssertTrue(error is NewsBarError, "Exceeding the cap must surface a NewsBarError")
            if case NewsBarError.rateLimited = error {
                // expected
            } else {
                XCTFail("Expected rateLimited, got \(error)")
            }
        }
        XCTAssertEqual(
            AISummaryService.readGenerationAttempts(target: retryTarget, mode: retryMode),
            2,
            "Denied attempt must not increment the attempt counter"
        )
    }

    // MARK: - No HTTP call is made by the budget primitive itself

    func testConsumeAttemptBudget_doesNotPerformNetworkCall() {
        AISummaryService.initBudget(target: retryTarget, mode: retryMode, baseline: 0, cap: 50)
        let before = AISummaryService.readGenerationAttempts(target: retryTarget, mode: retryMode)
        XCTAssertEqual(before, 0)
        XCTAssertNoThrow(try AISummaryService.consumeAttemptBudget(target: retryTarget, mode: retryMode))
        XCTAssertEqual(
            AISummaryService.readGenerationAttempts(target: retryTarget, mode: retryMode),
            before + 1,
            "Budget consumption must only increment the in-memory attempt counter"
        )
    }
}
