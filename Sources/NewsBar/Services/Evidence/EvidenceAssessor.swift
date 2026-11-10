import Foundation

/// One batched assessor call. The model proposes a type, an adoption level and
/// quotations; the app verifies every quote against the fetched text and
/// applies the downgrade rules itself.
enum EvidenceAssessor {
    static let maxClaimsPerSource = 3

    static func assess(
        question: String,
        pageTitle: String?,
        sources: [AISearchSource],
        client: any AIChatClienting,
        language: AppLanguage
    ) async -> AssessmentResult {
        let prepared = sources.map { source -> AISearchSource in
            var copy = source
            if source.duplicateOf != nil {
                copy.assessment = SourceAssessment(
                    independence: .duplicate,
                    adoption: .rejected,
                    reason: .duplicate
                )
            }
            return copy
        }
        let eligible = prepared.filter { $0.duplicateOf == nil }
        guard !eligible.isEmpty else {
            return AssessmentResult(sources: prepared, conflicts: [], notes: [])
        }

        let system = EvidencePrompts.system(language)
        let user = EvidencePrompts.user(
            question: question,
            pageTitle: pageTitle,
            sources: prepared,
            language: language
        )
        let request = AIChatRequest(
            messages: [
                AIChatMessage(role: .system, content: system),
                AIChatMessage(role: .user, content: user),
            ],
            maxTokens: 1_200,
            temperature: 0.1
        )

        let response: AIChatResponse
        do {
            response = try await client.complete(request)
        } catch is CancellationError {
            return heuristic(question: question, sources: prepared)
        } catch {
            let note: RetrievalNote = isQuotaError(error) ? .assessmentSkipped : .assessmentFailed
            return heuristic(question: question, sources: prepared, note: note)
        }

        if let payload = parse(response.text) {
            return apply(payload, sources: prepared)
        }

        // One repair call, never two. A malformed JSON reply is common enough
        // with small models; a second failure falls back to the readability
        // heuristic rather than failing the whole search.
        do {
            let repair = try await client.complete(AIChatRequest(
                messages: [
                    AIChatMessage(role: .system, content: system),
                    AIChatMessage(role: .user, content: user),
                    AIChatMessage(role: .user, content: EvidencePrompts.repair(language)),
                ],
                maxTokens: 1_200,
                temperature: 0.0
            ))
            if let payload = parse(repair.text) {
                return apply(payload, sources: prepared)
            }
        } catch is CancellationError {
            return heuristic(question: question, sources: prepared)
        } catch {
            let note: RetrievalNote = isQuotaError(error) ? .assessmentSkipped : .assessmentFailed
            return heuristic(question: question, sources: prepared, note: note)
        }

        return heuristic(question: question, sources: prepared, note: .assessmentFailed)
    }

    /// The no-assessment path. It promises only what it can keep: readable,
    /// non-duplicate pages are supporting evidence, never "verified".
    static func heuristic(
        question: String,
        sources: [AISearchSource],
        note: RetrievalNote? = nil
    ) -> AssessmentResult {
        var result = sources
        for index in result.indices {
            if result[index].duplicateOf != nil {
                result[index].assessment = SourceAssessment(
                    independence: .duplicate,
                    adoption: .rejected,
                    reason: .duplicate
                )
            } else if result[index].text.count < 400 {
                result[index].assessment = SourceAssessment(
                    adoption: .rejected,
                    reason: .noMaterial
                )
            } else {
                result[index].assessment = SourceAssessment(
                    adoption: .supporting,
                    reason: .heuristic
                )
            }
        }
        return AssessmentResult(
            sources: result,
            conflicts: [],
            notes: note.map { [$0] } ?? []
        )
    }

    // MARK: - Validation

    private static func apply(
        _ payload: Payload,
        sources: [AISearchSource]
    ) -> AssessmentResult {
        var result = sources
        var notes: [RetrievalNote] = []
        var items: [Int: Item] = [:]
        for item in payload.sources {
            guard item.index >= 1, item.index <= result.count, items[item.index] == nil else {
                continue
            }
            items[item.index] = item
        }

        var conflicts: [EvidenceConflict] = []
        for raw in payload.conflicts ?? [] {
            let indices = Array(Set(raw.sources ?? []))
                .filter { $0 >= 1 && $0 <= result.count }
                .sorted()
            guard indices.count >= 2 else { continue }
            conflicts.append(EvidenceConflict(
                claim: String((raw.claim ?? "").prefix(200)),
                indices: indices,
                note: String((raw.note ?? "").prefix(200))
            ))
        }

        var allRejected = true
        for index in result.indices {
            let source = result[index]
            if source.duplicateOf != nil {
                result[index].assessment = SourceAssessment(
                    independence: .duplicate,
                    adoption: .rejected,
                    reason: .duplicate
                )
                continue
            }
            guard let item = items[source.index] else {
                // The assessor omitted a source (usually because the prompt
                // budget ran out). Keep it as supporting rather than silently
                // dropping a page the app did read.
                result[index].assessment = SourceAssessment(
                    adoption: .supporting,
                    reason: .heuristic
                )
                notes.append(.assessmentFailed)
                allRejected = false
                continue
            }
            let assessment = validate(item, source: source)
            result[index].assessment = assessment
            if assessment.adoption != .rejected {
                allRejected = false
            }
        }

        for conflict in conflicts {
            for index in conflict.indices {
                let position = index - 1
                guard result.indices.contains(position),
                      let assessment = result[position].assessment,
                      assessment.adoption == .primary else { continue }
                result[position].assessment = SourceAssessment(
                    type: assessment.type,
                    independence: assessment.independence,
                    adoption: .supporting,
                    reason: .conflict,
                    detail: assessment.detail,
                    claims: assessment.claims
                )
            }
        }

        if allRejected {
            notes.append(.assessmentFailed)
        }
        if !conflicts.isEmpty {
            notes.append(.conflictingSources)
        }
        return AssessmentResult(
            sources: result,
            conflicts: conflicts,
            notes: Array(Set(notes)).sorted { $0.rawValue < $1.rawValue }
        )
    }

    private static func validate(_ item: Item, source: AISearchSource) -> SourceAssessment {
        let type = SourceType(rawValue: item.type ?? "") ?? .unknown
        let independence = SourceIndependence(rawValue: item.independence ?? "") ?? .unknown
        let adopt = item.adopt ?? ""

        if adopt == "reject" {
            return SourceAssessment(
                type: type,
                independence: independence,
                adoption: .rejected,
                reason: .modelRejected,
                detail: item.reason
            )
        }
        if independence == .duplicate {
            return SourceAssessment(
                type: type,
                independence: independence,
                adoption: .rejected,
                reason: .duplicate,
                detail: item.reason
            )
        }

        let claims = verifiedClaims(item.claims ?? [], source: source)
        guard !claims.isEmpty else {
            return SourceAssessment(
                type: type,
                independence: independence,
                adoption: .rejected,
                reason: .quoteNotVerifiable,
                detail: item.reason
            )
        }

        var adoption: SourceAdoption = adopt == "primary" ? .primary : .supporting
        var reason: SourceReason = .assessed
        if adoption == .primary {
            // "Primary" is a claim about the source itself, not about the
            // model's confidence. A reprint, a secondary write-up, or a quote
            // that is only partially supported cannot carry it.
            let direct = claims.contains { $0.support == .direct }
            if type != .primary || independence != .independent || !direct {
                adoption = .supporting
                reason = type == .aggregator ? .aggregator : .singleSource
            }
        }

        return SourceAssessment(
            type: type,
            independence: independence,
            adoption: adoption,
            reason: reason,
            detail: item.reason,
            claims: claims
        )
    }

    private static func verifiedClaims(
        _ claims: [Claim],
        source: AISearchSource
    ) -> [VerifiedClaim] {
        let page = normalizedForQuote(source.text)
        var result: [VerifiedClaim] = []
        for claim in claims {
            guard result.count < maxClaimsPerSource else { break }
            guard let rawQuote = claim.quote else { continue }
            let quote = rawQuote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard quote.count >= 12, quote.count <= 400 else { continue }
            guard page.contains(normalizedForQuote(quote)) else { continue }
            let text = (claim.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let support = SupportLevel(rawValue: claim.support ?? "") ?? .partial
            result.append(VerifiedClaim(
                text: String(text.prefix(200)),
                quote: String(quote.prefix(400)),
                support: support
            ))
        }
        return result
    }

    /// Quote matching is whitespace- and case-insensitive, and ignores the
    /// zero-width characters that copy/paste from a web page often carries.
    static func normalizedForQuote(_ text: String) -> String {
        var value = text.lowercased()
        for scalar in ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}"] {
            value = value.replacingOccurrences(of: scalar, with: "")
        }
        value = value.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isQuotaError(_ error: Error) -> Bool {
        guard let chatError = error as? AIChatError else { return false }
        return chatError == .quotaUnavailable
    }

    // MARK: - Decoding

    private struct Payload: Decodable {
        let sources: [Item]
        let conflicts: [Conflict]?
    }

    private struct Item: Decodable {
        let index: Int
        let type: String?
        let independence: String?
        let adopt: String?
        let reason: String?
        let claims: [Claim]?
    }

    private struct Claim: Decodable {
        let text: String?
        let quote: String?
        let support: String?
    }

    private struct Conflict: Decodable {
        let claim: String?
        let sources: [Int]?
        let note: String?
    }

    private static func parse(_ raw: String) -> Payload? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else { return nil }
        let json = String(text[start...end])
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)),
              !payload.sources.isEmpty else { return nil }
        return payload
    }
}
