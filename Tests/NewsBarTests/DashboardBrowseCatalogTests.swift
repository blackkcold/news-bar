import XCTest
@testable import NewsBar

final class DashboardBrowseCatalogTests: XCTestCase {
    private let rssA = NewsSource.rss(name: "Feed A", url: "https://example.com/a.xml")
    private let rssB = NewsSource.rss(name: "Feed B", url: "https://example.com/b.xml")

    private func item(_ title: String, source: NewsSource, rank: Int? = nil) -> NewsItem {
        NewsItem(
            title: title,
            url: "https://example.com/\(UUID().uuidString)",
            source: source,
            rank: rank
        )
    }

    func testNoFilterKeepsEmptyHotGroups() {
        let groups = DashboardBrowseCatalog.groups(
            sources: [.weibo, .bilibili],
            weiboItems: [],
            bilibiliItems: [],
            rssItems: [:],
            filter: .all,
            query: nil
        )

        XCTAssertEqual(groups.map(\.source), [.weibo, .bilibili])
        XCTAssertEqual(groups.map(\.totalCount), [0, 0])
        XCTAssertEqual(groups.map(\.matchCount), [0, 0])
    }

    func testQueryOnlyMatchesHotSearch() {
        let weibo = [
            item("热点 A", source: .weibo, rank: 1),
            item("热点 B", source: .weibo, rank: 2),
            item("普通微博", source: .weibo, rank: 3)
        ]
        let groups = DashboardBrowseCatalog.groups(
            sources: [.weibo, .bilibili, rssA],
            weiboItems: weibo,
            bilibiliItems: [item("普通 B站", source: .bilibili)],
            rssItems: [rssA.id: [item("普通 RSS", source: rssA)]],
            filter: .all,
            query: "热点"
        )

        XCTAssertEqual(groups.map(\.source), [.weibo])
        XCTAssertEqual(groups.first?.totalCount, 3)
        XCTAssertEqual(groups.first?.matchCount, 2)
    }

    func testChipRSSExcludesHotSearch() {
        let groups = DashboardBrowseCatalog.groups(
            sources: [.weibo, .bilibili, rssA],
            weiboItems: [item("热点", source: .weibo)],
            bilibiliItems: [item("热点 B站", source: .bilibili)],
            rssItems: [rssA.id: [item("热点 RSS", source: rssA)]],
            filter: .rss,
            query: "热点"
        )

        XCTAssertEqual(groups.map(\.source), [rssA])
        XCTAssertEqual(groups.first?.matchCount, 1)
    }

    func testCountMatchesRenderedGroups() {
        let groups = DashboardBrowseCatalog.groups(
            sources: [.weibo, .bilibili, rssA, rssB],
            weiboItems: [item("A", source: .weibo), item("B", source: .weibo)],
            bilibiliItems: [item("C", source: .bilibili)],
            rssItems: [
                rssA.id: [item("D", source: rssA), item("E", source: rssA)],
                rssB.id: [item("F", source: rssB)]
            ],
            filter: .all,
            query: nil
        )

        XCTAssertEqual(groups.reduce(0) { $0 + $1.matchCount }, 6)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.totalCount }, 6)
    }

    func testRSSTotalUnaffectedByQuery() {
        let groups = DashboardBrowseCatalog.groups(
            sources: [rssA],
            weiboItems: [],
            bilibiliItems: [],
            rssItems: [
                rssA.id: [
                    item("热点 1", source: rssA),
                    item("其他 1", source: rssA),
                    item("其他 2", source: rssA)
                ]
            ],
            filter: .all,
            query: "热点"
        )

        XCTAssertEqual(groups.first?.totalCount, 3)
        XCTAssertEqual(groups.first?.matchCount, 1)
    }

    func testEmptyGroupsHiddenOnlyWhenFiltering() {
        let unfiltered = DashboardBrowseCatalog.groups(
            sources: [.weibo, .bilibili],
            weiboItems: [],
            bilibiliItems: [],
            rssItems: [:],
            filter: .all,
            query: nil
        )
        XCTAssertEqual(unfiltered.count, 2)

        let filtered = DashboardBrowseCatalog.groups(
            sources: [.weibo, .bilibili],
            weiboItems: [],
            bilibiliItems: [],
            rssItems: [:],
            filter: .weibo,
            query: nil
        )
        XCTAssertTrue(filtered.isEmpty)
    }

    func testGroupOrderFollowsActiveSources() {
        let sources: [NewsSource] = [rssB, .weibo, .bilibili, rssA]
        let groups = DashboardBrowseCatalog.groups(
            sources: sources,
            weiboItems: [item("A", source: .weibo)],
            bilibiliItems: [item("B", source: .bilibili)],
            rssItems: [
                rssA.id: [item("C", source: rssA)],
                rssB.id: [item("D", source: rssB)]
            ],
            filter: .all,
            query: nil
        )

        XCTAssertEqual(groups.map(\.source), sources)
    }

    func testRSSGroupUsesOnlyItsOwnItems() {
        let groups = DashboardBrowseCatalog.groups(
            sources: [rssA, rssB],
            weiboItems: [],
            bilibiliItems: [],
            rssItems: [
                rssA.id: [item("A1", source: rssA), item("A2", source: rssA)],
                rssB.id: [item("B1", source: rssB)]
            ],
            filter: .rss,
            query: nil
        )

        XCTAssertEqual(groups.map(\.totalCount), [2, 1])
        XCTAssertEqual(groups.map(\.matchCount), [2, 1])
    }

    func testSourceNotInActiveSourcesIsExcluded() {
        let groups = DashboardBrowseCatalog.groups(
            sources: [.weibo],
            weiboItems: [item("A", source: .weibo)],
            bilibiliItems: [item("B", source: .bilibili)],
            rssItems: [rssA.id: [item("C", source: rssA)]],
            filter: .all,
            query: nil
        )

        XCTAssertEqual(groups.map(\.source), [.weibo])
    }

    func testEmptyQueryIsTreatedAsNoFilter() {
        let groups = DashboardBrowseCatalog.groups(
            sources: [.weibo, .bilibili],
            weiboItems: [],
            bilibiliItems: [],
            rssItems: [:],
            filter: .all,
            query: ""
        )

        XCTAssertEqual(groups.count, 2)
    }
}
