import Foundation
import SystemConfiguration

/// One canary lookup used to identify a local Fake-IP resolver.
struct FakeIPProbe: Equatable, Sendable {
    let host: String
    let addresses: [String]

    /// A Fake-IP answer is only meaningful when every returned address is
    /// either a Fake-IP or a real public address. A real private address in the
    /// same answer keeps the destination in the strict path.
    var isFakeIP: Bool {
        guard !addresses.isEmpty,
              addresses.allSatisfy({ IPAddress.isPublic($0) || IPAddress.isFakeIP($0) }) else {
            return false
        }
        return addresses.contains(where: IPAddress.isFakeIP)
    }
}

struct FakeIPDetection: Equatable, Sendable {
    let isFakeIPNetwork: Bool
    let router: String?
    let probes: [FakeIPProbe]

    static let unknown = FakeIPDetection(isFakeIPNetwork: false, router: nil, probes: [])
}

/// Recognizes a local transparent proxy that answers public hostnames with
/// addresses from the RFC 2544 Fake-IP block (198.18.0.0/15).
///
/// The detector is deliberately conservative: it requires a private/LAN
/// gateway and at least two independent public canaries resolving into the
/// block. One Fake-IP answer, a public gateway, or any real private address in
/// a canary answer keeps the reader in strict mode.
struct ReaderFakeIPDetector: Sendable {
    typealias Resolver = @Sendable (String) async -> [String]
    typealias RouterProvider = @Sendable () -> String?

    static let canaries = ["example.com", "www.cloudflare.com", "www.apple.com"]
    static let defaultTimeout: TimeInterval = 1.5

    let resolver: Resolver
    let routerProvider: RouterProvider
    let timeout: TimeInterval

    init(
        resolver: @escaping Resolver = { await ReaderNavigationPolicy.resolveAddresses($0) },
        routerProvider: @escaping RouterProvider = { ReaderFakeIPDetector.systemRouter() },
        timeout: TimeInterval = ReaderFakeIPDetector.defaultTimeout
    ) {
        self.resolver = resolver
        self.routerProvider = routerProvider
        self.timeout = timeout
    }

    static let live = ReaderFakeIPDetector()

    func detect() async -> FakeIPDetection {
        let router = routerProvider()
        let probes = await withTaskGroup(of: FakeIPProbe.self) { group in
            for host in Self.canaries {
                group.addTask { await probe(host) }
            }
            var results: [FakeIPProbe] = []
            for await probe in group {
                results.append(probe)
            }
            return results
        }

        // Keep a stable order for diagnostics and tests even though the
        // lookups finish concurrently.
        let ordered = Self.canaries.map { host in
            probes.first { $0.host == host } ?? FakeIPProbe(host: host, addresses: [])
        }
        let fakeCount = ordered.filter { $0.isFakeIP }.count
        let privateGateway = router.map(Self.isPrivateGateway) ?? false
        return FakeIPDetection(
            isFakeIPNetwork: privateGateway && fakeCount >= 2,
            router: router,
            probes: ordered
        )
    }

    private func probe(_ host: String) async -> FakeIPProbe {
        FakeIPProbe(host: host, addresses: await resolveWithTimeout(host))
    }

    private func resolveWithTimeout(_ host: String) async -> [String] {
        await withTaskGroup(of: [String]?.self) { group in
            group.addTask { await resolver(host) }
            group.addTask {
                let nanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    static func isPrivateGateway(_ raw: String) -> Bool {
        guard let parsed = IPAddress.parse(raw), parsed.family == AF_INET else { return false }
        let bytes = parsed.bytes
        if bytes[0] == 10 { return true }
        if bytes[0] == 172, (16...31).contains(bytes[1]) { return true }
        if bytes[0] == 192, bytes[1] == 168 { return true }
        if bytes[0] == 100, (64...127).contains(bytes[1]) { return true }
        if bytes[0] == 127 { return true }
        if bytes[0] == 169, bytes[1] == 254 { return true }
        return false
    }

    /// The primary IPv4 router from the system's dynamic store. Reading it
    /// needs no location, SSID, or network entitlement.
    static func systemRouter() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "NewsBarFakeIPDetector" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let router = value["Router"] as? String else {
            return nil
        }
        return router
    }
}
