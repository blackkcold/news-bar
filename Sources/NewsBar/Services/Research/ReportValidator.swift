import Foundation

/// Deterministic quote matching. The model's quote is split on ellipses; each
/// surviving segment must appear verbatim in the fetched page text. A hit rate
/// of 0.6 with at least one hit is enough to keep the evidence verified. A
/// failed check only lowers confidence — evidence is never deleted for it.
enum QuoteVerifier {
    static let minimumSegmentLength = 8
    static let minimumHitRatio = 0.6

    static func normalize(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))

        let punctuation: [Character: Character] = [
            "，": ",", "。": ".", "！": "!", "？": "?", "；": ";", "：": ":",
            "（": "(", "）": ")", "【": "[", "】": "]", "「": "\"", "」": "\"",
            "『": "\"", "』": "\"", "“": "\"", "”": "\"", "‘": "'", "’": "'",
            "、": ",", "～": "~", "—": "-", "–": "-",
        ]
        value = String(value.map { punctuation[$0] ?? $0 })

        let whitespace = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet.controlCharacters)
        value = value.unicodeScalars
            .filter { !whitespace.contains($0) }
            .map(String.init)
            .joined()
        return value.lowercased()
    }

    static func segments(of quote: String) -> [String] {
        let pattern = #"…+|\.{3,}|⋯+"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(quote.startIndex..., in: quote)
        let parts: [String]
        if let regex {
            parts = regex.stringByReplacingMatches(in: quote, options: [], range: range, withTemplate: "\u{0001}")
                .components(separatedBy: "\u{0001}")
        } else {
            parts = [quote]
        }

        let normalized = parts
            .map(normalize)
            .filter { $0.count >= minimumSegmentLength }
        if !normalized.isEmpty { return normalized }

        let whole = normalize(quote)
        return whole.count >= minimumSegmentLength ? [whole] : []
    }

    static func verified(quote: String, in pageText: String) -> Bool {
        let segments = segments(of: quote)
        guard !segments.isEmpty else { return false }
        let page = normalize(pageText)
        guard !page.isEmpty else { return false }

        var hits = 0
        for segment in segments where page.contains(segment) {
            hits += 1
        }
        guard hits >= 1 else { return false }
        return Double(hits) / Double(segments.count) >= minimumHitRatio
    }
}

struct ReportValidationInput: Sendable {
    var draft: ResearchDraft
    var candidates: [EvidenceCandidate]
    var plannedClaims: [String]
    /// Canonical URL → fetched document. Snippet-only hits are included so a
    /// quote can still be checked against the snippet it came from.
    var documents: [String: ResearchDocument]
    /// Canonical URLs from this run's search results plus the seed URL.
    var allowedURLs: Set<String>
    var searchStatus: BurstSearchStatus
    var pagesRead: Int
    var truncated: Bool
    var depth: ResearchDepth
    var method: ResearchMethod
    var now: Date = Date()
    var language: AppLanguage = L10n.currentLanguage
}

/// Recomputes everything that can be derived deterministically. The model's
/// verdict is never trusted: evidence IDs, quotes, dates, syndication,
/// independence, claim status and the final verdict are all rebuilt here.
enum ReportValidator {
    static func validate(_ input: ReportValidationInput) -> BurstResearch {
        let allowed = Set(input.allowedURLs.map { ContentIdentity.canonicalURL($0) })

        // When extraction produced no candidates, fall back to the inline
        // evidence the synthesis model returned. It goes through the same URL
        // whitelist and verbatim quote check, so an ungrounded URL is dropped.
        var effectiveCandidates = input.candidates
        if effectiveCandidates.isEmpty {
            effectiveCandidates = input.draft.inlineEvidence.compactMap { raw in
                guard let url = raw.url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return EvidenceCandidate(
                    url: url,
                    title: "",
                    quote: raw.quote,
                    claim: raw.claim,
                    stance: raw.stance,
                    publishedAt: raw.publishedAt,
                    fetchedAt: input.now
                )
            }
        }

        let evidence = buildEvidence(
            candidates: effectiveCandidates,
            documents: input.documents,
            allowed: allowed
        )
        let (mergedEvidence, idRemap) = mergeSameURL(evidence)
        let groupedEvidence = assignSyndicationGroups(mergedEvidence, documents: input.documents)
        let independentDomains = independentDomainSet(groupedEvidence)

        var limitations: [String] = []
        if !input.draft.limitations.isEmpty {
            limitations.append(input.draft.limitations)
        }

        let claims = buildClaims(
            draftClaims: input.draft.claims,
            plannedClaims: input.plannedClaims,
            candidates: effectiveCandidates.filter { allowed.contains(ContentIdentity.canonicalURL($0.url)) },
            evidence: groupedEvidence,
            idRemap: idRemap,
            language: input.language
        )

        var timeline = input.draft.timeline.map { node -> TimelineNode in
            let normalizedIDs = EvidenceIdentity.normalizedIDs(node.evidenceIDs)
            var mapped = normalizedIDs.compactMap { id in idRemap[id] ?? id }
            mapped = Array(Set(mapped)).sorted { lhs, rhs in
                evidenceOrder(lhs) < evidenceOrder(rhs)
            }
            mapped = mapped.filter { id in groupedEvidence.contains(where: { $0.id == id }) }

            var sortDate = node.sortDate ?? TimelineDateParser.parse(node.date, now: input.now)?.date
            if let date = sortDate {
                let earliest = TimelineDateParser.defaultCalendar.date(
                    from: DateComponents(year: 1990, month: 1, day: 1)
                ) ?? .distantPast
                let latest = input.now.addingTimeInterval(86_400)
                if date < earliest || date > latest {
                    sortDate = nil
                }
            }

            var confidence = node.confidence
            if mapped.isEmpty {
                // The node stays visible, but no UI may present it as sourced.
                confidence = .low
            } else if sortDate == nil {
                confidence = lowered(confidence)
            }
            if !mapped.isEmpty,
               mapped.contains(where: { id in
                   groupedEvidence.first(where: { $0.id == id })?.quoteVerified == false
               }) {
                confidence = lowered(confidence)
            }

            return TimelineNode(
                date: node.date,
                title: node.title,
                detail: node.detail,
                sortDate: sortDate,
                precision: sortDate == nil ? .unknown : node.precision,
                evidenceIDs: mapped,
                confidence: confidence
            )
        }

        let originalTimelineCount = input.draft.timeline.count
        timeline = mergeTimeline(timeline)
        timeline.sort { lhs, rhs in
            switch (lhs.sortDate, rhs.sortDate) {
            case let (left?, right?): return left < right
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return false
            }
        }

        let citedTimelineCount = timeline.filter { !$0.evidenceIDs.isEmpty }.count
        let unverifiedTimelineCount = timeline.count - citedTimelineCount
        var unresolvedCitationCount = 0
        for node in input.draft.timeline {
            for rawID in Set(EvidenceIdentity.normalizedIDs(node.evidenceIDs)) {
                let mappedID = idRemap[rawID] ?? rawID
                if !groupedEvidence.contains(where: { $0.id == mappedID }) {
                    unresolvedCitationCount += 1
                }
            }
        }
        NSLog(
            "[ReportValidator] timelineDraft=%ld kept=%ld cited=%ld unresolvedIDs=%ld evidence=%ld",
            originalTimelineCount,
            timeline.count,
            citedTimelineCount,
            unresolvedCitationCount,
            groupedEvidence.count
        )

        if input.truncated {
            limitations.append(L10n.string("research.limitation.truncated", language: input.language))
        }

        let notOnline = input.searchStatus != .succeeded || groupedEvidence.isEmpty || input.pagesRead == 0
        if notOnline {
            limitations.append(L10n.string("research.limitation.notOnline", language: input.language))
        }
        if groupedEvidence.isEmpty {
            limitations.append(L10n.string("research.limitation.noEvidence", language: input.language))
        }

        if (originalTimelineCount > 0 || !groupedEvidence.isEmpty) && citedTimelineCount < 3 {
            limitations.append(L10n.string("research.limitation.noTimeline", language: input.language))
        }

        if unverifiedTimelineCount > 0 {
            limitations.append(
                L10n.string(
                    "research.limitation.unverifiedTimeline",
                    language: input.language,
                    unverifiedTimelineCount
                )
            )
        }

        if !groupedEvidence.isEmpty,
           groupedEvidence.allSatisfy({ $0.tier.rawValue >= 3 }) {
            limitations.append(L10n.string("research.limitation.lowTier", language: input.language))
        }

        var verification = computeVerification(
            evidence: groupedEvidence,
            claims: claims,
            independentDomainSet: independentDomains,
            notOnline: notOnline || input.pagesRead == 0
        )
        verification.conflicts = uniqueNonEmpty(input.draft.conflicts)
        verification.missing = uniqueNonEmpty(input.draft.missing)

        var report = BurstResearch(
            summary: input.draft.summary,
            overview: input.draft.overview,
            timeline: timeline,
            sources: unique(groupedEvidence.map(\.url)),
            needsRefetch: false,
            refetchURLs: [],
            searchStatus: input.searchStatus,
            evidence: groupedEvidence,
            verification: verification,
            limitations: uniqueNonEmpty(limitations).joined(separator: "\n"),
            generatedAt: input.now,
            promptVersion: ResearchPrompts.version,
            depth: input.depth,
            method: input.method
        )

        if verification.verdict == .unverified,
           input.draft.summary.isEmpty,
           input.draft.overview.isEmpty,
           citedTimelineCount == 0 {
            report.limitations = uniqueNonEmpty([
                report.limitations,
                L10n.string("research.limitation.insufficient", language: input.language),
            ]).joined(separator: "\n")
        }

        // Reader-facing prose must never expose the pipeline's own vocabulary,
        // even when an older prompt or a provider rewrite produced it.
        let readerFindings = ReaderFacingText.findings(in: report)
        if !readerFindings.isEmpty {
            NSLog(
                "[ReportValidator] hiding %ld reader-facing field(s) with internal vocabulary: %@",
                readerFindings.count,
                readerFindings.map(\.description).joined(separator: "; ")
            )
            report = ReaderFacingText.enforce(report)
        }
        return report
    }

    // MARK: - Evidence

    private static func buildEvidence(
        candidates: [EvidenceCandidate],
        documents: [String: ResearchDocument],
        allowed: Set<String>
    ) -> [EvidenceItem] {
        var items: [EvidenceItem] = []

        for candidate in EvidenceIdentity.ordered(candidates, allowedURLs: allowed) {
            let canonical = ContentIdentity.canonicalURL(candidate.url)
            let document = documents[canonical]
            let info = SourceTierCatalog.info(for: candidate.url)
            let title = [document?.title, candidate.title]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? info.domain
            let quoteVerified = document.map {
                QuoteVerifier.verified(quote: candidate.quote, in: $0.text)
            } ?? false

            items.append(
                EvidenceItem(
                    id: "E\(items.count + 1)",
                    url: candidate.url,
                    canonicalURL: canonical,
                    domain: info.domain,
                    title: title,
                    publishedAt: candidate.publishedAt ?? document?.publishedAt,
                    quote: String(candidate.quote.prefix(300)),
                    quoteVerified: quoteVerified,
                    stance: candidate.stance,
                    tier: info.tier,
                    syndicationGroup: nil,
                    fetchedAt: candidate.fetchedAt
                )
            )
        }
        return items
    }

    /// One evidence row per page: later quotes from the same URL are folded in
    /// and their IDs remapped, so claims and timeline references stay valid.
    private static func mergeSameURL(_ evidence: [EvidenceItem]) -> ([EvidenceItem], [String: String]) {
        var output: [EvidenceItem] = []
        var indexByURL: [String: Int] = [:]
        var remap: [String: String] = [:]

        for item in evidence {
            guard let existingIndex = indexByURL[item.canonicalURL] else {
                indexByURL[item.canonicalURL] = output.count
                remap[item.id] = item.id
                output.append(item)
                continue
            }

            var existing = output[existingIndex]
            remap[item.id] = existing.id
            // A verified quote is more valuable than an unverified one; a clear
            // stance is more valuable than "unclear". Never invent a stance.
            if !existing.quoteVerified, item.quoteVerified {
                existing = EvidenceItem(
                    id: existing.id,
                    url: existing.url,
                    canonicalURL: existing.canonicalURL,
                    domain: existing.domain,
                    title: existing.title,
                    publishedAt: existing.publishedAt ?? item.publishedAt,
                    quote: item.quote,
                    quoteVerified: true,
                    stance: mergedStance(existing.stance, item.stance),
                    tier: existing.tier,
                    syndicationGroup: nil,
                    fetchedAt: existing.fetchedAt
                )
            } else if existing.stance == .unclear, item.stance != .unclear {
                existing = EvidenceItem(
                    id: existing.id,
                    url: existing.url,
                    canonicalURL: existing.canonicalURL,
                    domain: existing.domain,
                    title: existing.title,
                    publishedAt: existing.publishedAt ?? item.publishedAt,
                    quote: existing.quote,
                    quoteVerified: existing.quoteVerified,
                    stance: mergedStance(existing.stance, item.stance),
                    tier: existing.tier,
                    syndicationGroup: nil,
                    fetchedAt: existing.fetchedAt
                )
            }
            output[existingIndex] = existing
        }
        return (output, remap)
    }

    private static func mergedStance(_ lhs: EvidenceStance, _ rhs: EvidenceStance) -> EvidenceStance {
        if lhs == .unclear { return rhs }
        if rhs == .unclear { return lhs }
        if lhs == rhs { return lhs }
        return .unclear
    }

    /// Two differently-domained pages with the same normalized title and ≥0.9
    /// body similarity are treated as one syndicated story. Without both page
    /// bodies the pair is left independent: guessing would undercount sources.
    private static func assignSyndicationGroups(
        _ evidence: [EvidenceItem],
        documents: [String: ResearchDocument]
    ) -> [EvidenceItem] {
        var output = evidence
        var groupByIndex: [Int: String] = [:]
        var nextGroup = 1

        for i in output.indices {
            guard groupByIndex[i] == nil else { continue }
            let leftDoc = documents[output[i].canonicalURL]
            let leftTitle = TopicFingerprint.normalized(output[i].title)
            guard !leftTitle.isEmpty, let leftDoc else { continue }

            for j in output.indices where j > i {
                guard groupByIndex[j] == nil else { continue }
                let right = output[j]
                guard right.domain != output[i].domain else { continue }
                guard TopicFingerprint.normalized(right.title) == leftTitle else { continue }
                guard let rightDoc = documents[right.canonicalURL] else { continue }
                guard textSimilarity(leftDoc.text, rightDoc.text) >= 0.9 else { continue }
                let group = "SYN-\(nextGroup)"
                if groupByIndex[i] == nil {
                    groupByIndex[i] = group
                    nextGroup += 1
                }
                groupByIndex[j] = groupByIndex[i]
            }
        }

        for index in groupByIndex.keys {
            let item = output[index]
            output[index] = EvidenceItem(
                id: item.id,
                url: item.url,
                canonicalURL: item.canonicalURL,
                domain: item.domain,
                title: item.title,
                publishedAt: item.publishedAt,
                quote: item.quote,
                quoteVerified: item.quoteVerified,
                stance: item.stance,
                tier: item.tier,
                syndicationGroup: groupByIndex[index],
                fetchedAt: item.fetchedAt
            )
        }
        return output
    }

    private static func textSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = trigrams(String(lhs.prefix(3_000)))
        let right = trigrams(String(rhs.prefix(3_000)))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let intersection = left.intersection(right).count
        let union = left.union(right).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    private static func trigrams(_ text: String) -> Set<String> {
        let normalized = QuoteVerifier.normalize(text)
        let characters = Array(normalized)
        guard characters.count >= 3 else {
            return characters.isEmpty ? [] : [String(characters)]
        }
        var output: Set<String> = []
        for index in 0..<(characters.count - 2) {
            output.insert(String(characters[index...index + 2]))
        }
        return output
    }

    private static func independentDomainSet(_ evidence: [EvidenceItem]) -> Set<String> {
        var representatives: [String: String] = [:]
        var ungrouped: Set<String> = []
        for item in evidence {
            let domain = item.domain.isEmpty ? item.canonicalURL : item.domain
            if let group = item.syndicationGroup {
                if representatives[group] == nil { representatives[group] = domain }
            } else {
                ungrouped.insert(domain)
            }
        }
        return ungrouped.union(representatives.values)
    }

    // MARK: - Claims

    private static func buildClaims(
        draftClaims: [ClaimCheck],
        plannedClaims: [String],
        candidates: [EvidenceCandidate],
        evidence: [EvidenceItem],
        idRemap: [String: String],
        language: AppLanguage
    ) -> [ClaimCheck] {
        // A claim without evidence is not a conclusion. Keeping planned claims
        // here is what produced "5 claims · 0 evidence" reports; the UI must
        // show an evidence gap instead of a fake checklist.
        guard !evidence.isEmpty else { return [] }

        var claims: [ClaimCheck]

        if !draftClaims.isEmpty {
            claims = draftClaims
        } else {
            let planned = plannedClaims
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let source = planned.isEmpty
                ? candidates.map(\.claim).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                : planned
            claims = unique(source.filter { !$0.isEmpty }).prefix(5).map {
                ClaimCheck(claim: $0, status: nil, evidenceIDs: [], note: "")
            }
        }

        return claims.map { claim in
            let normalizedIDs = EvidenceIdentity.normalizedIDs(claim.evidenceIDs)
            var ids = normalizedIDs.compactMap { id in idRemap[id] ?? id }
            ids = unique(ids).filter { id in evidence.contains(where: { $0.id == id }) }

            // Only the evidence cited by *this* claim counts, and only quotes
            // that were found verbatim in the fetched page. A claim backed only
            // by tier-3/4 sources can no longer borrow another claim's tier-1
            // domain, and a hallucinated quote cannot support anything.
            let claimEvidence = evidence.filter { ids.contains($0.id) && $0.quoteVerified }
            let supportDomains = independentDomains(for: claimEvidence, stance: .supports)
            let refuteDomains = independentDomains(for: claimEvidence, stance: .refutes)
            let tier12Support = tier12Domains(claimEvidence, stance: .supports)
            let tier12Refute = tier12Domains(claimEvidence, stance: .refutes)

            let status: EvidenceStance?
            if ids.isEmpty || claimEvidence.isEmpty {
                status = nil
            } else if tier12Refute.count >= 2, tier12Support.isEmpty, supportDomains.isEmpty {
                status = .refutes
            } else if tier12Support.count >= 1, tier12Refute.isEmpty, supportDomains.count >= 2 {
                status = .supports
            } else if !supportDomains.isEmpty, !refuteDomains.isEmpty {
                status = .unclear
            } else if supportDomains.isEmpty, refuteDomains.isEmpty {
                status = nil
            } else {
                status = .unclear
            }

            var note = claim.note
            if let aiStatus = claim.status, let status, aiStatus != status, note.isEmpty {
                note = L10n.string("research.limitation.claimAdjusted", language: language)
            }

            return ClaimCheck(claim: claim.claim, status: status, evidenceIDs: ids, note: note)
        }
    }

    private static func independentDomains(
        for evidence: [EvidenceItem],
        stance: EvidenceStance
    ) -> Set<String> {
        var output: Set<String> = []
        var groupsSeen: Set<String> = []
        for item in evidence where item.stance == stance {
            if let group = item.syndicationGroup {
                guard !groupsSeen.contains(group) else { continue }
                groupsSeen.insert(group)
            }
            output.insert(item.domain.isEmpty ? item.canonicalURL : item.domain)
        }
        return output
    }

    private static func tier12Domains(
        _ evidence: [EvidenceItem],
        stance: EvidenceStance
    ) -> Set<String> {
        var output: Set<String> = []
        var groupsSeen: Set<String> = []
        for item in evidence where item.stance == stance && item.tier.rawValue <= 2 {
            if let group = item.syndicationGroup {
                guard !groupsSeen.contains(group) else { continue }
                groupsSeen.insert(group)
            }
            output.insert(item.domain.isEmpty ? item.canonicalURL : item.domain)
        }
        return output
    }

    // MARK: - Verification

    private static func computeVerification(
        evidence: [EvidenceItem],
        claims: [ClaimCheck],
        independentDomainSet: Set<String>,
        notOnline: Bool
    ) -> VerificationReport {
        var verification = VerificationReport()
        verification.claims = claims
        verification.independentSources = independentDomainSet.count

        // Only verified evidence actually cited by a claim may shape the
        // verdict; uncited tier-1 pages must not upgrade an unrelated claim.
        let citedIDs = Set(claims.flatMap(\.evidenceIDs))
        let citedEvidence = evidence.filter { citedIDs.contains($0.id) && $0.quoteVerified }

        let supportDomains = independentDomains(for: citedEvidence, stance: .supports)
        let refuteDomains = independentDomains(for: citedEvidence, stance: .refutes)
        let tier12Support = tier12Domains(citedEvidence, stance: .supports)
        let tier12Refute = tier12Domains(citedEvidence, stance: .refutes)
        let otherSupport = supportDomains.subtracting(tier12Support)

        let keyClaims = claims
        let allSupported = !keyClaims.isEmpty && keyClaims.allSatisfy { $0.status == .supports }
        let allRefuted = !keyClaims.isEmpty && keyClaims.allSatisfy { $0.status == .refutes }

        if notOnline || evidence.isEmpty {
            verification.verdict = .unverified
        } else if allSupported, tier12Support.count >= 2, tier12Refute.isEmpty {
            verification.verdict = .confirmed
        } else if allSupported,
                  tier12Support.count >= 1,
                  !otherSupport.isEmpty,
                  tier12Refute.isEmpty {
            verification.verdict = .mostlyConfirmed
        } else if !tier12Support.isEmpty, !tier12Refute.isEmpty {
            verification.verdict = .mixed
        } else if tier12Refute.count >= 2,
                  tier12Support.isEmpty,
                  allRefuted || keyClaims.isEmpty {
            verification.verdict = .refuted
        } else {
            verification.verdict = .unverified
        }

        let tier12Independent = independentDomainSet.filter { domain in
            citedEvidence.contains { item in
                (item.domain.isEmpty ? item.canonicalURL : item.domain) == domain
                    && item.tier.rawValue <= 2
            }
        }.count
        let hasPrimary = citedEvidence.contains { $0.tier == .primary }

        switch verification.verdict {
        case .confirmed, .mostlyConfirmed:
            // Strength 4 requires a primary source plus at least three
            // independent tier-1/2 domains; three tier-2 outlets alone cap at 3.
            if hasPrimary, tier12Independent >= 3 { verification.strength = 4 }
            else if tier12Independent >= 2 { verification.strength = 3 }
            else if tier12Independent >= 1 { verification.strength = 2 }
            else { verification.strength = 1 }
        case .mixed, .refuted:
            verification.strength = tier12Independent >= 2 ? 2 : (tier12Independent >= 1 ? 1 : 0)
        case .unverified:
            // Offline or unsupported runs never claim more than "unverified".
            verification.strength = 0
        }
        return verification
    }

    // MARK: - Timeline helpers

    private static func mergeTimeline(_ nodes: [TimelineNode]) -> [TimelineNode] {
        var output: [TimelineNode] = []
        var indexByKey: [String: Int] = [:]
        for node in nodes {
            let title = TopicFingerprint.normalized(node.title)
            let key = (node.sortDate.map { TimelineDateParser.dayKey($0) } ?? "undated") + "\n" + title
            guard let index = indexByKey[key] else {
                indexByKey[key] = output.count
                output.append(node)
                continue
            }

            let existing = output[index]
            if existing.evidenceIDs.isEmpty, !node.evidenceIDs.isEmpty {
                // A duplicate without evidence must never hide the sourced one.
                output[index] = node
            } else if !existing.evidenceIDs.isEmpty, !node.evidenceIDs.isEmpty {
                let mergedIDs = Array(Set(existing.evidenceIDs + node.evidenceIDs)).sorted {
                    evidenceOrder($0) < evidenceOrder($1)
                }
                output[index] = TimelineNode(
                    date: existing.date,
                    title: existing.title,
                    detail: existing.detail,
                    sortDate: existing.sortDate ?? node.sortDate,
                    precision: existing.sortDate == nil ? node.precision : existing.precision,
                    evidenceIDs: mergedIDs,
                    confidence: higherConfidence(existing.confidence, node.confidence)
                )
            }
        }
        return output
    }

    private static func higherConfidence(_ lhs: Confidence, _ rhs: Confidence) -> Confidence {
        func rank(_ value: Confidence) -> Int {
            switch value {
            case .high: return 3
            case .medium: return 2
            case .low: return 1
            }
        }
        return rank(lhs) >= rank(rhs) ? lhs : rhs
    }

    private static func evidenceOrder(_ id: String) -> Int {
        guard id.hasPrefix("E"), let number = Int(id.dropFirst()) else { return Int.max }
        return number
    }

    private static func lowered(_ confidence: Confidence) -> Confidence {
        switch confidence {
        case .high: return .medium
        case .medium: return .low
        case .low: return .low
        }
    }

    // MARK: - Generic

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        unique(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }
}
