import Foundation

struct ResearchPlan: Sendable, Equatable {
    var claims: [String]
    var queries: [PlannedQuery]
}

struct PlannedQuery: Sendable, Equatable {
    var text: String
    var recency: SearchRecency?
}

struct RawEvidence: Sendable, Equatable {
    /// 1-based index into the batch of documents sent with the extraction prompt.
    var sourceIndex: Int?
    /// Fallback URL when the provider/format allows one.
    var url: String?
    var quote: String
    var claim: String
    var stance: EvidenceStance
    var publishedAt: Date?
}

struct EvidenceCandidate: Sendable, Equatable {
    var url: String
    var title: String
    var quote: String
    var claim: String
    var stance: EvidenceStance
    var publishedAt: Date?
    var fetchedAt: Date

    init(
        url: String,
        title: String,
        quote: String,
        claim: String,
        stance: EvidenceStance,
        publishedAt: Date? = nil,
        fetchedAt: Date = Date()
    ) {
        self.url = url
        self.title = title
        self.quote = quote
        self.claim = claim
        self.stance = stance
        self.publishedAt = publishedAt
        self.fetchedAt = fetchedAt
    }
}

struct ResearchDraft: Sendable, Equatable {
    var summary = ""
    var overview = ""
    var timeline: [TimelineNode] = []
    var claims: [ClaimCheck] = []
    /// Evidence returned inline by the synthesis call. Only used when the
    /// extraction stage produced none (quick depth or a skipped batch).
    var inlineEvidence: [RawEvidence] = []
    var conflicts: [String] = []
    var missing: [String] = []
    var limitations = ""
}

/// Tolerant decoder for the three JSON contracts. Models wrap JSON in code
/// fences, prepend prose, and occasionally emit a scalar where an array was
/// requested; none of that should fail the whole research task.
enum ResearchReportParser {

    // MARK: - Planning

    static func plan(from text: String) -> ResearchPlan? {
        guard let object = ResearchJSON.object(from: text) else { return nil }
        let claims = stringArray(object["claims"])
        let rawQueries = object["queries"] as? [[String: Any]] ?? []
        let queries = rawQueries.compactMap { item -> PlannedQuery? in
            let text = string(item["text"])
            guard !text.isEmpty else { return nil }
            let recencyText = string(item["recency"])
            let recency = SearchRecency(rawValue: recencyText)
            return PlannedQuery(text: text, recency: recency)
        }
        guard !claims.isEmpty || !queries.isEmpty else { return nil }
        return ResearchPlan(claims: claims, queries: queries)
    }

    // MARK: - Extraction

    static func evidence(from text: String, now: Date = Date()) -> [RawEvidence]? {
        guard let object = ResearchJSON.object(from: text) else { return nil }
        guard let rawItems = object["evidence"] as? [[String: Any]] else { return [] }
        let items = rawItems.compactMap { item -> RawEvidence? in
            let quote = string(item["quote"])
            guard !quote.isEmpty else { return nil }
            return RawEvidence(
                sourceIndex: int(item["source"]),
                url: string(item["url"]).isEmpty ? nil : string(item["url"]),
                quote: quote,
                claim: string(item["claim"]),
                stance: stance(item["stance"]),
                publishedAt: date(item["publishedAt"], now: now)
                    ?? date(item["published_at"], now: now)
            )
        }
        return items
    }

    // MARK: - Synthesis

    static func synthesis(from text: String, now: Date = Date()) -> ResearchDraft? {
        guard let object = ResearchJSON.object(from: text) else { return nil }

        var draft = ResearchDraft()
        draft.summary = string(object["summary"]).trimmingCharacters(in: .whitespacesAndNewlines)
        draft.overview = string(object["overview"]).trimmingCharacters(in: .whitespacesAndNewlines)

        let rawTimeline = object["timeline"] as? [[String: Any]] ?? []
        draft.timeline = rawTimeline.compactMap { item -> TimelineNode? in
            let title = string(item["title"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = string(item["detail"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let dateLabel = string(item["date"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let evidenceIDs = stringArray(item["evidenceIDs"])
            let confidence = confidence(item["confidence"])
            let parsed = TimelineDateParser.parse(dateLabel, now: now)
            return TimelineNode(
                date: dateLabel,
                title: title,
                detail: detail,
                sortDate: parsed?.date,
                precision: parsed?.precision ?? .unknown,
                evidenceIDs: evidenceIDs,
                confidence: confidence
            )
        }

        let rawClaims = object["claims"] as? [[String: Any]] ?? []
        draft.claims = rawClaims.compactMap { item -> ClaimCheck? in
            let claim = string(item["claim"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !claim.isEmpty else { return nil }
            let status: EvidenceStance?
            if let raw = item["status"] as? String {
                status = raw.lowercased() == "null" ? nil : EvidenceStance(rawValue: raw)
            } else {
                status = nil
            }
            return ClaimCheck(
                claim: claim,
                status: status,
                evidenceIDs: stringArray(item["evidenceIDs"]),
                note: string(item["note"])
            )
        }

        draft.inlineEvidence = evidence(from: text, now: now) ?? []
        draft.conflicts = stringArray(object["conflicts"])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        draft.missing = stringArray(object["missing"])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        draft.limitations = string(object["limitations"]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !draft.summary.isEmpty || !draft.overview.isEmpty || !draft.timeline.isEmpty else {
            return nil
        }
        return draft
    }

    // MARK: - Field coercion

    private static func string(_ value: Any?) -> String {
        switch value {
        case let value as String: return value
        case let value as NSNumber: return value.stringValue
        default: return ""
        }
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let value as Int: return value
        case let value as NSNumber: return value.intValue
        case let value as String: return Int(value)
        default: return nil
        }
    }

    private static func stringArray(_ value: Any?) -> [String] {
        if let array = value as? [String] { return array.filter { !$0.isEmpty } }
        if let array = value as? [Any] {
            return array.compactMap { item in
                let text = string(item)
                return text.isEmpty ? nil : text
            }
        }
        if let single = value as? String, !single.isEmpty { return [single] }
        return []
    }

    private static func stance(_ value: Any?) -> EvidenceStance {
        guard let raw = value as? String else { return .unclear }
        switch raw.lowercased() {
        case "supports", "support", "supported": return .supports
        case "refutes", "refute", "refuted", "contradicts": return .refutes
        default: return .unclear
        }
    }

    private static func confidence(_ value: Any?) -> Confidence {
        guard let raw = value as? String else { return .medium }
        switch raw.lowercased() {
        case "high": return .high
        case "low": return .low
        default: return .medium
        }
    }

    private static func date(_ value: Any?, now: Date) -> Date? {
        guard let raw = value as? String, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        if raw.lowercased() == "null" { return nil }
        return TimelineDateParser.parse(raw, now: now)?.date
    }
}

/// Extracts the first JSON object from model output, tolerating code fences and
/// surrounding prose. Brace counting is string- and escape-aware.
enum ResearchJSON {
    static func object(from text: String) -> [String: Any]? {
        let cleaned = stripFence(text)
        guard let slice = firstObjectSlice(cleaned) else { return nil }
        guard let data = slice.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func stripFence(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            if let newline = value.firstIndex(of: "\n") {
                value = String(value[value.index(after: newline)...])
            } else {
                return ""
            }
        }
        if value.hasSuffix("```") {
            value = String(value.dropLast(3))
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func firstObjectSlice(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start

        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
