import Foundation
import Observation

enum QuickSearchMode: String, CaseIterable, Identifiable, Sendable {
    case local
    case web

    var id: String { rawValue }
}

enum QuickSearchResult: Identifiable, Sendable {
    case news(NewsItem)
    case readerHistory(ReaderHistoryEntry)
    case archive(AISearchArchiveEntry)
    case workspace(WorkspaceSearchResult)

    var id: String {
        switch self {
        case .news(let item): return "news:\(item.id)"
        case .readerHistory(let entry): return "history:\(entry.id.uuidString)"
        case .archive(let entry): return "archive:\(entry.id.uuidString)"
        case .workspace(let result): return "workspace:\(result.id)"
        }
    }
}

@MainActor
@Observable
final class QuickSearchModel {
    var query = ""
    var mode: QuickSearchMode = .local
    private(set) var localResults: [QuickSearchResult] = []
    var workspaceResults: [WorkspaceSearchResult] = []
    var workspaceSubjectTitles: [String: String] = [:]
    var workspaceActiveResearchRuns: [WorkspaceSearchRunSnapshot] = []
    private(set) var webHits: [SearchHit] = []
    private(set) var isSearching = false
    private(set) var error: String?

    func searchLocal(
        query: String,
        newsItems: [NewsItem],
        readingHistory: [ReaderHistoryEntry],
        archiveEntries: [AISearchArchiveEntry],
        workspaceResults: [WorkspaceSearchResult] = [],
        workspaceSubjectTitles: [String: String] = [:],
        workspaceActiveResearchRuns: [WorkspaceSearchRunSnapshot] = [],
        allWorkspaceResults: [WorkspaceSearchResult]? = nil
    ) {
        self.query = query
        self.workspaceResults = allWorkspaceResults ?? workspaceResults
        self.workspaceSubjectTitles = workspaceSubjectTitles
        self.workspaceActiveResearchRuns = workspaceActiveResearchRuns
        mode = .local
        error = nil

        let needle = Self.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else {
            localResults = []
            return
        }

        var results: [QuickSearchResult] = []
        var seenContentURLs: Set<String> = []

        let matchingNewsItems = newsItems.enumerated().filter { _, item in
            Self.matches(needle, in: [item.title, item.displayTitle, item.url, item.readerURL])
        }.sorted { lhs, rhs in
            let lhsExact = Self.normalized(lhs.element.title) == needle
                || Self.normalized(lhs.element.displayTitle) == needle
            let rhsExact = Self.normalized(rhs.element.title) == needle
                || Self.normalized(rhs.element.displayTitle) == needle
            if lhsExact != rhsExact { return lhsExact }
            return lhs.offset < rhs.offset
        }
        for (_, item) in matchingNewsItems {
            let destination = item.readerURL ?? item.url
            let canonicalURL = ContentIdentity.canonicalURL(destination)
            if !canonicalURL.isEmpty, !seenContentURLs.insert(canonicalURL).inserted {
                continue
            }
            guard results.filter({ if case .news = $0 { true } else { false } }).count < 30 else {
                break
            }
            results.append(.news(item))
        }

        var historyCount = 0
        for entry in readingHistory {
            guard Self.matches(needle, in: [entry.title, entry.url, entry.canonicalURL]) else {
                continue
            }
            let canonicalURL = ContentIdentity.canonicalURL(entry.url)
            if !canonicalURL.isEmpty, !seenContentURLs.insert(canonicalURL).inserted {
                continue
            }
            guard historyCount < 30 else { break }
            results.append(.readerHistory(entry))
            historyCount += 1
        }

        var archiveCount = 0
        for entry in archiveEntries {
            guard Self.matches(
                needle,
                in: [entry.query, entry.pageTitle, entry.answer.oneLine]
            ) else {
                continue
            }
            guard archiveCount < 30 else { break }
            results.append(.archive(entry))
            archiveCount += 1
        }

        var seenResultIDs = Set(results.map(\.id))
        var workspaceCount = 0
        for result in workspaceResults {
            let id = QuickSearchResult.workspace(result).id
            guard seenResultIDs.insert(id).inserted else { continue }
            guard workspaceCount < 8 else { break }
            results.append(.workspace(result))
            workspaceCount += 1
        }

        localResults = results
    }

    func searchWeb(
        query: String,
        language: AppLanguage,
        enabledProviders: Set<SearchProviderID>,
        keys: [SearchProviderID: String],
        gateway: ManualSearchGateway
    ) async {
        guard !isSearching else { return }

        self.query = query
        mode = .web
        error = nil
        webHits = []

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isSearching = false
            return
        }

        isSearching = true
        defer { isSearching = false }

        do {
            let batch = try await gateway.search(
                text: query,
                language: language,
                enabledProviders: enabledProviders,
                keys: keys
            )
            webHits = batch.hits
        } catch is CancellationError {
            // Cancellation is not a provider failure and can be retried.
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func matches(_ needle: String, in fields: [String?]) -> Bool {
        fields.compactMap { $0 }.contains { normalized($0).contains(needle) }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
