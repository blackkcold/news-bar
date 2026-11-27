import AppKit
import XCTest
@testable import NewsBar

/// The popup's height rules and its reading body, kept separate from the
/// rendering suite so a failure names the rule instead of a snapshot diff.
final class ResearchPanelSizingTests: XCTestCase {

    // MARK: - Frame height

    func testShortReportGetsTheFloorInsteadOfADialogSizedWindow() {
        // A report whose content cannot fill a page still gets a page.
        let height = ResearchPanelSizing.frameHeight(contentHeight: 200, screenVisibleHeight: 1_000)
        XCTAssertEqual(height, ResearchPanelSizing.minimumFrameHeight)
    }

    func testTypicalReportShrinksBelowTheOldFixedWindow() {
        // The real median overview is ~296 characters, which lands near 530pt
        // of content. The panel used to be a fixed 760.
        let content: CGFloat = 530
        let height = ResearchPanelSizing.frameHeight(contentHeight: content, screenVisibleHeight: 1_000)
        XCTAssertEqual(height, content + ResearchPanelSizing.titlebarHeight + ResearchPanelSizing.breathingRoom)
        XCTAssertLessThan(height, 760, "the fixed window left about 200pt empty")
        XCTAssertGreaterThan(height, ResearchPanelSizing.minimumFrameHeight)
    }

    func testLongReportStopsAtTheScreenFractionAndThenScrolls() {
        let screen: CGFloat = 1_000
        let ceiling = screen * ResearchPanelSizing.maximumFrameFraction
        let height = ResearchPanelSizing.frameHeight(contentHeight: 5_000, screenVisibleHeight: screen)
        XCTAssertEqual(height, ceiling, accuracy: 0.001)
        XCTAssertLessThan(height, screen, "the panel must leave the menu bar and dock visible")
    }

    func testCeilingNeverFallsBelowTheFloor() {
        // A tiny screen must not produce a frame shorter than the readable
        // minimum, or the panel would be unusable rather than merely tight.
        let height = ResearchPanelSizing.frameHeight(contentHeight: 5_000, screenVisibleHeight: 400)
        XCTAssertEqual(height, ResearchPanelSizing.minimumFrameHeight)
    }

    func testTitlebarIsCountedOnceNotTwice() {
        // The old code copied the SwiftUI content floor straight into
        // `contentMinSize`, which clipped 28pt of content. The arithmetic adds
        // the bar exactly once, so a frame built from the content floor must be
        // one title bar above it, never two.
        let content = ResearchPanelSizing.minimumFrameHeight
            - ResearchPanelSizing.titlebarHeight
        let height = ResearchPanelSizing.frameHeight(contentHeight: content, screenVisibleHeight: 2_000)
        XCTAssertEqual(
            height,
            content + ResearchPanelSizing.titlebarHeight + ResearchPanelSizing.breathingRoom,
            accuracy: 0.001
        )
        XCTAssertLessThan(
            height,
            content + ResearchPanelSizing.titlebarHeight * 2,
            "a doubled title bar would mean the bar is being added twice"
        )
    }

    func testWindowContentFloorMatchesTheSizingRules() {
        // `contentMinSize` is expressed in content coordinates, so it must be
        // the frame floor minus the title bar. Feeding it the frame floor would
        // make the window's real minimum 28pt taller than the rules allow.
        XCTAssertEqual(
            TransientResearchReportView.minimumContentHeight,
            ResearchPanelSizing.minimumFrameHeight - ResearchPanelSizing.titlebarHeight,
            accuracy: 0.001
        )
    }

    // MARK: - Growth direction

    func testHeightChangeKeepsTheTopEdgeFixed() {
        let frame = CGRect(x: 100, y: 200, width: 620, height: 560)
        let grown = ResearchPanelSizing.originKeepingTop(currentFrame: frame, newHeight: 700)
        XCTAssertEqual(grown.y, frame.maxY - 700, accuracy: 0.001)
        XCTAssertEqual(grown.x, frame.origin.x)
        // The bottom edge moves down; the top stays where the reader's eye is.
        XCTAssertEqual(grown.y + 700, frame.maxY, accuracy: 0.001)

        let shrunk = ResearchPanelSizing.originKeepingTop(currentFrame: frame, newHeight: 480)
        XCTAssertEqual(shrunk.y + 480, frame.maxY, accuracy: 0.001)
    }

    // MARK: - Reading body

    func testPopupBodyIsTheOverviewAndTheSummaryStaysOutOfIt() {
        let presentation = ResearchReportPresentation.popup
        XCTAssertTrue(presentation.usesOverviewAsBody)
        XCTAssertFalse(
            presentation.showsOverviewInConclusion,
            "the overview is the body now; a disclosure for it would repeat the same copy"
        )
        // The workbench keeps the summary as its body: it is a management
        // surface where the one-line answer is what people scan for.
        XCTAssertFalse(ResearchReportPresentation.workspace.usesOverviewAsBody)
    }

    /// The paragraph layout belongs to the popup. Both hosts render this view,
    /// so a change here reaches the workbench as well — and the workbench's
    /// summary briefly lost its own line spacing to exactly that. The switch
    /// makes the choice explicit instead of implied by the body text.
    func testOnlyThePopupSplitsTheBodyIntoParagraphs() {
        XCTAssertTrue(ResearchReportPresentation.popup.splitsBodyIntoParagraphs)
        XCTAssertFalse(
            ResearchReportPresentation.workspace.splitsBodyIntoParagraphs,
            "the workbench shares this view and must keep its single-Text body"
        )
    }

    func testPopupReaderSectionsDoNotDependOnTheBodyChoice() {
        // Swapping the body must not add or remove a chapter.
        var report = BurstResearch(summary: "一句话。", overview: "一段背景。")
        report.timeline = [TimelineNode(date: "2026-11-01", title: "节点", detail: "细节")]
        let popup = ResearchReportReader(
            report: report, contextID: nil, onOpenURL: { _, _ in }, presentation: .popup
        )
        let workspace = ResearchReportReader(report: report, contextID: nil, onOpenURL: { _, _ in })
        XCTAssertEqual(popup.sections, workspace.sections)
    }

    // MARK: - Caption width

    func testCaptionTextWidthFitsARealTitleWithoutClipping() {
        // Real titles run 11–15 Chinese characters. At 11pt a wide glyph is
        // about 11pt, so 118pt holds roughly 10–11 of them plus the ellipsis:
        // enough that the common title is not cut at all, and the longest ends
        // in an ellipsis rather than a chopped glyph.
        let width = ResearchTimelineStrip.captionTextWidth
        let widestGlyph: CGFloat = 11
        XCTAssertGreaterThan(width / widestGlyph, 9, "too narrow: most titles would ellipsize")
        XCTAssertLessThan(width, 132, "wider than the old cap, which already overflowed the row")

        // Three captions, their horizontal padding, the state dot, the spacings
        // and the badge slot must still fit a 620pt window's 584pt of content.
        let perCaption = width + 18 + 6 + 5
        let row = perCaption * 3 + 8 * 2 + 6 + 40
        XCTAssertLessThan(row, 584, "three captions plus the badge must fit the narrow window")
    }
}
