import Foundation

/// A cookie captured from the Dashboard reader, stored in the encrypted vault.
///
/// Values are kept verbatim so a saved sign-in can be replayed on the next visit.
/// The HTTP-only flag is restored through the `HttpOnly` property key where the
/// platform accepts it; `isHTTPOnly` remains part of the persisted record so a
/// runtime that rejects the key can still fall back safely.
struct ReaderStoredCookie: Codable, Equatable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expiresAt: Date?
    var isSecure: Bool
    var isHTTPOnly: Bool
    var storedAt: Date

    /// Session cookies have no expiry; keep them usable for 30 days after capture
    /// so a sign-in survives a relaunch instead of dying with the process.
    static let sessionLifetime: TimeInterval = 30 * 24 * 60 * 60

    init(
        name: String,
        value: String,
        domain: String,
        path: String,
        expiresAt: Date?,
        isSecure: Bool,
        isHTTPOnly: Bool,
        storedAt: Date
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expiresAt = expiresAt
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.storedAt = storedAt
    }

    init?(cookie: HTTPCookie, now: Date = Date()) {
        let trimmedName = cookie.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let domain = ReaderCookieHost.normalizeCookieDomain(cookie.domain) else { return nil }
        self.name = trimmedName
        self.value = cookie.value
        self.domain = domain
        self.path = cookie.path.isEmpty ? "/" : cookie.path
        self.expiresAt = cookie.expiresDate
        self.isSecure = cookie.isSecure
        self.isHTTPOnly = cookie.isHTTPOnly
        self.storedAt = now
    }

    var identity: String { "\(name)|\(domain)|\(path)" }

    /// A cookie without a leading dot is scoped to one host only.
    var isHostOnly: Bool { !domain.hasPrefix(".") }

    /// Domain without the leading dot, for matching and display.
    var domainBase: String { domain.hasPrefix(".") ? String(domain.dropFirst()) : domain }

    var effectiveExpiry: Date {
        expiresAt ?? storedAt.addingTimeInterval(Self.sessionLifetime)
    }

    func isExpired(now: Date = Date()) -> Bool {
        effectiveExpiry <= now
    }

    func makeCookie() -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
            .secure: isSecure ? "TRUE" : "FALSE",
        ]
        // `HTTPCookie(properties:)` drops `.expires` whenever `.discard` is present,
        // so session cookies are persisted with an explicit soft expiry instead.
        properties[.expires] = expiresAt ?? effectiveExpiry

        let httpOnlyKey = HTTPCookiePropertyKey("HttpOnly")
        if isHTTPOnly {
            properties[httpOnlyKey] = "TRUE"
        }
        if let cookie = HTTPCookie(properties: properties),
           !isHTTPOnly || cookie.isHTTPOnly {
            return cookie
        }
        // Some Foundation versions ignore the undocumented key. Never fail a
        // replay because of it; fall back to the existing non-HTTP-only cookie.
        if isHTTPOnly {
            properties.removeValue(forKey: httpOnlyKey)
            return HTTPCookie(properties: properties)
        }
        return nil
    }
}

enum ReaderCookieHost {
    /// Lowercase, no leading dot, no trailing dot, no port.
    static func normalize(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        if value.hasPrefix(".") { value.removeFirst() }
        if value.hasSuffix(".") { value.removeLast() }
        if value.filter({ $0 == ":" }).count == 1, let colon = value.lastIndex(of: ":") {
            value = String(value[..<colon])
        }
        return value.isEmpty ? nil : value
    }

    /// Cookie domain as WebKit reports it: a leading dot means the cookie is
    /// scoped to subdomains (`.weibo.com`), while no dot means host-only
    /// (`weibo.com`). Never strip that dot when persisting a cookie.
    static func normalizeCookieDomain(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        if value.hasSuffix(".") { value.removeLast() }
        guard value != ".", !value.isEmpty, !value.contains(":") else { return nil }
        return value
    }

    /// Cookie-domain matching with a dot boundary, so `evil-example.com`
    /// never matches `example.com`. Host-only cookies (`weibo.com`) do not
    /// cover subdomains; domain cookies (`.weibo.com`) do.
    static func matches(host: String, domain: String) -> Bool {
        guard let host = normalize(host),
              let domain = normalizeCookieDomain(domain) else { return false }
        if domain.hasPrefix(".") {
            let base = String(domain.dropFirst())
            guard base.contains(".") else { return false }
            return host == base || host.hasSuffix("." + base)
        }
        return host == domain
    }

    /// True when a cookie domain belongs to a site: the site itself, one of its
    /// subdomains, or a known short-link/SSO alias (`b23.tv` -> `bilibili.com`).
    ///
    /// This is used to select one site's cookie jar for capture and display.
    /// It does not broaden the cookie's own host-only scope: WebKit still only
    /// sends a host-only cookie to its exact host.
    static func belongsToSite(domain: String, site: String) -> Bool {
        guard let domain = normalizeCookieDomain(domain),
              let rawSite = normalize(site),
              let siteKey = ReaderCookieSiteScope.site(for: rawSite) else { return false }
        let base = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        if base == siteKey || base.hasSuffix("." + siteKey) { return true }
        return ReaderCookieSiteScope.site(for: base) == siteKey
    }
}

struct ReaderSavedSite: Codable, Identifiable, Equatable, Sendable {
    var host: String
    var title: String?
    var savedAt: Date
    var updatedAt: Date
    var cookies: [ReaderStoredCookie]

    var id: String { host }

    func validCookies(now: Date = Date()) -> [ReaderStoredCookie] {
        cookies.filter { !$0.isExpired(now: now) }
    }
}

struct ReaderCookieSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 3

    var version: Int
    var sites: [ReaderSavedSite]

    init(version: Int = currentVersion, sites: [ReaderSavedSite] = []) {
        self.version = version
        self.sites = sites
    }
}
