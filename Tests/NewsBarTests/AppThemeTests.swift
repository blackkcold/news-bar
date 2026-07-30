import SwiftUI
import XCTest
@testable import NewsBar

final class AppThemeTests: XCTestCase {
    private let themeKey = "appTheme"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: themeKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: themeKey)
        super.tearDown()
    }

    func testModernThemeIsTheDefault() {
        let settings = AppSettings()

        XCTAssertEqual(settings.appTheme, .modern)
    }

    func testRetroThemePersistsAndForcesLightAppearance() {
        let settings = AppSettings()
        settings.colorScheme = "dark"
        settings.appTheme = .retroEditorial

        let restored = AppSettings()

        XCTAssertEqual(restored.appTheme, .retroEditorial)
        XCTAssertEqual(restored.resolvedColorScheme, .light)
    }
}
