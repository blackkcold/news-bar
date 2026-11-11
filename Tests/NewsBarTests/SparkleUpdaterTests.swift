import XCTest
@testable import NewsBar

@MainActor
final class SparkleUpdaterTests: XCTestCase {

    /// The test runner is a bare bundle with no `SUFeedURL`, exactly like
    /// `swift run`. Sparkle must stay completely inert there; otherwise it
    /// shows its "misconfigured updater" alert during tests and local runs.
    func testUpdaterIsInertWhenTheBundleHasNoFeed() {
        XCTAssertFalse(SparkleUpdater.isConfigured)

        let updater = SparkleUpdater()
        updater.start()
        updater.checkForUpdates()

        XCTAssertEqual(updater.state, .idle)
        XCTAssertFalse(updater.canCheckForUpdates)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        XCTAssertFalse(updater.automaticallyDownloadsUpdates)
    }

    /// Settings writes must not crash or mutate Sparkle state when the updater
    /// is disabled; the toggles are still rendered by tests and previews.
    func testSettingsWritesAreIgnoredWhenDisabled() {
        let updater = SparkleUpdater()
        updater.setAutomaticallyChecksForUpdates(true)
        updater.setAutomaticallyDownloadsUpdates(true)

        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        XCTAssertFalse(updater.automaticallyDownloadsUpdates)
    }

    func testBadgeStatesAreDistinct() {
        XCTAssertNotEqual(SparkleUpdater.State.idle, .checking)
        XCTAssertNotEqual(SparkleUpdater.State.available("3.1.0"), .ready("3.1.0"))
        XCTAssertEqual(SparkleUpdater.State.upToDate("3.0.0"), .upToDate("3.0.0"))
    }
}
