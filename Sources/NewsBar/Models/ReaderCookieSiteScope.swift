import Foundation

/// Sign-in cookie scopes shared by a site and its short-link domains.
///
/// Keep this list conservative: only domains that belong to the same account
/// system should share a site key. This is deliberately not a public-suffix
/// implementation; unknown hosts keep their own exact host as the site key.
enum ReaderCookieSiteScope {
    /// Ordered, first match wins. A dictionary would make a future overlapping
    /// group resolve differently on each launch.
    ///
    /// `bili2233.cn` is Bilibili's own short-link domain (CNNIC registrant
    /// 上海幻电信息科技有限公司, contact `@bilibili.com`) and 302s a `BV` id to
    /// `www.bilibili.com`.
    static let aliasGroups: [(site: String, domains: [String])] = [
        ("bilibili.com", ["bilibili.com", "b23.tv", "bili2233.cn"]),
        ("weibo.com", ["weibo.com", "weibo.cn", "t.cn"]),
    ]

    /// Domains that belong to `site`, including `site` itself.
    static func aliases(forSite site: String) -> [String]? {
        aliasGroups.first { $0.site == site }?.domains
    }

    /// Page host -> sign-in site key.
    static func site(for rawHost: String?) -> String? {
        guard let host = ReaderCookieHost.normalize(rawHost) else { return nil }
        for group in aliasGroups {
            if group.domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                return group.site
            }
        }
        return host
    }

    /// URL -> sign-in site key.
    static func site(forURL rawURL: String?) -> String? {
        guard let rawURL, let host = URL(string: rawURL)?.host else { return nil }
        return site(for: host)
    }

    /// True when two URLs resolve to the same sign-in site, so a short-link
    /// redirect (`b23.tv` -> `www.bilibili.com`) is the same destination.
    static func sameSite(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let left = site(forURL: lhs), let right = site(forURL: rhs) else { return false }
        return left == right
    }

    /// Hosts that should be preloaded before opening `rawURL`.
    ///
    /// The initial URL can be a short link (`b23.tv`); the sign-in cookies live
    /// on `.bilibili.com`. Injecting the union lets the 302 target request carry
    /// the sign-in even though the first request cannot use it.
    static func injectionHosts(for rawURL: String?) -> [String] {
        guard let rawURL,
              let host = ReaderCookieHost.normalize(URL(string: rawURL)?.host),
              let site = site(for: host) else { return [] }
        var hosts = [host, site]
        if let aliases = aliases(forSite: site) {
            hosts.append(contentsOf: aliases)
            if site.contains(".") {
                hosts.append("www." + site)
            }
        }
        var seen = Set<String>()
        return hosts.filter { seen.insert($0).inserted }
    }

    /// True when a site key has known short-link or SSO aliases.
    static func isAliasSite(_ site: String) -> Bool {
        aliases(forSite: site) != nil
    }

    /// Cookie domains that belong to a site, used for display and cleanup.
    static func cookieDomains(forSite site: String) -> [String] {
        var domains = [site]
        if let aliases = aliases(forSite: site) {
            domains.append(contentsOf: aliases)
        }
        return Array(Set(domains)).sorted()
    }
}
