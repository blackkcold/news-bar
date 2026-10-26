import Foundation

/// WKWebView's default user agent ends at `(KHTML, like Gecko)` and carries no
/// browser product token. Some sites classify that as an old or unsupported
/// client and serve their "browser too old" interstitial, so the reader reports
/// a coherent Safari user agent for the same WebKit engine.
enum ReaderUserAgent {
    static func value(
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String {
        let major = max(operatingSystemVersion.majorVersion, 0)
        let minor = max(operatingSystemVersion.minorVersion, 0)
        // Safari 26 adopted the macOS version number; earlier Safari majors ran
        // three ahead (macOS 15 → Safari 18). Keep the claim plausible on both.
        let safariMajor = major >= 26 ? major : major + 3
        let os = "\(major)_\(minor)"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X \(os)) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariMajor).\(minor) Safari/605.1.15"
    }
}
