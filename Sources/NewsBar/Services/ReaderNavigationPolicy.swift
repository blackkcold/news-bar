import Darwin
import Foundation

enum ReaderNavigationPolicy {
    enum DestinationResolution: Equatable { case publicDestination, privateDestination, unresolved }

    static func classifyAddresses(_ addresses: [String]) -> DestinationResolution {
        guard !addresses.isEmpty else { return .unresolved }
        return addresses.allSatisfy(isPublicAddress) ? .publicDestination : .privateDestination
    }
    static func allowedURL(_ raw: String) -> URL? {
        guard let c = URLComponents(string: raw), c.scheme?.lowercased() == "https",
              c.user == nil, c.password == nil, let host = c.host?.lowercased(),
              host.contains("."), !host.hasSuffix("."), !host.contains(":"),
              !["localhost", "local", "internal", "lan", "home", "test", "invalid"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              host.range(of: "^[0-9.]+$", options: .regularExpression) == nil,
              c.port == nil || c.port == 443 else { return nil }
        return c.url
    }

    /// The destination a `window.open` request may navigate to in place.
    ///
    /// The reader never creates a second web view: a popup would escape the
    /// ephemeral store and the content rule list. Returning `nil` drops a
    /// scripted open that could not have loaded anyway.
    static func popupDestination(_ rawURL: String?) -> URL? {
        guard let rawURL else { return nil }
        return allowedURL(rawURL)
    }

    /// A site's own log-out landing page.
    ///
    /// An empty cookie capture is ambiguous — a login redirect and a sign-out
    /// look the same — so only a path segment that names the sign-out endpoint
    /// may clear a saved site. Segment matching keeps `/exitpoll` out.
    static func isLogoutDestination(_ rawURL: String?) -> Bool {
        guard let rawURL, let url = URL(string: rawURL) else { return false }
        let segments = url.path.lowercased().split(separator: "/").map(String.init)
        let names: Set<String> = ["logout", "log-out", "log_out", "signout", "sign-out", "sign_out", "exit", "logoff"]
        return segments.contains { names.contains($0) }
    }

    static func isPublicAddress(_ address: String) -> Bool {
        IPAddress.isPublic(address)
    }

    /// Navigation DNS checks complement literal-host content rules. This is not a
    /// universal WebKit subresource firewall and cannot eliminate DNS rebinding.
    static func resolvesPublicly(_ url: URL) async -> Bool {
        await resolveDestination(url) == .publicDestination
    }

    static func resolveDestination(_ url: URL) async -> DestinationResolution {
        guard let host = url.host else { return .unresolved }
        return await Task.detached(priority: .userInitiated) {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return DestinationResolution.unresolved }
            defer { freeaddrinfo(first) }
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            var addresses: [String] = []
            while let node = cursor {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(node.pointee.ai_addr, node.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return DestinationResolution.unresolved }
                addresses.append(String(cString: buffer))
                cursor = node.pointee.ai_next
            }
            return classifyAddresses(addresses)
        }.value
    }

    static var resourceRules: String {
        // WebKit's content-rule regex subset does not support disjunctions.
        var patterns = ["^http://", "^https?://localhost[:/]", "^https?://\\["]
        patterns += ["local", "internal", "lan", "home"].map { "^https?://[^/]*\\." + $0 + "[:/]" }
        var prefixes = ["0.", "10.", "127.", "169.254.", "192.168.", "192.0.", "198.18.", "198.19."]
        prefixes += (16...31).map { "172.\($0)." }
        prefixes += (64...127).map { "100.\($0)." }
        patterns += prefixes.map { "^https?://" + $0.replacingOccurrences(of: ".", with: "\\.") }
        let rules = patterns.map { ["trigger": ["url-filter": $0], "action": ["type": "block"]] }
        guard let data = try? JSONSerialization.data(withJSONObject: rules), let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }
}
