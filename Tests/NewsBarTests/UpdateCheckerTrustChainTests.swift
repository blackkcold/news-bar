import XCTest
@testable import NewsBar

final class UpdateCheckerTrustChainTests: XCTestCase {

    // MARK: - isGitHubOwnedHost

    func testIsGitHubOwnedHost_GitHubCom_True() {
        XCTAssertTrue(UpdateChecker.isGitHubOwnedHost("github.com"))
    }

    func testIsGitHubOwnedHost_ObjectsGithubusercontent_True() {
        XCTAssertTrue(UpdateChecker.isGitHubOwnedHost("objects.githubusercontent.com"))
    }

    func testIsGitHubOwnedHost_ReleaseAssetsGithubusercontent_True() {
        XCTAssertTrue(UpdateChecker.isGitHubOwnedHost("release-assets.githubusercontent.com"))
    }

    func testIsGitHubOwnedHost_CaseInsensitive_True() {
        XCTAssertTrue(UpdateChecker.isGitHubOwnedHost("GitHub.Com"))
        XCTAssertTrue(UpdateChecker.isGitHubOwnedHost("OBJECTS.GITHUBUSERCONTENT.COM"))
    }

    func testIsGitHubOwnedHost_ThirdPartyProxy_False() {
        XCTAssertFalse(UpdateChecker.isGitHubOwnedHost("gh-proxy.com"))
    }

    func testIsGitHubOwnedHost_ArbitraryHost_False() {
        XCTAssertFalse(UpdateChecker.isGitHubOwnedHost("evil.example.com"))
    }

    func testIsGitHubOwnedHost_Nil_False() {
        XCTAssertFalse(UpdateChecker.isGitHubOwnedHost(nil))
    }

    func testIsGitHubOwnedHost_Empty_False() {
        XCTAssertFalse(UpdateChecker.isGitHubOwnedHost(""))
    }

    // MARK: - canAuthorizeAutoDownload

    func testCanAuthorize_CanonicalWithGitHubHost_True() {
        XCTAssertTrue(
            UpdateChecker.canAuthorizeAutoDownload(
                provenance: .canonical,
                downloadHost: "github.com"
            )
        )
    }

    func testCanAuthorize_CanonicalWithObjectsHost_True() {
        XCTAssertTrue(
            UpdateChecker.canAuthorizeAutoDownload(
                provenance: .canonical,
                downloadHost: "objects.githubusercontent.com"
            )
        )
    }

    func testCanAuthorize_ProxyWithGitHubHost_False() {
        XCTAssertFalse(
            UpdateChecker.canAuthorizeAutoDownload(
                provenance: .proxy(label: "ghproxy"),
                downloadHost: "github.com"
            )
        )
    }

    func testCanAuthorize_CanonicalWithNonGitHubHost_False() {
        XCTAssertFalse(
            UpdateChecker.canAuthorizeAutoDownload(
                provenance: .canonical,
                downloadHost: "evil.example.com"
            )
        )
    }

    func testCanAuthorize_ProxyWithNonGitHubHost_False() {
        XCTAssertFalse(
            UpdateChecker.canAuthorizeAutoDownload(
                provenance: .proxy(label: "ghproxy888"),
                downloadHost: "evil.example.com"
            )
        )
    }

    func testCanAuthorize_CanonicalWithNilHost_False() {
        XCTAssertFalse(
            UpdateChecker.canAuthorizeAutoDownload(
                provenance: .canonical,
                downloadHost: nil
            )
        )
    }

    func testCanAuthorize_ProxyWithNilHost_False() {
        XCTAssertFalse(
            UpdateChecker.canAuthorizeAutoDownload(
                provenance: .proxy(label: "ghproxy"),
                downloadHost: nil
            )
        )
    }

    // MARK: - ReleaseProvenance defaults

    func testGitHubRelease_DefaultProvenanceIsCanonical() throws {
        let json = #"""
        {
            "tag_name": "v1.5.0",
            "name": "Release 1.5.0",
            "body": "changelog",
            "assets": []
        }
        """#.data(using: .utf8)!

        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        XCTAssertEqual(release.provenance, .canonical)
        XCTAssertTrue(release.isCanonical)
    }

    func testGitHubRelease_ProxyProvenanceIsNotCanonical() {
        var release = GitHubRelease(
            tag_name: "v1.5.0",
            name: nil,
            body: nil,
            assets: []
        )
        release.provenance = .proxy(label: "ghproxy")

        XCTAssertFalse(release.isCanonical)
        XCTAssertEqual(release.provenance, .proxy(label: "ghproxy"))
    }

    func testGitHubRelease_CanonicalProvenanceIsCanonical() {
        let release = GitHubRelease(
            tag_name: "v1.5.0",
            name: nil,
            body: nil,
            assets: []
        )

        XCTAssertTrue(release.isCanonical)
        XCTAssertEqual(release.provenance, .canonical)
    }

    // MARK: - Trust chain policy: proxy can never authorize download

    func testTrustChain_ProxyMetadataCannotAuthorizeEvenWithGitHubHost() {
        let proxyRelease = makeRelease(
            provenance: .proxy(label: "ghproxy"),
            downloadURL: "https://github.com/blackkcold/news-bar/releases/download/v1.5.0/NewsBar-1.5.0.dmg"
        )

        let host = URL(string: proxyRelease.assets[0].browser_download_url)?.host
        XCTAssertFalse(UpdateChecker.canAuthorizeAutoDownload(
            provenance: proxyRelease.provenance,
            downloadHost: host
        ))
    }

    func testTrustChain_CanonicalWithGitHubHostAuthorizes() {
        let canonicalRelease = makeRelease(
            provenance: .canonical,
            downloadURL: "https://github.com/blackkcold/news-bar/releases/download/v1.5.0/NewsBar-1.5.0.dmg"
        )

        let host = URL(string: canonicalRelease.assets[0].browser_download_url)?.host
        XCTAssertTrue(UpdateChecker.canAuthorizeAutoDownload(
            provenance: canonicalRelease.provenance,
            downloadHost: host
        ))
    }

    func testTrustChain_CanonicalWithRedirectedHostRejected() {
        let canonicalRelease = makeRelease(
            provenance: .canonical,
            downloadURL: "https://objects.githubusercontent.com/blackkcold/news-bar/NewsBar-1.5.0.dmg"
        )

        let host = URL(string: canonicalRelease.assets[0].browser_download_url)?.host
        XCTAssertTrue(UpdateChecker.canAuthorizeAutoDownload(
            provenance: canonicalRelease.provenance,
            downloadHost: host
        ))
    }

    func testTrustChain_CanonicalWithAttackerHostRejected() {
        let canonicalRelease = makeRelease(
            provenance: .canonical,
            downloadURL: "https://attacker.example.com/NewsBar-1.5.0.dmg"
        )

        let host = URL(string: canonicalRelease.assets[0].browser_download_url)?.host
        XCTAssertFalse(UpdateChecker.canAuthorizeAutoDownload(
            provenance: canonicalRelease.provenance,
            downloadHost: host
        ))
    }

    func testTrustChain_ProxyWithAttackerHostRejected() {
        let proxyRelease = makeRelease(
            provenance: .proxy(label: "ghproxy"),
            downloadURL: "https://attacker.example.com/NewsBar-1.5.0.dmg"
        )

        let host = URL(string: proxyRelease.assets[0].browser_download_url)?.host
        XCTAssertFalse(UpdateChecker.canAuthorizeAutoDownload(
            provenance: proxyRelease.provenance,
            downloadHost: host
        ))
    }

    // MARK: - SHA-256 digest still validated (existing checks preserved)

    func testSHA256Digest_ValidHex_PreservedFromCanonical() {
        let release = makeRelease(
            provenance: .canonical,
            downloadURL: "https://github.com/blackkcold/news-bar/releases/download/v1.5.0/NewsBar-1.5.0.dmg",
            digest: "sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        )

        XCTAssertEqual(
            release.assets[0].sha256Digest,
            "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        )
    }

    func testSHA256Digest_ProxyDigestStillParsedButCannotAuthorize() {
        let proxyRelease = makeRelease(
            provenance: .proxy(label: "ghproxy"),
            downloadURL: "https://github.com/blackkcold/news-bar/releases/download/v1.5.0/NewsBar-1.5.0.dmg",
            digest: "sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        )

        XCTAssertEqual(
            proxyRelease.assets[0].sha256Digest,
            "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        )
        XCTAssertFalse(proxyRelease.isCanonical)
    }

    // MARK: - Helpers

    private func makeRelease(
        provenance: ReleaseProvenance,
        downloadURL: String,
        digest: String? = nil
    ) -> GitHubRelease {
        var release = GitHubRelease(
            tag_name: "v1.5.0",
            name: "Release 1.5.0",
            body: "changelog",
            assets: [
                GitHubAsset(
                    name: "NewsBar-1.5.0.dmg",
                    browser_download_url: downloadURL,
                    size: 10_000_000,
                    content_type: "application/x-apple-diskimage",
                    digest: digest
                )
            ]
        )
        release.provenance = provenance
        return release
    }
}