import Foundation

/// Decodes the structured JSON contract the AI returns for burst research.
/// Tolerant of markdown code-fence wrapping, extra surrounding prose, and
/// missing/optional fields (timeline may be absent in pure-AI fallback mode).
enum BurstResearchParser {

    struct RawResearch: Decodable {
        var summary: String = ""
        var overview: String = ""
        var timeline: [TimelineNode] = []
        var sources: [String] = []
        var needsRefetch: Bool = false
        var refetchURLs: [String] = []

        enum CodingKeys: String, CodingKey {
            case summary, overview, timeline, sources, needsRefetch, refetchURLs
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? ""
            overview = (try? c.decodeIfPresent(String.self, forKey: .overview)) ?? ""
            timeline = (try? c.decodeIfPresent([TimelineNode].self, forKey: .timeline)) ?? []
            sources = (try? c.decodeIfPresent([String].self, forKey: .sources)) ?? []
            needsRefetch = (try? c.decodeIfPresent(Bool.self, forKey: .needsRefetch)) ?? false
            refetchURLs = (try? c.decodeIfPresent([String].self, forKey: .refetchURLs)) ?? []
        }
    }

    /// Returns `nil` when no usable summary or overview could be extracted.
    static func parse(_ text: String) -> BurstResearch? {
        parse(text, searchStatus: .none)
    }

    /// Parses JSON into a `BurstResearch`, stamping the given search outcome so
    /// the UI/logging can report whether web search actually ran.
    static func parse(_ text: String, searchStatus: BurstSearchStatus) -> BurstResearch? {
        let cleaned = stripCodeFence(text)
        guard let data = cleaned.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawResearch.self, from: data) else {
            return nil
        }
        let summary = cleanedText(raw.summary)
        let overview = cleanedText(raw.overview)
        guard !summary.isEmpty || !overview.isEmpty else { return nil }

        let timeline = raw.timeline
            .map { TimelineNode(date: cleanedText($0.date), title: cleanedText($0.title), detail: cleanedText($0.detail)) }
            .filter { !$0.title.isEmpty && (!$0.date.isEmpty || !$0.detail.isEmpty) }

        return BurstResearch(
            summary: summary,
            overview: overview,
            timeline: timeline,
            sources: raw.sources.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") },
            needsRefetch: raw.needsRefetch,
            refetchURLs: raw.refetchURLs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") },
            searchStatus: searchStatus
        )
    }

    /// Returns true when the parsed research has real, renderable content.
    static func hasUsableContent(_ research: BurstResearch) -> Bool {
        !research.summary.isEmpty || !research.overview.isEmpty || !research.timeline.isEmpty
    }

    private static func cleanedText(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripCodeFence(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a leading ```json/``` fence line and trailing ``` line.
        if t.hasPrefix("```") {
            if let newline = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: newline)...])
            } else {
                t = ""
            }
        }
        if t.hasSuffix("```") {
            let end = t.index(t.endIndex, offsetBy: -3)
            t = String(t[..<end])
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
