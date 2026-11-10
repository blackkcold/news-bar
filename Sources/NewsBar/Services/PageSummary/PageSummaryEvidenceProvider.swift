import Foundation

enum PageSummaryEvidenceStage: Equatable, Sendable {
    case searching
    case reading(index: Int, total: Int)
    case assessing
}

struct PageSummaryEvidenceResult: Equatable, Sendable {
    var evidence: PageSummaryEvidence
    var searchAttempted: Bool

    static func pageOnly(
        basis: PageSummaryBasis,
        notes: [RetrievalNote] = [],
        retrieval: PageSummaryRetrieval? = nil,
        searchAttempted: Bool
    ) -> PageSummaryEvidenceResult {
        var counts = retrieval ?? PageSummaryRetrieval()
        for note in notes { counts.add(note) }
        return PageSummaryEvidenceResult(
            evidence: PageSummaryEvidence(
                sources: [],
                conflicts: [],
                basis: basis,
                retrieval: counts,
                searchAttempted: searchAttempted
            ),
            searchAttempted: searchAttempted
        )
    }
}

/// Collects the optional external evidence for one page overview. The provider
/// is injected end-to-end (search/read/assess), so private reading and every
/// degradation path can be tested without a network or an API key.
struct PageSummaryEvidenceProvider: Sendable {
    typealias SearchHandler = @Sendable (
        _ query: SearchQuery,
        _ ticket: SearchAttemptTicket
    ) async throws -> [SearchHit]
    typealias ReadHandler = @Sendable (SearchHit) async throws -> PageReadOutcome
    typealias AssessHandler = @Sendable (
        _ question: String,
        _ pageTitle: String?,
        _ sources: [AISearchSource]
    ) async -> AssessmentResult

    var search: SearchHandler
    var read: ReadHandler
    var assess: AssessHandler?
    var ticketLimit: Int = 4
    var candidateCap: Int = 5
    var readLimit: Int = 3

    func collect(
        title: String,
        excerpt: String,
        currentPageURL: String,
        language: AppLanguage,
        onStage: @Sendable (PageSummaryEvidenceStage) async -> Void = { _ in }
    ) async -> PageSummaryEvidenceResult {
        let plan = QueryPlanner.planOverview(
            title: title,
            excerpt: excerpt,
            language: language
        )
        guard !plan.queries.isEmpty else {
            return .pageOnly(basis: .pageOnly, searchAttempted: false)
        }

        await onStage(.searching)
        let ticket = SearchAttemptTicket(limit: ticketLimit)
        let retrieval = await EvidenceRetriever.retrieve(
            plan: plan,
            search: search,
            ticket: ticket,
            candidateCap: candidateCap,
            language: language
        )
        var counts = PageSummaryRetrieval(
            foundCount: retrieval.foundCount,
            queryCount: plan.queries.count,
            httpAttempts: retrieval.attemptsUsed
        )

        if retrieval.searchUnavailable {
            return .pageOnly(
                basis: .searchUnavailable,
                notes: [.searchUnavailable],
                retrieval: counts,
                searchAttempted: true
            )
        }

        // The current page is source 1. A search hit that points back at it must
        // not be counted as independent external corroboration.
        let currentCanonical = ContentIdentity.canonicalURL(currentPageURL)
        let candidates = retrieval.candidates.filter {
            $0.hit.canonicalURL != currentCanonical
        }
        guard !candidates.isEmpty else {
            return .pageOnly(
                basis: .pageOnly,
                notes: [.noResults],
                retrieval: counts,
                searchAttempted: true
            )
        }

        let readResult: ReadResult
        do {
            readResult = try await EvidenceReader.read(
                candidates: candidates,
                read: read,
                readLimit: readLimit
            ) { index, total in
                await onStage(.reading(index: index, total: total))
            }
        } catch is CancellationError {
            return .pageOnly(
                basis: .pageOnly,
                retrieval: counts,
                searchAttempted: true
            )
        } catch {
            return .pageOnly(
                basis: .pageOnly,
                notes: [.noSourcesReadable],
                retrieval: counts,
                searchAttempted: true
            )
        }
        counts.readCount = readResult.readCount
        guard !readResult.sources.isEmpty else {
            return .pageOnly(
                basis: .pageOnly,
                notes: [.noSourcesReadable],
                retrieval: counts,
                searchAttempted: true
            )
        }

        // Assessment must run while indices are 1...n: the assessor matches its
        // payload by source.index and drops anything outside that range.
        let question = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(excerpt.prefix(120))
            : title
        let assessment: AssessmentResult
        if let assess {
            await onStage(.assessing)
            assessment = await assess(question, title, readResult.sources)
        } else {
            assessment = EvidenceAssessor.heuristic(
                question: question,
                sources: readResult.sources
            )
        }

        counts.adoptedCount = assessment.sources.filter {
            $0.assessment?.adoption != .rejected
        }.count
        counts.rejectedCount = assessment.sources.count - counts.adoptedCount
        for note in assessment.notes { counts.add(note) }

        // Renumber only after assessment: source 1 is the current page, so the
        // first external source becomes 2.
        let remapped = assessment.sources.enumerated().map { offset, source in
            AISearchSource(
                index: offset + 2,
                url: source.url,
                title: source.title,
                text: source.text,
                publishedAt: source.publishedAt,
                fetchedAt: source.fetchedAt,
                origin: .web,
                provider: source.provider,
                assessment: source.assessment,
                duplicateOf: source.duplicateOf
            )
        }
        let conflicts = assessment.conflicts.map { conflict in
            EvidenceConflict(
                claim: conflict.claim,
                indices: conflict.indices.map { $0 + 1 },
                note: conflict.note
            )
        }
        guard counts.adoptedCount > 0 else {
            return PageSummaryEvidenceResult(
                evidence: PageSummaryEvidence(
                    sources: remapped,
                    conflicts: conflicts,
                    basis: .pageOnly,
                    retrieval: counts,
                    searchAttempted: true
                ),
                searchAttempted: true
            )
        }
        let adopted = assessment.sources.filter {
            $0.assessment?.adoption != .rejected
        }
        let basis: PageSummaryBasis
        if adopted.contains(where: { $0.assessment?.adoption == .primary }) {
            basis = .externalSupported
        } else {
            let independent = adopted.filter {
                $0.assessment?.independence == .independent
            }.count
            basis = independent >= 2 ? .externalSupported : .externalLimited
        }

        return PageSummaryEvidenceResult(
            evidence: PageSummaryEvidence(
                sources: remapped,
                conflicts: conflicts,
                basis: basis,
                retrieval: counts,
                searchAttempted: true
            ),
            searchAttempted: true
        )
    }
}

@MainActor
enum PageSummaryEvidenceFactory {
    static func make(
        settings: AppSettings,
        configuration: ValidatedAIConfiguration
    ) async -> PageSummaryEvidenceProvider {
        let providerIDs = Set(
            settings.researchSearchProviders.compactMap(SearchProviderID.init(rawValue:))
        )
        let searchKeys = await SearchKeyStore.loadAll()
        let searchConfiguration = SearchRouterConfiguration(
            enabled: providerIDs,
            keys: searchKeys
        )
        let router = SearchRouter(quota: .shared)
        let firecrawlKey = searchKeys[.firecrawl] ?? ""
        let pageReader = PageReader(isScrapeEnabled: !firecrawlKey.isEmpty)
        let language = settings.appLanguage

        let assess: PageSummaryEvidenceProvider.AssessHandler?
        if settings.aiEvidenceAssessmentEnabled {
            let price = configuration.connection.customPrice
                ?? AIPriceCatalog.price(for: configuration.providerID, model: configuration.model)
            let client = HTTPAIChatClient(
                connection: configuration.connection,
                apiKey: configuration.apiKey,
                model: configuration.model,
                thinking: nil,
                timeout: 45,
                quota: .tracked(
                    origin: .pageSummary,
                    policy: settings.aiQuotaPolicy,
                    price: price
                )
            )
            assess = { question, pageTitle, sources in
                await EvidenceAssessor.assess(
                    question: question,
                    pageTitle: pageTitle,
                    sources: sources,
                    client: client,
                    language: language
                )
            }
        } else {
            assess = nil
        }

        return PageSummaryEvidenceProvider(
            search: { query, ticket in
                let batch = try await router.search(
                    query,
                    configuration: searchConfiguration,
                    maxAttempts: EvidenceRetriever.maxAttemptsPerQuery,
                    maxProviderAttempts: EvidenceRetriever.maxProviderAttemptsPerQuery,
                    useCache: false,
                    ticket: ticket
                )
                return batch.hits
            },
            read: { hit in
                try await pageReader.readOutcome(hit, apiKey: firecrawlKey)
            },
            assess: assess
        )
    }
}
