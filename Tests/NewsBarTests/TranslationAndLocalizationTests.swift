import XCTest
@testable import NewsBar

final class TranslationCacheStoreTests: XCTestCase {

    private func tempStore() -> TranslationCacheStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewsBarTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return TranslationCacheStore(cacheDirectory: dir)
    }

    func testCacheRoundTrip() async {
        let store = tempStore()
        let initial = await store.cachedTranslation(for: "标题", targetLang: "en")
        XCTAssertNil(initial)
        await store.saveTranslation("Title", for: "标题", targetLang: "en")
        let cached = await store.cachedTranslation(for: "标题", targetLang: "en")
        XCTAssertEqual(cached, "Title")
    }

    func testCacheKeyIsLanguageScoped() async {
        let store = tempStore()
        await store.saveTranslation("Title", for: "标题", targetLang: "en")
        // A different target language must not collide with the cached one.
        let other = await store.cachedTranslation(for: "标题", targetLang: "ja")
        XCTAssertNil(other)
    }

    func testClearRemovesAllEntries() async {
        let store = tempStore()
        await store.saveTranslation("Title", for: "标题", targetLang: "en")
        await store.clear()
        let after = await store.cachedTranslation(for: "标题", targetLang: "en")
        XCTAssertNil(after)
    }
}

final class NewsItemTranslationTests: XCTestCase {

    func testDisplayTitleFallsBackToOriginal() {
        let item = NewsItem(title: "原文", url: "https://example.com", source: .rss(name: "源", url: "https://example.com"))
        XCTAssertEqual(item.displayTitle, "原文")
        XCTAssertNil(item.translatedTitle)
    }

    func testWithTranslatedTitlePreservesOriginal() {
        let original = NewsItem(title: "原文", url: "https://example.com", source: .rss(name: "源", url: "https://example.com"), rank: 3)
        let translated = original.withTranslatedTitle("Original")
        XCTAssertEqual(translated.displayTitle, "Original")
        XCTAssertEqual(translated.title, "原文")
        XCTAssertEqual(translated.rank, 3)
        XCTAssertEqual(translated.url, original.url)
        XCTAssertEqual(translated.id, original.id)
        // Original item is unchanged (immutable copy semantics).
        XCTAssertNil(original.translatedTitle)
        XCTAssertEqual(original.displayTitle, "原文")
    }
}

final class LocalizedTests: XCTestCase {

    func testZhStringsResolve() {
        L10n.currentLanguage = .zh
        XCTAssertEqual("general.refresh".localized, "刷新设置")
        XCTAssertEqual("popover.weibo".localized, "微博热搜")
    }

    func testEnStringsResolve() {
        L10n.currentLanguage = .en
        XCTAssertEqual("general.refresh".localized, "Refresh")
        XCTAssertEqual("popover.weibo".localized, "Weibo Trending")
    }

    func testUnknownKeyReturnsKey() {
        L10n.currentLanguage = .zh
        XCTAssertEqual("nonexistent.key".localized, "nonexistent.key")
    }

    func testFormatArgumentsWithInt() {
        L10n.currentLanguage = .zh
        XCTAssertEqual(L10n.string("news.count", 5), "5 条")
        L10n.currentLanguage = .en
        XCTAssertEqual(L10n.string("news.count", 5), "5 items")
    }

    func testFormatArgumentsWithString() {
        L10n.currentLanguage = .en
        XCTAssertEqual(L10n.string("popover.collapse", "Tech Feed"), "Tech Feed · Collapse")
    }

    func testBothLanguageTablesResolveSettingsLanguage() {
        L10n.currentLanguage = .en
        XCTAssertEqual("settings.language".localized, "Language")
        L10n.currentLanguage = .zh
        XCTAssertEqual("settings.language".localized, "语言")
    }
}
