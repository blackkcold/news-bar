import Foundation

enum AISearchScope: String, Codable, Sendable, CaseIterable, Identifiable {
    case currentPage
    case web

    var id: String { rawValue }

    func title(_ language: AppLanguage) -> String {
        switch self {
        case .currentPage: return language == .en ? "This page" : "当前页"
        case .web: return language == .en ? "Web search" : "全网检索"
        }
    }
}

/// A page that was actually fetched (or the current reader page) for this
/// answer. Citations are validated against this set and nothing else.
struct AISearchSource: Identifiable, Equatable, Sendable {
    let id: String
    let index: Int
    let url: String
    let title: String
    let host: String
    /// Prompt-sized text, capped when the source is created.
    let text: String
    let excerpt: String

    init(index: Int, url: String, title: String, text: String, textLimit: Int = 8_000) {
        let capped = String(text.prefix(max(1, textLimit)))
        self.id = ContentIdentity.canonicalURL(url)
        self.index = index
        self.url = url
        self.title = title
        self.host = URL(string: url)?.host ?? ""
        self.text = capped
        self.excerpt = String(capped.prefix(280))
    }
}

struct AISearchCitation: Identifiable, Equatable, Sendable {
    let id: String
    let index: Int
    let url: String
    let title: String
    let host: String

    init(source: AISearchSource) {
        self.id = source.id
        self.index = source.index
        self.url = source.url
        self.title = source.title
        self.host = source.host
    }
}

struct AISearchAnswer: Equatable, Sendable {
    let question: String
    let answer: String
    let citations: [AISearchCitation]
    let fetchedSources: [AISearchSource]
    let thinkingLevel: AIThinkingLevel
    let model: String
    let scope: AISearchScope
    let searchedAt: Date
    /// True when every citation was discarded and the answer was degraded.
    let citationsUnavailable: Bool
}

enum AISearchStage: Equatable, Sendable {
    case searching
    case reading(index: Int, total: Int)
    case answering
}

struct AISearchPageContext: Equatable, Sendable {
    let url: String
    let title: String
    let text: String
}

enum AISearchError: Error, Equatable, LocalizedError {
    case emptyQuestion
    case noPageText
    case noModel
    case noKey
    case quotaUnavailable
    case searchFailed(String)
    case noSourcesReadable
    case modelFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyQuestion: return "Question is empty"
        case .noPageText: return "The current page has no readable text"
        case .noModel: return "No AI model configured"
        case .noKey: return "No API key configured"
        case .quotaUnavailable: return "Daily AI quota reached"
        case .searchFailed(let detail): return "Search failed: \(detail)"
        case .noSourcesReadable: return "No source could be read"
        case .modelFailed(let detail): return "AI request failed: \(detail)"
        }
    }

    func message(_ language: AppLanguage) -> String {
        let english = language == .en
        switch self {
        case .emptyQuestion:
            return english ? "Type a question first." : "请先输入问题。"
        case .noPageText:
            return english ? "This page has no readable article text. Try web search instead." : "当前页没有可读正文，可改用全网检索。"
        case .noModel:
            return english ? "Choose an AI model for search in Settings → AI." : "请先在设置 → AI 中为搜索选择模型。"
        case .noKey:
            return english ? "Add an API key in Settings → AI first." : "请先在设置 → AI 中配置 API Key。"
        case .quotaUnavailable:
            return english ? "Today's AI limit is reached. It resets tomorrow." : "今日 AI 用量已用完，明天重置。"
        case .searchFailed:
            return english ? "Web search is unavailable. Check search providers in Settings → AI." : "全网检索不可用，请检查设置 → AI 中的搜索提供商。"
        case .noSourcesReadable:
            return english ? "None of the search results could be read. Try another question or open a result directly." : "搜索结果均无法读取正文，请换个问题或直接打开结果。"
        case .modelFailed:
            return english ? "The AI provider did not answer. Try again." : "AI 提供商未返回结果，请重试。"
        }
    }
}
