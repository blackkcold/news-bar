import Foundation
import Observation

@MainActor
@Observable
final class ReaderResearchPanelModel {
    private let store: ResearchStore
    private let matcher: WorkspaceReaderResearchMatcher
    private var revision = 0
    private(set) var match: ResearchIndexEntry?
    private(set) var association: WorkspaceReaderResearchMatch?
    private(set) var record: ResearchRecord?
    private(set) var recent: [ResearchIndexEntry] = []
    var showsProgress = UserDefaults.standard.bool(forKey: "reader.research.progressExpanded") {
        didSet { UserDefaults.standard.set(showsProgress, forKey: "reader.research.progressExpanded") }
    }

    init(
        store: ResearchStore = .shared,
        matcher: WorkspaceReaderResearchMatcher? = nil
    ) {
        self.store = store
        self.matcher = matcher ?? .shared
    }

    static func verificationItem(original: NewsItem?, requestURL: String, currentURL: String, title: String) -> NewsItem? {
        guard ReaderNavigationPolicy.allowedURL(currentURL) != nil else { return nil }
        if ContentIdentity.canonicalURL(currentURL) == ContentIdentity.canonicalURL(requestURL), let original {
            return original
        }
        let host = URL(string: currentURL)?.host ?? ""
        return NewsItem(title: title, url: currentURL, source: .rss(name: host, url: currentURL))
    }

    func refresh(item: NewsItem?, requestURL: String, currentURL: String) async {
        revision += 1
        let currentRevision = revision
        match = nil
        association = nil
        record = nil
        recent = []
        let isOriginalPage = ContentIdentity.canonicalURL(requestURL) == ContentIdentity.canonicalURL(currentURL)
        let matchingItem = isOriginalPage ? item : nil
        let matchedAssociation = await matcher.match(item: matchingItem, url: currentURL)
        let matched = matchedAssociation?.entry
        let entries = await matcher.recentEntries(excluding: matched?.id, limit: 5)
        let loadedRecord: ResearchRecord? = if let matched { await store.record(id: matched.id) } else { nil }
        guard revision == currentRevision, !Task.isCancelled else { return }
        match = matched
        association = matchedAssociation
        record = loadedRecord
        recent = entries
    }

    func clear() {
        revision += 1
        match = nil
        association = nil
        record = nil
        recent = []
    }
}
