import Foundation

/// Prompt for the batched source assessor. The model only proposes; every
/// quote it returns is checked against the fetched text before it counts.
enum EvidencePrompts {
    static let maxSourceCharacters = 3_000
    static let maxTotalCharacters = 18_000
    static let maxQuestionCharacters = 500
    static let maxPageTitleCharacters = 200

    static func system(_ language: AppLanguage) -> String {
        let languageLine = language == .en
            ? "Write reason, claim and note in English."
            : "reason、claim 和 note 用中文写。"
        return """
        You audit evidence for a search answer. You do not answer the question.
        For each source, find exact sentences that support a claim about the question.
        Use only the text provided. Never use outside knowledge. Never invent a quote.
        A duplicate or aggregator cannot be "primary". A source with no verifiable quote cannot be "primary".
        If two sources disagree, list both in conflicts and mark both "supporting".
        \(languageLine)
        Return strict JSON only, no prose, no code fences:
        {"sources":[{"index":1,"type":"primary|secondary|aggregator|unknown","independence":"independent|duplicate|unknown","adopt":"primary|supporting|reject","reason":"short","claims":[{"text":"claim","quote":"exact sentence","support":"direct|partial"}]}],"conflicts":[{"claim":"...","sources":[1,2],"note":"..."}]}
        """
    }

    static func user(
        question: String,
        pageTitle: String?,
        sources: [AISearchSource],
        language: AppLanguage
    ) -> String {
        let sanitizedQuestion = AISearchPrompts.sanitize(question, limit: maxQuestionCharacters)
        var header = language == .en
            ? "Question: \(sanitizedQuestion)"
            : "问题：\(sanitizedQuestion)"
        if let pageTitle, !pageTitle.isEmpty {
            let title = AISearchPrompts.sanitize(pageTitle, limit: maxPageTitleCharacters)
            header += language == .en ? "\nPage title: \(title)" : "\n页面标题：\(title)"
        }

        var blocks: [String] = []
        var budget = maxTotalCharacters
        for source in sources where source.duplicateOf == nil {
            guard budget > 0 else { break }
            let allowed = min(maxSourceCharacters, budget)
            let text = AISearchPrompts.sanitize(source.text, limit: allowed)
            guard !text.isEmpty else { continue }
            budget -= text.count
            let title = AISearchPrompts.sanitize(source.title, limit: 200)
            let host = AISearchPrompts.sanitize(source.host, limit: 120)
            let published = source.publishedAt.map(Self.isoDate) ?? "unknown"
            blocks.append("""
            <evidence_source index="\(source.index)" title="\(title)" host="\(host)" published="\(published)">
            \(text)
            </evidence_source>
            """)
        }
        let footer = language == .en
            ? "Return only the JSON object. Every quote must be copied from the source text above."
            : "只返回 JSON 对象。每条 quote 必须逐字来自上面的来源正文。"
        return ([header, blocks.joined(separator: "\n\n"), footer])
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    static func repair(_ language: AppLanguage) -> String {
        language == .en
            ? "Your previous reply was not valid JSON. Return only the JSON object described above, with no prose and no code fences."
            : "你上一条回复不是合法 JSON。只返回上面描述的 JSON 对象，不要解释，不要代码围栏。"
    }

    static func isoDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }
}
