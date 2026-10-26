import Foundation

/// Source filter used by the dashboard's "by source" browser.
///
/// This used to be nested inside `DashboardWindow`. It lives at file scope so
/// the pure browse catalog can be tested without instantiating a SwiftUI view.
enum DashboardSourceFilter: String, CaseIterable, Identifiable {
    case all, weibo, bilibili, rss

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "dash.filter.all".localized
        case .weibo: return "source.weibo".localized
        case .bilibili: return "source.bilibili".localized
        case .rss: return "dash.filter.rss".localized
        }
    }

    func matches(_ source: NewsSource) -> Bool {
        switch self {
        case .all: return true
        case .weibo: return source == .weibo
        case .bilibili: return source == .bilibili
        case .rss: return source != .weibo && source != .bilibili
        }
    }
}

/// One source's counters in the by-source browser. It deliberately does not
/// carry items: `DashboardRSSSourceCard` keeps reading its own slice so a
/// refresh of one RSS source does not rebuild every card.
struct DashboardBrowseGroup: Identifiable, Equatable {
    let source: NewsSource
    /// Unfiltered item count for the source.
    let totalCount: Int
    /// Count after the active search/query filter. Equals `totalCount` when
    /// there is no query.
    let matchCount: Int

    var id: NewsSource.ID { source.id }
}

enum DashboardBrowseCatalog {
    /// Builds the source rows for the by-source browser.
    ///
    /// - Parameters:
    ///   - sources: The active sources in display order (`AppSettings.activeSources`).
    ///   - filter: The selected source chip.
    ///   - query: An already-normalized search query, or nil.
    static func groups(
        sources: [NewsSource],
        weiboItems: [NewsItem],
        bilibiliItems: [NewsItem],
        rssItems: [String: [NewsItem]],
        filter: DashboardSourceFilter,
        query: String?
    ) -> [DashboardBrowseGroup] {
        let effectiveQuery = query.flatMap { $0.isEmpty ? nil : $0 }
        let hasFilter = filter != .all || effectiveQuery != nil

        return sources.compactMap { source in
            guard filter.matches(source) else { return nil }

            let items: [NewsItem]
            if source == .weibo {
                items = weiboItems
            } else if source == .bilibili {
                items = bilibiliItems
            } else {
                items = rssItems[source.id] ?? []
            }

            let totalCount = items.count
            let matchCount: Int
            if let effectiveQuery {
                matchCount = items.reduce(0) { partial, item in
                    partial + (DashboardSearch.matches(item, query: effectiveQuery) ? 1 : 0)
                }
            } else {
                matchCount = totalCount
            }

            guard !hasFilter || matchCount > 0 else { return nil }
            return DashboardBrowseGroup(source: source, totalCount: totalCount, matchCount: matchCount)
        }
    }
}
