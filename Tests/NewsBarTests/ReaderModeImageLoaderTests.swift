import XCTest
@testable import NewsBar

final class ReaderModeImageLoaderTests: XCTestCase {
    private actor NetworkGate {
        private var entered = false
        private var current = true
        private var enteredWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func resolve() async -> ReaderNavigationPolicy.DestinationResolution {
            entered = true
            enteredWaiter?.resume()
            enteredWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
            return .publicDestination
        }

        func waitForResolution() async {
            if entered { return }
            await withCheckedContinuation { enteredWaiter = $0 }
        }

        func invalidateAndRelease() {
            current = false
            releaseWaiter?.resume()
            releaseWaiter = nil
        }

        func isCurrent() -> Bool { current }
    }

    private func loader(limit: Int) -> ReaderModeImageLoader {
        ReaderModeImageLoader(maxBytes: limit, configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PrivateHTTPStubProtocol.self]
            return configuration
        })
    }

    private var network: ReaderImageNetworkContext {
        ReaderImageNetworkContext(
            proxy: nil, resolve: { _ in .publicDestination },
            allowsFakeIP: { false }, isCurrent: { true }
        )
    }

    func testImageDataIsReturnedWithoutResamplingOrConversion() async throws {
        defer { PrivateHTTPStubProtocol.reset() }
        PrivateHTTPStubProtocol.bodySize = 512
        let url = try XCTUnwrap(URL(string: "https://images.example.com/image"))
        let data = try await loader(limit: 1024).load(url, cookies: [], referer: nil, network: network)
        XCTAssertEqual(data, Data(repeating: 0x41, count: 512))
    }

    func testStreamingBodyWithoutContentLengthIsStoppedAtLimit() async throws {
        defer { PrivateHTTPStubProtocol.reset() }
        PrivateHTTPStubProtocol.bodySize = 64 * 1024
        PrivateHTTPStubProtocol.declaredLength = nil
        let url = try XCTUnwrap(URL(string: "https://images.example.com/image"))
        do {
            _ = try await loader(limit: 1024).load(url, cookies: [], referer: nil, network: network)
            XCTFail("An oversized response must not be returned")
        } catch {
            XCTAssertEqual(error as? ReaderModeImageError, .tooLarge)
        }
    }

    func testOversizedDeclaredContentLengthIsRejected() async throws {
        defer { PrivateHTTPStubProtocol.reset() }
        PrivateHTTPStubProtocol.bodySize = 16
        PrivateHTTPStubProtocol.declaredLength = "1048576"
        let url = try XCTUnwrap(URL(string: "https://images.example.com/image"))
        do {
            _ = try await loader(limit: 1024).load(url, cookies: [], referer: nil, network: network)
            XCTFail("An oversized Content-Length must be rejected")
        } catch {
            XCTAssertEqual(error as? ReaderModeImageError, .tooLarge)
        }
    }

    func testPrivateDestinationDoesNotStartTheImageRequest() async throws {
        defer { PrivateHTTPStubProtocol.reset() }
        PrivateHTTPStubProtocol.bodySize = 128
        let url = try XCTUnwrap(URL(string: "https://images.example.com/image"))
        let blocked = ReaderImageNetworkContext(
            proxy: nil, resolve: { _ in .privateDestination },
            allowsFakeIP: { false }, isCurrent: { true }
        )
        do {
            _ = try await loader(limit: 1024).load(url, cookies: [], referer: nil, network: blocked)
            XCTFail("Private destinations must be blocked before transfer")
        } catch {
            XCTAssertEqual(error as? ReaderModeImageError, .invalidURL)
        }
    }

    func testExpiredNetworkContextCannotStartTheImageRequest() async throws {
        defer { PrivateHTTPStubProtocol.reset() }
        let url = try XCTUnwrap(URL(string: "https://images.example.com/image"))
        let stale = ReaderImageNetworkContext(
            proxy: nil, resolve: { _ in .publicDestination },
            allowsFakeIP: { true }, isCurrent: { false }
        )
        do {
            _ = try await loader(limit: 1024).load(url, cookies: [], referer: nil, network: stale)
            XCTFail("A stale network context must not start a request")
        } catch {
            XCTAssertEqual(error as? ReaderModeImageError, .networkChanged)
        }
    }

    func testNetworkChangeDuringDNSStopsTheRequest() async throws {
        defer { PrivateHTTPStubProtocol.reset() }
        let url = try XCTUnwrap(URL(string: "https://images.example.com/image"))
        let gate = NetworkGate()
        let context = ReaderImageNetworkContext(
            proxy: nil, resolve: { _ in await gate.resolve() },
            allowsFakeIP: { false }, isCurrent: { await gate.isCurrent() }
        )
        let imageLoader = loader(limit: 1024)
        let request = Task { try await imageLoader.load(url, cookies: [], referer: nil, network: context) }
        await gate.waitForResolution()
        await gate.invalidateAndRelease()
        do {
            _ = try await request.value
            XCTFail("A DNS result from the old network must not start a request")
        } catch {
            XCTAssertEqual(error as? ReaderModeImageError, .networkChanged)
        }
    }
}
