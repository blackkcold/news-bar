import XCTest
@testable import NewsBar

final class RecommendationGuideTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDown() {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
        super.tearDown()
    }

    // MARK: - Bundled resource

    func testBundledResourceIsAvailableWithStableSectionOrder() throws {
        XCTAssertTrue(RecommendationGuide.isAvailable, RecommendationGuide.unavailableReason ?? "")
        XCTAssertNil(RecommendationGuide.unavailableReason)

        let sections = RecommendationGuide.sections(language: .zh)
        XCTAssertEqual(sections.map(\.id), RecommendationGuideDocument.requiredSectionIDs)
        for section in sections {
            XCTAssertFalse(section.title.isEmpty, "empty title for \(section.id)")
            XCTAssertFalse(section.body.isEmpty, "empty body for \(section.id)")
        }
    }

    func testBilingualCompleteness() throws {
        for language in AppLanguage.allCases {
            let sections = RecommendationGuide.sections(language: language)
            XCTAssertEqual(sections.count, RecommendationGuideDocument.requiredSectionIDs.count, "\(language)")

            for section in sections {
                switch language {
                case .zh:
                    XCTAssertTrue(containsHan(section.title), "zh title not Chinese: \(section.id)")
                    XCTAssertTrue(containsHan(section.body), "zh body not Chinese: \(section.id)")
                case .en:
                    XCTAssertFalse(containsHan(section.title), "en title contains Chinese: \(section.id)")
                    XCTAssertFalse(containsHan(section.body), "en body contains Chinese: \(section.id)")
                }
            }
        }
    }

    // MARK: - Required disclosures

    func testChineseGuideDisclosesRequiredFacts() {
        let text = RecommendationGuide.sections(language: .zh).map { $0.title + "\n" + $0.body }.joined(separator: "\n")
        let required = [
            "归一化", "公共基线", "软惩罚", "来源补位", "别名", "轨迹",
            "未加密", "AI", "翻译", "搜索", "浏览器", "收藏", "停止学习", "语义",
            "更多同类", "显式屏蔽", "调研", "学习开启",
        ]
        for phrase in required {
            XCTAssertTrue(text.contains(phrase), "missing disclosure: \(phrase)")
        }
    }

    func testEnglishGuideDisclosesRequiredFacts() {
        let text = RecommendationGuide.sections(language: .en).map { $0.title + "\n" + $0.body }.joined(separator: "\n")
        let required = [
            "normalized", "public baseline", "soft", "source rotation", "alias", "trace",
            "not encrypted", "AI", "translation", "search", "browser", "bookmark", "stop learning", "semantic",
            "more like this", "explicit", "research", "learning on",
        ]
        for phrase in required {
            XCTAssertTrue(text.contains(phrase), "missing disclosure: \(phrase)")
        }
    }

    // MARK: - Generated Markdown

    func testMarkdownMatchesRepositoryDocs() throws {
        let zh = try String(contentsOf: repositoryURL("docs/recommendations-explained.zh-CN.md"), encoding: .utf8)
        let en = try String(contentsOf: repositoryURL("docs/recommendations-explained.md"), encoding: .utf8)
        XCTAssertEqual(RecommendationGuide.markdown(language: .zh), zh)
        XCTAssertEqual(RecommendationGuide.markdown(language: .en), en)
    }

    func testMarkdownCoversEverySection() {
        let markdown = RecommendationGuide.markdown(language: .zh)
        XCTAssertTrue(markdown.hasPrefix("# "))
        for section in RecommendationGuide.sections(language: .zh) {
            XCTAssertTrue(markdown.contains("## \(section.title)"), "missing heading for \(section.id)")
            XCTAssertTrue(markdown.contains(section.body), "missing body for \(section.id)")
        }
    }

    // MARK: - Packaged layout and explicit failures

    /// Guards the production lookup order: a packaged app keeps the SPM bundle
    /// in `Contents/Resources`, which is `Bundle.main.resourceURL`. Dropping it
    /// would keep swift test green while the shipped settings page goes blank.
    func testDefaultSearchStartsWithMainResourceDirectory() {
        XCTAssertEqual(RecommendationGuide.defaultSearchDirectories.first, Bundle.main.resourceURL)
    }

    func testPackagedAppResourcesLayoutIsLocatable() throws {
        let resources = try makePackagedAppResources(json: bundledJSON())
        XCTAssertEqual(
            RecommendationGuide.resourceBundleURL(searchDirectories: [resources])?.lastPathComponent,
            RecommendationGuide.resourceBundleName
        )

        let sections = try RecommendationGuide.document(searchDirectories: [resources]).sections
        XCTAssertEqual(sections.map(\.id), RecommendationGuideDocument.requiredSectionIDs)

        let text = try RecommendationGuide.document(searchDirectories: [resources])
        XCTAssertFalse(text.title.en.isEmpty)
    }

    func testMissingBundleFailsExplicitly() throws {
        let empty = try makeTemporaryDirectory()
        XCTAssertNil(RecommendationGuide.resourceBundleURL(searchDirectories: [empty]))
        XCTAssertThrowsError(try RecommendationGuide.document(searchDirectories: [empty])) { error in
            XCTAssertEqual(error as? RecommendationGuideError, .resourceMissing)
        }
    }

    func testMalformedBundleFailsExplicitly() throws {
        let resources = try makePackagedAppResources(json: Data("{not valid json".utf8))
        XCTAssertThrowsError(try RecommendationGuide.document(searchDirectories: [resources])) { error in
            guard let guideError = error as? RecommendationGuideError,
                  case .invalidDocument = guideError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testUntranslatedSectionIsRejected() throws {
        try assertInvalidGuide { object in
            var sections = try XCTUnwrap(object["sections"] as? [[String: Any]])
            var first = sections[0]
            var body = try XCTUnwrap(first["body"] as? [String: Any])
            body["en"] = ""
            first["body"] = body
            sections[0] = first
            object["sections"] = sections
        }
    }

    func testExtraSectionIsRejected() throws {
        try assertInvalidGuide { object in
            var sections = try XCTUnwrap(object["sections"] as? [[String: Any]])
            var extra = sections[0]
            extra["id"] = "extra"
            sections.append(extra)
            object["sections"] = sections
        }
    }

    func testBlankDocumentTitleIsRejected() throws {
        try assertInvalidGuide { object in
            object["title"] = ["zh": "推荐原理与我的兴趣", "en": "   "]
        }
    }

    func testBlankSectionBodyIsRejected() throws {
        try assertInvalidGuide { object in
            var sections = try XCTUnwrap(object["sections"] as? [[String: Any]])
            var first = sections[0]
            var body = try XCTUnwrap(first["body"] as? [String: Any])
            body["zh"] = " \n "
            first["body"] = body
            sections[0] = first
            object["sections"] = sections
        }
    }

    func testMissingPrivacySectionThrowsMissingSection() throws {
        var object = try bundledObject()
        var sections = try XCTUnwrap(object["sections"] as? [[String: Any]])
        sections.removeAll { ($0["id"] as? String) == "privacy" }
        object["sections"] = sections
        let resources = try makePackagedAppResources(object: object)

        XCTAssertThrowsError(try RecommendationGuide.document(searchDirectories: [resources])) { error in
            XCTAssertEqual(error as? RecommendationGuideError, .missingSection("privacy"))
        }
    }

    func testUnsupportedSchemaIsRejected() throws {
        try assertInvalidGuide { object in
            object["schemaVersion"] = 2
        }
    }

    // MARK: - Helpers

    private func bundledObject() throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: bundledJSON()) as? [String: Any])
    }

    private func assertInvalidGuide(
        _ mutate: (inout [String: Any]) throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var object = try bundledObject()
        try mutate(&object)
        let resources = try makePackagedAppResources(object: object)
        XCTAssertThrowsError(try RecommendationGuide.document(searchDirectories: [resources])) { error in
            guard let guideError = error as? RecommendationGuideError,
                  case .invalidDocument = guideError else {
                return XCTFail("unexpected error: \(error)", file: file, line: line)
            }
        }
    }

    private func bundledJSON() throws -> Data {
        try Data(contentsOf: repositoryURL("Sources/NewsBar/Resources/recommendation-guide.json"))
    }

    private func repositoryURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecommendationGuideTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryRoots.append(root)
        return root
    }

    private func makePackagedAppResources(json: Data) throws -> URL {
        let root = try makeTemporaryDirectory()
        let resources = root
            .appendingPathComponent("NewsBar.app/Contents/Resources", isDirectory: true)
        let bundle = resources.appendingPathComponent(RecommendationGuide.resourceBundleName, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try json.write(to: bundle.appendingPathComponent(RecommendationGuide.resourceFileName))
        return resources
    }

    private func makePackagedAppResources(object: [String: Any]) throws -> URL {
        try makePackagedAppResources(json: JSONSerialization.data(withJSONObject: object))
    }

    private func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }
}
