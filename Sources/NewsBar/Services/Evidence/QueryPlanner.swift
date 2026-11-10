import Foundation

/// One query the app will send to the search router. The role is kept so the
/// retriever can prefer the user's own wording over a derived variant.
struct EvidenceQuery: Equatable, Sendable {
    enum Role: String, Sendable, Equatable {
        case original
        case clause
        case quotedEntity
        case pageTitle

        /// Added to a provider rank when ordering merged candidates. The
        /// original question always wins ties; a page-title query is the most
        /// speculative and therefore the last resort.
        var rankBonus: Int {
            switch self {
            case .original: return 0
            case .clause: return 1
            case .quotedEntity: return 2
            case .pageTitle: return 3
            }
        }
    }

    let text: String
    let recency: SearchRecency
    let role: Role
}

struct EvidenceQueryPlan: Equatable, Sendable {
    let queries: [EvidenceQuery]
    let recency: SearchRecency

    static let empty = EvidenceQueryPlan(queries: [], recency: .month)
}

/// Deterministic query expansion. No model call: the app must know exactly
/// what it will send to a search provider before it spends an attempt.
///
/// The rules are deliberately small. A single question stays a single query;
/// only a multi-clause question, a quoted phrase, or a deictic question with a
/// page title adds a variant. Three queries is the ceiling because the run
/// shares one six-attempt ticket.
enum QueryPlanner {
    static let maxQueries = 3
    private static let maxQueryCharacters = 200

    static func plan(
        question: String,
        scope: AISearchScope,
        page: AISearchPageContext?,
        language: AppLanguage
    ) -> EvidenceQueryPlan {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        let recency = recency(for: trimmed)
        guard scope == .web else {
            return EvidenceQueryPlan(
                queries: [EvidenceQuery(text: cap(trimmed), recency: recency, role: .original)],
                recency: recency
            )
        }

        var queries: [EvidenceQuery] = [
            EvidenceQuery(text: cap(trimmed), recency: recency, role: .original)
        ]

        for clause in clauses(in: trimmed) where queries.count < maxQueries {
            append(EvidenceQuery(text: cap(clause), recency: recency, role: .clause), to: &queries)
        }

        if let quoted = quotedPhrase(in: trimmed), queries.count < maxQueries {
            append(EvidenceQuery(text: cap(quoted), recency: recency, role: .quotedEntity), to: &queries)
        }

        if isDeictic(trimmed), queries.count < maxQueries,
           let title = page?.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            append(EvidenceQuery(text: cap(title), recency: recency, role: .pageTitle), to: &queries)
        }

        return EvidenceQueryPlan(queries: Array(queries.prefix(maxQueries)), recency: recency)
    }

    /// Page-overview queries. Two at most: the overview run has a four-attempt
    /// ticket, and two attempts per query is the matching ceiling.
    static func planOverview(
        title: String,
        excerpt: String,
        language: AppLanguage
    ) -> EvidenceQueryPlan {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanExcerpt = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty || !cleanExcerpt.isEmpty else { return .empty }

        let recency: SearchRecency = .month
        var queries: [EvidenceQuery] = []
        if !cleanTitle.isEmpty {
            queries.append(
                EvidenceQuery(text: cap(cleanTitle), recency: recency, role: .original)
            )
        }
        if let sentence = firstOverviewSentence(cleanExcerpt) {
            let role: EvidenceQuery.Role = queries.isEmpty ? .original : .clause
            append(
                EvidenceQuery(text: cap(sentence), recency: recency, role: role),
                to: &queries
            )
        }
        return EvidenceQueryPlan(queries: Array(queries.prefix(2)), recency: recency)
    }

    private static func firstOverviewSentence(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let separators = CharacterSet(charactersIn: "。！？!?\n")
        let first = text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        if let first, first.count >= 2 {
            return String(first.prefix(120))
        }
        let fallback = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.count >= 2 ? String(fallback.prefix(120)) : nil
    }

    // MARK: - Recency

    /// Explicit time words beat intent words. A question that says "today"
    /// must not be widened to "all" just because it also says "what is".
    static func recency(for question: String) -> SearchRecency {
        let text = question.lowercased()
        if contains(text, any: [
            "今天", "今日", "刚刚", "刚才", "最新", "突发",
            "today", "just now", "latest", "breaking",
        ]) {
            return .day
        }
        if contains(text, any: ["本周", "这周", "this week", "past week"]) {
            return .week
        }
        if contains(text, any: [
            "今年", "本年", "过去一年", "近一年",
            "this year", "past year", "last year",
        ]) {
            return .year
        }
        // Conceptual questions rarely benefit from a 30-day window. Keep the
        // news default for everything that does not look conceptual.
        if contains(text, any: [
            "是什么", "什么是", "定义", "原理", "区别", "怎么", "如何", "为什么",
            "历史", "背景", "解释", "介绍",
            "what is", "definition", "how to", "how does", "why", "difference",
            "history", "background",
        ]) {
            return .all
        }
        return .month
    }

    // MARK: - Variant extraction

    private static func clauses(in question: String) -> [String] {
        let separators = CharacterSet(charactersIn: "？?；;\n")
        let parts = question
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        guard parts.count > 1 else { return [] }
        // At most two derived clauses; the original is already in the plan.
        return Array(parts.prefix(2))
    }

    private static func quotedPhrase(in question: String) -> String? {
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("「", "」")]
        for (open, close) in pairs {
            guard let start = question.firstIndex(of: open) else { continue }
            let afterOpen = question.index(after: start)
            guard let end = question[afterOpen...].firstIndex(of: close) else { continue }
            let phrase = question[afterOpen..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if phrase.count >= 2, phrase.count <= 80 {
                return phrase
            }
        }
        return nil
    }

    private static func isDeictic(_ question: String) -> Bool {
        let text = question.lowercased()
        // Bare "该" is a common word inside "应该"; only specific demonstrative
        // phrases may pull the page title into the query.
        if contains(text, any: [
            "这个", "这款", "这家", "此人", "上述", "它",
            "该文", "该产品", "该公司", "该事件", "该项目", "该功能", "该模型",
        ]) {
            return true
        }
        return text.hasPrefix("this ") || text.hasPrefix("that ") || text.contains(" this ")
    }

    private static func append(_ query: EvidenceQuery, to queries: inout [EvidenceQuery]) {
        let key = normalized(query.text)
        guard !key.isEmpty else { return }
        guard !queries.contains(where: { normalized($0.text) == key }) else { return }
        queries.append(query)
    }

    private static func contains(_ text: String, any needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func cap(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxQueryCharacters else { return trimmed }
        return String(trimmed.prefix(maxQueryCharacters))
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }
}
