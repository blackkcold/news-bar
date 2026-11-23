import XCTest
@testable import NewsBar

@MainActor
final class WorkspacePresentationStoreTests: XCTestCase {
    func testNewSubjectHasNoChosenSegment() {
        let store = WorkspacePresentationStore()
        XCTAssertFalse(store.hasChosenSegment(for: "subject-1"))
        XCTAssertEqual(store.segment(for: "subject-1"), .overview)
    }

    func testSetSegmentMarksChosen() {
        let store = WorkspacePresentationStore()
        store.setSegment(.research, for: "subject-1")
        XCTAssertTrue(store.hasChosenSegment(for: "subject-1"))
        XCTAssertEqual(store.segment(for: "subject-1"), .research)
    }

    func testSelectingCurrentSegmentMarksChosen() {
        let store = WorkspacePresentationStore()
        store.setSegment(.overview, for: "subject-1")
        XCTAssertTrue(store.hasChosenSegment(for: "subject-1"))
        XCTAssertEqual(store.segment(for: "subject-1"), .overview)
    }
}
