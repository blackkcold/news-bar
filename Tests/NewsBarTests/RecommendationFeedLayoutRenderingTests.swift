import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

@MainActor
final class RecommendationFeedLayoutRenderingTests: XCTestCase {
    func testCardsFitColumnsAtWideSidebarAndReaderWidths() async throws {
        let settings = AppSettings()
        settings.appLanguage = .zh
        settings.appTheme = .modern
        let snapshot = makeSnapshot()
        let cases: [(name: String, width: CGFloat, columns: Int)] = [
            ("wide-feed", 1200, 3),
            ("dashboard-with-sidebar", 804, 2),
            ("reader-pane", 440, 1),
        ]

        for testCase in cases {
            let expectations = expectation(description: "frames-\(testCase.name)")
            let box = FrameBox()
            let view = RecommendationFeedView(
                matches: { _ in true },
                width: testCase.width,
                snapshotOverride: snapshot,
                onCardFrames: { frames in
                    box.frames = frames
                    if frames.count == snapshot.items.count, !box.fulfilled {
                        box.fulfilled = true
                        expectations.fulfill()
                    }
                }
            )
            .environment(settings)
            .frame(width: testCase.width, height: 2_400)

            let host = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: testCase.width, height: 2_400),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            await fulfillment(of: [expectations], timeout: 3)

            let frames = box.frames
            XCTAssertEqual(frames.count, snapshot.items.count, testCase.name)
            let expectedWidth = RecommendationMasonryLayout.columnWidth(
                for: testCase.width,
                columns: testCase.columns
            )
            for frame in frames {
                XCTAssertEqual(frame.frame.width, expectedWidth, accuracy: 1, testCase.name)
                XCTAssertGreaterThanOrEqual(frame.frame.minX, -1, testCase.name)
                XCTAssertLessThanOrEqual(frame.frame.maxX, testCase.width + 1, testCase.name)
            }

            let origins = Set(frames.map { Int($0.frame.minX.rounded()) })
            XCTAssertEqual(origins.count, testCase.columns, testCase.name)

            for left in frames.indices {
                for right in frames.indices where right > left {
                    let a = frames[left].frame
                    let b = frames[right].frame
                    let overlapX = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                    let overlapY = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                    XCTAssertFalse(
                        overlapX > 1 && overlapY > 1,
                        "\(testCase.name): cards overlap at \(a) and \(b)"
                    )
                }
            }
            window.contentView = nil
        }
    }

    private func makeSnapshot() -> RecommendationSnapshot {
        let items = (0..<6).map { index in
            NewsItem(
                title: index == 1
                    ? String(repeating: "VeryLongUnbrokenLatinHeadline", count: 4)
                    : "这是一个用于检查瀑布流列宽与卡片重叠问题的中文标题 \(index)，长度足够触发多行换行并暴露列宽约束问题",
                url: "https://example.com/masonry-\(index)",
                source: .rss(
                    name: index == 2 ? "一个非常非常长的订阅源名称用于检查徽章溢出" : "少数派",
                    url: "https://sspai.com/feed-\(index)"
                )
            )
        }
        let recommendations = items.enumerated().map { index, item in
            ScoredRecommendation(
                item: item,
                contentID: "content-\(index)",
                clusterID: "cluster-\(index)",
                score: 0.5,
                components: [:],
                reason: "recent",
                topic: nil
            )
        }
        return RecommendationSnapshot(
            asOf: Date(),
            profileVersion: 1,
            policyVersion: 3,
            profileConfidence: 0.5,
            semanticDegraded: false,
            items: recommendations
        )
    }
}

@MainActor
private final class FrameBox {
    var frames: [RecommendationCardFrame] = []
    var fulfilled = false
}
