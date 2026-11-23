import XCTest
@testable import NewsBar

/// The old `Bundle.module` accessor embedded the build-machine path and would
/// `fatalError` on a user's Mac. The explicit search must find reader-mode.js
/// in the SwiftPM/test layout without that accessor.
final class ReaderModeScriptResourceTests: XCTestCase {
    @MainActor
    func testReaderModeScriptLoadsFromTheBuildLayout() throws {
        let script = try XCTUnwrap(
            ReaderModeScript.source(),
            "reader-mode.js must be found without Bundle.module"
        )
        XCTAssertFalse(script.isEmpty)
    }
}
