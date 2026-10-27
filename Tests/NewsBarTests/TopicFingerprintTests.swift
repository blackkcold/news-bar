import XCTest
@testable import NewsBar

final class TopicFingerprintTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNormalizationRemovesNoiseAndFoldsWidthAndCase() {
        XCTAssertEqual(
            TopicFingerprint.normalized("# 某公司　发布 新 产品！🔥"),
            "某公司 发布 新 产品"
        )
        XCTAssertEqual(TopicFingerprint.normalized("ＡＢＣ　１２３"), "abc 123")
        XCTAssertEqual(TopicFingerprint.normalized("Hello, World!!!"), "hello world")
        XCTAssertEqual(TopicFingerprint.normalized("  #事件#  "), "事件")
        XCTAssertEqual(TopicFingerprint.normalized("C++ 与 Swift"), "c 与 swift")
    }

    func testTopicKeyIsStableAcrossNoiseVariants() {
        XCTAssertEqual(
            TopicFingerprint.key(for: "#事件！"),
            TopicFingerprint.key(for: " 事件 ")
        )
        XCTAssertNotEqual(
            TopicFingerprint.key(for: "事件"),
            TopicFingerprint.key(for: "另一事件")
        )
    }

    func testCJKBigramSimilarityIsStrict() {
        XCTAssertEqual(
            TopicFingerprint.similarity("苹果发布新款手机", "苹果发布新款手机"),
            1,
            accuracy: 0.0001
        )

        let characters = (0..<30)
            .compactMap { Unicode.Scalar(0x4E00 + $0 * 7) }
            .map { String($0) }
        let base = characters.joined()
        var variantCharacters = characters
        variantCharacters[29] = "龘"
        let variant = variantCharacters.joined()
        XCTAssertGreaterThanOrEqual(
            TopicFingerprint.similarity(base, variant),
            TopicFingerprint.fuzzyMergeThreshold
        )

        XCTAssertLessThan(
            TopicFingerprint.similarity("苹果发布新款手机", "足球比赛结果公布"),
            0.2
        )

        // A mixed CJK/Latin title must keep the Latin model token; otherwise
        // iPhone 15 and iPhone 16 would look identical on CJK bigrams alone.
        XCTAssertLessThan(
            TopicFingerprint.similarity("苹果iPhone15发布", "苹果iPhone16发布"),
            TopicFingerprint.fuzzyMergeThreshold
        )
    }

    func testFuzzyMergeRequiresAutomaticRecordsSameDomainAndWindow() {
        let existing = researchTestRecord(
            title: "苹果发布新款手机",
            origin: .burst,
            updatedAt: now,
            lastSeenAt: now.addingTimeInterval(-3_600),
            seedURL: "https://news.example.com/a"
        )

        XCTAssertTrue(
            TopicFingerprint.shouldFuzzyMerge(
                title: "苹果发布新款手机",
                seedURL: "https://m.example.com/b",
                source: .weibo,
                origin: .burst,
                with: existing,
                now: now
            )
        )

        XCTAssertFalse(
            TopicFingerprint.shouldFuzzyMerge(
                title: "苹果发布新款手机",
                seedURL: "https://other.example.org/b",
                source: .weibo,
                origin: .burst,
                with: existing,
                now: now
            ),
            "a different seed domain must not merge"
        )

        XCTAssertFalse(
            TopicFingerprint.shouldFuzzyMerge(
                title: "苹果发布新款手机",
                seedURL: "https://news.example.com/b",
                source: .weibo,
                origin: .manual,
                with: existing,
                now: now
            ),
            "a manual record never fuzzy-merges"
        )

        var manualExisting = existing
        manualExisting.origin = .manual
        XCTAssertFalse(
            TopicFingerprint.shouldFuzzyMerge(
                title: "苹果发布新款手机",
                seedURL: "https://news.example.com/b",
                source: .weibo,
                origin: .burst,
                with: manualExisting,
                now: now
            ),
            "an automatic candidate must not absorb a manual record"
        )

        var stale = existing
        stale.lastSeenAt = now.addingTimeInterval(-49 * 3_600)
        XCTAssertFalse(
            TopicFingerprint.shouldFuzzyMerge(
                title: "苹果发布新款手机",
                seedURL: "https://news.example.com/b",
                source: .weibo,
                origin: .burst,
                with: stale,
                now: now
            )
        )

        XCTAssertFalse(
            TopicFingerprint.shouldFuzzyMerge(
                title: "完全不同的话题",
                seedURL: "https://news.example.com/b",
                source: .weibo,
                origin: .burst,
                with: existing,
                now: now
            )
        )
    }

    func testFuzzyMergeConsidersAliases() {
        let existing = researchTestRecord(
            title: "旧标题",
            origin: .keyword,
            updatedAt: now,
            lastSeenAt: now,
            seedURL: "https://news.example.com/a",
            aliases: ["苹果发布新款手机"]
        )

        XCTAssertTrue(
            TopicFingerprint.shouldFuzzyMerge(
                title: "苹果发布新款手机",
                seedURL: "https://news.example.com/b",
                source: .weibo,
                origin: .keyword,
                with: existing,
                now: now
            )
        )
    }
}
