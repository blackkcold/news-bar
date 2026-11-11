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

    func testIsAcceptableResponse_HTTPErrorStatus_False() {
        let response = makeResponse(contentType: "image/png", statusCode: 404)
        let data = Data(repeating: 0x89, count: 512)
        XCTAssertFalse(ImageCache.isAcceptableResponse(httpResponse: response, data: data))
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

    func testMaxCacheCount_Is120() {
        XCTAssertEqual(ImageCache.maxCacheCount, 120)
    }

    // MARK: - Pixel buckets

    func testPixelSizeRoundsUpToTheBucketAndNeverBelowIt() {
        XCTAssertEqual(ImageCache.pixelSize(forPoints: 20, displayScale: 2, step: 64), 64)
        XCTAssertEqual(ImageCache.pixelSize(forPoints: 65, displayScale: 1, step: 64), 128)
        XCTAssertEqual(ImageCache.pixelSize(forPoints: 348, displayScale: 2), 768)
        XCTAssertEqual(ImageCache.pixelSize(forPoints: 348, displayScale: 1), 512)

        // An exact multiple of the step must not be pushed into the next bucket.
        XCTAssertEqual(ImageCache.pixelSize(forPoints: 128, displayScale: 1, step: 64), 128)

        // For normal sizes the decode is never smaller than the screen needs.
        for (points, scale) in [(320.0, 2.0), (348.0, 1.0), (180.0, 3.0)] {
            let size = ImageCache.pixelSize(forPoints: points, displayScale: scale)
            XCTAssertGreaterThanOrEqual(size, Int(points * scale))
        }
    }

    func testPixelSizeIgnoresInvalidInputAndCapsTheResult() {
        XCTAssertEqual(ImageCache.pixelSize(forPoints: .nan, displayScale: 2), 256)
        XCTAssertEqual(ImageCache.pixelSize(forPoints: .infinity, displayScale: 2), 256)
        XCTAssertEqual(ImageCache.pixelSize(forPoints: 0, displayScale: 2), 256)
        XCTAssertEqual(ImageCache.pixelSize(forPoints: -10, displayScale: 2), 256)
        XCTAssertEqual(ImageCache.pixelSize(forPoints: 348, displayScale: .nan), 768)
        XCTAssertEqual(ImageCache.pixelSize(forPoints: 348, displayScale: 0), 768)
        XCTAssertEqual(ImageCache.pixelSize(forPoints: 348, displayScale: -2), 768)
        XCTAssertEqual(ImageCache.pixelSize(forPoints: 348, displayScale: .infinity), 768)
        XCTAssertEqual(ImageCache.pixelSize(forPoints: 10_000, displayScale: 2), 2_048)
        // step is clamped to at least 64.
        XCTAssertEqual(ImageCache.pixelSize(forPoints: 20, displayScale: 1, step: 10), 64)
    }

    func testThumbnailMaxPixelSize_IsBoundedForCardRendering() {
        XCTAssertEqual(ImageCache.thumbnailMaxPixelSize, 480)
    }

    func testDecodeThumbnail_InvalidData_ReturnsNil() {
        XCTAssertNil(ImageCache.decodeThumbnail(from: Data([0x00, 0x01, 0x02])))
    }

    func testNonHTTPSImageURLIsRejectedWithoutNetwork() async {
        let url = URL(string: "http://example.com/image.png")!
        let image = await ImageCache.shared.image(for: url)
        XCTAssertNil(image)
    }

    // MARK: - Helpers

    private func makeResponse(contentType: String?, statusCode: Int = 200) -> HTTPURLResponse {
        let url = URL(string: "https://example.com/image.png")!
        return HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: contentType.map { ["Content-Type": $0] }
        )!
    }
}
