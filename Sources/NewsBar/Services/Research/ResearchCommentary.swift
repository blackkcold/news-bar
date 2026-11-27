import Foundation

/// When a position was taken: before this event (a precedent) or about it.
enum CommentaryEra: String, Codable, Sendable, CaseIterable {
    case past
    case present
}

/// Where a position comes from. Paired with `CommentaryEra` this gives the four
/// cells 古今中外 — not a marketing grid, but four genuinely different sources of
/// opinion that a report on one country's event would otherwise miss.
enum CommentaryOrigin: String, Codable, Sendable, CaseIterable {
    case domestic
    case foreign
}

/// One checked position on the event: who said it, where, and whether the words
/// are theirs or a paraphrase.
///
/// Commentary is deliberately parallel to `evidence` rather than part of it:
/// evidence answers "what happened" and feeds the verdict, commentary answers
/// "what do people think" and must never move the verdict. It is also not part
/// of the `E` numbering — the two lists are cited differently and the reader
/// should be able to tell them apart on sight.
struct CommentaryItem: Codable, Hashable, Sendable, Identifiable {
    /// C1…Cn, contiguous after validation. Separate from E1…En.
    let id: String
    let era: CommentaryEra
    let origin: CommentaryOrigin
    /// The person's name, as it appears in the source. Gate 1 requires this to
    /// be findable in the cited page; a name the source never mentions is not an
    /// attribution.
    let speaker: String
    /// Title or affiliation, when the source states one.
    let role: String?
    let quote: String
    /// True only when the words appear verbatim in the cited page.
    let quoteVerified: Bool
    let url: String
    let domain: String
    let publishedAt: Date?
    /// The fact this opinion is about, when the model tied it to one.
    let evidenceID: String?
    /// True when the words are the model's summary of the position rather than
    /// the speaker's own. The UI must say so; showing an approximation in quote
    /// marks is the one failure this whole file exists to prevent.
    let isParaphrase: Bool

    init(
        id: String,
        era: CommentaryEra,
        origin: CommentaryOrigin,
        speaker: String,
        role: String?,
        quote: String,
        quoteVerified: Bool,
        url: String,
        domain: String,
        publishedAt: Date?,
        evidenceID: String?,
        isParaphrase: Bool
    ) {
        self.id = id
        self.era = era
        self.origin = origin
        self.speaker = speaker
        self.role = role
        self.quote = quote
        self.quoteVerified = quoteVerified
        self.url = url
        self.domain = domain
        self.publishedAt = publishedAt
        self.evidenceID = evidenceID
        self.isParaphrase = isParaphrase
    }
}

extension CommentaryItem {
    enum CodingKeys: String, CodingKey {
        case id, era, origin, speaker, role, quote, quoteVerified
        case url, domain, publishedAt, evidenceID, isParaphrase
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Identity without an author is meaningless; a corrupt row must not
        // silently become an anonymous quote.
        id = try container.decode(String.self, forKey: .id)
        speaker = try container.decode(String.self, forKey: .speaker)
        quote = try container.decode(String.self, forKey: .quote)
        era = try container.decodeIfPresent(CommentaryEra.self, forKey: .era) ?? .present
        origin = try container.decodeIfPresent(CommentaryOrigin.self, forKey: .origin) ?? .domestic
        role = try container.decodeIfPresent(String.self, forKey: .role)
        quoteVerified = try container.decodeIfPresent(Bool.self, forKey: .quoteVerified) ?? false
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        domain = try container.decodeIfPresent(String.self, forKey: .domain) ?? ""
        publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
        evidenceID = try container.decodeIfPresent(String.self, forKey: .evidenceID)
        isParaphrase = try container.decodeIfPresent(Bool.self, forKey: .isParaphrase) ?? false
    }
}

/// What the synthesis call returns, before any gate runs. Everything here is a
/// claim, not a fact: no field is trusted until `ResearchCommentaryValidator`
/// has checked it against the page.
struct CommentaryCandidate: Sendable, Equatable {
    var era: CommentaryEra
    var origin: CommentaryOrigin
    var speaker: String
    var role: String?
    var quote: String
    var url: String
    var publishedAt: Date?
    var evidenceID: String?
}

/// The only thing standing between a report and fabricated commentary.
///
/// Three gates, all deterministic — the model never declares its own quote as
/// verified:
///
/// 1. **The speaker must be findable in the page.** A name the source does not
///    mention is not an attribution, so the item is dropped.
/// 2. **The page must be reachable and must have been read this pass.** The same
///    policy the reader applies to links, plus a lookup in the documents this
///    run actually fetched: a plausible URL that was never opened cannot vouch
///    for anything.
/// 3. **The words must be verbatim.** Reuses `QuoteVerifier`, the same check
///    behind `EvidenceItem.quoteVerified`. Failing this does not drop the item —
///    the position may still be real — it downgrades it to `isParaphrase` so the
///    UI never presents an approximation in quote marks.
///
/// At most one item per quadrant, and the resulting order is fixed, so a report
/// reads the same way every run. Ids are renumbered after filtering, so the
/// reader never sees C1, C3.
enum ResearchCommentaryValidator {
    /// Reader-facing order: 古中、古外、今中、今外.
    static let quadrantOrder: [(CommentaryEra, CommentaryOrigin)] = [
        (.past, .domestic),
        (.past, .foreign),
        (.present, .domestic),
        (.present, .foreign),
    ]

    static func accepted(
        _ candidates: [CommentaryCandidate],
        documents: [String: ResearchDocument],
        language: AppLanguage
    ) -> [CommentaryItem] {
        // One slot per quadrant. Candidates arrive in the model's order, so the
        // first one that passes the gates wins its cell.
        var byQuadrant: [Quadrant: CommentaryItem] = [:]

        for candidate in candidates {
            let quadrant = Quadrant(era: candidate.era, origin: candidate.origin)
            guard byQuadrant[quadrant] == nil else { continue }

            // Gate 2a — the link must be one a reader could follow.
            guard let url = ReaderNavigationPolicy.allowedURL(candidate.url) else { continue }
            let canonical = ContentIdentity.canonicalURL(candidate.url)
            // Gate 2b — the page must have been read in this pass.
            guard let document = documents[canonical] else { continue }

            // Gate 1 — the attribution must exist in the source.
            let speaker = candidate.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !speaker.isEmpty, mentions(speaker, in: document.text) else { continue }

            let quote = candidate.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !quote.isEmpty else { continue }

            // Gate 3 — verbatim, or an honest paraphrase.
            let verbatim = QuoteVerifier.verified(quote: quote, in: document.text)
            let info = SourceTierCatalog.info(for: candidate.url)
            byQuadrant[quadrant] = CommentaryItem(
                id: "", // assigned below, after filtering
                era: candidate.era,
                origin: candidate.origin,
                speaker: speaker,
                role: candidate.role?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty,
                quote: String(quote.prefix(300)),
                quoteVerified: verbatim,
                url: url.absoluteString,
                domain: info.domain,
                publishedAt: candidate.publishedAt ?? document.publishedAt,
                evidenceID: candidate.evidenceID?.nilIfEmpty,
                isParaphrase: !verbatim
            )
        }

        return quadrantOrder.compactMap { era, origin in
            byQuadrant[Quadrant(era: era, origin: origin)]
        }.enumerated().map { index, item in
            CommentaryItem(
                id: "C\(index + 1)",
                era: item.era,
                origin: item.origin,
                speaker: item.speaker,
                role: item.role,
                quote: item.quote,
                quoteVerified: item.quoteVerified,
                url: item.url,
                domain: item.domain,
                publishedAt: item.publishedAt,
                evidenceID: item.evidenceID,
                isParaphrase: item.isParaphrase
            )
        }
    }

    private struct Quadrant: Hashable {
        let era: CommentaryEra
        let origin: CommentaryOrigin
    }

    /// Whitespace-insensitive containment. Names contain spaces in English and
    /// never in Chinese, so the page and the name are compared with whitespace
    /// removed on both sides — the same normalization the quote verifier uses.
    static func mentions(_ speaker: String, in page: String) -> Bool {
        let needle = QuoteVerifier.normalize(speaker)
        guard needle.count >= 2 else { return false }
        return QuoteVerifier.normalize(page).contains(needle)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
