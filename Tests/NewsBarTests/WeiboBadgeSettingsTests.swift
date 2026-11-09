import XCTest
@testable import NewsBar

@MainActor
final class WeiboBadgeSettingsTests: XCTestCase {
    private let menuBarKey = "weiboMonitorMenuBarBadgeEnabled"
    private let dashboardKey = "weiboMonitorDashboardBadgeEnabled"

    func testBadgeSwitchesDefaultOnAndPersistIndependently() {
        let defaults = TestIsolation.defaults
        defaults.removeObject(forKey: menuBarKey)
        defaults.removeObject(forKey: dashboardKey)
        defer {
            defaults.removeObject(forKey: menuBarKey)
            defaults.removeObject(forKey: dashboardKey)
        }

        let initial = AppSettings()
        XCTAssertTrue(initial.weiboMonitorMenuBarBadgeEnabled)
        XCTAssertTrue(initial.weiboMonitorDashboardBadgeEnabled)

        initial.weiboMonitorMenuBarBadgeEnabled = false
        initial.weiboMonitorDashboardBadgeEnabled = true

        let reloaded = AppSettings()
        XCTAssertFalse(reloaded.weiboMonitorMenuBarBadgeEnabled)
        XCTAssertTrue(reloaded.weiboMonitorDashboardBadgeEnabled)

        reloaded.weiboMonitorMenuBarBadgeEnabled = true
        reloaded.weiboMonitorDashboardBadgeEnabled = false

        let final = AppSettings()
        XCTAssertTrue(final.weiboMonitorMenuBarBadgeEnabled)
        XCTAssertFalse(final.weiboMonitorDashboardBadgeEnabled)
    }
}
