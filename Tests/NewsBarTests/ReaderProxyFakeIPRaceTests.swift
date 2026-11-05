import XCTest
@testable import NewsBar

final class ReaderProxyFakeIPRaceTests: XCTestCase {
    @MainActor
    func testDisablingFakeIPDuringDetectionRejectsThePendingDecision() async throws {
        let suite = "reader-fakeip-race-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = FakeIPRaceGate()
        let detector = ReaderFakeIPDetector(
            resolver: { _ in await gate.resolve() },
            routerProvider: { "192.168.0.1" },
            timeout: 30
        )
        let credentials = ReaderProxyCredentialStore(read: { _ in nil }, save: { _, _ in false })
        let controller = ReaderProxyController(
            defaults: defaults, credentials: credentials, monitor: nil, fakeIPDetector: detector
        )
        controller.updateNetwork(available: true)

        let pending = Task { await controller.allowsFakeIPDestination() }
        await gate.waitUntilStarted()
        controller.blocksFakeIP = true
        await gate.release()

        let allowed = await pending.value
        XCTAssertFalse(allowed)
    }
}

private actor FakeIPRaceGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var started: CheckedContinuation<Void, Never>?

    func resolve() async -> [String] {
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            if waiting.count == 3 {
                started?.resume()
                started = nil
            }
        }
        return ["198.18.28.202"]
    }

    func waitUntilStarted() async {
        if waiting.count == 3 { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        let continuations = waiting
        waiting = []
        for continuation in continuations { continuation.resume() }
    }
}
