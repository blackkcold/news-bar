import XCTest
@testable import NewsBar

final class DisplayModeMigrationTests: XCTestCase {

    func testOldSingleDecodesAsText() throws {
        let json = #""single""#
        let data = json.data(using: .utf8)!
        let mode = try JSONDecoder().decode(RSSSourceConfig.DisplayMode.self, from: data)
        XCTAssertEqual(mode, .text)
    }

    func testOldScrollDecodesAsImage() throws {
        let json = #""scroll""#
        let data = json.data(using: .utf8)!
        let mode = try JSONDecoder().decode(RSSSourceConfig.DisplayMode.self, from: data)
        XCTAssertEqual(mode, .image)
    }

    func testNewTextRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(RSSSourceConfig.DisplayMode.text)
        let decoded = try decoder.decode(RSSSourceConfig.DisplayMode.self, from: data)
        XCTAssertEqual(decoded, .text)
    }

    func testNewImageRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(RSSSourceConfig.DisplayMode.image)
        let decoded = try decoder.decode(RSSSourceConfig.DisplayMode.self, from: data)
        XCTAssertEqual(decoded, .image)
    }

    func testUnknownValueFallsBackToText() throws {
        let json = #""unknown""#
        let data = json.data(using: .utf8)!
        let mode = try JSONDecoder().decode(RSSSourceConfig.DisplayMode.self, from: data)
        XCTAssertEqual(mode, .text)
    }

    func testArrayWithOldValuesDoesNotLoseData() throws {
        let json = #"""
        [
            {"name": "Source A", "url": "https://a.com", "displayMode": "single"},
            {"name": "Source B", "url": "https://b.com", "displayMode": "scroll"},
            {"name": "Source C", "url": "https://c.com", "displayMode": "text"},
            {"name": "Source D", "url": "https://d.com", "displayMode": "image"}
        ]
        """#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([RSSSourceConfig].self, from: data)
        XCTAssertEqual(decoded.count, 4)
        XCTAssertEqual(decoded[0].displayMode, .text)
        XCTAssertEqual(decoded[1].displayMode, .image)
        XCTAssertEqual(decoded[2].displayMode, .text)
        XCTAssertEqual(decoded[3].displayMode, .image)
    }

    func testArrayWithUnknownValueDoesNotLoseData() throws {
        let json = #"""
        [
            {"name": "Source A", "url": "https://a.com", "displayMode": "single"},
            {"name": "Source B", "url": "https://b.com", "displayMode": "bogus"},
            {"name": "Source C", "url": "https://c.com", "displayMode": "image"}
        ]
        """#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([RSSSourceConfig].self, from: data)
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0].displayMode, .text)
        XCTAssertEqual(decoded[1].displayMode, .text)
        XCTAssertEqual(decoded[2].displayMode, .image)
    }

    func testEncodeProducesNewRawValues() throws {
        let encoder = JSONEncoder()
        let textData = try encoder.encode(RSSSourceConfig.DisplayMode.text)
        let imageData = try encoder.encode(RSSSourceConfig.DisplayMode.image)
        let textString = String(data: textData, encoding: .utf8)
        let imageString = String(data: imageData, encoding: .utf8)
        XCTAssertEqual(textString, #""text""#)
        XCTAssertEqual(imageString, #""image""#)
    }

    // MARK: - supportsImage migration

    func testSupportsImageDefaultsTrueWhenMissing() throws {
        let json = #"{"name":"A","url":"https://a.com","displayMode":"text"}"#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RSSSourceConfig.self, from: data)
        XCTAssertTrue(decoded.supportsImage, "supportsImage should default to true when key is missing")
    }

    func testSupportsImageRoundTrip() throws {
        let config = RSSSourceConfig(name: "Test", url: "https://t.com", displayMode: .image, supportsImage: false)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(RSSSourceConfig.self, from: data)
        XCTAssertEqual(decoded.supportsImage, false)
    }

    func testArrayWithoutSupportsImageDoesNotLoseData() throws {
        let json = #"""
        [
            {"name": "A", "url": "https://a.com", "displayMode": "text"},
            {"name": "B", "url": "https://b.com", "displayMode": "image", "supportsImage": false},
            {"name": "C", "url": "https://c.com", "displayMode": "text", "supportsImage": true}
        ]
        """#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([RSSSourceConfig].self, from: data)
        XCTAssertEqual(decoded.count, 3)
        XCTAssertTrue(decoded[0].supportsImage)
        XCTAssertFalse(decoded[1].supportsImage)
        XCTAssertTrue(decoded[2].supportsImage)
    }

    func testArrayWithOldAndNewFieldsMixed() throws {
        let json = #"""
        [
            {"name": "Old", "url": "https://old.com", "displayMode": "single"},
            {"name": "New", "url": "https://new.com", "displayMode": "image", "supportsImage": true}
        ]
        """#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([RSSSourceConfig].self, from: data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].displayMode, .text)
        XCTAssertTrue(decoded[0].supportsImage)
        XCTAssertEqual(decoded[1].displayMode, .image)
        XCTAssertTrue(decoded[1].supportsImage)
    }
}