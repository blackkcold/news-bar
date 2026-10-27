import XCTest
@testable import NewsBar

final class UpdateCheckerFallbackTests: XCTestCase {

    // MARK: - Release page parsing (official GitHub HTML fallback)

    func testReleasePageVersionParsesCanonicalRedirect() {
        let url = URL(string: "https://github.com/blackkcold/news-bar/releases/tag/v2.6.0")!
        XCTAssertEqual(UpdateChecker.version(fromReleasePageURL: url), "2.6.0")
    }

    func testReleasePageVersionRejectsAttackerHost() {
        let url = URL(string: "https://attacker.example.com/blackkcold/news-bar/releases/tag/v2.6.0")!
        XCTAssertNil(UpdateChecker.version(fromReleasePageURL: url))
    }

    func testReleasePageVersionRejectsOtherRepository() {
        let url = URL(string: "https://github.com/attacker/news-bar/releases/tag/v2.6.0")!
        XCTAssertNil(UpdateChecker.version(fromReleasePageURL: url))
    }

    func testReleasePageVersionRejectsNonSemanticTag() {
        let url = URL(string: "https://github.com/blackkcold/news-bar/releases/tag/nightly")!
        XCTAssertNil(UpdateChecker.version(fromReleasePageURL: url))
    }

    // MARK: - Asset URL construction

    func testFallbackAssetURLsUseOfficialRepoReleasePath() {
        XCTAssertEqual(
            UpdateChecker.releaseAssetURL(version: "2.6.0", suffix: ".dmg")?.absoluteString,
            "https://github.com/blackkcold/news-bar/releases/download/v2.6.0/NewsBar-2.6.0.dmg"
        )
        XCTAssertEqual(
            UpdateChecker.releaseAssetURL(version: "2.6.0", suffix: ".dmg.sha256")?.absoluteString,
            "https://github.com/blackkcold/news-bar/releases/download/v2.6.0/NewsBar-2.6.0.dmg.sha256"
        )
    }

    func testFallbackAssetURLRejectsNonSemanticVersion() {
        XCTAssertNil(UpdateChecker.releaseAssetURL(version: "../bad", suffix: ".dmg"))
    }

    // MARK: - SHA256 sidecar parsing

    func testSHA256FileParsesHashOnly() {
        let hash = String(repeating: "a", count: 64)
        XCTAssertEqual(UpdateChecker.parseSHA256File(hash + "\n"), hash)
    }

    func testSHA256FileParsesHashWithFilename() {
        let hash = String(repeating: "b", count: 64)
        XCTAssertEqual(UpdateChecker.parseSHA256File("\(hash)  NewsBar-2.6.0.dmg\n"), hash)
    }

    func testSHA256FileRejectsInvalid() {
        XCTAssertNil(UpdateChecker.parseSHA256File("not-a-digest"))
        XCTAssertNil(UpdateChecker.parseSHA256File(String(repeating: "z", count: 64)))
        XCTAssertNil(UpdateChecker.parseSHA256File(""))
    }

    // MARK: - Trust chain for the official HTML fallback

    func testGitHubHTMLProvenanceAuthorizesGitHubHost() {
        XCTAssertTrue(
            UpdateChecker.canAuthorizeAutoDownload(
                provenance: .githubHTML,
                downloadHost: "github.com"
            )
        )
        XCTAssertTrue(
            UpdateChecker.canAuthorizeAutoDownload(
                provenance: .githubHTML,
                downloadHost: "objects.githubusercontent.com"
            )
        )
    }

    func testGitHubHTMLProvenanceRejectsAttackerHost() {
        XCTAssertFalse(
            UpdateChecker.canAuthorizeAutoDownload(
                provenance: .githubHTML,
                downloadHost: "attacker.example.com"
            )
        )
        XCTAssertFalse(
            UpdateChecker.canAuthorizeAutoDownload(
                provenance: .githubHTML,
                downloadHost: nil
            )
        )
    }

    func testGitHubHTMLIsNotReportedAsCanonicalAPIProvenance() {
        let release = GitHubRelease(
            tag_name: "v2.6.0",
            name: nil,
            body: nil,
            assets: [],
            provenance: .githubHTML
        )
        XCTAssertFalse(release.isCanonical)
        XCTAssertTrue(release.isGitHubOfficial)
    }

    // Opt-in live check: proves the official HTML fallback works end-to-end
    // without a third-party mirror. Run with NEWSBAR_LIVE_UPDATE_TEST=1.
    func testLiveGitHubHTMLFallbackFetchesPublishedRelease() async throws {
        guard ProcessInfo.processInfo.environment["NEWSBAR_LIVE_UPDATE_TEST"] == "1" else {
            throw XCTSkip("set NEWSBAR_LIVE_UPDATE_TEST=1 to run")
        }
        let release = await UpdateChecker().fetchGitHubHTMLFallback()
        XCTAssertNotNil(release)
        XCTAssertEqual(release?.version, "2.6.0")
        XCTAssertEqual(release?.provenance, .githubHTML)
        XCTAssertEqual(release?.assets.first?.sha256Digest?.count, 64)
        XCTAssertEqual(
            release?.assets.first?.browser_download_url,
            "https://github.com/blackkcold/news-bar/releases/download/v2.6.0/NewsBar-2.6.0.dmg"
        )
    }
}
