import XCTest
@testable import NewsBar

final class PrivateHTTPTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrivateHTTPStubProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        PrivateHTTPStubProtocol.reset()
        super.tearDown()
    }

    func testRejectsStreamedBodyOverLimitWithoutContentLength() async {
        PrivateHTTPStubProtocol.bodySize = 64 * 1024
        PrivateHTTPStubProtocol.declaredLength = nil

        do {
            _ = try await PrivateHTTP.data(
                for: URLRequest(url: URL(string: "https://example.com/")!),
                maxBytes: 1024,
                session: session
            )
            XCTFail("Expected the streaming ceiling to reject the body")
        } catch let error as PrivateHTTPError {
            XCTAssertEqual(error, .tooLarge(1024))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRejectsDeclaredLengthOverLimitBeforeReading() async {
        PrivateHTTPStubProtocol.bodySize = 4 * 1024
        PrivateHTTPStubProtocol.declaredLength = "1048576"

        do {
            _ = try await PrivateHTTP.data(
                for: URLRequest(url: URL(string: "https://example.com/")!),
                maxBytes: 4096,
                session: session
            )
            XCTFail("Expected declared Content-Length to be rejected")
        } catch let error as PrivateHTTPError {
            XCTAssertEqual(error, .tooLarge(4096))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRejectsUnexpectedContentType() async {
        PrivateHTTPStubProtocol.bodySize = 16
        PrivateHTTPStubProtocol.contentType = "text/html"

        do {
            _ = try await PrivateHTTP.data(
                for: URLRequest(url: URL(string: "https://example.com/")!),
                maxBytes: 4096,
                allowedContentTypes: ["application/json"],
                session: session
            )
            XCTFail("Expected the content type to be rejected")
        } catch let error as PrivateHTTPError {
            XCTAssertEqual(error, .unsupportedContentType("text/html"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAcceptsBodyWithinLimit() async throws {
        PrivateHTTPStubProtocol.bodySize = 512

        let (data, response) = try await PrivateHTTP.data(
            for: URLRequest(url: URL(string: "https://example.com/")!),
            maxBytes: 1024,
            allowedContentTypes: ["application/json"],
            session: session
        )

        XCTAssertEqual(data.count, 512)
        XCTAssertEqual(response.statusCode, 200)
    }
}

final class PrivateHTTPStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodySize = 0
    nonisolated(unsafe) static var declaredLength: String?
    nonisolated(unsafe) static var contentType = "application/json"
    nonisolated(unsafe) static var statusCode = 200

    static func reset() {
        bodySize = 0
        declaredLength = nil
        contentType = "application/json"
        statusCode = 200
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var headers = ["Content-Type": Self.contentType]
        if let declaredLength = Self.declaredLength {
            headers["Content-Length"] = declaredLength
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: Self.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if Self.bodySize > 0 {
            client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: Self.bodySize))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
