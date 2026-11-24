import XCTest
@testable import NewsBar

@MainActor
final class WeiboBadgeSettingsTests: XCTestCase {
    private let menuBarKey = "weiboMonitorMenuBarBadgeEnabled"
    private let dashboardKey = "weiboMonitorDashboardBadgeEnabled"
    private let masterKey = "weiboMonitorBadgeEnabled"
    private let popoverKey = "weiboMonitorPopoverBadgeEnabled"

    private var allKeys: [String] { [menuBarKey, dashboardKey, masterKey, popoverKey] }

    func testBadgeSwitchesDefaultOnAndPersistIndependently() {
        let defaults = TestIsolation.defaults
        allKeys.forEach(defaults.removeObject(forKey:))
        defer { allKeys.forEach(defaults.removeObject(forKey:)) }

        let initial = AppSettings()
        XCTAssertTrue(initial.weiboMonitorMenuBarBadgeEnabled)
        XCTAssertTrue(initial.weiboMonitorDashboardBadgeEnabled)
        XCTAssertTrue(initial.weiboMonitorBadgeEnabled)
        XCTAssertTrue(initial.weiboMonitorPopoverBadgeEnabled)
        XCTAssertTrue(initial.showsWeiboMenuBarBadge)
        XCTAssertTrue(initial.showsWeiboDashboardBadge)
        XCTAssertTrue(initial.showsWeiboPopoverBadge)

        initial.weiboMonitorMenuBarBadgeEnabled = false
        initial.weiboMonitorDashboardBadgeEnabled = true
        initial.weiboMonitorPopoverBadgeEnabled = false

        let reloaded = AppSettings()
        XCTAssertFalse(reloaded.weiboMonitorMenuBarBadgeEnabled)
        XCTAssertTrue(reloaded.weiboMonitorDashboardBadgeEnabled)
        XCTAssertFalse(reloaded.weiboMonitorPopoverBadgeEnabled)

        reloaded.weiboMonitorMenuBarBadgeEnabled = true
        reloaded.weiboMonitorDashboardBadgeEnabled = false
        reloaded.weiboMonitorPopoverBadgeEnabled = true

        let final = AppSettings()
        XCTAssertTrue(final.weiboMonitorMenuBarBadgeEnabled)
        XCTAssertFalse(final.weiboMonitorDashboardBadgeEnabled)
        XCTAssertTrue(final.weiboMonitorPopoverBadgeEnabled)
    }

    func testMasterSwitchHidesEverySurfaceBadge() {
        let defaults = TestIsolation.defaults
        allKeys.forEach(defaults.removeObject(forKey:))
        defer { allKeys.forEach(defaults.removeObject(forKey:)) }

        let settings = AppSettings()
        XCTAssertTrue(settings.showsWeiboMenuBarBadge)
        XCTAssertTrue(settings.showsWeiboDashboardBadge)
        XCTAssertTrue(settings.showsWeiboPopoverBadge)

        settings.weiboMonitorBadgeEnabled = false
        XCTAssertFalse(settings.showsWeiboMenuBarBadge)
        XCTAssertFalse(settings.showsWeiboDashboardBadge)
        XCTAssertFalse(settings.showsWeiboPopoverBadge)

        // Per-surface switches keep their own value, so turning the master
        // back on restores exactly what the user chose.
        settings.weiboMonitorMenuBarBadgeEnabled = false
        settings.weiboMonitorBadgeEnabled = true
        XCTAssertFalse(settings.showsWeiboMenuBarBadge)
        XCTAssertTrue(settings.showsWeiboDashboardBadge)
        XCTAssertTrue(settings.showsWeiboPopoverBadge)
    }
}
