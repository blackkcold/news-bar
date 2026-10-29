import Foundation

/// One AI verdict for one candidate. Decoding is lenient: a single malformed
/// row must not throw away the whole batch.
struct ResearchTriageDecision: Sendable, Equatable {
    let id: String
    let sameEventAs: String?
    let sameAngleAs: String?
    let worth: Bool
    let confidence: Double
    let reason: String
}

/// Prompt, parser and selection for the paid pre-research check. The model sees
/// at most six candidates and the last thirty record titles, and must answer
/// with a compact JSON array.
enum ResearchTriage {
    static let maxCandidates = 6
    static let recentLimit = 30
    static let duplicateConfidence = 0.7
    static let worthConfidence = 0.5

    static func request(
        candidates: [ResearchCandidateItem],
        recent: [ResearchIndexEntry],
        language: AppLanguage,
        now: Date = Date()
    ) -> AIChatRequest {
        let system = """
        You are a strict research editor for a personal news app.
        For each candidate decide:
        1. sameEventAs: the id of a recent record that covers the same real-world event, or null.
        2. sameAngleAs: the id of a recent record with the same angle/format but a different event, or null.
        3. worth: true only when the topic has a concrete subject, new facts since the recent record (if any), verifiable sources, and is not an ad, listicle, roundup or pure opinion. Default to false when uncertain.
        4. confidence: 0 to 1.
        Use only the ids provided. Return only a JSON array, no markdown, no prose:
        [{"id":"...","sameEventAs":null,"sameAngleAs":null,"worth":true,"confidence":0.8,"reason":"short reason"}]
        """

        var lines: [String] = []
        lines.append("CANDIDATES")
        for candidate in candidates.prefix(maxCandidates) {
            lines.append("- id: \(candidate.item.id) | kind: \(kindLabel(candidate.kind)) | title: \(candidate.item.title) | source: \(candidate.item.source.displayName)")
        }
        lines.append("RECENT RECORDS")
        if recent.isEmpty {
            lines.append("- none")
        } else {
            for entry in recent.prefix(recentLimit) {
                let days = max(0, Int(now.timeIntervalSince(entry.lastSeenAt) / 86_400))
                lines.append("- id: \(entry.id) | title: \(entry.topic) | daysAgo: \(days)")
            }
        }
        lines.append("Answer in \(language == .en ? "English" : "Chinese") for the reason field only.")

        return AIChatRequest(
            messages: [
                AIChatMessage(role: .system, content: system),
                AIChatMessage(role: .user, content: lines.joined(separator: "\n")),
            ],
            maxTokens: 700,
            temperature: 0
        )
    }

    static func parse(_ text: String) -> [ResearchTriageDecision] {
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]"),
              start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let raw = try? JSONDecoder().decode([FailableDecision].self, from: data) else {
            return []
        }
        return raw.compactMap { entry in
            guard let row = entry.value else { return nil }
            guard let id = row.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
            return ResearchTriageDecision(
                id: id,
                sameEventAs: row.sameEventAs,
                sameAngleAs: row.sameAngleAs,
                worth: row.worth ?? false,
                confidence: min(1, max(0, row.confidence ?? 0)),
                reason: row.reason ?? ""
            )
        }
    }

    /// Highest-priority candidate the editor accepted. A confident
    /// `sameEventAs` pointing at a real recent record wins over `worth`.
    static func choose(
        candidates: [ResearchCandidateItem],
        decisions: [ResearchTriageDecision],
        knownRecordIDs: Set<String>
    ) -> ResearchCandidateItem? {
        let map = Dictionary(decisions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return candidates.first { candidate in
            guard let decision = map[candidate.item.id],
                  decision.worth,
                  decision.confidence >= worthConfidence else { return false }
            if let sameEvent = decision.sameEventAs,
               decision.confidence >= duplicateConfidence,
               knownRecordIDs.contains(sameEvent) {
                return false
            }
            return true
        }
    }

    /// Conservative fallback when no usable verdict exists. A candidate that
    /// already has a verdict — including a cached "not worth it" — must never
    /// be reconsidered by the fallback.
    static func fallbackBurst(
        candidates: [ResearchCandidateItem],
        decisions: [ResearchTriageDecision],
        minimumHeat: Double = 0.8
    ) -> ResearchCandidateItem? {
        let decidedIDs = Set(decisions.map(\.id))
        return candidates.first {
            $0.kind == .burst
                && ($0.publicHeat ?? 0) >= minimumHeat
                && !decidedIDs.contains($0.item.id)
        }
    }

    private static func kindLabel(_ kind: ResearchCandidateItem.Kind) -> String {
        switch kind {
        case .burst: return "burst"
        case .personal: return "personal"
        case .publicHot: return "public"
        }
    }

    private struct RawDecision: Decodable {
        let id: String?
        let sameEventAs: String?
        let sameAngleAs: String?
        let worth: Bool?
        let confidence: Double?
        let reason: String?
    }

    private struct FailableDecision: Decodable {
        let value: RawDecision?

        init(from decoder: Decoder) throws {
            value = try? RawDecision(from: decoder)
        }
    }
}
