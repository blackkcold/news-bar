import Foundation
import XCTest
@testable import NewsBar

final class ReaderFakeIPDetectorTests: XCTestCase {
    func testPrivateGatewayAndTwoFakeCanariesDetectNetwork() async {
        let fakeHosts: Set<String> = ["example.com", "www.cloudflare.com"]
        let detector = ReaderFakeIPDetector(
            resolver: { host in fakeHosts.contains(host) ? ["198.18.1.1"] : ["8.8.8.8"] },
            routerProvider: { "192.168.0.14" },
            timeout: 0.1
        )
        let result = await detector.detect()
        XCTAssertTrue(result.isFakeIPNetwork)
        XCTAssertEqual(result.router, "192.168.0.14")
        XCTAssertEqual(result.probes.count, 3)
        XCTAssertEqual(result.probes.filter { $0.isFakeIP }.count, 2)
    }

    func testPublicGatewayNeverDetectsFakeIPNetwork() async {
        let detector = ReaderFakeIPDetector(
            resolver: { _ in ["198.18.1.1"] },
            routerProvider: { "8.8.8.8" },
            timeout: 0.1
        )
        let result = await detector.detect()
        XCTAssertFalse(result.isFakeIPNetwork)
    }

    func testOneFakeCanaryIsNotEnough() async {
        let detector = ReaderFakeIPDetector(
            resolver: { host in host == "example.com" ? ["198.18.1.1"] : ["8.8.8.8"] },
            routerProvider: { "192.168.0.14" },
            timeout: 0.1
        )
        let result = await detector.detect()
        XCTAssertFalse(result.isFakeIPNetwork)
        XCTAssertEqual(result.probes.filter { $0.isFakeIP }.count, 1)
    }

    func testMixedFakeAndPrivateCanaryIsNotFakeIP() async {
        let detector = ReaderFakeIPDetector(
            resolver: { _ in ["198.18.1.1", "10.0.0.5"] },
            routerProvider: { "192.168.0.14" },
            timeout: 0.1
        )
        let result = await detector.detect()
        XCTAssertFalse(result.isFakeIPNetwork)
        XCTAssertTrue(result.probes.allSatisfy { !$0.isFakeIP })
    }

    func testProbeClassification() {
        XCTAssertTrue(FakeIPProbe(host: "x", addresses: ["198.18.0.1"]).isFakeIP)
        XCTAssertTrue(FakeIPProbe(host: "x", addresses: ["198.18.0.1", "8.8.8.8"]).isFakeIP)
        XCTAssertFalse(FakeIPProbe(host: "x", addresses: ["198.18.0.1", "10.0.0.1"]).isFakeIP)
        XCTAssertFalse(FakeIPProbe(host: "x", addresses: ["8.8.8.8"]).isFakeIP)
        XCTAssertFalse(FakeIPProbe(host: "x", addresses: []).isFakeIP)
    }

    func testPrivateGatewayClassification() {
        for ip in ["192.168.0.14", "10.0.0.1", "172.16.0.1", "172.31.255.254", "100.64.0.1", "100.127.255.254", "127.0.0.1", "169.254.1.1"] {
            XCTAssertTrue(ReaderFakeIPDetector.isPrivateGateway(ip), ip)
        }
        for ip in ["8.8.8.8", "172.32.0.1", "100.128.0.1", "198.18.0.1", "::1"] {
            XCTAssertFalse(ReaderFakeIPDetector.isPrivateGateway(ip), ip)
        }
    }

    func testHangingCanariesTimeOutWithoutDetecting() async {
        let detector = ReaderFakeIPDetector(
            resolver: { host in
                if host == "www.apple.com" { return ["198.18.1.1"] }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return ["198.18.1.1"]
            },
            routerProvider: { "192.168.0.14" },
            timeout: 0.05
        )
        let started = Date()
        let result = await detector.detect()
        XCTAssertFalse(result.isFakeIPNetwork)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testLiveNetworkDetectsLocalFakeIPWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["NEWSBAR_VALIDATE_FAKE_IP"] == "1" else {
            throw XCTSkip("Live Fake-IP validation is opt-in; the default suite stays offline.")
        }
        let result = await ReaderFakeIPDetector.live.detect()
        XCTAssertTrue(result.isFakeIPNetwork, "Expected a private gateway and at least two Fake-IP canaries")
    }
}
