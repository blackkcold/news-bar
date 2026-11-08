import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

/// Guards the recommendation masonry's paint contract with a real hosting
/// view: no card and no column may draw outside the slot it was given.
///
/// The existing frame tests cannot see this. They measure a `GeometryReader`
/// that sits *outside* the card, so they always report the column width even
/// when the card's surface, cover or rounded corners paint wider. The stage
/// here is painted red and the margins are scanned, so a card that reports a
/// width larger than its column (long unbroken title, long source badge) or a
/// masonry laid out for a wider hint than the slot really has becomes a hard
/// test failure instead of a visual defect.
@MainActor
final class RecommendationCardOverflowRenderingTests: XCTestCase {
    private let margin: CGFloat = 40
    private let height: CGFloat = 640

    func testCardPaintsNothingOutsideItsColumn() throws {
        let settings = AppSettings()
        settings.appLanguage = .zh
        settings.appTheme = .modern

        for columnWidth in [272.0, 300.0, 396.0] {
            for fixture in Fixture.allCases {
                let containerWidth = columnWidth + margin * 2
                let stage = RecommendationCardView(
                    row: fixture.row,
                    contextID: "overflow-\(fixture.rawValue)",
                    position: 0,
                    policyVersion: "ranking-v3",
                    profileVersion: 1,
                    columnWidth: columnWidth
                )
                // Exactly what the feed does, then a wider red stage.
                .frame(width: columnWidth, alignment: .top)
                .frame(width: containerWidth, height: height, alignment: .center)
                .background(Color.red)

                let rep = try capture(stage, width: containerWidth, height: height, settings: settings)
                let painted = paintedPixels(
                    in: rep,
                    stageWidth: containerWidth,
                    keep: margin...(margin + columnWidth)
                )
                XCTAssertEqual(
                    painted,
                    0,
                    "\(fixture.rawValue) at \(Int(columnWidth))pt painted \(painted)px outside the card"
                )
            }
        }
    }

    func testMasonryPaintsNothingOutsideItsSlot() throws {
        let settings = AppSettings()
        settings.appLanguage = .zh
        settings.appTheme = .modern
        let snapshot = makeSnapshot()
        // (hinted width, real slot width). The second group is the width-drift
        // case: the dashboard hands the feed a width from its own arithmetic
        // while a scroller, safe-area inset or a mid-transition pane leaves the
        // feed less room. The masonry must never paint outside the room it
        // actually got.
        let cases: [(hint: CGFloat, slot: CGFloat)] = [
            (1200, 1200), (804, 804), (440, 440),
            (1200, 1185), (804, 789), (440, 420), (900, 700),
        ]

        for (hint, slot) in cases {
            let extra: CGFloat = 80
            let stageWidth = slot + extra * 2
            let stage = RecommendationFeedView(
                matches: { _ in true },
                width: hint,
                snapshotOverride: snapshot
            )
            .environment(settings)
            .frame(width: slot, alignment: .topLeading)
            .frame(width: stageWidth, height: 1_600, alignment: .center)
            .background(Color.red)

            let rep = try capture(stage, width: stageWidth, height: 1_600, settings: settings)
            let outside = paintedPixels(
                in: rep,
                stageWidth: stageWidth,
                keep: extra...(extra + slot)
            )
            XCTAssertEqual(
                outside,
                0,
                "\(Int(hint))pt hint in a \(Int(slot))pt slot painted \(outside)px outside the feed"
            )
        }
    }

    /// Writes the rendered feed to `.build/recommendation-overflow-validation`
    /// for a human or CI to eyeball the result next to the numbers above.
    func testFeedSnapshotForVisualReview() throws {
        let settings = AppSettings()
        settings.appLanguage = .zh
        settings.appTheme = .modern
        let snapshot = makeSnapshot()

        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/recommendation-overflow-validation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for slot in [1200.0, 804.0, 440.0] {
            let view = RecommendationFeedView(
                matches: { _ in true },
                width: slot,
                snapshotOverride: snapshot
            )
            .environment(settings)
            .frame(width: slot, height: 1_600, alignment: .topLeading)

            let rep = try capture(view, width: slot, height: 1_600, settings: settings)
            XCTAssertGreaterThan(rep.pixelsWide, 0)
            try rep.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("feed-\(Int(slot)).png"))
        }
    }

    private func capture(
        _ view: some View,
        width: CGFloat,
        height: CGFloat,
        settings: AppSettings
    ) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.environment(settings))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw XCTSkip("host produced no bitmap")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        return rep
    }

    /// Counts pixels outside `keep` that are not the stage's red.
    private func paintedPixels(
        in rep: NSBitmapImageRep,
        stageWidth: CGFloat,
        keep keepPoints: ClosedRange<CGFloat>
    ) -> Int {
        let scale = CGFloat(rep.pixelsWide) / max(1, stageWidth)
        let lower = Int((keepPoints.lowerBound * scale).rounded(.down))
        let upper = Int((keepPoints.upperBound * scale).rounded(.up))
        var painted = 0
        for x in 0..<rep.pixelsWide where x < lower || x > upper {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y),
                      let rgb = color.usingColorSpace(.sRGB) else { continue }
                let isStage = rgb.redComponent > 0.6
                    && rgb.greenComponent < 0.45
                    && rgb.blueComponent < 0.45
                if !isStage { painted += 1 }
            }
        }
        return painted
    }

    private func makeSnapshot() -> RecommendationSnapshot {
        let items = (0..<8).map { index in
            NewsItem(
                title: index % 3 == 0
                    ? "这是一个用于检查瀑布流列宽与卡片重叠问题的中文标题 \(index)，长度足够触发多行换行"
                    : "相对短的标题 \(index)",
                url: "https://example.com/masonry-\(index)",
                source: .rss(
                    name: index % 3 == 1 ? "AnExtremelyLongUnbrokenSourceNameUsedToCheckBadgeOverflow" : "少数派",
                    url: "https://sspai.com/feed-\(index)"
                ),
                hotLabel: index % 3 == 2 ? "爆" : nil
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

private enum Fixture: String, CaseIterable {
    case plainCJK
    case unbrokenLatinTitle
    case longCJKSource
    case unbrokenLatinSource
    case hotLabel

    var row: ScoredRecommendation {
        let title: String
        let source: NewsSource
        let hot: String?

        switch self {
        case .plainCJK:
            title = "这是一个用于检查瀑布流列宽与卡片重叠问题的中文标题，长度足够触发多行换行"
            source = .rss(name: "少数派", url: "https://sspai.com/feed")
            hot = nil
        case .unbrokenLatinTitle:
            title = String(repeating: "VeryLongUnbrokenLatinHeadline", count: 4)
            source = .rss(name: "少数派", url: "https://sspai.com/feed")
            hot = nil
        case .longCJKSource:
            title = "短标题"
            source = .rss(name: "一个非常非常长的订阅源名称用于检查徽章溢出", url: "https://example.com/feed")
            hot = nil
        case .unbrokenLatinSource:
            title = "短标题"
            source = .rss(
                name: String(repeating: "UnbrokenSourceName", count: 4),
                url: "https://example.com/latin-feed"
            )
            hot = nil
        case .hotLabel:
            title = "带热度标签的标题"
            source = .weibo
            hot = "爆"
        }

        let item = NewsItem(
            title: title,
            url: "https://example.com/\(rawValue)",
            source: source,
            hotLabel: hot
        )
        return ScoredRecommendation(
            item: item,
            contentID: "content-\(rawValue)",
            clusterID: "cluster-\(rawValue)",
            score: 0.5,
            components: [:],
            reason: "interest",
            topic: nil
        )
    }
}
