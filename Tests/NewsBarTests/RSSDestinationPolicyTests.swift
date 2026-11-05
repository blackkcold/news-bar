import XCTest
@testable import NewsBar

final class RSSDestinationPolicyTests: XCTestCase {
    private let feedURL = URL(string: "https://feeds.example.com/rss")!

    func testPublicDestinationIsAllowed() async throws {
        let policy = RSSDestinationPolicy(
            resolve: { _ in .publicDestination }, allowsFakeIP: { false }
        )
        let allowed = try await policy.allows(feedURL)
        XCTAssertTrue(allowed)
    }

    func testPrivateDestinationIsBlockedEvenWhenFakeIPIsAllowed() async throws {
        let policy = RSSDestinationPolicy(
            resolve: { _ in .privateDestination }, allowsFakeIP: { true }
        )
        let allowed = try await policy.allows(feedURL)
        XCTAssertFalse(allowed)
    }

    func testFakeIPRequiresPositiveNetworkAuthorization() async throws {
        let permitted = RSSDestinationPolicy(
            resolve: { _ in .fakeIPDestination }, allowsFakeIP: { true }
        )
        let denied = RSSDestinationPolicy(
            resolve: { _ in .fakeIPDestination }, allowsFakeIP: { false }
        )
        let allowed = try await permitted.allows(feedURL)
        let blocked = try await denied.allows(feedURL)
        XCTAssertTrue(allowed)
        XCTAssertFalse(blocked)
    }

    func testLocalURLIsBlockedBeforeResolution() async throws {
        let policy = RSSDestinationPolicy(
            resolve: { _ in .publicDestination }, allowsFakeIP: { true }
        )
        let local = try XCTUnwrap(URL(string: "https://127.0.0.1/rss"))
        let allowed = try await policy.allows(local)
        XCTAssertFalse(allowed)
    }

    func testSlowResolutionTimesOutInsteadOfHoldingTheRequest() async throws {
        let policy = RSSDestinationPolicy(
            resolve: { _ in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return .publicDestination
            },
            allowsFakeIP: { false },
            timeoutNanoseconds: 10_000_000
        )
        do {
            _ = try await policy.allows(feedURL)
            XCTFail("A stalled DNS decision must time out")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
    }

    func testCancellationIsNotReportedAsAServerFailure() {
        let result = RSSValidationService.classifyFetchResult(
            urlString: "https://feeds.example.com/rss", data: nil, error: CancellationError()
        )
        XCTAssertEqual(result, .cancelled)
    }

    func testPrivateInitialDestinationIsRejectedBeforeTransport() async throws {
        let policy = RSSDestinationPolicy(
            resolve: { _ in .privateDestination }, allowsFakeIP: { true }
        )
        let session = timeoutSession()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await HTTPClient.data(
                for: feedURL, config: .rss, restrictToPublicDestinations: true,
                destinationPolicy: policy, session: session
            )
            XCTFail("The private destination must be rejected")
        } catch let error as NewsBarError {
            guard case .requestFailed = error else { return XCTFail("Unexpected RSS error: \(error)") }
        } catch {
            XCTFail("Transport was reached or the wrong error was returned: \(error)")
        }
    }

    func testTransportTimeoutIsPreserved() async throws {
        let policy = RSSDestinationPolicy(
            resolve: { _ in .publicDestination }, allowsFakeIP: { false }
        )
        let session = timeoutSession()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await HTTPClient.data(
                for: feedURL, config: .rss, restrictToPublicDestinations: true,
                destinationPolicy: policy, session: session
            )
            XCTFail("The stub must fail with a timeout")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
    }

    private func timeoutSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RSSTimeoutProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class RSSTimeoutProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
    }
    override func stopLoading() {}
}
