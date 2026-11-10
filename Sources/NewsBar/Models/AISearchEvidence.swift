import Foundation

/// Where a source came from. The current page is never external corroboration;
/// the UI must keep the two apart even when both appear in one answer.
enum EvidenceOrigin: String, Codable, Sendable, Equatable {
    case currentPage
    case web
}

/// What kind of page this is, as judged by the assessor (never by the model
/// alone): an original document, reporting about one, or a reprint.
enum SourceType: String, Codable, Sendable, Equatable, CaseIterable {
    case primary
    case secondary
    case aggregator
    case unknown
}

enum SourceIndependence: String, Codable, Sendable, Equatable {
    case independent
    case duplicate
    case unknown
}

/// How the answer is allowed to use a source.
enum SourceAdoption: String, Codable, Sendable, Equatable {
    case primary
    case supporting
    case rejected
}

enum SupportLevel: String, Codable, Sendable, Equatable {
    case direct
    case partial
}

/// A quotation the app verified against the fetched text. The model proposes
/// it; `EvidenceAssessor` drops it unless the quote really exists in the page.
struct VerifiedClaim: Equatable, Sendable {
    let text: String
    let quote: String
    let support: SupportLevel
}

/// Machine-readable reasons. The UI localizes known codes and only falls back
/// to `detail` for a reason it does not know.
enum SourceReason: String, Codable, Sendable, Equatable, CaseIterable {
    case duplicate
    case quoteNotVerifiable
    case aggregator
    case singleSource
    case conflict
    case modelRejected
    case noMaterial
    case heuristic
    case assessed
}

struct SourceAssessment: Equatable, Sendable {
    let type: SourceType
    let independence: SourceIndependence
    let adoption: SourceAdoption
    let reason: SourceReason
    /// Optional assessor note, shown only as a tooltip detail.
    let detail: String?
    let claims: [VerifiedClaim]

    init(
        type: SourceType = .unknown,
        independence: SourceIndependence = .unknown,
        adoption: SourceAdoption,
        reason: SourceReason,
        detail: String? = nil,
        claims: [VerifiedClaim] = []
    ) {
        self.type = type
        self.independence = independence
        self.adoption = adoption
        self.reason = reason
        self.detail = detail
        self.claims = claims
    }
}

struct EvidenceConflict: Equatable, Sendable {
    let claim: String
    let indices: [Int]
    let note: String
}

/// What the answer as a whole is allowed to claim. Computed by the app from
/// adopted sources and verified citations, never by the model.
enum AnswerBasis: String, Codable, Sendable, Equatable {
    /// At least one primary source, or two independent supporting sources,
    /// with a verified citation.
    case externalSupported
    /// External sources exist but are single, secondary, undated, or
    /// unassessed. The answer may use them, but cannot claim verification.
    case externalLimited
    /// The reader's current page is the only material.
    case currentPageOnly
    /// The answer has adopted sources but none of its citation numbers passed
    /// validation. The prose is kept and clearly marked unverified.
    case noVerifiedCitations
    /// Nothing readable was available.
    case insufficientMaterial
}

enum RetrievalNote: String, Codable, Sendable, Equatable, CaseIterable {
    case searchUnavailable
    case noResults
    case noSourcesReadable
    case partialProviders
    case assessmentSkipped
    case assessmentFailed
    case conflictingSources
    case partialCitations
    /// Page overview only: external sources were adopted but the summary never
    /// cited one of them.
    case externalNotCited

    func message(_ language: AppLanguage) -> String {
        L10n.string("answer.note.\(rawValue)", language: language)
    }
}

/// Counts the app can verify without trusting the model. Kept separate from
/// `AnswerEvidence` so the existing selection/offline canvas is untouched.
struct RetrievalEvidence: Equatable, Sendable, Codable {
    var foundCount: Int = 0
    var readCount: Int = 0
    var adoptedCount: Int = 0
    var rejectedCount: Int = 0
    var invalidCitationCount: Int = 0
    var uncitedFactualSentences: Int = 0
    var queryCount: Int = 0
    var httpAttempts: Int = 0
    var basis: AnswerBasis = .insufficientMaterial
    var notes: [RetrievalNote] = []

    static let empty = RetrievalEvidence()

    mutating func add(_ note: RetrievalNote) {
        guard !notes.contains(note) else { return }
        notes.append(note)
    }
}

struct AssessmentResult: Equatable, Sendable {
    var sources: [AISearchSource]
    var conflicts: [EvidenceConflict]
    var notes: [RetrievalNote]

    static func rejected(_ sources: [AISearchSource], note: RetrievalNote?) -> AssessmentResult {
        AssessmentResult(sources: sources, conflicts: [], notes: note.map { [$0] } ?? [])
    }
}
