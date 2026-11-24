import Foundation

/// What the current cookie snapshot can do before any write path exists.
///
/// This is a pure capability check: it never sends a request, never persists a
/// cookie, and never logs a value. The write service is gated on a real request
/// capture, so `.ready` only means "the desktop credentials needed for a write
/// are present", not "writes are implemented".
enum WeiboWriteCapability: String, Equatable, Sendable, CaseIterable {
    /// Desktop `SUB` and `XSRF-TOKEN` are both present.
    case ready
    /// Desktop `SUB` is present but the AJAX XSRF cookie is missing.
    case missingXSRF
    /// Only the mobile session is available; desktop AJAX writes cannot use it.
    case mobileOnly
    /// No usable login cookie.
    case signedOut

    var allowsWrites: Bool { self == .ready }
}

/// Minimal, side-effect-free access to names in a `Cookie` request header.
/// Values are only inspected to decide presence; they are never printed or
/// written anywhere.
enum WeiboCookieHeader {
    /// First non-empty value for `name`, matched case-insensitively.
    static func value(named name: String, in header: String?) -> String? {
        guard let header else { return nil }
        for pair in header.split(separator: ";", omittingEmptySubsequences: true) {
            let fields = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { continue }
            let key = fields[0].trimmingCharacters(in: .whitespaces)
            guard key.caseInsensitiveCompare(name) == .orderedSame else { continue }
            let raw = fields[1].trimmingCharacters(in: .whitespaces)
            let unquoted = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !unquoted.isEmpty { return unquoted }
        }
        return nil
    }
}

extension WeiboCredentials {
    /// Desktop writes need both the login cookie and the XSRF token that Weibo
    /// mirrors into `x-xsrf-token`. The header is the source of truth; the
    /// `hasDesktopLogin` flag alone was the old, insufficient check.
    var writeCapability: WeiboWriteCapability {
        let desktopSUB = WeiboCookieHeader.value(named: "SUB", in: desktopCookieHeader)
        let desktopXSRF = WeiboCookieHeader.value(named: "XSRF-TOKEN", in: desktopCookieHeader)
        if desktopSUB != nil, desktopXSRF != nil {
            return .ready
        }
        if desktopSUB != nil {
            return .missingXSRF
        }
        if WeiboCookieHeader.value(named: "SUB", in: mobileCookieHeader) != nil {
            return .mobileOnly
        }
        return .signedOut
    }
}
