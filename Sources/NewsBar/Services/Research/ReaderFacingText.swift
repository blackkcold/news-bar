import Foundation

/// Detects internal workflow vocabulary that must never reach a reader-facing
/// report.
///
/// The list is deliberately phrase-based. Single ambiguous words such as
/// "种子" or "模型" are legitimate news subjects, so only combinations that
/// describe this app's machinery count as a leak.
enum ReaderFacingText {
    struct Finding: Equatable, CustomStringConvertible {
        let field: String
        let term: String

        var description: String { "\(field) → \(term)" }
    }

    /// Phrases that only make sense inside the research pipeline.
    private static let patterns: [String] = [
        // Chinese
        "种子文章", "种子信息", "种子内容", "本次种子", "给定种子",
        "证据卡", "来源档案", "证据编号",
        "核查流程", "抽取阶段", "抽取流程", "研究管线", "核查管线",
        "候选文章", "候选条目", "候选列表",
        "模型没有返回", "模型未能返回", "模型无法返回", "模型生成的内容",
        "客户端会依据", "客户端会根据", "客户端负责",
        // English
        "seed article", "seed context", "evidence card", "evidence cards",
        "source dossier", "evidence id", "evidence ids",
        "extraction stage", "research pipeline", "candidate article",
        "the client computes", "the model returned", "the model produced",
        "the model generated",
        // Cross-language tokens that should not appear in prose
        "triage",
    ]

    private static let regex: NSRegularExpression? = {
        let joined = patterns
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        return try? NSRegularExpression(pattern: joined, options: [.caseInsensitive])
    }()

    /// The first internal phrase in `text`, if any.
    static func firstTerm(in text: String) -> String? {
        guard !text.isEmpty, let regex else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range, in: text) else { return nil }
        return String(text[matchRange])
    }

    static func containsInternalTerm(_ text: String) -> Bool {
        firstTerm(in: text) != nil
    }

    static func findings(in draft: ResearchDraft) -> [Finding] {
        var output: [Finding] = []
        func check(_ field: String, _ value: String) {
            if let term = firstTerm(in: value) {
                output.append(Finding(field: field, term: term))
            }
        }
        check("summary", draft.summary)
        check("overview", draft.overview)
        for (index, node) in draft.timeline.enumerated() {
            check("timeline[\(index)].title", node.title)
            check("timeline[\(index)].detail", node.detail)
        }
        for (index, claim) in draft.claims.enumerated() {
            check("claims[\(index)].claim", claim.claim)
            check("claims[\(index)].note", claim.note)
        }
        for (index, value) in draft.conflicts.enumerated() {
            check("conflicts[\(index)]", value)
        }
        for (index, value) in draft.missing.enumerated() {
            check("missing[\(index)]", value)
        }
        check("limitations", draft.limitations)
        return output
    }

    static func findings(in report: BurstResearch) -> [Finding] {
        var output: [Finding] = []
        func check(_ field: String, _ value: String) {
            if let term = firstTerm(in: value) {
                output.append(Finding(field: field, term: term))
            }
        }
        check("summary", report.summary)
        check("overview", report.overview)
        for (index, node) in report.timeline.enumerated() {
            check("timeline[\(index)].title", node.title)
            check("timeline[\(index)].detail", node.detail)
        }
        for (index, claim) in (report.verification?.claims ?? []).enumerated() {
            check("verification.claims[\(index)].claim", claim.claim)
            check("verification.claims[\(index)].note", claim.note)
        }
        for (index, value) in (report.verification?.conflicts ?? []).enumerated() {
            check("verification.conflicts[\(index)]", value)
        }
        for (index, value) in (report.verification?.missing ?? []).enumerated() {
            check("verification.missing[\(index)]", value)
        }
        check("limitations", report.limitations)
        return output
    }

    /// Deterministic last resort. Runs after the bounded rewrite and again when
    /// a stored report is displayed, so an older artifact cannot leak pipeline
    /// jargon either. A dirty field is removed, never mechanically rewritten:
    /// substring replacement produces broken sentences and can invert meaning.
    static func enforce(_ report: BurstResearch) -> BurstResearch {
        var output = report

        if containsInternalTerm(output.summary) {
            output.summary = ""
        }
        if containsInternalTerm(output.overview) {
            output.overview = ""
        }

        output.timeline = output.timeline.compactMap { node in
            guard !containsInternalTerm(node.title) else { return nil }
            guard containsInternalTerm(node.detail) else { return node }
            return TimelineNode(
                date: node.date,
                title: node.title,
                detail: "",
                sortDate: node.sortDate,
                precision: node.precision,
                evidenceIDs: node.evidenceIDs,
                confidence: node.confidence
            )
        }

        if var verification = output.verification {
            verification.claims = verification.claims.map(cleanClaim)
            verification.conflicts = verification.conflicts.filter { !containsInternalTerm($0) }
            verification.missing = verification.missing.filter { !containsInternalTerm($0) }
            output.verification = verification
        }

        output.limitations = output.limitations
            .components(separatedBy: "\n")
            .filter { !containsInternalTerm($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return output
    }

    private static func cleanClaim(_ claim: ClaimCheck) -> ClaimCheck {
        guard containsInternalTerm(claim.note) else { return claim }
        return ClaimCheck(
            claim: claim.claim,
            status: claim.status,
            evidenceIDs: claim.evidenceIDs,
            note: ""
        )
    }
}
