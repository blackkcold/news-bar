import XCTest
@testable import NewsBar

/// Covers the packaged-app verification hook as a pure function. These tests
/// never launch the app, initialize AppKit, touch `AppDelegate`/stores, or read
/// user data: the probe is injected and output is captured in memory.
final class RecommendationGuideDiagnosticTests: XCTestCase {
    private let executable = "/Applications/NewsBar.app/Contents/MacOS/NewsBar"

    func testOrdinaryLaunchReturnsNilWithoutReadingGuideOrPrinting() {
        var lines: [String] = []
        var reads = 0
        let probe = RecommendationGuideDiagnostic.Probe(
            isAvailable: { reads += 1; return true },
            sectionCount: { _ in reads += 1; return 8 }
        )

        let status = RecommendationGuideDiagnostic.runIfRequested(
            arguments: [executable],
            output: { lines.append($0) },
            probe: probe
        )

        XCTAssertNil(status)
        XCTAssertEqual(reads, 0, "normal startup must not read the guide")
        XCTAssertTrue(lines.isEmpty, "normal startup must not print diagnostics")
    }

    func testRequestedFlagReportsAvailableGuideAndSucceeds() {
        var lines: [String] = []
        var requestedLanguages: [AppLanguage] = []
        let probe = RecommendationGuideDiagnostic.Probe(
            isAvailable: { true },
            sectionCount: { language in
                requestedLanguages.append(language)
                return 8
            }
        )

        let status = RecommendationGuideDiagnostic.runIfRequested(
            arguments: [executable, RecommendationGuideDiagnostic.flag],
            output: { lines.append($0) },
            probe: probe
        )

        XCTAssertEqual(status, 0)
        XCTAssertEqual(requestedLanguages, [.zh, .en])
        XCTAssertEqual(lines, [
            "recommendation-guide available=true",
            "recommendation-guide sections zh=8 en=8",
            "recommendation-guide result=ok",
        ])
    }

    func testUnavailableGuideFailsWithoutEmittingUserContent() {
        var lines: [String] = []
        var sectionReads = 0
        let probe = RecommendationGuideDiagnostic.Probe(
            isAvailable: { false },
            sectionCount: { _ in sectionReads += 1; return 0 }
        )

        let status = RecommendationGuideDiagnostic.runIfRequested(
            arguments: [executable, RecommendationGuideDiagnostic.flag],
            output: { lines.append($0) },
            probe: probe
        )

        XCTAssertEqual(status, 1)
        XCTAssertEqual(sectionReads, 0, "sections are meaningless when the bundle is unavailable")
        XCTAssertEqual(lines, [
            "recommendation-guide available=false",
            "recommendation-guide result=unavailable",
        ])
    }

    func testUnexpectedSectionCountFails() {
        var lines: [String] = []
        let probe = RecommendationGuideDiagnostic.Probe(
            isAvailable: { true },
            sectionCount: { $0 == .zh ? 8 : 7 }
        )

        let status = RecommendationGuideDiagnostic.runIfRequested(
            arguments: [executable, RecommendationGuideDiagnostic.flag],
            output: { lines.append($0) },
            probe: probe
        )

        XCTAssertEqual(status, 1)
        XCTAssertEqual(lines, [
            "recommendation-guide available=true",
            "recommendation-guide sections zh=8 en=7",
            "recommendation-guide result=unexpected-section-count",
        ])
    }

    func testExpectedSectionCountMatchesShippedGuideContract() {
        XCTAssertEqual(RecommendationGuideDiagnostic.expectedSectionCount, 8)
        XCTAssertEqual(RecommendationGuideDocument.requiredSectionIDs.count, 8)
    }

    /// Pins the default (`output:`-only) overload to the live guide API: the
    /// diagnostic must never gain its own resource loading or app state.
    func testDefaultOverloadUsesLiveProbe() {
        let probe = RecommendationGuideDiagnostic.Probe.live
        XCTAssertEqual(probe.isAvailable(), RecommendationGuide.isAvailable)
        for language in AppLanguage.allCases {
            XCTAssertEqual(
                probe.sectionCount(language),
                RecommendationGuide.sections(language: language).count
            )
        }
    }
}
