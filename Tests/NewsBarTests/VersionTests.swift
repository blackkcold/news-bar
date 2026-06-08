import XCTest
@testable import NewsBar

final class VersionTests: XCTestCase {
    func testVersionIsNewer_SimpleIncrement_True() {
        XCTAssertTrue(versionIsNewer("1.1.0", than: "1.0.0"))
    }

    func testVersionIsNewer_Same_False() {
        XCTAssertFalse(versionIsNewer("1.0.0", than: "1.0.0"))
    }

    func testVersionIsNewer_DifferentLength_True() {
        XCTAssertTrue(versionIsNewer("1.0.1", than: "1.0.0"))
    }
}
