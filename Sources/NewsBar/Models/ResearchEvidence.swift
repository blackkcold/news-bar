import Foundation

/// Confidence attached to a timeline node, claim or evidence item. The
/// verifier lowers this deterministically; the AI only proposes it.
enum Confidence: String, Codable, Sendable, CaseIterable {
    case high, medium, low
}

enum DatePrecision: String, Codable, Sendable {
    case day, month, relative, unknown
}

enum EvidenceStance: String, Codable, Sendable {
    case supports, refutes, unclear
}

/// Tier 1 is a first-party or wire-service source; tier 4 is social/self-media.
enum SourceTier: Int, Codable, Sendable, CaseIterable {
    case primary = 1
    case major = 2
    case industry = 3
    case social = 4
}

struct EvidenceItem: Codable, Hashable, Sendable, Identifiable {
    /// Stable within one report: E1…En.
    let id: String
    let url: String
    let canonicalURL: String
    /// Registrable domain (eTLD+1).
    let domain: String
    let title: String
    let publishedAt: Date?
    /// Short excerpt (≤300 characters) used for deterministic quote checks.
    let quote: String
    let quoteVerified: Bool
    let stance: EvidenceStance
    let tier: SourceTier
    /// Merge key for syndicated copies of the same article.
    let syndicationGroup: String?
    let fetchedAt: Date
}

extension EvidenceItem {
    enum CodingKeys: String, CodingKey {
        case id, url, canonicalURL, domain, title, publishedAt, quote
        case quoteVerified, stance, tier, syndicationGroup, fetchedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Identity and link are authoritative: without them the evidence
        // cannot be attributed, so the record is not silently invented.
        id = try container.decode(String.self, forKey: .id)
        url = try container.decode(String.self, forKey: .url)
        let rawCanonical = try container.decodeIfPresent(String.self, forKey: .canonicalURL)
        canonicalURL = rawCanonical?.isEmpty == false
            ? rawCanonical!
            : ContentIdentity.canonicalURL(url)
        let rawDomain = try container.decodeIfPresent(String.self, forKey: .domain)
        if let rawDomain, !rawDomain.isEmpty {
            domain = rawDomain
        } else if let host = URL(string: url)?.host, !host.isEmpty {
            domain = SourceTierCatalog.registrableDomain(host)
        } else {
            domain = ""
        }
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
        quote = try container.decodeIfPresent(String.self, forKey: .quote) ?? ""
        // Missing verification flags are never upgraded to "verified".
        quoteVerified = try container.decodeIfPresent(Bool.self, forKey: .quoteVerified) ?? false
        stance = try container.decodeIfPresent(EvidenceStance.self, forKey: .stance) ?? .unclear
        // A missing tier is derived from the URL with the bundled catalog and
        // never defaults to `primary`. A present value is kept so a legitimate
        // catalog result survives a round trip; the report validator still
        // recomputes tiers when it builds a report.
        tier = try container.decodeIfPresent(SourceTier.self, forKey: .tier)
            ?? SourceTierCatalog.info(for: url).tier
        syndicationGroup = try container.decodeIfPresent(String.self, forKey: .syndicationGroup)
        fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? .distantPast
    }
}

struct VerificationReport: Codable, Hashable, Sendable {
    enum Verdict: String, Codable, Sendable, CaseIterable {
        case confirmed, mostlyConfirmed, mixed, unverified, refuted
    }

    var verdict: Verdict = .unverified
    /// 0…4. Primary information in the UI; `verdict` is a secondary label.
    var strength: Int = 0
    /// Independent registrable domains after syndication is collapsed.
    var independentSources: Int = 0
    var claims: [ClaimCheck] = []
    var conflicts: [String] = []
    var missing: [String] = []
}

extension VerificationReport {
    enum CodingKeys: String, CodingKey {
        case verdict, strength, independentSources, claims, conflicts, missing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        verdict = try container.decodeIfPresent(Verdict.self, forKey: .verdict) ?? .unverified
        strength = max(0, min(4, try container.decodeIfPresent(Int.self, forKey: .strength) ?? 0))
        independentSources = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .independentSources) ?? 0
        )
        claims = try container.decodeIfPresent([ClaimCheck].self, forKey: .claims) ?? []
        conflicts = try container.decodeIfPresent([String].self, forKey: .conflicts) ?? []
        missing = try container.decodeIfPresent([String].self, forKey: .missing) ?? []
    }
}

struct ClaimCheck: Codable, Hashable, Sendable, Identifiable {
    var id: String { claim }
    let claim: String
    /// `nil` means the claim could not be checked.
    var status: EvidenceStance?
    var evidenceIDs: [String]
    var note: String
}

extension ClaimCheck {
    enum CodingKeys: String, CodingKey {
        case claim, status, evidenceIDs, note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        claim = try container.decode(String.self, forKey: .claim)
        status = try container.decodeIfPresent(EvidenceStance.self, forKey: .status)
        evidenceIDs = try container.decodeIfPresent([String].self, forKey: .evidenceIDs) ?? []
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

/// How a report was produced, shown in the report's method section.
struct ResearchMethod: Codable, Hashable, Sendable {
    var providers: [String]
    var queries: [String]
    var pagesRead: Int
    var recency: String
    var generatedAt: Date
    var promptVersion: Int
    var failovers: Int
}

extension ResearchMethod {
    enum CodingKeys: String, CodingKey {
        case providers, queries, pagesRead, recency, generatedAt, promptVersion, failovers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = try container.decodeIfPresent([String].self, forKey: .providers) ?? []
        queries = try container.decodeIfPresent([String].self, forKey: .queries) ?? []
        pagesRead = try container.decodeIfPresent(Int.self, forKey: .pagesRead) ?? 0
        recency = try container.decodeIfPresent(String.self, forKey: .recency) ?? ""
        generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt) ?? .distantPast
        promptVersion = try container.decodeIfPresent(Int.self, forKey: .promptVersion) ?? 0
        failovers = try container.decodeIfPresent(Int.self, forKey: .failovers) ?? 0
    }
}
