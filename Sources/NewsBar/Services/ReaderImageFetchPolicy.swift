import Foundation

/// Request privacy and destination checks shared by every image redirect hop.
enum ReaderImageFetchPolicy {
    static func allows(
        _ url: URL,
        proxyResolves: Bool,
        resolve: @Sendable (URL) async -> ReaderNavigationPolicy.DestinationResolution,
        allowsFakeIP: @Sendable () async -> Bool
    ) async -> Bool {
        guard ReaderNavigationPolicy.allowedURL(url.absoluteString) != nil else { return false }
        if proxyResolves { return true }
        switch await resolve(url) {
        case .publicDestination: return true
        case .fakeIPDestination: return await allowsFakeIP()
        case .privateDestination, .unresolved: return false
        }
    }

    /// Same-origin images may need the article path for anti-hotlink checks;
    /// cross-origin images receive only the origin, never article paths/tokens.
    static func referer(article: String?, destination: URL) -> String? {
        guard let article, let source = ReaderNavigationPolicy.allowedURL(article),
              var parts = URLComponents(url: source, resolvingAgainstBaseURL: false),
              let sourceHost = source.host?.lowercased(),
              let destinationHost = destination.host?.lowercased() else { return nil }
        parts.fragment = nil
        if sourceHost != destinationHost || (source.port ?? 443) != (destination.port ?? 443) {
            parts.path = "/"
            parts.query = nil
        }
        return parts.url?.absoluteString
    }

    static func prepare(_ request: URLRequest, cookies: [HTTPCookie], article: String?) -> URLRequest {
        var result = request
        result.httpShouldHandleCookies = false
        result.setValue(nil, forHTTPHeaderField: "Cookie")
        result.setValue(nil, forHTTPHeaderField: "Referer")
        guard let url = result.url, let host = url.host else { return result }
        let path = url.path.isEmpty ? "/" : url.path
        let eligible = cookies.filter { cookie in
            guard ReaderCookieHost.matches(host: host, domain: cookie.domain),
                  cookie.expiresDate.map({ $0 > Date() }) ?? true else { return false }
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            guard path.hasPrefix(cookiePath) else { return false }
            return path == cookiePath || cookiePath.hasSuffix("/")
                || path.dropFirst(cookiePath.count).first == "/"
        }
        if !eligible.isEmpty {
            for (name, value) in HTTPCookie.requestHeaderFields(with: eligible) {
                result.setValue(value, forHTTPHeaderField: name)
            }
        }
        result.setValue(referer(article: article, destination: url), forHTTPHeaderField: "Referer")
        return result
    }
}
