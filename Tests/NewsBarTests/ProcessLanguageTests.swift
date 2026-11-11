import XCTest
@testable import NewsBar

/// Locks the contract that keeps Sparkle's update window in the same language
/// as the rest of the app: the setting wins, writes are idempotent, and the
/// code never rewrites the preference of a non-app host (swift run, XCTest).
final class ProcessLanguageTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "ProcessLanguageTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testSyncWritesTheChosenLanguageInsideAnAppBundle() {
        let wrote = ProcessLanguage.sync(
            language: .zh,
            defaults: defaults,
            bundlePath: "/Applications/NewsBar.app"
        )

        XCTAssertTrue(wrote)
        XCTAssertEqual(
            defaults.stringArray(forKey: ProcessLanguage.defaultsKey),
            ["zh-CN"]
        )
    }

    func testSyncIsIdempotent() {
        let bundlePath = "/Applications/NewsBar.app"

        XCTAssertTrue(
            ProcessLanguage.sync(language: .en, defaults: defaults, bundlePath: bundlePath)
        )
        XCTAssertFalse(
            ProcessLanguage.sync(language: .en, defaults: defaults, bundlePath: bundlePath),
            "A second launch must not rewrite an already correct preference"
        )
    }

    func testSyncLeavesNonAppHostsAlone() {
        let wrote = ProcessLanguage.sync(
            language: .zh,
            defaults: defaults,
            bundlePath: "/tmp/.build/debug/NewsBar"
        )

        XCTAssertFalse(wrote)
        XCTAssertNil(
            defaults.persistentDomain(forName: suiteName)?[ProcessLanguage.defaultsKey],
            "swift run and XCTest must never rewrite their host's language"
        )
    }

    func testPreferredLocalizationsUseBCP47Values() {
        XCTAssertEqual(ProcessLanguage.preferredLocalizations(for: .zh), ["zh-CN"])
        XCTAssertEqual(ProcessLanguage.preferredLocalizations(for: .en), ["en"])
    }

    func testResolvedLanguageMapsTheProcessLocalization() {
        XCTAssertEqual(ProcessLanguage.resolvedLanguage(preferredLocalizations: ["zh_CN"]), .zh)
        XCTAssertEqual(ProcessLanguage.resolvedLanguage(preferredLocalizations: ["zh-Hans"]), .zh)
        XCTAssertEqual(ProcessLanguage.resolvedLanguage(preferredLocalizations: ["en"]), .en)
        XCTAssertNil(ProcessLanguage.resolvedLanguage(preferredLocalizations: []))
    }

    func testRestartHintIsLocalizedInBothTables() {
        XCTAssertFalse(L10n.string("settings.language.restartHint", language: .zh).isEmpty)
        XCTAssertNotEqual(
            L10n.string("settings.language.restartHint", language: .zh),
            "settings.language.restartHint"
        )
        XCTAssertNotEqual(
            L10n.string("settings.language.restartHint", language: .en),
            "settings.language.restartHint"
        )
    }
}
