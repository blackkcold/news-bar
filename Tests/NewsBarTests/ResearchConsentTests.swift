import XCTest
@testable import NewsBar

final class ResearchConsentTests: XCTestCase {
    func testConsentVersionPolicy() {
        XCTAssertTrue(ResearchConsent.requiresConsent(storedVersion: 0))
        XCTAssertFalse(ResearchConsent.requiresConsent(storedVersion: 1))
        XCTAssertFalse(ResearchConsent.requiresConsent(storedVersion: 2))
    }

    func testDisclosureListsEnabledProvidersAndAIModel() {
        let text = ResearchConsent.disclosure(
            providers: [.tavily, .brave],
            providerName: "DeepSeek",
            model: "deepseek-chat",
            language: .zh
        )

        XCTAssertTrue(text.contains("Tavily"))
        XCTAssertTrue(text.contains("Brave"))
        XCTAssertTrue(text.contains("DeepSeek"))
        XCTAssertTrue(text.contains("deepseek-chat"))
        XCTAssertFalse(text.contains("Firecrawl"))
        XCTAssertTrue(text.contains("不构成事实裁定"))
    }

    func testEnglishDisclosureUsesEnglishCopy() {
        let text = ResearchConsent.disclosure(
            providers: [.firecrawl],
            providerName: "MiniMax",
            model: "MiniMax-M2",
            language: .en
        )

        XCTAssertTrue(text.contains("Firecrawl"))
        XCTAssertTrue(text.contains("MiniMax-M2"))
        XCTAssertTrue(text.contains("not fact adjudication"))
    }

    func testAutomaticResearchDisclosureCoversTriageData() {
        let chinese = L10n.string("research.auto.footer", language: .zh)
        let english = L10n.string("research.auto.footer", language: .en)

        XCTAssertTrue(chinese.contains("候选标题"))
        XCTAssertTrue(chinese.contains("历史研究标题"))
        XCTAssertTrue(english.contains("candidate titles"))
        XCTAssertTrue(english.contains("previous research titles"))
    }

    @MainActor
    func testClearingInterestDataClearsLastAutomaticDecision() async throws {
        let settings = AppSettings()
        let original = settings.researchLastAutomaticDecision
        defer { settings.updateResearchLastAutomaticDecision(original) }
        settings.updateResearchLastAutomaticDecision("旧的私人主题")
        let directory = try researchTestDirectory()
        let controller = InterestController(store: LocalInterestStore(fileURL: directory.appendingPathComponent("interest.sqlite")))

        let success = await controller.clear(keepBookmarks: false)

        XCTAssertTrue(success)
        XCTAssertNil(settings.researchLastAutomaticDecision)
        XCTAssertNil(UserDefaults.standard.string(forKey: "researchLastAutomaticDecision"))
    }

    func testMissingProviderAndModelHaveReadableFallbacks() {
        let text = ResearchConsent.disclosure(
            providers: [],
            providerName: "DeepSeek",
            model: "   ",
            language: .zh
        )

        XCTAssertTrue(text.contains("未启用任何搜索服务"))
        XCTAssertTrue(text.contains("未选择模型"))
    }

    @MainActor
    func testEnabledProvidersFollowFailoverOrder() {
        let settings = AppSettings()
        let previous = settings.researchSearchProviders
        defer { settings.researchSearchProviders = previous }

        settings.researchSearchProviders = ["brave", "tavily"]
        XCTAssertEqual(ResearchConsent.enabledProviders(settings), [.tavily, .brave])
    }
}
