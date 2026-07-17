import XCTest
@testable import NewsBar

final class RSSDisplayCountTests: XCTestCase {

    // MARK: - Whitelist constants

    func testValidTextCounts() {
        XCTAssertEqual(RSSSourceConfig.validTextCounts, [5, 10])
    }

    func testValidImageCounts() {
        XCTAssertEqual(RSSSourceConfig.validImageCounts, [4, 6, 8])
    }

    // MARK: - AppSettings defaults

    func testAppSettingsDefaults() {
        let keys = ["rssUnifiedDisplayCount", "rssDefaultTextCount", "rssDefaultImageCount"]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }

        let settings = AppSettings()
        XCTAssertTrue(settings.rssUnifiedDisplayCount)
        XCTAssertEqual(settings.rssDefaultTextCount, 10)
        XCTAssertEqual(settings.rssDefaultImageCount, 4)

        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testAppSettingsPersistsValues() {
        let keys = ["rssUnifiedDisplayCount", "rssDefaultTextCount", "rssDefaultImageCount"]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }

        let settings = AppSettings()
        settings.rssUnifiedDisplayCount = false
        settings.rssDefaultTextCount = 5
        settings.rssDefaultImageCount = 8

        let settings2 = AppSettings()
        XCTAssertFalse(settings2.rssUnifiedDisplayCount)
        XCTAssertEqual(settings2.rssDefaultTextCount, 5)
        XCTAssertEqual(settings2.rssDefaultImageCount, 8)

        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: - AppSettings whitelist validation on init

    func testAppSettingsRejectsInvalidTextCount() {
        let keys = ["rssUnifiedDisplayCount", "rssDefaultTextCount", "rssDefaultImageCount"]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(99, forKey: "rssDefaultTextCount")
        UserDefaults.standard.set(7, forKey: "rssDefaultImageCount")

        let settings = AppSettings()
        XCTAssertEqual(settings.rssDefaultTextCount, 10)
        XCTAssertEqual(settings.rssDefaultImageCount, 4)

        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testAppSettingsAcceptsValidTextCounts() {
        let keys = ["rssUnifiedDisplayCount", "rssDefaultTextCount", "rssDefaultImageCount"]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(5, forKey: "rssDefaultTextCount")

        let settings = AppSettings()
        XCTAssertEqual(settings.rssDefaultTextCount, 5)

        UserDefaults.standard.set(10, forKey: "rssDefaultTextCount")
        let settings2 = AppSettings()
        XCTAssertEqual(settings2.rssDefaultTextCount, 10)

        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testAppSettingsAcceptsValidImageCounts() {
        let keys = ["rssUnifiedDisplayCount", "rssDefaultTextCount", "rssDefaultImageCount"]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(6, forKey: "rssDefaultImageCount")

        let settings = AppSettings()
        XCTAssertEqual(settings.rssDefaultImageCount, 6)

        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: - RSSSourceConfig effectiveTextCount — override chain (unified OFF mode)

    func testEffectiveTextCountUsesOverrideWhenValid() {
        let config = RSSSourceConfig(name: "A", url: "https://a.com", displayMode: .text,
                                      textCountOverride: 10, imageCountOverride: nil)
        XCTAssertEqual(config.effectiveTextCount(global: 5), 10)
    }

    func testEffectiveTextCountFallsToGlobalWhenOverrideNil() {
        let config = RSSSourceConfig(name: "A", url: "https://a.com", displayMode: .text,
                                      textCountOverride: nil, imageCountOverride: nil)
        XCTAssertEqual(config.effectiveTextCount(global: 10), 10)
    }

    func testEffectiveTextCountFallsToGlobalWhenOverrideInvalid() {
        let config = RSSSourceConfig(name: "A", url: "https://a.com", displayMode: .text,
                                      textCountOverride: 3, imageCountOverride: nil)
        XCTAssertEqual(config.effectiveTextCount(global: 10), 10)
    }

    func testEffectiveTextCountFallsToFallbackWhenBothInvalid() {
        let config = RSSSourceConfig(name: "A", url: "https://a.com", displayMode: .text,
                                      textCountOverride: 3, imageCountOverride: nil)
        XCTAssertEqual(config.effectiveTextCount(global: 7), 10)
    }

    func testEffectiveTextCountFallsToFallbackWhenGlobalInvalidAndOverrideNil() {
        let config = RSSSourceConfig(name: "A", url: "https://a.com", displayMode: .text,
                                      textCountOverride: nil, imageCountOverride: nil)
        XCTAssertEqual(config.effectiveTextCount(global: 1), 10)
    }

    // MARK: - RSSSourceConfig effectiveImageCount — override chain (unified OFF mode)

    func testEffectiveImageCountUsesOverrideWhenValid() {
        let config = RSSSourceConfig(name: "A", url: "https://a.com", displayMode: .image,
                                      textCountOverride: nil, imageCountOverride: 8)
        XCTAssertEqual(config.effectiveImageCount(global: 4), 8)
    }

    func testEffectiveImageCountFallsToGlobalWhenOverrideNil() {
        let config = RSSSourceConfig(name: "A", url: "https://a.com", displayMode: .image,
                                      textCountOverride: nil, imageCountOverride: nil)
        XCTAssertEqual(config.effectiveImageCount(global: 6), 6)
    }

    func testEffectiveImageCountFallsToGlobalWhenOverrideInvalid() {
        let config = RSSSourceConfig(name: "A", url: "https://a.com", displayMode: .image,
                                      textCountOverride: nil, imageCountOverride: 2)
        XCTAssertEqual(config.effectiveImageCount(global: 8), 8)
    }

    func testEffectiveImageCountFallsToFallbackWhenBothInvalid() {
        let config = RSSSourceConfig(name: "A", url: "https://a.com", displayMode: .image,
                                      textCountOverride: nil, imageCountOverride: 10)
        XCTAssertEqual(config.effectiveImageCount(global: 5), 4)
    }

    func testEffectiveImageCountFallsToFallbackWhenGlobalInvalidAndOverrideNil() {
        let config = RSSSourceConfig(name: "A", url: "https://a.com", displayMode: .image,
                                      textCountOverride: nil, imageCountOverride: nil)
        XCTAssertEqual(config.effectiveImageCount(global: 1), 4)
    }

    // MARK: - RSSSourceConfig Codable round-trip with overrides

    func testCodableRoundTripWithOverrides() throws {
        let config = RSSSourceConfig(name: "Test", url: "https://t.com", displayMode: .text,
                                      supportsImage: false,
                                      textCountOverride: 10, imageCountOverride: 8)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(RSSSourceConfig.self, from: data)
        XCTAssertEqual(decoded.name, "Test")
        XCTAssertEqual(decoded.url, "https://t.com")
        XCTAssertEqual(decoded.displayMode, .text)
        XCTAssertFalse(decoded.supportsImage)
        XCTAssertEqual(decoded.textCountOverride, 10)
        XCTAssertEqual(decoded.imageCountOverride, 8)
    }

    // MARK: - RSSSourceConfig Codable backward compat (missing override keys)

    func testCodableBackwardCompatWithoutOverrides() throws {
        let json = #"{"name":"Old","url":"https://old.com","displayMode":"text"}"#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RSSSourceConfig.self, from: data)
        XCTAssertEqual(decoded.name, "Old")
        XCTAssertEqual(decoded.displayMode, .text)
        XCTAssertNil(decoded.textCountOverride)
        XCTAssertNil(decoded.imageCountOverride)
    }

    func testCodableBackwardCompatPartialOverrides() throws {
        let json = #"""
        {"name":"P","url":"https://p.com","displayMode":"image","textCountOverride":10}
        """#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RSSSourceConfig.self, from: data)
        XCTAssertEqual(decoded.textCountOverride, 10)
        XCTAssertNil(decoded.imageCountOverride)
    }

    func testArrayWithMixedOverridesDoesNotLoseData() throws {
        let json = #"""
        [
            {"name":"A","url":"https://a.com","displayMode":"text"},
            {"name":"B","url":"https://b.com","displayMode":"text","textCountOverride":10},
            {"name":"C","url":"https://c.com","displayMode":"image","imageCountOverride":8},
            {"name":"D","url":"https://d.com","displayMode":"text","textCountOverride":5,"imageCountOverride":6}
        ]
        """#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([RSSSourceConfig].self, from: data)
        XCTAssertEqual(decoded.count, 4)
        XCTAssertNil(decoded[0].textCountOverride)
        XCTAssertNil(decoded[0].imageCountOverride)
        XCTAssertEqual(decoded[1].textCountOverride, 10)
        XCTAssertNil(decoded[1].imageCountOverride)
        XCTAssertNil(decoded[2].textCountOverride)
        XCTAssertEqual(decoded[2].imageCountOverride, 8)
        XCTAssertEqual(decoded[3].textCountOverride, 5)
        XCTAssertEqual(decoded[3].imageCountOverride, 6)
    }

    // MARK: - Unified ON: global wins, override ignored

    func testUnifiedON_TextIgnoresOverrideUsesGlobal() {
        let keys = ["rssUnifiedDisplayCount", "rssDefaultTextCount", "rssDefaultImageCount"]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(true, forKey: "rssUnifiedDisplayCount")
        UserDefaults.standard.set(5, forKey: "rssDefaultTextCount")

        let settings = AppSettings()
        let source = RSSSourceConfig(name: "X", url: "https://x.com", displayMode: .text,
                                      textCountOverride: 10)
        let result = settings.effectiveTextDisplayCount(for: source)
        XCTAssertEqual(result, 5, "unified ON must ignore per-source override (10) and use global (5)")

        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testUnifiedON_ImageIgnoresOverrideUsesGlobal() {
        let keys = ["rssUnifiedDisplayCount", "rssDefaultTextCount", "rssDefaultImageCount"]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(true, forKey: "rssUnifiedDisplayCount")
        UserDefaults.standard.set(8, forKey: "rssDefaultImageCount")

        let settings = AppSettings()
        let source = RSSSourceConfig(name: "Y", url: "https://y.com", displayMode: .image,
                                      imageCountOverride: 4)
        let result = settings.effectiveImageDisplayCount(for: source)
        XCTAssertEqual(result, 8, "unified ON must ignore per-source override (4) and use global (8)")

        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testUnifiedON_TextReturnsGlobalDefaultWhenNoOverrideSet() {
        let keys = ["rssUnifiedDisplayCount", "rssDefaultTextCount", "rssDefaultImageCount"]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(true, forKey: "rssUnifiedDisplayCount")
        UserDefaults.standard.set(10, forKey: "rssDefaultTextCount")

        let settings = AppSettings()
        let source = RSSSourceConfig(name: "Z", url: "https://z.com", displayMode: .text)
        let result = settings.effectiveTextDisplayCount(for: source)
        XCTAssertEqual(result, 10)

        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: - Unified OFF: override wins, global as fallback

    func testUnifiedOFF_TextOverrideWins() {
        let keys = ["rssUnifiedDisplayCount", "rssDefaultTextCount", "rssDefaultImageCount"]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(false, forKey: "rssUnifiedDisplayCount")
        UserDefaults.standard.set(5, forKey: "rssDefaultTextCount")

        let settings = AppSettings()
        let source = RSSSourceConfig(name: "X", url: "https://x.com", displayMode: .text,
                                      textCountOverride: 10)
        let result = settings.effectiveTextDisplayCount(for: source)
        XCTAssertEqual(result, 10, "unified OFF must honor valid per-source override")

        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testUnifiedOFF_TextFallsToGlobalWhenNoOverride() {
        let keys = ["rssUnifiedDisplayCount", "rssDefaultTextCount", "rssDefaultImageCount"]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(false, forKey: "rssUnifiedDisplayCount")
        UserDefaults.standard.set(10, forKey: "rssDefaultTextCount")

        let settings = AppSettings()
        let source = RSSSourceConfig(name: "X", url: "https://x.com", displayMode: .text)
        let result = settings.effectiveTextDisplayCount(for: source)
        XCTAssertEqual(result, 10, "unified OFF falls to global when no override")

        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testUnifiedOFF_ImageOverrideWins() {
        let keys = ["rssUnifiedDisplayCount", "rssDefaultTextCount", "rssDefaultImageCount"]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(false, forKey: "rssUnifiedDisplayCount")
        UserDefaults.standard.set(4, forKey: "rssDefaultImageCount")

        let settings = AppSettings()
        let source = RSSSourceConfig(name: "X", url: "https://x.com", displayMode: .image,
                                      imageCountOverride: 8)
        let result = settings.effectiveImageDisplayCount(for: source)
        XCTAssertEqual(result, 8, "unified OFF must honor valid per-source override")

        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testUnifiedOFF_ImageFallsToGlobalWhenNoOverride() {
        let keys = ["rssUnifiedDisplayCount", "rssDefaultTextCount", "rssDefaultImageCount"]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(false, forKey: "rssUnifiedDisplayCount")
        UserDefaults.standard.set(6, forKey: "rssDefaultImageCount")

        let settings = AppSettings()
        let source = RSSSourceConfig(name: "X", url: "https://x.com", displayMode: .image)
        let result = settings.effectiveImageDisplayCount(for: source)
        XCTAssertEqual(result, 6, "unified OFF falls to global when no override")

        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testUnifiedOFF_TextFallsToFallbackWhenBothInvalid() {
        let keys = ["rssUnifiedDisplayCount", "rssDefaultTextCount", "rssDefaultImageCount"]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(false, forKey: "rssUnifiedDisplayCount")
        UserDefaults.standard.set(7, forKey: "rssDefaultTextCount")

        let settings = AppSettings()
        let source = RSSSourceConfig(name: "X", url: "https://x.com", displayMode: .text,
                                      textCountOverride: 3)
        let result = settings.effectiveTextDisplayCount(for: source)
        XCTAssertEqual(result, 10, "unified OFF falls to hard-coded fallback when override and global both invalid")

        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testUnifiedOFF_ImageFallsToFallbackWhenBothInvalid() {
        let keys = ["rssUnifiedDisplayCount", "rssDefaultTextCount", "rssDefaultImageCount"]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(false, forKey: "rssUnifiedDisplayCount")
        UserDefaults.standard.set(5, forKey: "rssDefaultImageCount")

        let settings = AppSettings()
        let source = RSSSourceConfig(name: "X", url: "https://x.com", displayMode: .image,
                                      imageCountOverride: 10)
        let result = settings.effectiveImageDisplayCount(for: source)
        XCTAssertEqual(result, 4, "unified OFF falls to hard-coded fallback when override and global both invalid")

        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: - RSSSourceConfig hashable / equatable with overrides

    func testRSSSourceConfigEqualityWithOverrides() {
        let a = RSSSourceConfig(name: "A", url: "https://a.com", displayMode: .text,
                                 textCountOverride: 10)
        let b = RSSSourceConfig(name: "A", url: "https://a.com", displayMode: .text,
                                 textCountOverride: 10)
        let c = RSSSourceConfig(name: "A", url: "https://a.com", displayMode: .text,
                                 textCountOverride: 5)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertNotEqual(a, c)
    }
}
