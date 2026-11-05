import SwiftUI
import XCTest
@testable import NewsBar

@MainActor
final class SearchProviderCardTests: XCTestCase {
    private func card(
        enabled: Bool = false, configured: Bool = false,
        unverified: Bool = false, retryRemoval: Bool = false
    ) -> SearchProviderCard {
        SearchProviderCard(
            provider: .tavily, language: .en, status: nil,
            isEnabled: enabled, isConfigured: configured,
            isKeyUnverified: unverified, canRetryKeyRemoval: retryRemoval,
            canRetryKeySync: false, isSaving: false, keyInput: .constant(""),
            onToggle: { _ in }, onSave: {}, onClear: {}, onRetryKeySync: {}, onRetryAuth: nil
        )
    }

    func testUnverifiedSaveStillOffersKeyRemoval() {
        let view = card(unverified: true)
        XCTAssertTrue(view.showsKeyControls)
        XCTAssertTrue(view.showsKeyRemoval)
    }

    func testDisabledProviderStillOffersRemovalOfStoredOrRetryableKey() {
        for view in [card(configured: true), card(retryRemoval: true)] {
            XCTAssertTrue(view.showsKeyControls)
            XCTAssertTrue(view.showsKeyRemoval)
        }
    }

    func testDisabledProviderWithoutStoredKeyDoesNotShowKeyControls() {
        let view = card()
        XCTAssertFalse(view.showsKeyControls)
        XCTAssertFalse(view.showsKeyRemoval)
        XCTAssertTrue(card(enabled: true).showsKeyControls)
        XCTAssertFalse(card(enabled: true).showsKeyRemoval)
    }
}
