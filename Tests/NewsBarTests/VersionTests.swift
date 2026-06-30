import XCTest
@testable import NewsBar

final class VersionTests: XCTestCase {
    func testVersionIsNewer_SimpleIncrement_True() {
        XCTAssertTrue(versionIsNewer("1.1.0", than: "1.0.0"))
    }

    func testVersionIsNewer_Same_False() {
        XCTAssertFalse(versionIsNewer("1.0.0", than: "1.0.0"))
    }

    func testVersionIsNewer_DifferentLength_True() {
        XCTAssertTrue(versionIsNewer("1.0.1", than: "1.0.0"))
    }

    func testVersionIsNewer_StripsVPrefix_True() {
        XCTAssertTrue(versionIsNewer("v1.3.6", than: "1.3.5"))
    }

    func testVersionIsNewer_PrereleaseUsesCoreVersion_FalseForSameCore() {
        XCTAssertFalse(versionIsNewer("1.4.0-beta.1", than: "1.4.0"))
    }

    func testGitHubAssetSHA256Digest_StripsPrefixAndLowercases() {
        let digest = "sha256:ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789"
        let asset = GitHubAsset(
            name: "NewsBar-1.3.5.dmg",
            browser_download_url: "https://example.com/NewsBar-1.3.5.dmg",
            size: 123,
            content_type: "application/x-apple-diskimage",
            digest: digest
        )

        XCTAssertEqual(
            asset.sha256Digest,
            "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        )
    }

    func testGitHubAssetSHA256Digest_InvalidDigestReturnsNil() {
        let asset = GitHubAsset(
            name: "NewsBar-1.3.5.dmg",
            browser_download_url: "https://example.com/NewsBar-1.3.5.dmg",
            size: 123,
            content_type: nil,
            digest: "sha256:not-a-valid-digest"
        )

        XCTAssertNil(asset.sha256Digest)
    }

    func testGitHubAssetDecodesWithoutDigest() throws {
        let json = #"""
        {
            "name": "NewsBar-1.3.5.dmg",
            "browser_download_url": "https://example.com/NewsBar-1.3.5.dmg",
            "size": 123,
            "content_type": "application/x-apple-diskimage"
        }
        """#.data(using: .utf8)!

        let asset = try JSONDecoder().decode(GitHubAsset.self, from: json)
        XCTAssertNil(asset.sha256Digest)
        XCTAssertTrue(asset.isDMG)
    }
}
