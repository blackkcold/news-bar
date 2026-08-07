import XCTest
@testable import NewsBar

final class RSSRecommendationsTests: XCTestCase {

    // MARK: - Known proxy / aggregator / third-party hosts

    private let knownProxyHosts: Set<String> = [
        "rsshub.app",
        "hnrss.org",
        "feedx.xyz",
        "rss-bridge.org",
        "fetchrss.com",
        "feed43.com",
        "rss.app",
        "feedburner.com",
        "feedly.com",
        "inoreader.com",
        "feedwrangler.com",
        "newsblur.com",
        "theoldreader.com",
        "bazqux.com",
        "miniflux.app",
        "freshrss.org",
        "tt-rss.org",
        "rssant.com",
    ]

    // MARK: - HTTPS enforcement

    func test_allRecommendations_useHTTPS() {
        for rec in RSSRecommendations.all {
            guard let components = URLComponents(string: rec.url) else {
                XCTFail("\(rec.name): invalid URL '\(rec.url)'")
                continue
            }
            XCTAssertEqual(
                components.scheme?.lowercased(),
                "https",
                "\(rec.name): must use HTTPS, got '\(components.scheme ?? "nil")'"
            )
        }
    }

    func test_allRecommendationURLs_areValid() {
        for rec in RSSRecommendations.all {
            XCTAssertNotNil(
                URL(string: rec.url),
                "\(rec.name): URL '\(rec.url)' could not be parsed"
            )
        }
    }

    // MARK: - Proxy-host rejection

    func test_noFeed_usesKnownProxyHost() {
        for rec in RSSRecommendations.all {
            guard let host = URL(string: rec.url)?.host?.lowercased() else {
                XCTFail("\(rec.name): could not extract host from '\(rec.url)'")
                continue
            }
            for proxyHost in knownProxyHosts {
                XCTAssertFalse(
                    host == proxyHost || host.hasSuffix(".\(proxyHost)"),
                    "\(rec.name): host '\(host)' matches known proxy '\(proxyHost)'"
                )
            }
        }
    }

    func test_noFeed_usesRSSHubApp() {
        for rec in RSSRecommendations.all {
            guard let host = URL(string: rec.url)?.host else { continue }
            XCTAssertFalse(
                host.contains("rsshub"),
                "\(rec.name): host '\(host)' appears to be rsshub — use direct publisher feed"
            )
        }
    }

    // MARK: - Catalog shape

    func test_catalog_isNotEmpty() {
        XCTAssertFalse(RSSRecommendations.all.isEmpty, "Recommendations catalog must not be empty")
    }

    func test_allRecommendations_haveNonEmptyName() {
        for rec in RSSRecommendations.all {
            XCTAssertFalse(
                rec.name.trimmingCharacters(in: .whitespaces).isEmpty,
                "Feed with URL '\(rec.url)' has empty name"
            )
        }
    }

    func test_noDuplicateURLs() {
        let urls = RSSRecommendations.all.map(\.url)
        let uniqueURLs = Set(urls)
        XCTAssertEqual(
            urls.count, uniqueURLs.count,
            "Duplicate URLs found: \(urls)"
        )
    }

    func test_noDuplicateNames() {
        let names = RSSRecommendations.all.map(\.name)
        let uniqueNames = Set(names)
        XCTAssertEqual(
            names.count, uniqueNames.count,
            "Duplicate names found: \(names)"
        )
    }

    func test36krRecommendation_UsesCanonicalWWWHost() {
        let recommendation = RSSRecommendations.all.first { $0.name == "36氪" }
        XCTAssertEqual(recommendation?.url, "https://www.36kr.com/feed")
        XCTAssertEqual(
            SecurityPolicies.canonicalRSSURL("https://36kr.com/feed"),
            recommendation?.url
        )
    }

    // MARK: - Direct-only: feeds are publisher-hosted, not subdomain proxies

    func test_eachFeed_usesPublisherDomain() {
        // Publisher-hosted means every feed URL's host is the publisher's own
        // domain, not a generic feed service. We already check proxy hosts above.
        // This test guards against future RSSaaS additions.
        let genericFeedDomains: Set<String> = [
            "feeds.bbci.co.uk",   // known BBC subdomain — explicitly allowed
        ]
        for rec in RSSRecommendations.all {
            guard let host = URL(string: rec.url)?.host?.lowercased() else { continue }
            // If the host is in our explicit allow-list, skip the suffix check
            if genericFeedDomains.contains(host) { continue }
            // Reject hosts with generic proxy indicators in hostname
            for indicator in ["rsshub", "hnrss", "feedx", "rss-bridge", "rss.app"] {
                XCTAssertFalse(
                    host.contains(indicator),
                    "\(rec.name): host '\(host)' contains proxy indicator '\(indicator)'"
                )
            }
        }
    }
}
