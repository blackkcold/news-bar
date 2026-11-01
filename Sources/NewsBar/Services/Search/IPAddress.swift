import Darwin
import Foundation

/// Binary IP classification shared by the reader and the research pipeline.
///
/// String prefix matching is not sufficient for IPv6: the same address has
/// many textual forms (`::1` vs `0:0:0:0:0:0:0:1`). Every check here parses
/// into bytes with `inet_pton` first.
enum IPAddress {
    struct Parsed: Equatable {
        let family: Int32
        let bytes: [UInt8]
    }

    static func parse(_ raw: String) -> Parsed? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("["), text.hasSuffix("]") {
            text.removeFirst()
            text.removeLast()
        }
        // A zone identifier is never a public destination.
        if let percent = text.firstIndex(of: "%") {
            text = String(text[text.startIndex..<percent])
        }
        guard !text.isEmpty, text.utf8.count <= 45 else { return nil }

        // Reject legacy IPv4 spellings (`010.0.0.1`) outright. The resolver may
        // still interpret them as an address, so they must never be accepted as
        // a public host name either.
        if text.contains("."), !text.contains(":") {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            for part in parts {
                guard !part.isEmpty, part.count <= 3,
                      part.allSatisfy(\.isNumber),
                      part.count == 1 || part.first != "0" else { return nil }
            }
        }

        if text.contains(":") {
            var buffer = [UInt8](repeating: 0, count: 16)
            guard inet_pton(AF_INET6, text, &buffer) == 1 else { return nil }
            return Parsed(family: AF_INET6, bytes: Array(buffer[0..<16]))
        }

        var buffer = [UInt8](repeating: 0, count: 4)
        guard inet_pton(AF_INET, text, &buffer) == 1 else { return nil }
        return Parsed(family: AF_INET, bytes: buffer)
    }

    static func isLiteral(_ raw: String) -> Bool {
        parse(raw) != nil
    }

    static func isPublic(_ raw: String) -> Bool {
        guard let parsed = parse(raw) else { return false }
        return isPublic(parsed)
    }

    static func isPublic(_ parsed: Parsed) -> Bool {
        parsed.family == AF_INET
            ? isPublicIPv4(parsed.bytes)
            : isPublicIPv6(parsed.bytes)
    }

    /// The local transparent-proxy Fake-IP block (RFC 2544 benchmarking space).
    ///
    /// A router in Fake-IP mode answers every proxied hostname with an address
    /// from this range and maps the address back to the hostname when the
    /// connection reaches it. The address is therefore not a real destination:
    /// it must not be treated as a private host, but it also must not be
    /// accepted by the general public-address classifier. The reader only
    /// relaxes this block after it has positively detected a local Fake-IP
    /// network.
    static func isFakeIP(_ raw: String) -> Bool {
        guard let parsed = parse(raw), parsed.family == AF_INET else { return false }
        return isFakeIPv4(parsed.bytes)
    }

    static func isFakeIPv4(_ bytes: [UInt8]) -> Bool {
        bytes.count == 4 && bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19)
    }

    static func isPublicIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let a = bytes[0], b = bytes[1], c = bytes[2]

        if a == 0 { return false }                                   // 0.0.0.0/8
        if a == 10 { return false }                                  // 10.0.0.0/8
        if a == 100, (64...127).contains(b) { return false }         // 100.64.0.0/10
        if a == 127 { return false }                                 // loopback
        if a == 169, b == 254 { return false }                       // link-local
        if a == 172, (16...31).contains(b) { return false }          // 172.16.0.0/12
        if a == 192, b == 0 { return false }                         // 192.0.0.0/24 + TEST-NET-1
        if a == 192, b == 168 { return false }                       // private
        if a == 198, b == 18 || b == 19 { return false }             // benchmarking
        if a == 198, b == 51, c == 100 { return false }              // TEST-NET-2
        if a == 203, b == 0, c == 113 { return false }               // TEST-NET-3
        if a >= 224 { return false }                                 // multicast + reserved
        return true
    }

    static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }

        // Only global unicast 2000::/3. This allowlist alone excludes ::/8
        // (`::`, `::1`, `::ffff:0:0/96`), 64:ff9b::/96, fc00::/7, fe80::/10,
        // fec0::/10 and ff00::/8.
        guard bytes[0] & 0xE0 == 0x20 else { return false }

        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0d, bytes[3] == 0xb8 {
            return false // 2001:db8::/32 documentation
        }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x00, bytes[3] == 0x00 {
            return false // 2001::/32 Teredo
        }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x00, bytes[3] == 0x10 {
            return false // 2001:10::/28 ORCHID
        }
        if bytes[0] == 0x20, bytes[1] == 0x02 {
            return false // 2002::/16 6to4
        }
        if bytes[0] == 0x3f, bytes[1] == 0xff, bytes[2] & 0xf0 == 0x00 {
            return false // 3fff::/20 documentation
        }
        return true
    }
}
