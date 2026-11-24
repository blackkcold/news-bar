import XCTest
@testable import NewsBar

@MainActor
final class WeiboCommentInteractionSettingsTests: XCTestCase {
    private let enabledKey = "weiboCommentInteractionsEnabled"
    private let ackKey = "weiboCommentInteractionsAckAt"

    private var keys: [String] { [enabledKey, ackKey] }

    func testDefaultsOffAndWithoutConsent() {
        let defaults = TestIsolation.defaults
        keys.forEach(defaults.removeObject(forKey:))
        defer { keys.forEach(defaults.removeObject(forKey:)) }

        let settings = AppSettings()
        XCTAssertFalse(settings.weiboCommentInteractionsEnabled)
        XCTAssertNil(settings.weiboCommentInteractionsAckAt)
    }

    func testInteractionFlagAndConsentPersist() {
        let defaults = TestIsolation.defaults
        keys.forEach(defaults.removeObject(forKey:))
        defer { keys.forEach(defaults.removeObject(forKey:)) }

        let consent = Date(timeIntervalSince1970: 1_800_000_000)
        let initial = AppSettings()
        initial.weiboCommentInteractionsEnabled = true
        initial.weiboCommentInteractionsAckAt = consent

        let reloaded = AppSettings()
        XCTAssertTrue(reloaded.weiboCommentInteractionsEnabled)
        XCTAssertEqual(reloaded.weiboCommentInteractionsAckAt, consent)

        reloaded.weiboCommentInteractionsEnabled = false
        reloaded.weiboCommentInteractionsAckAt = nil

        let cleared = AppSettings()
        XCTAssertFalse(cleared.weiboCommentInteractionsEnabled)
        XCTAssertNil(cleared.weiboCommentInteractionsAckAt)
    }
}
