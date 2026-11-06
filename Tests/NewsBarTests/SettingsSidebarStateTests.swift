import XCTest
@testable import NewsBar

/// The settings sidebar toggle now lives outside SwiftUI, so its state is a
/// plain object with rules worth pinning down.
final class SettingsSidebarStateTests: XCTestCase {
    func testStartsExpanded() {
        let state = SettingsSidebarState()
        XCTAssertEqual(state.visibility, .all)
        XCTAssertFalse(state.isCollapsed)
        XCTAssertTrue(state.isCollapsible)
    }

    func testToggleCollapsesAndRestores() {
        let state = SettingsSidebarState()

        state.toggle()
        XCTAssertEqual(state.visibility, .detailOnly)
        XCTAssertTrue(state.isCollapsed)

        state.toggle()
        XCTAssertEqual(state.visibility, .all)
        XCTAssertFalse(state.isCollapsed)
    }

    /// The retro skin has no split view; the toolbar item must not move columns
    /// that are not there.
    func testToggleDoesNothingWhenCollapsingIsUnavailable() {
        let state = SettingsSidebarState()
        state.isCollapsible = false

        state.toggle()

        XCTAssertEqual(state.visibility, .all)
    }

    /// The AppKit toolbar item refreshes its label from this hook; a silent
    /// state change would leave "Hide Sidebar" on a collapsed sidebar.
    func testToggleNotifiesTheToolbarItem() {
        let state = SettingsSidebarState()
        var notifications = 0
        state.onChange = { notifications += 1 }

        state.toggle()
        XCTAssertEqual(notifications, 1)

        state.toggle()
        XCTAssertEqual(notifications, 2)
    }

    func testUnavailableToggleDoesNotNotify() {
        let state = SettingsSidebarState()
        state.isCollapsible = false
        var notifications = 0
        state.onChange = { notifications += 1 }

        state.toggle()

        XCTAssertEqual(notifications, 0)
    }
}
