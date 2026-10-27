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

/// Pure address classification used before any local HTTP request. It is
/// intentionally conservative: reserved, documentation, carrier-grade NAT,
/// link-local, multicast and loopback ranges are all treated as non-public.
enum PublicAddressPolicy {
    static func isIPLiteral(_ host: String) -> Bool {
        isIPv4Literal(host) || isIPv6Literal(host)
    }

    static func isIPv4Literal(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, let value = Int(part), (0...255).contains(value) else {
                return false
            }
            return String(value) == part || (part.count > 1 && part.first == "0" && value >= 0)
        }
    }

    static func isIPv6Literal(_ host: String) -> Bool {
        let cleaned = stripBrackets(host)
        guard cleaned.contains(":") else { return false }
        return cleaned.unicodeScalars.allSatisfy { scalar in
            CharacterSet(charactersIn: "0123456789abcdefABCDEF:.%").contains(scalar)
        }
    }

    static func isPublicAddress(_ address: String) -> Bool {
        let cleaned = stripBrackets(address)
            .split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? address
        if isIPv4Literal(cleaned) { return isPublicIPv4(cleaned) }
        if isIPv6Literal(cleaned) { return isPublicIPv6(cleaned) }
        return false
    }

    static func isPublicIPv4(_ host: String) -> Bool {
        guard isIPv4Literal(host) else { return false }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        let a = octets[0], b = octets[1], c = octets[2]

        if a == 0 { return false }                                   // 0.0.0.0/8
        if a == 10 { return false }                                  // 10.0.0.0/8
        if a == 100, (64...127).contains(b) { return false }         // 100.64.0.0/10
        if a == 127 { return false }                                 // loopback
        if a == 169, b == 254 { return false }                       // link-local
        if a == 172, (16...31).contains(b) { return false }          // 172.16.0.0/12
        if a == 192, b == 0, c == 0 { return false }                 // 192.0.0.0/24
        if a == 192, b == 0, c == 2 { return false }                 // TEST-NET-1
        if a == 192, b == 168 { return false }                       // private
        if a == 198, (18...19).contains(b) { return false }          // benchmarking
        if a == 198, b == 51, c == 100 { return false }              // TEST-NET-2
        if a == 203, b == 0, c == 113 { return false }               // TEST-NET-3
        if (224...239).contains(a) { return false }                  // multicast
        if a >= 240 { return false }                                 // reserved
        return true
    }

    static func isPublicIPv6(_ host: String) -> Bool {
        let cleaned = stripBrackets(host).lowercased()
        guard isIPv6Literal(cleaned) else { return false }

        if cleaned == "::" || cleaned == "::1" { return false }
        if cleaned.hasPrefix("::ffff:") {
            let tail = String(cleaned.dropFirst("::ffff:".count))
            return isPublicIPv4(tail)
        }

        let firstHextet = cleaned.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        guard let first = UInt16(firstHextet, radix: 16) else {
            // A compressed prefix such as "::1" was handled above; anything
            // else starting with "::" is unspecified or IPv4-compatible.
            return false
        }

        if first & 0xFE00 == 0xFC00 { return false }   // fc00::/7 unique local
        if first & 0xFFC0 == 0xFE80 { return false }   // fe80::/10 link-local
        if first & 0xFF00 == 0xFF00 { return false }   // ff00::/8 multicast
        if first == 0x0100 { return false }            // 100::/64 discard-only
        if first == 0x2001 {
            let second = cleaned.split(separator: ":").dropFirst().first.map(String.init) ?? ""
            if second == "0db8" || second == "db8" { return false } // documentation
            if second == "10" { return false }                       // ORCHID
        }
        if first == 0x0064, cleaned.hasPrefix("64:ff9b:") { return true } // NAT64 (public target)
        return true
    }

    private static func stripBrackets(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("["), value.hasSuffix("]") {
            value.removeFirst()
            value.removeLast()
        }
        return value
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
