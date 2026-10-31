import XCTest
@testable import NewsBar

/// The price sheet is pure mapping over the generated catalog: these tests pin
/// the parts a reader would notice if they broke (which models appear, which
/// column the plan changes, how a missing price reads).
final class OpenCodePriceSheetTests: XCTestCase {
    // MARK: - Catalog shape

    func testGoListsEveryModelIncludingTheFreeOnes() {
        XCTAssertEqual(
            OpenCodePriceSheet.rows(plan: .go).count,
            OpenCodePriceCatalog.go.count
        )
        XCTAssertFalse(
            OpenCodePriceSheet.rows(plan: .go).filter(\.isFree).isEmpty,
            "Go's promotional models are callable, so they belong in the table"
        )
    }

    func testZenDropsTheFreeModelsThirdPartyClientsCannotCall() {
        let expected = OpenCodePriceCatalog.zen.filter { !$0.isFree }.count
        let rows = OpenCodePriceSheet.rows(plan: .zen)
        XCTAssertEqual(rows.count, expected)
        XCTAssertTrue(rows.allSatisfy { !$0.isFree })
        XCTAssertGreaterThan(rows.count, 50, "the Zen catalog should not collapse to a handful of rows")
    }

    /// The generator fails the build when a paid Go model has no documented
    /// allowance, so an "unlimited" here would mean a silent data regression.
    func testEveryPaidGoModelCarriesAllThreeTierAllowances() throws {
        for entry in OpenCodePriceCatalog.go where !entry.isFree {
            let allowance = try XCTUnwrap(entry.allowance, "\(entry.model) has no allowance")
            XCTAssertNotNil(allowance.go, "\(entry.model) has no Go allowance")
            XCTAssertNotNil(allowance.goPlus, "\(entry.model) has no Go Plus allowance")
            XCTAssertNotNil(allowance.goTeams, "\(entry.model) has no Teams allowance")
        }
    }

    // MARK: - Plans

    func testGoTiersReadTheirOwnAllowanceField() throws {
        func allowance(_ plan: OpenCodePricingPlan, _ model: String) throws -> OpenCodeAllowance {
            try XCTUnwrap(
                OpenCodePriceSheet.rows(plan: plan).first { $0.model == model }?.allowance
            )
        }

        // Documented plan terms for DeepSeek V4.1 Flash.
        XCTAssertEqual(try allowance(.go, "deepseek-v4.1-flash"), .monthlyUSD(100))
        XCTAssertEqual(try allowance(.goPlus, "deepseek-v4.1-flash"), .monthlyUSD(200))
        XCTAssertEqual(try allowance(.teams, "deepseek-v4.1-flash"), .monthlyUSD(105))
    }

    func testFreeGoModelsAreUnlimitedAndZenIsMetered() {
        let free = OpenCodePriceSheet.rows(plan: .go).filter(\.isFree)
        XCTAssertFalse(free.isEmpty)
        XCTAssertTrue(free.allSatisfy { $0.allowance == .unlimited })
        XCTAssertTrue(OpenCodePriceSheet.rows(plan: .zen).allSatisfy { $0.allowance == .metered })
    }

    // MARK: - Ordering and search

    func testCurrentModelFloatsToTheTopAndTheRestStayAlphabetical() {
        let rows = OpenCodePriceSheet.rows(plan: .go, currentModel: "glm-5.3-flash")
        XCTAssertEqual(rows.first?.model, "glm-5.3-flash")
        XCTAssertTrue(rows.first?.isCurrent == true)
        XCTAssertEqual(rows.filter(\.isCurrent).count, 1)

        let rest = rows.dropFirst().map(\.model)
        XCTAssertEqual(rest, rest.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    func testPinnedSnapshotStillMarksItsModelCurrent() {
        let rows = OpenCodePriceSheet.rows(plan: .go, currentModel: "glm-5.3-flash:2026-10-01")
        XCTAssertTrue(rows.first?.isCurrent == true)
        XCTAssertEqual(rows.first?.model, "glm-5.3-flash")
    }

    func testSearchIsCaseInsensitiveAndTrimsWhitespace() {
        let deepSeek = OpenCodePriceSheet.rows(plan: .go, query: "DEEPSEEK")
        XCTAssertFalse(deepSeek.isEmpty)
        XCTAssertTrue(deepSeek.allSatisfy { $0.model.lowercased().contains("deepseek") })
        XCTAssertEqual(
            OpenCodePriceSheet.rows(plan: .go, query: "  deepseek  ").count,
            deepSeek.count
        )
        XCTAssertTrue(OpenCodePriceSheet.rows(plan: .go, query: "no-such-model").isEmpty)
    }

    func testSearchKeepsTheCurrentModelHighlight() {
        let rows = OpenCodePriceSheet.rows(
            plan: .go,
            query: "deepseek",
            currentModel: "deepseek-v4-pro"
        )
        XCTAssertEqual(rows.first?.model, "deepseek-v4-pro")
    }

    // MARK: - Formatting

    func testPerMillionPricesKeepThreeSignificantDecimals() {
        XCTAssertEqual(OpenCodePriceSheet.decimal(0), "0")
        XCTAssertEqual(OpenCodePriceSheet.decimal(0.006), "0.006")
        XCTAssertEqual(OpenCodePriceSheet.decimal(0.15), "0.15")
        XCTAssertEqual(OpenCodePriceSheet.decimal(1.2), "1.2")
        XCTAssertEqual(OpenCodePriceSheet.decimal(50), "50")
    }

    func testUnpublishedPriceReadsAsADashInsteadOfZero() {
        XCTAssertEqual(OpenCodePriceSheet.price(nil, currency: .usd), "—")
        XCTAssertEqual(OpenCodePriceSheet.price(0, currency: .usd), "$0")
    }

    func testCurrencySwitchConvertsWithTheAppRate() {
        XCTAssertEqual(OpenCodePriceSheet.money(0.3, currency: .usd), "$0.3")
        XCTAssertEqual(OpenCodePriceSheet.money(0.3, currency: .cny), "¥2.16")
        XCTAssertEqual(OpenCodePriceSheet.money(15, currency: .cny), "¥108")
    }

    func testAllowanceTextCoversEveryKind() {
        XCTAssertEqual(
            OpenCodePriceSheet.allowanceText(.monthlyUSD(100), currency: .usd, language: .zh),
            "$100"
        )
        XCTAssertEqual(
            OpenCodePriceSheet.allowanceText(.unlimited, currency: .usd, language: .zh),
            "不限"
        )
        XCTAssertEqual(
            OpenCodePriceSheet.allowanceText(.metered, currency: .usd, language: .en),
            "Metered"
        )
    }

    // MARK: - Copy

    func testPricingCopyExistsInBothLanguages() {
        let keys = [
            "settings.pricing.title",
            "settings.pricing.subtitle",
            "settings.pricing.count",
            "settings.pricing.countFiltered",
            "settings.pricing.currency",
            "settings.pricing.search",
            "settings.pricing.search.clear",
            "settings.pricing.col.model",
            "settings.pricing.col.input",
            "settings.pricing.col.output",
            "settings.pricing.col.cacheRead",
            "settings.pricing.col.allowance",
            "settings.pricing.col.billing",
            "settings.pricing.allowance.unlimited",
            "settings.pricing.allowance.metered",
            "settings.pricing.current",
            "settings.pricing.empty",
            "settings.pricing.row.accessibility",
            "settings.pricing.note.source",
            "settings.pricing.note.go",
            "settings.pricing.note.peak",
            "settings.pricing.note.zen",
            "settings.pricing.console",
            "settings.pricing.done",
            "ai.pricing.summary",
            "ai.pricing.open"
        ]
        for key in keys {
            XCTAssertNotEqual(L10n.string(key, language: .zh), key, "missing zh copy for \(key)")
            XCTAssertNotEqual(L10n.string(key, language: .en), key, "missing en copy for \(key)")
        }

        for plan in OpenCodePricingPlan.allCases {
            XCTAssertNotEqual(L10n.string(plan.titleKey, language: .zh), plan.titleKey)
            XCTAssertNotEqual(L10n.string(plan.titleKey, language: .en), plan.titleKey)
        }
    }
}
