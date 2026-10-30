import Foundation

/// What the model decided before answering a selected passage.
struct SelectionPlan: Equatable, Sendable {
    var kind: AnswerKind
    var needsLookup: Bool
    var query: String
}

/// One cheap classification turn used only in the `.auto` mode.
///
/// The model decides whether the passage is a definition it can answer from
/// knowledge, or a claim/news item that needs sources. It also proposes the
/// search query, because a whole paragraph is a poor search string.
enum SelectionQueryPlanner {
    static func prompt(_ language: AppLanguage) -> String {
        if language == .en {
            return """
            Classify the passage the user selected. Answer with one JSON object and nothing else:
            {"kind":"term|event|number|comparison|howto","needsLookup":true|false,"query":"search query"}
            Rules:
            - term: a concept or name that can be explained without sources. needsLookup=false.
            - event, number, comparison: a specific happening, figure or product claim. needsLookup=true.
            - howto: a procedure. needsLookup=false unless it names a specific product or version.
            - query: at most 40 characters, in the passage's language, suitable for a search engine.
            - If unsure, set needsLookup=true.
            """
        }
        return """
        判断用户选中的这段文字属于哪一类。只输出一个 JSON 对象：
        {"kind":"term|event|number|comparison|howto","needsLookup":true|false,"query":"检索词"}
        规则：
        - term：可以直接解释的概念或名称，needsLookup=false
        - event、number、comparison：具体事件、具体数字或产品说法，needsLookup=true
        - howto：操作步骤，除非点名具体产品或版本，否则 needsLookup=false
        - query：不超过 40 字，与原文同语言，适合直接丢给搜索引擎
        - 不确定时一律 needsLookup=true
        """
    }

    static func parse(_ raw: String) -> SelectionPlan? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        guard let data = String(text[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let kind = (object["kind"] as? String).flatMap(AnswerKind.init(rawValue:)) ?? .term
        let needsLookup = object["needsLookup"] as? Bool ?? true
        let query = (object["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(80) ?? ""
        return SelectionPlan(kind: kind, needsLookup: needsLookup, query: String(query))
    }
}
