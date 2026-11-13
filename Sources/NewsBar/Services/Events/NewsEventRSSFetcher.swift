import Foundation

enum NewsEventFeedRefresh: Sendable {
    case modified([NewsEventEvidence], cursor: NewsEventFeedCursor)
    case notModified(cursor: NewsEventFeedCursor)
}

protocol NewsEventRSSFetching: Sendable {
    func refresh(
        _ source: NewsSource,
        cursor: NewsEventFeedCursor?,
        now: Date
    ) async throws -> NewsEventFeedRefresh
}

struct NewsEventRSSFetcher: NewsEventRSSFetching {
    private let inputAdapter: any NewsEventInputAdapting

    init(inputAdapter: any NewsEventInputAdapting = NewsEventInputAdapter()) {
        self.inputAdapter = inputAdapter
    }

    func refresh(
        _ source: NewsSource,
        cursor: NewsEventFeedCursor?,
        now: Date
    ) async throws -> NewsEventFeedRefresh {
        guard case .rss = source else { throw NewsBarError.invalidURL }
        let result = try await RSSService.fetchConditional(
            url: source.id,
            sourceName: source.displayName,
            eTag: cursor?.eTag,
            lastModified: cursor?.lastModified
        )

        switch result {
        case let .notModified(eTag, lastModified):
            return .notModified(cursor: NewsEventFeedCursor(
                sourceID: source.id,
                eTag: eTag,
                lastModified: lastModified,
                checkedAt: now,
                attemptedAt: now,
                failureCount: 0
            ))
        case let .modified(items, eTag, lastModified):
            let evidence = inputAdapter.from(items: items, kind: .rss, now: now)
            return .modified(evidence, cursor: NewsEventFeedCursor(
                sourceID: source.id,
                eTag: eTag,
                lastModified: lastModified,
                checkedAt: now,
                attemptedAt: now,
                failureCount: 0
            ))
        }
    }
}
