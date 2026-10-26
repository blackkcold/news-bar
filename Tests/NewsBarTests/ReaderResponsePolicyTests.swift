import XCTest
@testable import NewsBar

final class ReaderResponsePolicyTests: XCTestCase {
    func testOnly412IsTreatedAsRiskControlRejection() {
        XCTAssertTrue(ReaderResponsePolicy.isRiskControlRejection(status: 412))
        XCTAssertFalse(ReaderResponsePolicy.isRiskControlRejection(status: 200))
        XCTAssertFalse(ReaderResponsePolicy.isRiskControlRejection(status: 403))
        XCTAssertFalse(ReaderResponsePolicy.isRiskControlRejection(status: 429))
        XCTAssertFalse(ReaderResponsePolicy.isRiskControlRejection(status: nil))
    }
}
