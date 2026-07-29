import XCTest
@testable import NewsBar

final class OnePasswordServiceTests: XCTestCase {

    // MARK: - isValidReference (pure function, no I/O)

    func testIsValidReference_ValidFormat_True() {
        XCTAssertTrue(OnePasswordService.isValidReference("op://Private/MyItem/credential"))
    }

    func testIsValidReference_MissingScheme_False() {
        XCTAssertFalse(OnePasswordService.isValidReference("Private/MyItem/credential"))
    }

    func testIsValidReference_TooFewComponents_False() {
        XCTAssertFalse(OnePasswordService.isValidReference("op://Private/MyItem"))
    }

    func testIsValidReference_EmptyString_False() {
        XCTAssertFalse(OnePasswordService.isValidReference(""))
    }

    func testIsValidReference_ExtraComponents_True() {
        XCTAssertTrue(OnePasswordService.isValidReference("op://Vault/Item/Section/Field"))
    }

    func testIsValidReference_TrailingSlash_True() {
        XCTAssertTrue(OnePasswordService.isValidReference("op://Vault/Item/Field/"))
    }

    // MARK: - Error cases

    func testOnePasswordError_invalidReference_HasDescription() {
        XCTAssertNotNil(OnePasswordError.invalidReference.errorDescription)
    }

    func testOnePasswordError_allCases_HaveDescriptions() {
        for error in [OnePasswordError.notInstalled, .timeout, .readFailed, .invalidReference] {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
        }
    }
}