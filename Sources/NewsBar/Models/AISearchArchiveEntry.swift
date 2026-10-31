import Foundation

enum AISearchArchiveOrigin: String, Codable, Sendable, CaseIterable {
    case readerSearch
    case selectionLookup
}

struct AISearchArchiveBlock: Codable, Equatable, Sendable {
    let id: Int
    let heading: String?
    let body: String

    init(id: Int, heading: String?, body: String) {
        self.id = id
        self.heading = heading
        self.body = body
    }
}

struct AISearchArchiveSource: Codable, Equatable, Sendable {
    let index: Int
    let url: String?
    let title: String

    init(index: Int, url: String?, title: String) {
        self.index = index
        self.url = url
        self.title = title
    }
}

struct AISearchArchiveAnswer: Codable, Equatable, Sendable {
    let kind: AnswerKind
    let oneLine: String
    let blocks: [AISearchArchiveBlock]
    let sources: [AISearchArchiveSource]
    let mode: AnswerMode
    let model: String
    let providerName: String
    let thinking: AIThinkingLevel
    let generatedAt: Date
    let truncated: Bool

    init(answer: AnswerDocument, providerName: String) {
        kind = answer.kind
        oneLine = answer.oneLine
        blocks = answer.blocks.map {
            AISearchArchiveBlock(id: $0.id, heading: $0.heading, body: $0.body)
        }
        sources = answer.sources.map {
            AISearchArchiveSource(
                index: $0.index,
                url: AISearchArchiveEntry.sanitizedURL($0.url),
                title: $0.title
            )
        }
        mode = answer.mode
        model = answer.model
        self.providerName = providerName
        thinking = answer.thinking
        generatedAt = answer.generatedAt
        truncated = answer.truncated
    }

    func answerDocument() -> AnswerDocument {
        AnswerDocument(
            kind: kind,
            oneLine: oneLine,
            blocks: blocks.map {
                AnswerBlock(id: $0.id, heading: $0.heading, body: $0.body)
            },
            sources: sources.map {
                AISearchSource(index: $0.index, url: $0.url ?? "", title: $0.title, text: "")
            },
            mode: mode,
            model: model,
            thinking: thinking,
            generatedAt: generatedAt,
            question: nil,
            truncated: truncated
        )
    }
}

struct AISearchArchiveEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let query: String
    let scope: AISearchScope
    let origin: AISearchArchiveOrigin
    let pageTitle: String?
    let pageURL: String?
    let answer: AISearchArchiveAnswer

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        query: String,
        scope: AISearchScope,
        origin: AISearchArchiveOrigin,
        pageTitle: String?,
        pageURL: String?,
        providerName: String,
        answer: AnswerDocument
    ) {
        self.id = id
        self.createdAt = createdAt
        self.query = query
        self.scope = scope
        self.origin = origin
        self.pageTitle = pageTitle
        self.pageURL = pageURL.flatMap(Self.sanitizedURL)
        self.answer = AISearchArchiveAnswer(answer: answer, providerName: providerName)
    }

    func answerDocument() -> AnswerDocument {
        var restored = answer.answerDocument()
        restored.question = query
        return restored
    }

    static func sanitizedURL(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw) else { return nil }
        components.user = nil
        components.password = nil
        components.fragment = nil
        guard let candidate = components.url?.absoluteString,
              let allowed = ReaderNavigationPolicy.allowedURL(candidate) else {
            return nil
        }
        return allowed.absoluteString
    }
}

struct AISearchArchiveSnapshot: Codable, Equatable, Sendable {
    let version: Int
    var entries: [AISearchArchiveEntry]

    init(version: Int = 1, entries: [AISearchArchiveEntry] = []) {
        self.version = version
        self.entries = entries
    }
}
