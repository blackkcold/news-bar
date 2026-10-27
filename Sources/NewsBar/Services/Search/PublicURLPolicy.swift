import Foundation

enum PublicURLValidation: Equatable {
    case valid(URL)
    case blocked(reason: String)

    var url: URL? {
        if case .valid(let url) = self { return url }
        return nil
    }

    var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }
}

/// Compatibility wrapper over `IPAddress`, the single binary classifier used
/// by both the reader and the research pipeline. It is intentionally
/// conservative: reserved, documentation, carrier-grade NAT, link-local,
/// multicast and loopback ranges are all treated as non-public.
enum PublicAddressPolicy {
    static func isIPLiteral(_ host: String) -> Bool {
        IPAddress.isLiteral(host)
    }

    static func isIPv4Literal(_ host: String) -> Bool {
        IPAddress.parse(host)?.family == AF_INET
    }

    static func isIPv6Literal(_ host: String) -> Bool {
        IPAddress.parse(host)?.family == AF_INET6
    }

    static func isPublicAddress(_ address: String) -> Bool {
        IPAddress.isPublic(address)
    }

    static func isPublicIPv4(_ host: String) -> Bool {
        guard let parsed = IPAddress.parse(host), parsed.family == AF_INET else { return false }
        return IPAddress.isPublicIPv4(parsed.bytes)
    }

    static func isPublicIPv6(_ host: String) -> Bool {
        guard let parsed = IPAddress.parse(host), parsed.family == AF_INET6 else { return false }
        return IPAddress.isPublicIPv6(parsed.bytes)
    }
}

extension SecurityPolicies {
    /// Synchronous string-level public URL check. DNS resolution and per-hop
    /// redirect checks happen inside `DirectHTMLReader`, which can be async.
    static func validatePublicHTTPURL(_ urlString: String) -> PublicURLValidation {
        guard let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              scheme == allowedScheme,
              let host = components.host,
              !host.isEmpty else {
            return .blocked(reason: "URL must be https with a host")
        }
        if components.user != nil || components.password != nil {
            return .blocked(reason: "URL must not embed credentials")
        }
        if let port = components.port, port != 443 {
            return .blocked(reason: "URL must use port 443")
        }

        let normalizedHost = host.lowercased()
        if normalizedHost == "localhost"
            || normalizedHost.hasSuffix(".localhost")
            || normalizedHost.hasSuffix(".local")
            || normalizedHost.hasSuffix(".internal")
            || normalizedHost.hasSuffix(".home.arpa") {
            return .blocked(reason: "Local host names are not allowed")
        }

        // Numeric-looking hosts that are not canonical literals (`010.0.0.1`,
        // `0x7f.0.0.1`) may still be interpreted as an address by the resolver.
        let firstLabel = normalizedHost.split(separator: ".").first.map(String.init) ?? ""
        if normalizedHost.range(of: "^[0-9.]+$", options: .regularExpression) != nil,
           !PublicAddressPolicy.isIPLiteral(normalizedHost) {
            return .blocked(reason: "Ambiguous numeric host")
        }
        if firstLabel.hasPrefix("0x") {
            return .blocked(reason: "Ambiguous numeric host")
        }

        if PublicAddressPolicy.isIPLiteral(normalizedHost) {
            guard PublicAddressPolicy.isPublicAddress(normalizedHost) else {
                return .blocked(reason: "Non-public IP address")
            }
            guard let url = components.url else {
                return .blocked(reason: "Invalid URL")
            }
            return .valid(url)
        }

        guard normalizedHost.contains(".") else {
            return .blocked(reason: "Single-label hosts are not public")
        }
        guard let url = components.url else {
            return .blocked(reason: "Invalid URL")
        }
        return .valid(url)
    }
}
