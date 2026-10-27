import Foundation

struct SourceTierInfo: Codable, Hashable, Sendable {
    let tier: SourceTier
    /// `false` for an unknown domain, which is tier 3 by default and may not
    /// single-handedly support a "confirmed" verdict.
    let isKnown: Bool
    /// Registrable domain (eTLD+1) used for independence counting.
    let domain: String
}

/// Static, conservative source tier catalog. It is intentionally small and
/// data-only: unknown domains stay tier 3 (`isKnown == false`) rather than
/// being promoted or demoted by heuristics.
enum SourceTierCatalog {
    static func info(for url: String) -> SourceTierInfo {
        guard let host = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines))?.host,
              !host.isEmpty else {
            return SourceTierInfo(tier: .industry, isKnown: false, domain: "")
        }
        return info(forHost: host)
    }

    static func info(forHost host: String) -> SourceTierInfo {
        let hostKey = normalizedHost(host)
        guard !hostKey.isEmpty else {
            return SourceTierInfo(tier: .industry, isKnown: false, domain: "")
        }

        let domain = registrableDomain(hostKey)
        if let tier = knownTiers[hostKey] ?? knownTiers[domain] {
            return SourceTierInfo(tier: tier, isKnown: true, domain: domain)
        }
        if hasSuffix(hostKey, ".gov.cn") || hasSuffix(hostKey, ".gov") || hasSuffix(hostKey, ".mil") {
            return SourceTierInfo(tier: .primary, isKnown: true, domain: domain)
        }
        if hasSuffix(hostKey, ".edu.cn") || hasSuffix(hostKey, ".edu") || hasSuffix(hostKey, ".ac.uk") {
            return SourceTierInfo(tier: .major, isKnown: true, domain: domain)
        }
        return SourceTierInfo(tier: .industry, isKnown: false, domain: domain)
    }

    /// eTLD+1 approximation with a small multi-part suffix table. IP addresses
    /// and single-label hosts are returned unchanged.
    static func registrableDomain(_ host: String) -> String {
        let cleaned = normalizedHost(host)
        guard !cleaned.isEmpty, !cleaned.contains(":") else { return cleaned }
        if cleaned.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil {
            return cleaned
        }
        let labels = cleaned.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return cleaned }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if multiPartSuffixes.contains(lastTwo) {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    private static func normalizedHost(_ host: String) -> String {
        var value = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while value.hasSuffix(".") { value.removeLast() }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        return value
    }

    private static func hasSuffix(_ host: String, _ suffix: String) -> Bool {
        host == String(suffix.dropFirst()) || host.hasSuffix(suffix)
    }

    private static let multiPartSuffixes: Set<String> = [
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
        "co.uk", "org.uk", "ac.uk", "gov.uk",
        "co.jp", "ne.jp", "or.jp",
        "com.hk", "com.tw", "com.au", "co.nz", "com.sg", "co.kr",
        "com.br", "com.mx",
    ]

    private static let knownTiers: [String: SourceTier] = [
        // Tier 1 — first-party / wire services
        "xinhuanet.com": .primary,
        "news.cn": .primary,
        "people.com.cn": .primary,
        "cctv.com": .primary,
        "chinanews.com.cn": .primary,
        "reuters.com": .primary,
        "apnews.com": .primary,
        "afp.com": .primary,
        "bbc.com": .primary,
        "bbc.co.uk": .primary,
        "who.int": .primary,
        "un.org": .primary,

        // Tier 2 — major national / metropolitan outlets
        "thepaper.cn": .major,
        "caixin.com": .major,
        "yicai.com": .major,
        "jiemian.com": .major,
        "infzm.com": .major,
        "nytimes.com": .major,
        "wsj.com": .major,
        "theguardian.com": .major,
        "ft.com": .major,
        "bloomberg.com": .major,
        "economist.com": .major,
        "scmp.com": .major,
        "cnn.com": .major,
        "npr.org": .major,

        // Tier 3 — industry / vertical media (known, but not tier 1–2)
        "36kr.com": .industry,
        "ithome.com": .industry,
        "huxiu.com": .industry,
        "pingwest.com": .industry,
        "geekpark.net": .industry,
        "tmtpost.com": .industry,
        "leiphone.com": .industry,
        "sohu.com": .industry,
        "sina.com.cn": .industry,
        "163.com": .industry,
        "qq.com": .industry,
        "ifeng.com": .industry,
        "theverge.com": .industry,
        "techcrunch.com": .industry,
        "wired.com": .industry,
        "arstechnica.com": .industry,

        // Tier 4 — social, aggregators, self-media
        "weibo.com": .social,
        "weibo.cn": .social,
        "zhihu.com": .social,
        "baidu.com": .social,
        "toutiao.com": .social,
        "douyin.com": .social,
        "bilibili.com": .social,
        "xiaohongshu.com": .social,
        "douban.com": .social,
        "x.com": .social,
        "twitter.com": .social,
        "facebook.com": .social,
        "instagram.com": .social,
        "reddit.com": .social,
        "youtube.com": .social,
        // Exact-host override: registrable domain is qq.com, which is tier 3.
        "mp.weixin.qq.com": .social,
    ]
}
