import XCTest
@testable import NewsBar

final class LocalizationParityTests: XCTestCase {
    func testChineseAndEnglishTablesCoverTheSameKeys() {
        let parity = L10n.keyParity
        XCTAssertTrue(
            parity.missingInEnglish.isEmpty,
            "Missing in en: \(parity.missingInEnglish.sorted().joined(separator: ", "))"
        )
        XCTAssertTrue(
            parity.missingInChinese.isEmpty,
            "Missing in zh: \(parity.missingInChinese.sorted().joined(separator: ", "))"
        )
    }
}
