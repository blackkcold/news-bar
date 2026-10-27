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

struct ClaimCheck: Codable, Hashable, Sendable, Identifiable {
    var id: String { claim }
    let claim: String
    /// `nil` means the claim could not be checked.
    var status: EvidenceStance?
    var evidenceIDs: [String]
    var note: String
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
