import Foundation

enum PageSummaryScope: String, Codable, Sendable {
    case article
    case list
}

/// What the overview is allowed to claim. A page overview has no answer-style
/// "citation validation"; it either used adopted external sources or it did not.
enum PageSummaryBasis: String, Codable, Sendable, Equatable {
    /// No external search ran (private reading, toggle off, or list scope).
    case pageOnly
    /// At least one primary source, or two independent supporting sources.
    case externalSupported
    /// External sources exist but are single, secondary, or unassessed.
    case externalLimited
    /// External search was attempted but failed or returned nothing readable.
    case searchUnavailable
    /// No readable page text and no external material.
    case insufficientMaterial
}

enum PageSummarySourceKind: String, Codable, Sendable, Equatable {
    case currentPage
    case external
}

struct PageSummarySource: Codable, Equatable, Identifiable, Sendable {
    /// 1 is always the current page; external sources start at 2.
    let index: Int
    let url: String
    let title: String
    let host: String
    let publishedAt: Date?
    let kind: PageSummarySourceKind
    let type: SourceType?
    /// The exact adoption level, so the row can say 采用 / 仅佐证 / 未采用.
    /// `nil` for the current page, which is never scored as an external source.
    let adoption: SourceAdoption?
    let reason: SourceReason?

    var id: Int { index }
    var adopted: Bool { adoption != .rejected }
}

/// Counts the app can verify without trusting the model. Separate from
/// `RetrievalEvidence`, whose basis is answer-shaped; an overview never has
/// answer citation numbers.
struct PageSummaryRetrieval: Codable, Equatable, Sendable {
    var foundCount: Int = 0
    var readCount: Int = 0
    var adoptedCount: Int = 0
    var rejectedCount: Int = 0
    var queryCount: Int = 0
    var httpAttempts: Int = 0
    var notes: [RetrievalNote] = []

    static let empty = PageSummaryRetrieval()

    mutating func add(_ note: RetrievalNote) {
        guard !notes.contains(note) else { return }
        notes.append(note)
    }
}

/// Input to the summary service after the optional evidence pass. External
/// sources are already renumbered 2...n+1 and assessed.
struct PageSummaryEvidence: Equatable, Sendable {
    var sources: [AISearchSource] = []
    var conflicts: [EvidenceConflict] = []
    var basis: PageSummaryBasis = .pageOnly
    var retrieval: PageSummaryRetrieval? = nil
    var searchAttempted: Bool = false

    static let pageOnly = PageSummaryEvidence()
}


/// One numbered row from the list that was actually sent to the provider.
/// `position` is the original recommendation position, not the visual cell.
struct PageSummaryListRow: Sendable, Equatable {
    let position: Int
    let item: NewsItem
}

/// Everything the overview is allowed to read. The service never fetches the
/// web on its own: an article supplies its extracted body, a list supplies only
/// the titles already loaded on screen.
struct PageSummaryInput: Identifiable, Sendable {
    let id = UUID()
    let scope: PageSummaryScope
    let title: String
    let url: String?
    let articleText: String?
    let listRows: [PageSummaryListRow]
    let language: AppLanguage
    let isPrivate: Bool

    static func article(
        title: String,
        url: String?,
        text: String,
        language: AppLanguage,
        isPrivate: Bool
    ) -> PageSummaryInput {
        PageSummaryInput(
            scope: .article,
            title: title,
            url: url,
            articleText: text,
            listRows: [],
            language: language,
            isPrivate: isPrivate
        )
    }

    static func list(
        title: String,
        rows: [PageSummaryListRow],
        language: AppLanguage,
        isPrivate: Bool
    ) -> PageSummaryInput {
        // No UI entry since 2.16.1: the page overview is only for the reader's
        // current page. Retained for cache compatibility and legacy tests; do
        // not re-expose it on Dashboard without a title-disclosure review.
        PageSummaryInput(
            scope: .list,
            title: title,
            url: nil,
            articleText: nil,
            listRows: rows,
            language: language,
            isPrivate: isPrivate
        )
    }

    /// Stable across view rebuilds. Includes the actual content digest, the
    /// scope, the language, the model, the effective thinking style and the
    /// prompt version, so a different page or thinking level can never be
    /// served from another request's cache.
    func cacheKey(
        model: String,
        providerID: String,
        promptVersion: String,
        thinking: AIThinkingLevel,
        thinkingStyle: AIThinkingStyle,
        webSupplement: Bool = false,
        searchProviderIDs: [String] = [],
        evidenceAssessmentEnabled: Bool = false
    ) -> String {
        let content: String
        switch scope {
        case .article:
            content = articleText ?? ""
        case .list:
            content = listRows
                .map { "\($0.position)|\($0.item.source.id)|\($0.item.title)|\($0.item.url)" }
                .joined(separator: "\n")
        }
        return ContentIdentity.digest(
            [
                promptVersion,
                scope.rawValue,
                ContentIdentity.canonicalURL(url ?? ""),
                language.rawValue,
                providerID,
                model,
                thinking.rawValue,
                thinkingStyle.rawValue,
                // The summary differs depending on whether external search ran
                // and which providers were enabled. The evidence fingerprint is
                // not part of the lookup key: computing it would require the
                // search we are trying to avoid.
                webSupplement ? "web-supplement" : "page-only",
                evidenceAssessmentEnabled ? "assessed" : "heuristic",
                searchProviderIDs.sorted().joined(separator: ","),
                ContentIdentity.digest(title),
                ContentIdentity.digest(content),
            ].joined(separator: "\n")
        )
    }
}

struct PageSummaryPoint: Codable, Equatable, Identifiable, Sendable {
    let text: String
    /// List-scope citation, kept for cache compatibility and the legacy list
    /// parser. Article overviews use `citationIndices`.
    let citationIndex: Int?
    /// Article-scope citations. `nil` for old entries and list scope.
    var citationIndices: [Int]? = nil

    var resolvedCitationIndices: [Int] {
        if let citationIndices, !citationIndices.isEmpty {
            return citationIndices
        }
        return citationIndex.map { [$0] } ?? []
    }

    var id: String {
        "\(resolvedCitationIndices.map(String.init).joined(separator: ","))-\(text)"
    }
}

struct PageSummaryCitation: Codable, Equatable, Identifiable, Sendable {
    /// 1-based number as printed in the overview.
    let index: Int
    let position: Int
    let item: NewsItem

    var id: String { "\(index)|\(item.id)" }
}

struct PageSummary: Codable, Equatable, Sendable {
    let scope: PageSummaryScope
    let oneLine: String
    let points: [PageSummaryPoint]
    let citations: [PageSummaryCitation]
    let generatedAt: Date
    let model: String
    let providerID: String
    let providerName: String
    let inputCharacters: Int
    let wasTruncated: Bool
    /// Optional so old v2 cache entries keep decoding. New article overviews
    /// always set this; list scope keeps using `citations`.
    var sources: [PageSummarySource]? = nil
    var basis: PageSummaryBasis? = nil
    var retrieval: PageSummaryRetrieval? = nil
}

enum PageSummaryError: Error, Equatable, LocalizedError {
    case noReadableContent
    case noModel
    case noKey
    case unauthorized
    case quotaUnavailable
    case configurationChanged
    case malformedResponse
    case modelFailed(String)

    var errorDescription: String? {
        switch self {
        case .noReadableContent: return "The page has no readable text"
        case .noModel: return "No AI model configured"
        case .noKey: return "No API key configured"
        case .unauthorized: return "AI API key is invalid"
        case .quotaUnavailable: return "Daily AI quota reached"
        case .configurationChanged: return "AI configuration changed"
        case .malformedResponse: return "The overview could not be parsed"
        case .modelFailed(let detail): return "AI request failed: \(detail)"
        }
    }

    func message(_ language: AppLanguage) -> String {
        switch self {
        case .noReadableContent:
            return L10n.string("reader.overview.error.noReadableContent", language: language)
        case .noModel:
            return L10n.string("reader.overview.error.noModel", language: language)
        case .noKey:
            return L10n.string("reader.overview.error.noKey", language: language)
        case .unauthorized:
            return L10n.string("reader.overview.error.unauthorized", language: language)
        case .quotaUnavailable:
            return L10n.string("reader.overview.error.quotaUnavailable", language: language)
        case .configurationChanged:
            return L10n.string("reader.overview.error.configurationChanged", language: language)
        case .malformedResponse:
            return L10n.string("reader.overview.error.malformedResponse", language: language)
        case .modelFailed:
            return L10n.string("reader.overview.error.modelFailed", language: language)
        }
    }
}
