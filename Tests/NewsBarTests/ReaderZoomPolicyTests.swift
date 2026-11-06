import CoreGraphics
import XCTest
@testable import NewsBar

final class ReaderZoomPolicyTests: XCTestCase {
    func testFitScaleShrinksOnlyWhenThePageIsWiderThanThePanel() {
        XCTAssertEqual(
            ReaderZoomPolicy.fitScale(panelWidth: 760, contentWidth: 1_200),
            760.0 / 1_200.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ReaderZoomPolicy.fitScale(panelWidth: 760, contentWidth: 760),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ReaderZoomPolicy.fitScale(panelWidth: 760, contentWidth: 520),
            1,
            accuracy: 0.0001,
            "Fitting must never blow a narrow page up past its actual size"
        )
    }

    func testFitScaleNeverGoesBelowTheMinimum() {
        XCTAssertEqual(
            ReaderZoomPolicy.fitScale(panelWidth: 500, contentWidth: 2_000),
            ReaderZoomPolicy.minimumScale,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ReaderZoomPolicy.fitScale(panelWidth: 0, contentWidth: 1_200),
            1,
            accuracy: 0.0001
        )
    }

    func testFixedModesApplyTheirExactScale() {
        XCTAssertEqual(ReaderZoomPolicy.scale(for: .fit), 1, accuracy: 0.0001)
        XCTAssertEqual(ReaderZoomPolicy.scale(for: .actual), 1, accuracy: 0.0001)
        XCTAssertEqual(ReaderZoomPolicy.scale(for: .large), 1.25, accuracy: 0.0001)
    }

    func testCorrectiveScaleTakesOneMoreReductionButStopsAtTheMinimum() {
        XCTAssertEqual(
            ReaderZoomPolicy.correctiveScale(
                current: 0.9,
                viewportWidth: 844,
                contentWidth: 1_000
            ) ?? 0,
            0.7596,
            accuracy: 0.001
        )
        XCTAssertNil(
            ReaderZoomPolicy.correctiveScale(
                current: ReaderZoomPolicy.minimumScale,
                viewportWidth: 400,
                contentWidth: 1_200
            ),
            "The policy must not scale text below its floor"
        )
        XCTAssertNil(
            ReaderZoomPolicy.correctiveScale(
                current: 0.9,
                viewportWidth: 1_000,
                contentWidth: 900
            ),
            "A page that already fits needs no correction"
        )
    }

    func testNaturalWidthComesFromLayoutNotOverflowingMedia() {
        XCTAssertEqual(
            ReaderZoomPolicy.naturalContentWidth(layoutWidth: 1_200, viewportWidth: 760) ?? 0,
            1_200,
            accuracy: 0.1,
            "A fixed 1200 pt layout must be fitted into a 760 pt panel"
        )
        XCTAssertNil(
            ReaderZoomPolicy.naturalContentWidth(layoutWidth: 760, viewportWidth: 760),
            "A 1200 pt image inside a 760 pt article must not shrink the article text"
        )
        XCTAssertNil(
            ReaderZoomPolicy.naturalContentWidth(layoutWidth: 761, viewportWidth: 760),
            "A one-point difference is rounding, not a layout that needs scaling"
        )
        XCTAssertEqual(
            ReaderZoomPolicy.naturalContentWidth(layoutWidth: 761.5, viewportWidth: 760) ?? 0,
            761.5,
            accuracy: 0.1
        )
        XCTAssertNil(ReaderZoomPolicy.naturalContentWidth(layoutWidth: .nan, viewportWidth: 760))
    }

    func testPercentRoundsForDisplay() {
        XCTAssertEqual(ReaderZoomPolicy.percent(0.6333), 63)
        XCTAssertEqual(ReaderZoomPolicy.percent(1), 100)
        XCTAssertEqual(ReaderZoomPolicy.percent(1.25), 125)
    }

    func testZoomModePersistsAsAString() {
        for mode in ReaderZoomMode.allCases {
            XCTAssertEqual(ReaderZoomMode(rawValue: mode.rawValue), mode)
        }
        XCTAssertNil(ReaderZoomMode(rawValue: "mobile"))
    }

    func testPageZoomModeDefaultsToFitAndPersists() {
        TestIsolation.defaults.removeObject(forKey: "readerPageZoomMode")
        let settings = AppSettings()
        XCTAssertEqual(settings.readerPageZoomMode, ReaderZoomMode.fit.rawValue)

        settings.readerPageZoomMode = ReaderZoomMode.large.rawValue
        let restored = AppSettings()
        XCTAssertEqual(restored.readerPageZoomMode, ReaderZoomMode.large.rawValue)

        TestIsolation.defaults.set("mobile", forKey: "readerPageZoomMode")
        XCTAssertEqual(AppSettings().readerPageZoomMode, ReaderZoomMode.fit.rawValue)

        TestIsolation.defaults.removeObject(forKey: "readerPageZoomMode")
    }
}
