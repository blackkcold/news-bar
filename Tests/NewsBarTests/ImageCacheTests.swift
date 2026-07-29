import XCTest
@testable import NewsBar

final class ImageCacheTests: XCTestCase {

    // MARK: - isAcceptableResponse (pure validation seam, no network)

    func testIsAcceptableResponse_ValidImageContentType_True() {
        let response = makeResponse(contentType: "image/png")
        let data = Data(repeating: 0x89, count: 1024)
        XCTAssertTrue(ImageCache.isAcceptableResponse(httpResponse: response, data: data))
    }

    func testIsAcceptableResponse_JPEG_True() {
        let response = makeResponse(contentType: "image/jpeg")
        let data = Data(repeating: 0xFF, count: 2048)
        XCTAssertTrue(ImageCache.isAcceptableResponse(httpResponse: response, data: data))
    }

    func testIsAcceptableResponse_HTMLContent_False() {
        let response = makeResponse(contentType: "text/html; charset=utf-8")
        let data = Data(repeating: 0x41, count: 512)
        XCTAssertFalse(ImageCache.isAcceptableResponse(httpResponse: response, data: data))
    }

    func testIsAcceptableResponse_JSONContent_False() {
        let response = makeResponse(contentType: "application/json")
        let data = Data(repeating: 0x7B, count: 256)
        XCTAssertFalse(ImageCache.isAcceptableResponse(httpResponse: response, data: data))
    }

    func testIsAcceptableResponse_EmptyContentType_False() {
        let response = makeResponse(contentType: nil)
        let data = Data(repeating: 0x42, count: 100)
        XCTAssertFalse(ImageCache.isAcceptableResponse(httpResponse: response, data: data))
    }

    func testIsAcceptableResponse_EmptyData_False() {
        let response = makeResponse(contentType: "image/png")
        XCTAssertFalse(ImageCache.isAcceptableResponse(httpResponse: response, data: Data()))
    }

    func testIsAcceptableResponse_OversizedPayload_False() {
        let response = makeResponse(contentType: "image/png")
        let oversized = Data(repeating: 0x89, count: ImageCache.maxPayloadBytes + 1)
        XCTAssertFalse(ImageCache.isAcceptableResponse(httpResponse: response, data: oversized))
    }

    func testIsAcceptableResponse_ExactMaxPayload_True() {
        let response = makeResponse(contentType: "image/png")
        let exactMax = Data(repeating: 0x89, count: ImageCache.maxPayloadBytes)
        XCTAssertTrue(ImageCache.isAcceptableResponse(httpResponse: response, data: exactMax))
    }

    func testIsAcceptableResponse_CaseInsensitiveContentType_True() {
        let response = makeResponse(contentType: "IMAGE/PNG")
        let data = Data(repeating: 0x89, count: 512)
        XCTAssertTrue(ImageCache.isAcceptableResponse(httpResponse: response, data: data))
    }

    func testIsAcceptableResponse_ContentTypeWithCharset_True() {
        let response = makeResponse(contentType: "image/png; charset=utf-8")
        let data = Data(repeating: 0x89, count: 512)
        XCTAssertTrue(ImageCache.isAcceptableResponse(httpResponse: response, data: data))
    }

    // MARK: - Cache limits

    func testMaxPayloadBytes_Is10MB() {
        XCTAssertEqual(ImageCache.maxPayloadBytes, 10 * 1024 * 1024)
    }

    func testMaxCacheBytes_Is100MB() {
        XCTAssertEqual(ImageCache.maxCacheBytes, 100 * 1024 * 1024)
    }

    func testMaxCacheCount_Is50() {
        XCTAssertEqual(ImageCache.maxCacheCount, 50)
    }

    // MARK: - Helpers

    private func makeResponse(contentType: String?) -> HTTPURLResponse {
        let url = URL(string: "https://example.com/image.png")!
        return HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: contentType.map { ["Content-Type": $0] }
        )!
    }
}