import Foundation

enum PageSummaryScope: String, Codable, Sendable {
    case article
    case list
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
    /// scope, the language, the model and the prompt version, so a different
    /// article can never be served from another page's cache.
    func cacheKey(model: String, providerID: String, promptVersion: String) -> String {
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
                ContentIdentity.digest(content),
            ].joined(separator: "\n")
        )
    }
}

struct PageSummaryPoint: Codable, Equatable, Identifiable, Sendable {
    let text: String
    let citationIndex: Int?

    var id: String { "\(citationIndex ?? 0)-\(text)" }
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
        let english = language == .en
        switch self {
        case .noReadableContent:
            return english ? "This page has no readable text to summarize." : "当前页面没有可概括的正文。"
        case .noModel:
            return english ? "Choose an AI model in Settings → AI first." : "请先在设置 → AI 中选择模型。"
        case .noKey:
            return english ? "Add an API key in Settings → AI first." : "请先在设置 → AI 中配置 API Key。"
        case .unauthorized:
            return english ? "The AI provider rejected the API key. Check Settings → AI." : "AI 提供商拒绝了当前 API Key，请检查设置 → AI。"
        case .quotaUnavailable:
            return english ? "Today's AI limit is reached. It resets tomorrow." : "今日 AI 用量已用完，明天重置。"
        case .configurationChanged:
            return english ? "AI settings changed. Please try again." : "AI 设置已更改，请重试。"
        case .malformedResponse:
            return english ? "The provider returned an overview in an unexpected format. Try again." : "提供商返回的概览格式异常，请重试。"
        case .modelFailed:
            return english ? "The AI provider did not answer. Try again." : "AI 提供商未返回结果，请重试。"
        }
    }
}
