import Foundation
import Observation

@MainActor
@Observable
final class ReaderResearchPanelModel {
    private let store: ResearchStore
    private var revision = 0
    private(set) var match: ResearchIndexEntry?
    private(set) var record: ResearchRecord?
    private(set) var recent: [ResearchIndexEntry] = []

    init(store: ResearchStore = .shared) {
        self.store = store
    }

    static func verificationItem(original: NewsItem?, requestURL: String, currentURL: String, title: String) -> NewsItem? {
        guard ReaderNavigationPolicy.allowedURL(currentURL) != nil else { return nil }
        if ContentIdentity.canonicalURL(currentURL) == ContentIdentity.canonicalURL(requestURL), let original {
            return original
        }
        let host = URL(string: currentURL)?.host ?? ""
        return NewsItem(title: title, url: currentURL, source: .rss(name: host, url: currentURL))
    }

    func refresh(item: NewsItem?, requestURL: String, currentURL: String, title: String) async {
        revision += 1
        let currentRevision = revision
        match = nil
        record = nil
        let isOriginalPage = ContentIdentity.canonicalURL(requestURL) == ContentIdentity.canonicalURL(currentURL)
        let matchingItem = isOriginalPage ? item : nil
        let topic = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = await store.indexEntry(
            matchingItemID: matchingItem?.id,
            url: currentURL,
            topicKey: topic.isEmpty ? nil : TopicFingerprint.key(for: topic)
        )
        let entries = await store.index()
        let loadedRecord: ResearchRecord? = if let matched { await store.record(id: matched.id) } else { nil }
        guard revision == currentRevision, !Task.isCancelled else { return }
        match = matched
        record = loadedRecord
        recent = Array(entries.filter { $0.id != matched?.id }.prefix(5))
    }
}
