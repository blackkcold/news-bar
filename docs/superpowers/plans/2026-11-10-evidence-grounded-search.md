# Evidence-Grounded Search and Page Overview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make AI search and page overview ground every external fact in a page the app actually read, show what was found/read/adopted, and degrade to the current content instead of a blank answer.

**Architecture:** A shared evidence core (deterministic query planner → retriever → reader/dedup → batched assessor → app-side validator) feeds two consumers: the existing `AISearchService` and `PageSummaryService`. The app assigns source IDs, verifies quoted spans against the fetched text, and computes the answer basis; the model only proposes. Retrieval stays keyword/provider-based; no vector store.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, existing `SearchRouter`/`PageReader`/`HTTPAIChatClient`, no new dependencies.

**Spec:** This document is the reviewed plan. The earlier agent proposal is input, not the spec.

## Global Constraints

- No new third-party dependencies.
- All new tests use mocks; no real paid API or network. Keep existing env-gated live tests skipped.
- Preserve the current uncommitted work in the worktree (thinking picker, `page-summary-v2`, `AIChatClient` 400/422 fallback). Do not overwrite it.
- Citation IDs are created and validated by the app; the model cannot add a source.
- Page text is untrusted. Keep the `<source>` / `<untrusted_page>` envelope and `AISearchPrompts.sanitize`.
- Do not log API keys, full page text, or full prompts.
- Every new user-facing string goes in both `zhStrings` and `enStrings`; use `%ld` for `Int`.
- UI copy says "引用 / 采用 / 评估", never "已验证 / 已核实".
- Page summary in private reading must not trigger external search.

## Review Focus

These are the five failure modes most likely to bite a user; each has a test in the task that owns the code.

1. Search returns 0 hits vs all hits unreadable vs all providers failed — three distinct outcomes.
2. Model returns zero citations — the answer is preserved with a warning, never blanked, and never presented as verified.
3. Assessor invents a quote — the claim is rejected; a source with no verifiable quote cannot be `primary`.
4. Syndicated copies — not counted as independent corroboration.
5. Current page — never labeled external verification; private reading never sends page text/title to a search provider.

---

## Milestone 1: Shared evidence core + AI search

### Task 1: Baseline, isolation, and test seams

**Files:**
- Modify: `Sources/NewsBar/Services/PageSummary/PageSummaryService.swift`
- Modify: `Sources/NewsBar/Services/Search/PageReader.swift`
- Test: `Tests/NewsBarTests/PageSummaryTests.swift`
- Test: `Tests/NewsBarTests/PageReaderOutcomeTests.swift` (create)

**Interfaces:**
- Consumes: current `HTTPAIChatClient`, `PageReader.read(hit:apiKey:)`.
- Produces:
  - `PageSummaryService.summarize(..., client: any AIChatClienting? = nil)` — nil builds the live client.
  - `PageReader.readOutcome(_ hit:apiKey:) async -> PageReadOutcome`
  - `enum PageReadOutcome { case document(ResearchDocument), tooShort(Int), failed(PageReadFailure) }`
  - `enum PageReadFailure: String { case timeout, transport, blocked, empty, unknown }`

- [ ] **Step 1: Record the baseline**

Run:
```bash
git status --short
git diff --stat
swift test 2>&1 | tail -20
```
Expected: current uncommitted changes are listed; tests pass (or record the exact pre-existing failures). Do not commit or stash yet.

- [ ] **Step 2: Add the page-summary client seam**

Change `PageSummaryService.summarize` to accept `client: (any AIChatClienting)? = nil`. When nil, build the current `HTTPAIChatClient`; when provided, use it. Do not change the quota wiring for the live path.

- [ ] **Step 3: Write the failing seam test**

In `PageSummaryTests.swift`:
```swift
func testSummarizeUsesInjectedClient() async throws {
    let client = SelectionTestClient(text: "【概览】一句话\n【要点】\n- 要点")
    let summary = try await PageSummaryService.summarize(
        input: .article(title: "T", url: "https://example.com/a", text: String(repeating: "正文", count: 300), language: .zh, isPrivate: false),
        configuration: makeConfiguration(),
        providerName: "Test",
        quotaPolicy: .unlimited,
        thinking: nil,
        client: client
    )
    XCTAssertEqual(summary.oneLine, "一句话")
    XCTAssertEqual(await client.requests.count, 1)
}
```
Run: `swift test --filter PageSummaryTests/testSummarizeUsesInjectedClient`
Expected: FAIL — no `client:` parameter.

- [ ] **Step 4: Implement the parameter and pass the test**

Run the same filter. Expected: PASS.

- [ ] **Step 5: Add typed read outcomes**

Add `readOutcome` to `PageReader`; keep `read` as a thin wrapper returning `.document` or nil so existing callers compile. Classify: `inlineContent`/cache/scrape/direct success → `.document`; text `< 200` → `.tooShort`; direct reader nil → `.failed(.unknown)` (use `.timeout` only if the reader exposes it).

- [ ] **Step 6: Write the failing read-outcome test**

`PageReaderOutcomeTests.swift`:
```swift
func testShortInlineContentIsTooShort() async {
    let reader = PageReader(isScrapeEnabled: false)
    let hit = SearchHit(url: "https://example.com/a", title: "A", snippet: "", inlineContent: "短", provider: .tavily, providerRank: 1)
    let outcome = await reader.readOutcome(hit, apiKey: "")
    XCTAssertEqual(outcome, .tooShort(1))
}
```
Run: `swift test --filter PageReaderOutcomeTests`
Expected: FAIL — `readOutcome` missing.

- [ ] **Step 7: Implement and verify**

Run: `swift test --filter PageReaderOutcomeTests`. Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/NewsBar/Services/PageSummary/PageSummaryService.swift Sources/NewsBar/Services/Search/PageReader.swift Tests/NewsBarTests/PageSummaryTests.swift Tests/NewsBarTests/PageReaderOutcomeTests.swift
git commit -m "test: add evidence pipeline seams for summary and page reads"
```

---

### Task 2: Source metadata and citation-marker hardening

**Files:**
- Modify: `Sources/NewsBar/Models/AISearchAnswer.swift`
- Modify: `Sources/NewsBar/Services/AISearch/AISearchService.swift`
- Modify: `Sources/NewsBar/Services/AISearch/AISearchPrompts.swift`
- Test: `Tests/NewsBarTests/AISearchTests.swift`

**Interfaces:**
- Consumes: `SearchHit.publishedAt`, `ResearchDocument.publishedAt/fetchedAt/source`.
- Produces:
  - `AISearchSource.publishedAt: Date?`, `.fetchedAt: Date?`, `.origin: EvidenceOrigin`, `.provider: SearchProviderID?`, `.assessment: SourceAssessment?`, `.duplicateOf: String?`
  - `AISearchPrompts.sanitize` escapes `[n]` / `[#n]` in source text.

- [ ] **Step 1: Write the failing metadata test**

```swift
func testSourceKeepsPublishedDateAndOrigin() async throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let service = service(
        search: { _, _ in [hit("https://example.com/a", publishedAt: date)] },
        read: { _ in document("https://example.com/a", text: String(repeating: "x", count: 300), publishedAt: date) },
        answer: { _, _, _ in answerText("A [1]") }
    )
    let result = try await service.run(question: "q", scope: .web, page: nil)
    XCTAssertEqual(result.sources.first?.publishedAt, date)
    XCTAssertEqual(result.sources.first?.origin, .web)
}
```
Run: `swift test --filter AISearchTests/testSourceKeepsPublishedDateAndOrigin`
Expected: FAIL — no `publishedAt`.

- [ ] **Step 2: Extend `AISearchSource` with defaulted fields**

Add the fields with defaults in the initializer so existing call sites compile. Propagate from `SearchHit`/`ResearchDocument` in `AISearchService` (lines 116-132). For `.currentPage`, set `origin: .currentPage`, `provider: nil`.

- [ ] **Step 3: Write the failing citation-injection test**

```swift
func testSourceTextCitationMarkersAreEscaped() {
    let source = AISearchSource(index: 1, url: "https://example.com/a", title: "A", text: "见 [1] 与 [#2]")
    let prompt = AISearchPrompts.user(question: "q", scope: .web, sources: [source], language: .zh)
    XCTAssertFalse(prompt.contains("[1]"))
    XCTAssertFalse(prompt.contains("[#2]"))
}
```
Run: `swift test --filter AISearchTests/testSourceTextCitationMarkersAreEscaped`
Expected: FAIL — current sanitizer only escapes `[#`.

- [ ] **Step 4: Escape numeric markers in `sanitize`**

After the existing `[#` replacement, replace `[` + 1-3 digits + `]` with `［n］` (full-width). Keep the replacement inside `sanitize` only; never sanitize model output.

- [ ] **Step 5: Verify and commit**

Run: `swift test --filter AISearchTests`. Expected: PASS.
```bash
git add Sources/NewsBar/Models/AISearchAnswer.swift Sources/NewsBar/Services/AISearch/AISearchService.swift Sources/NewsBar/Services/AISearch/AISearchPrompts.swift Tests/NewsBarTests/AISearchTests.swift
git commit -m "feat: carry source metadata and escape citation markers in page text"
```

---

### Task 3: Deterministic query planner

**Files:**
- Create: `Sources/NewsBar/Services/Evidence/QueryPlanner.swift`
- Test: `Tests/NewsBarTests/QueryPlannerTests.swift` (create)

**Interfaces:**
- Produces:
```swift
struct PlannedQuery: Equatable, Sendable {
    enum Role: String, Sendable { case original, clause, quotedEntity, pageTitle }
    let text: String
    let recency: SearchRecency
    let role: Role
}
struct QueryPlan: Equatable, Sendable {
    let queries: [PlannedQuery]
    let recency: SearchRecency
}
enum QueryPlanner {
    static func plan(question: String, scope: AISearchScope, page: AISearchPageContext?, language: AppLanguage) -> QueryPlan
}
```

- [ ] **Step 1: Write the failing tests**

Cover:
- `今天` / `刚刚` / `最新` → `.day`.
- `本周` → `.week`.
- `今年` → `.year`.
- `是什么` / `定义` / `原理` / `区别` / `怎么` → `.all`.
- default news question → `.month`.
- multi-clause question split into at most 2 clause queries.
- quoted phrase adds one `quotedEntity` query.
- deictic question (`这个/该/它`) with page context adds `pageTitle`.
- non-deictic question does not add `pageTitle`.
- total queries ≤ 3; empty/whitespace question → empty plan.

Run: `swift test --filter QueryPlannerTests`
Expected: FAIL — type missing.

- [ ] **Step 2: Implement the planner**

Rules only, no model call. Trim, cap each query at 200 chars, drop duplicates after normalization, cap at 3. Recency mapping uses the first matching rule; explicit time words beat intent words; default `.month`.

- [ ] **Step 3: Verify and commit**

Run: `swift test --filter QueryPlannerTests`. Expected: PASS.
```bash
git add Sources/NewsBar/Services/Evidence/QueryPlanner.swift Tests/NewsBarTests/QueryPlannerTests.swift
git commit -m "feat: add deterministic query planner for evidence search"
```

---

### Task 4: Retriever with one shared attempt budget

**Files:**
- Create: `Sources/NewsBar/Services/Evidence/EvidenceRetriever.swift`
- Modify: `Sources/NewsBar/Services/AISearch/AISearchServiceFactory.swift`
- Test: `Tests/NewsBarTests/EvidenceRetrieverTests.swift` (create)

**Interfaces:**
- Consumes: `QueryPlan`, `SearchHandler`, `SearchRouterConfiguration`, `SearchAttemptTicket`.
- Produces:
```swift
struct RetrievalResult: Sendable {
    var candidates: [EvidenceCandidate]
    var outcomes: [QueryOutcome]
    var foundCount: Int
    var uniqueCount: Int
    var attemptsUsed: Int
    var searchUnavailable: Bool
}
struct QueryOutcome: Sendable {
    let query: PlannedQuery
    let hitCount: Int
    let failed: Bool
}
struct EvidenceCandidate: Sendable {
    let hit: SearchHit
    let discoveredBy: PlannedQuery.Role
}
enum EvidenceRetriever {
    static func retrieve(
        plan: QueryPlan,
        search: @Sendable (String, SearchRecency, Int, SearchAttemptTicket) async throws -> [SearchHit],
        ticket: SearchAttemptTicket,
        readLimit: Int,
        candidateCap: Int
    ) async -> RetrievalResult
}
```

- [ ] **Step 1: Write the failing budget test**

Use a `SearchHandler` that records `ticket.remaining` and throws for every call. Assert that three queries cannot consume more than 6 attempts total.

```swift
func testVariantsShareOneAttemptBudget() async {
    let ticket = SearchAttemptTicket(limit: 6)
    let calls = Counter()
    let result = await EvidenceRetriever.retrieve(
        plan: QueryPlan(queries: [q("a"), q("b"), q("c")], recency: .month),
        search: { _, _, _, _ in await calls.increment(); throw SearchProviderError.missingKey },
        ticket: ticket,
        readLimit: 3,
        candidateCap: 6
    )
    XCTAssertEqual(ticket.used, 6)
    XCTAssertTrue(result.searchUnavailable)
}
```

Run: `swift test --filter EvidenceRetrieverTests`
Expected: FAIL — type missing.

- [ ] **Step 2: Implement retrieval**

- One ticket per run, passed in by the caller.
- Per query: `maxAttempts: 2`, `maxProviderAttempts: 2`, `maxResults: candidateCap`.
- Merge hits, dedup by `canonicalURL`, score by `min(providerRank)` plus role bonus (original 0, clause 1, quotedEntity 2, pageTitle 3), take `candidateCap`.
- Catch per query; `searchUnavailable = outcomes.allSatisfy(\.failed)`.
- `foundCount` is raw hits before dedup; `uniqueCount` after dedup.

- [ ] **Step 3: Wire the factory**

In `AISearchServiceFactory`, create `let ticket = SearchAttemptTicket(limit: 6)` once per `make`, capture it in the search closure, and pass `recency` from the plan. Do not create a ticket inside the per-query closure.

- [ ] **Step 4: Verify and commit**

Run: `swift test --filter EvidenceRetrieverTests`. Expected: PASS.
```bash
git add Sources/NewsBar/Services/Evidence/EvidenceRetriever.swift Sources/NewsBar/Services/AISearch/AISearchServiceFactory.swift Tests/NewsBarTests/EvidenceRetrieverTests.swift
git commit -m "feat: add evidence retriever with a shared attempt budget"
```

---

### Task 5: Read, normalize, and deduplicate candidates

**Files:**
- Create: `Sources/NewsBar/Services/Evidence/EvidenceReader.swift`
- Modify: `Sources/NewsBar/Services/AISearch/AISearchService.swift`
- Test: `Tests/NewsBarTests/EvidenceReaderTests.swift` (create)

**Interfaces:**
- Produces:
```swift
enum ReadStatus: Equatable, Sendable {
    case read(characters: Int)
    case tooShort(characters: Int)
    case failed(PageReadFailure)
    case skipped
}
struct ReadResult: Sendable {
    var sources: [AISearchSource]
    var statuses: [ReadStatus]
}
enum EvidenceReader {
    static func read(
        candidates: [EvidenceCandidate],
        read: @Sendable (SearchHit) async -> PageReadOutcome,
        readLimit: Int,
        profile: SearchProfile
    ) async -> ReadResult
}
enum EvidenceDeduplicator {
    static func markDuplicates(_ sources: [AISearchSource]) -> [AISearchSource]
}
```

- [ ] **Step 1: Write the failing tests**

Cover:
- short text → `.tooShort`, not a source.
- read failure → `.failed`, not fatal.
- `publishedAt` from hit when document has none.
- two domains with the same normalized body → second `.duplicateOf(first.id)`.
- same domain + same normalized title → duplicate.
- current page URL matching an external hit → external is duplicate of the current page.

Run: `swift test --filter EvidenceReaderTests`
Expected: FAIL.

- [ ] **Step 2: Implement read and dedup**

Read in profile-concurrency batches; stop at `readLimit` successes. Normalize text (trim, collapse whitespace). Dedup: canonical URL exact; then normalized title+domain; then 5-gram Jaccard ≥ 0.75 over the first 2,000 characters. Never drop a duplicate silently: keep it with `duplicateOf` and `assessment = SourceAssessment(adoption: .rejected, reason: "duplicate")` later.

- [ ] **Step 3: Replace the inline read loop in `AISearchService`**

Keep the stage callbacks (`.reading(index:total:)`). Use `EvidenceReader.read` and keep all sources for the UI, not only successful ones.

- [ ] **Step 4: Verify and commit**

Run: `swift test --filter EvidenceReaderTests`. Expected: PASS.
```bash
git add Sources/NewsBar/Services/Evidence/EvidenceReader.swift Sources/NewsBar/Services/AISearch/AISearchService.swift Tests/NewsBarTests/EvidenceReaderTests.swift
git commit -m "feat: normalize and deduplicate evidence sources"
```

---

### Task 6: Batched evidence assessor with quote verification

**Files:**
- Create: `Sources/NewsBar/Services/Evidence/EvidenceAssessor.swift`
- Create: `Sources/NewsBar/Services/Evidence/EvidencePrompts.swift`
- Modify: `Sources/NewsBar/Models/AISearchAnswer.swift`
- Test: `Tests/NewsBarTests/EvidenceAssessorTests.swift` (create)

**Interfaces:**
- Produces:
```swift
enum SourceType: String, Codable, Sendable { case primary, secondary, aggregator, unknown }
enum SourceIndependence: String, Codable, Sendable { case independent, duplicate, unknown }
enum SourceAdoption: String, Codable, Sendable { case primary, supporting, rejected }
enum SupportLevel: String, Codable, Sendable { case direct, partial }
struct VerifiedClaim: Equatable, Sendable { let text: String; let quote: String; let support: SupportLevel }
struct SourceAssessment: Equatable, Sendable {
    let type: SourceType
    let independence: SourceIndependence
    let adoption: SourceAdoption
    let reason: String
    let claims: [VerifiedClaim]
}
struct EvidenceConflict: Equatable, Sendable { let claim: String; let indices: [Int]; let note: String }
struct AssessmentResult: Sendable {
    var sources: [AISearchSource]
    var conflicts: [EvidenceConflict]
    var usedFallback: Bool
}
enum EvidenceAssessor {
    static func assess(
        question: String,
        pageTitle: String?,
        sources: [AISearchSource],
        client: any AIChatClienting,
        quota: AIQuotaPolicy
    ) async -> AssessmentResult
}
```

- [ ] **Step 1: Write the failing schema test**

```swift
func testQuoteNotInSourceIsRejected() async {
    let client = SelectionTestClient(text: """
    {"sources":[{"index":1,"type":"secondary","independence":"independent","adopt":"primary","reason":"ok","claims":[{"text":"X","quote":"not in the page","support":"direct"}]}]}
    """)
    let result = await EvidenceAssessor.assess(
        question: "q", pageTitle: nil,
        sources: [source(1, text: "The page says X.")],
        client: client, quota: .unlimited
    )
    XCTAssertEqual(result.sources[0].assessment?.adoption, .rejected)
    XCTAssertTrue(result.sources[0].assessment?.claims.isEmpty ?? false)
}
```
Run: `swift test --filter EvidenceAssessorTests`
Expected: FAIL.

- [ ] **Step 2: Add the assessor prompt**

`EvidencePrompts.system(language:)`:
- "You audit evidence, do not answer the question."
- "For each source, quote the exact sentence that supports a claim. No outside knowledge."
- Strict JSON only; no prose; no code fences.
- Input: question (≤500 chars), page title (≤200), each source with `index`, `title`, `host`, `published`, `text` (≤3,000 chars; total ≤18,000).
- Explicitly say duplicates are marked and must not be counted as independent.

- [ ] **Step 3: Implement parsing and validation**

- Strip ```json fences; extract first `{` to last `}`.
- Decode with `JSONDecoder`; unknown keys ignored.
- Validate `index` in range; drop duplicates.
- Normalize quote and source text (collapse whitespace, remove zero-width, lowercase); require quote length 12...400 and substring match.
- Downgrade rules: `aggregator` or `duplicate` cannot be `primary`; a claim with one source cannot be `primary`; a claim with conflicting sources is `supporting` for all involved.
- If all claims for a source fail → `adoption = .rejected`, reason `quoteNotVerifiable`.
- If JSON fails → one repair call; if it fails again → heuristic fallback: sources with ≥400 chars and title/question token overlap are `supporting`, others `rejected`; `usedFallback = true`.
- Quota error → heuristic fallback without throwing.

- [ ] **Step 4: Verify and commit**

Run: `swift test --filter EvidenceAssessorTests`. Expected: PASS.
```bash
git add Sources/NewsBar/Services/Evidence/EvidenceAssessor.swift Sources/NewsBar/Services/Evidence/EvidencePrompts.swift Sources/NewsBar/Models/AISearchAnswer.swift Tests/NewsBarTests/EvidenceAssessorTests.swift
git commit -m "feat: add batched evidence assessor with quote verification"
```

---

### Task 7: Answer contract, validator, and basis

**Files:**
- Modify: `Sources/NewsBar/Services/AI/AnswerPrompt.swift`
- Modify: `Sources/NewsBar/Services/AISearch/AISearchPrompts.swift`
- Modify: `Sources/NewsBar/Services/AI/AnswerParser.swift`
- Modify: `Sources/NewsBar/Models/Answer/AnswerDocument.swift`
- Modify: `Sources/NewsBar/Services/AISearch/AISearchService.swift`
- Test: `Tests/NewsBarTests/AISearchTests.swift`
- Test: `Tests/NewsBarTests/AnswerValidatorTests.swift` (create)

**Interfaces:**
- Produces:
```swift
enum AnswerBasis: String, Codable, Sendable { case externalSupported, externalLimited, currentPageOnly, noVerifiedCitations, insufficientMaterial }
enum RetrievalNote: String, Codable, Sendable { case searchUnavailable, noResults, noSourcesReadable, partialProviders, assessmentSkipped, assessmentFailed, conflictingSources, partialCitations }
struct RetrievalEvidence: Equatable, Sendable {
    var foundCount = 0
    var readCount = 0
    var adoptedCount = 0
    var rejectedCount = 0
    var invalidCitationCount = 0
    var uncitedFactualSentences = 0
    var queryCount = 0
    var httpAttempts = 0
    var basis: AnswerBasis = .insufficientMaterial
    var notes: [RetrievalNote] = []
}
enum AnswerValidator {
    struct Result: Equatable { let validCitations: [Int]; let invalidCitations: Int; let uncitedFactualSentences: Int }
    static func validate(blocks: [AnswerBlock], sources: [AISearchSource]) -> Result
    static func basis(sources: [AISearchSource], validation: Result, searchNote: RetrievalNote?) -> AnswerBasis
}
```

- [ ] **Step 1: Write the failing zero-citation tests**

```swift
func testWebAnswerWithZeroCitationsIsPreservedWithWarning() async throws {
    let service = service(
        search: { _, _ in [hit("https://example.com/a")] },
        read: { _ in document("https://example.com/a", text: String(repeating: "x", count: 300)) },
        answer: { _, _, _ in answerText("No citation here.") }
    )
    let result = try await service.run(question: "q", scope: .web, page: nil)
    XCTAssertFalse(result.blocks.isEmpty)
    XCTAssertEqual(result.retrieval.basis, .noVerifiedCitations)
}

func testCurrentPageAnswerWithZeroCitationsIsPreserved() async throws {
    let page = AISearchPageContext(url: "https://example.com/p", title: "P", text: String(repeating: "x", count: 300))
    let service = service(answer: { _, _, _ in answerText("No citation here.") })
    let result = try await service.run(question: "q", scope: .currentPage, page: page)
    XCTAssertFalse(result.blocks.isEmpty)
    XCTAssertEqual(result.retrieval.basis, .noVerifiedCitations)
}
```
Run: `swift test --filter AISearchTests/testWebAnswerWithZeroCitationsIsPreservedWithWarning`
Expected: FAIL — current code returns empty blocks.

- [ ] **Step 2: Add the validator**

- Allowed citation indices = sources where `assessment?.adoption != .rejected`.
- `AnswerCitationScanner.segments(in:sourceCount:allowed:)` gains a defaulted `allowed` set; existing callers keep all indices.
- `AnswerValidator` counts valid/invalid citations and factual sentences without a citation. Factual = contains a digit, date pattern, quote, or percentage.
- Basis mapping:
  - no adopted external + current page → `.currentPageOnly` (+ note).
  - adopted external with a `primary` claim or ≥2 independent supporting sources → `.externalSupported`.
  - adopted external but only one secondary / duplicate / uncertain → `.externalLimited`.
  - zero valid citations with adopted sources → `.noVerifiedCitations`.
  - no readable material → `.insufficientMaterial`.

- [ ] **Step 3: Update the prompt**

Add `published`, `type`, `adoption` to `<source>`. Add `<evidence_notes>` with verified claims/quotes and `<conflicts>`. Instruct: cite every factual sentence; use attribution for single-source claims; state conflicts; do not cite rejected sources; do not fill gaps from memory.

- [ ] **Step 4: Implement the one-repair rule**

If adopted sources exist and valid citations are zero, make at most one repair call with the original prompt plus: "Your previous answer cited no source. Rewrite with [n] for every factual sentence, or state that the sources do not support an answer." If the repair still has zero, keep the original blocks and set `.noVerifiedCitations`. Do not repair twice.

- [ ] **Step 5: Gate partial streaming**

In `onPartial`, only emit a snapshot when it has at least one valid citation or when the run has no adopted sources. This prevents showing prose that the final check will mark unverified. Update the misleading comment at `AISearchService.swift:46-48`.

- [ ] **Step 6: Update the existing zero-citation test**

Rename `testZeroCitationAnswerIsReplaced` to `testZeroCitationAnswerIsPreservedWithWarning` and assert the new behavior. Keep the out-of-range test; add a rejected-source citation test.

- [ ] **Step 7: Verify and commit**

Run: `swift test --filter "AISearchTests|AnswerValidatorTests"`. Expected: PASS.
```bash
git add Sources/NewsBar/Services/AI/AnswerPrompt.swift Sources/NewsBar/Services/AISearch/AISearchPrompts.swift Sources/NewsBar/Services/AI/AnswerParser.swift Sources/NewsBar/Models/Answer/AnswerDocument.swift Sources/NewsBar/Services/AISearch/AISearchService.swift Tests/NewsBarTests/AISearchTests.swift Tests/NewsBarTests/AnswerValidatorTests.swift
git commit -m "feat: validate citations and preserve answers with an explicit basis"
```

---

### Task 8: AI search UI — stages, counts, basis, source status

**Files:**
- Modify: `Sources/NewsBar/Models/AISearchAnswer.swift`
- Modify: `Sources/NewsBar/Views/Dashboard/AISearchPanelModel.swift`
- Modify: `Sources/NewsBar/Views/Answer/AnswerStageRow.swift`
- Modify: `Sources/NewsBar/Views/Answer/AnswerDocumentView.swift`
- Modify: `Sources/NewsBar/Models/Localized.swift`
- Test: `Tests/NewsBarTests/AISearchTests.swift`

**Interfaces:**
- Consumes: `RetrievalEvidence`, `AnswerBasis`, `SourceAssessment`.
- Produces:
  - `AISearchStage.assessing`
  - `AISearchPanelModel.State.assessing`
  - evidence row: `检索 N · 读取 M · 采用 K · 引用 C`
  - source row: date, type, adoption badge, rejection reason.

- [ ] **Step 1: Write the failing stage test**

Assert the stage sequence for a web run is `.searching, .reading, .assessing, .answering` when assessment is enabled, and `.searching, .reading, .answering` when disabled. Use the injected runner.

Run: `swift test --filter AISearchTests/testStageSequenceIncludesAssessment`
Expected: FAIL.

- [ ] **Step 2: Add the stage and state**

Add `.assessing` to both enums and `apply`. Add `reader.search.stage.assess` zh/en. `AnswerStageRow` builds steps conditionally; `currentIndex` accounts for the extra step.

- [ ] **Step 3: Add the evidence row**

In `AnswerDocumentView`, replace the current read/cited row with the four counts. Add keys:
- `answer.evidence.found` = `检索到 %ld 个`
- `answer.evidence.read` = `读取 %ld 个` (change existing wording; update tests)
- `answer.evidence.adopted` = `采用 %ld 个`
- `answer.evidence.cited` = `%ld 处引用`

Keep the existing `answer.evidence.read` key if changing it would break other call sites; grep first. Use `%ld`.

- [ ] **Step 4: Add the basis badge**

Below the oneLine:
- `.externalSupported`: green badge `已引用 N 个外部来源`.
- `.externalLimited`: orange badge `外部证据有限` + reason from the strongest source.
- `.currentPageOnly`: gray badge `仅基于当前页面` + search note.
- `.noVerifiedCitations`: orange callout `未通过引用校验；以下内容未经来源核验`.
- `.insufficientMaterial`: gray badge `没有足够的可读材料`.

Do not use "已验证".

- [ ] **Step 5: Add source status**

`AnswerSourceRow` shows `publishedAt` (short date), type label (`一手/报道/转载/未知`), adoption label (`采用/仅佐证/未采用`), and a help tooltip with `reason`. Rejected rows are dimmed but still clickable. Use the existing `answer.uncitedSource` key for "未引用" only if it fits; otherwise add `answer.source.rejected`.

- [ ] **Step 6: Add the diagnostics note**

If `retrieval.notes` contains `.partialProviders`, show `部分搜索提供商不可用，结果可能不完整`. If `.assessmentSkipped` / `.assessmentFailed`, show `来源评估未完成，仅按可读性筛选`. These are captions, not errors.

- [ ] **Step 7: Verify and commit**

Run: `swift test --filter AISearchTests`. Expected: PASS.
```bash
git add Sources/NewsBar/Models/AISearchAnswer.swift Sources/NewsBar/Views/Dashboard/AISearchPanelModel.swift Sources/NewsBar/Views/Answer/AnswerStageRow.swift Sources/NewsBar/Views/Answer/AnswerDocumentView.swift Sources/NewsBar/Models/Localized.swift Tests/NewsBarTests/AISearchTests.swift
git commit -m "feat: show retrieval counts, evidence basis, and source status"
```

---

## Milestone 2: Page overview with optional external corroboration

### Task 9: Page summary evidence model and service

**Files:**
- Modify: `Sources/NewsBar/Models/PageSummary.swift`
- Modify: `Sources/NewsBar/Services/PageSummary/PageSummaryService.swift`
- Modify: `Sources/NewsBar/Views/Dashboard/PageSummaryModel.swift`
- Test: `Tests/NewsBarTests/PageSummaryTests.swift`

**Interfaces:**
- Produces:
```swift
enum PageSummaryBasis: String, Codable, Sendable { case pageOnly, externalSupported, externalLimited, searchUnavailable, insufficientMaterial }
enum PageSummarySourceKind: String, Codable, Sendable { case currentPage, external }
struct PageSummarySource: Codable, Equatable, Identifiable, Sendable {
    let index: Int
    let url: String
    let title: String
    let host: String
    let publishedAt: Date?
    let kind: PageSummarySourceKind
    let type: SourceType?
    let adopted: Bool
    var id: Int { index }
}
struct PageSummaryPoint: Codable, Equatable, Identifiable, Sendable {
    let text: String
    let citationIndices: [Int]
}
struct PageSummary { ... let sources: [PageSummarySource]; let basis: PageSummaryBasis; let retrieval: RetrievalEvidence? }
```

- [ ] **Step 1: Write the failing page-summary external test**

```swift
func testArticleOverviewUsesCurrentPageAndExternalSources() async throws {
    let summary = try await PageSummaryService.summarize(
        input: .article(title: "T", url: "https://example.com/p", text: String(repeating: "正文", count: 300), language: .zh, isPrivate: false),
        configuration: makeConfiguration(),
        providerName: "Test",
        quotaPolicy: .unlimited,
        thinking: nil,
        client: SelectionTestClient(text: "【概览】一句话\n【要点】\n- 外部事实 [2]"),
        externalSources: [externalSource(index: 2, url: "https://example.com/e")],
        externalBasis: .externalSupported
    )
    XCTAssertEqual(summary.sources.map(\.index), [1, 2])
    XCTAssertEqual(summary.sources[0].kind, .currentPage)
    XCTAssertEqual(summary.points[0].citationIndices, [2])
}
```
Run: `swift test --filter PageSummaryTests/testArticleOverviewUsesCurrentPageAndExternalSources`
Expected: FAIL.

- [ ] **Step 2: Add the model fields and parser**

- Article scope with external sources: parse `[n]` citations; source 1 is the current page, 2..n external. Without external sources, keep the current "no citations for articles" rule.
- List scope: keep `[#N]` and `PageSummaryCitation`.
- `PageSummaryPoint.citationIndex` becomes `citationIndices: [Int]`; update the UI and tests.
- `PageSummary.sources` always includes the current page when `scope == .article`.

- [ ] **Step 3: Add the service path**

`summarize(..., externalSources: [AISearchSource] = [], externalBasis: PageSummaryBasis = .pageOnly, client: ...)`.
- If external sources are empty → current prompt, `basis = .pageOnly`.
- If non-empty → prompt with `<source index="2"...>` blocks and the evidence notes; `basis` from the assessor.
- Bump `promptVersion` to `"page-summary-v3"`.
- Keep `maxArticleCharacters` at 6,000 for the page; external per-source 3,000, total 12,000.

- [ ] **Step 4: Verify and commit**

Run: `swift test --filter PageSummaryTests`. Expected: PASS.
```bash
git add Sources/NewsBar/Models/PageSummary.swift Sources/NewsBar/Services/PageSummary/PageSummaryService.swift Sources/NewsBar/Views/Dashboard/PageSummaryModel.swift Tests/NewsBarTests/PageSummaryTests.swift
git commit -m "feat: ground page overviews in optional external evidence"
```

---

### Task 10: Page summary retrieval orchestration, privacy, and cache

**Files:**
- Modify: `Sources/NewsBar/Views/Dashboard/PageSummaryModel.swift`
- Modify: `Sources/NewsBar/Views/Dashboard/ReaderAuxiliaryModel.swift`
- Modify: `Sources/NewsBar/Views/Dashboard/PageSummaryPanel.swift`
- Modify: `Sources/NewsBar/Services/PageSummary/PageSummaryCacheStore.swift`
- Modify: `Sources/NewsBar/Models/AppSettings.swift`
- Test: `Tests/NewsBarTests/PageSummaryTests.swift`
- Test: `Tests/NewsBarTests/PageSummaryPanelRenderingTests.swift` (if present)

**Interfaces:**
- Consumes: `QueryPlanner`, `EvidenceRetriever`, `EvidenceReader`, `EvidenceAssessor`.
- Produces:
  - `AppSettings.aiOverviewWebSupplement: Bool` (default true)
  - `AppSettings.aiEvidenceAssessmentEnabled: Bool` (default true)
  - `PageSummaryCacheStore` namespace `page-summary-v3`; external summaries 24h TTL.

- [ ] **Step 1: Write the failing private-mode test**

Use a spy retriever that records calls. Assert that `isPrivate: true` never calls the retriever and produces `basis == .pageOnly`.

Run: `swift test --filter PageSummaryTests/testPrivateOverviewNeverSearches`
Expected: FAIL.

- [ ] **Step 2: Write the failing degradation tests**

- Retriever returns `searchUnavailable` → summary still succeeds, `basis == .pageOnly`, note `.searchUnavailable`.
- Retriever returns 0 hits → `basis == .pageOnly`, note `.noResults`.
- Retriever returns pages but assessor rejects all → `basis == .pageOnly`, note `.assessmentFailed` or `.noSourcesReadable`.
- Assessor returns a conflict → `basis == .externalLimited`, note `.conflictingSources`.

- [ ] **Step 3: Implement the orchestration**

In `PageSummaryModel.summarize`:
1. If `webSupplement && !isPrivate && scope == .article`, plan queries from the page title + first 500 chars, retrieve with ticket 4 / readLimit 3 / candidateCap 5, read, assess.
2. Compute the evidence fingerprint (sorted adopted canonical URLs + text digests).
3. Cache lookup with the new key (includes `webSupplement`, prompt version, evidence fingerprint). If hit, return.
4. Call `PageSummaryService.summarize` with the external sources and basis.
5. Cache only the summary + source metadata, never page text. External entries expire after 24h; page-only entries keep 7 days.

- [ ] **Step 4: Update the disclosure**

`PageSummaryPanel` disclosure copy:
- zh: `会把当前页正文发送给 {provider}；如开启外部补充，还会把页面标题和检索词发送给搜索服务，并把检索到的网页正文发送给 {provider}。`
- en: equivalent.
- Add a per-run toggle `同时检索外部资料` (default from `aiOverviewWebSupplement`; disabled in private reading).
- Add a second button `仅总结当前页`.
- Bump the disclosure acknowledgement: store `pageSummaryDisclosureVersion`; show the card again when the version changes, even for a previously acknowledged URL.

- [ ] **Step 5: Update the panel rendering**

- Basis line: `基于当前页面 + N 个外部来源` / `仅基于当前页面（未检索到可靠外部资料）`.
- Source list: current page first with `当前页面` label; external rows with date/type/adoption.
- Footer: `外部资料检索于 {time}` or `未检索外部资料`.
- Keep the old summary visible on failure (existing behavior).

- [ ] **Step 6: Verify and commit**

Run: `swift test --filter "PageSummaryTests|PageSummaryPanelRenderingTests"`. Expected: PASS.
```bash
git add Sources/NewsBar/Views/Dashboard/PageSummaryModel.swift Sources/NewsBar/Views/Dashboard/ReaderAuxiliaryModel.swift Sources/NewsBar/Views/Dashboard/PageSummaryPanel.swift Sources/NewsBar/Services/PageSummary/PageSummaryCacheStore.swift Sources/NewsBar/Models/AppSettings.swift Tests/NewsBarTests/PageSummaryTests.swift
git commit -m "feat: add optional external corroboration to page overviews"
```

---

### Task 11: Settings, privacy acknowledgement, localization, archive

**Files:**
- Modify: `Sources/NewsBar/Views/Settings/AITab.swift`
- Modify: `Sources/NewsBar/Models/Localized.swift`
- Modify: `Sources/NewsBar/Views/Dashboard/AISearchPanel.swift`
- Modify: `Sources/NewsBar/Views/Dashboard/AISearchPanelModel.swift`
- Modify: `Sources/NewsBar/Models/AISearchArchiveEntry.swift`
- Test: `Tests/NewsBarTests/LocalizationParityTests.swift` (existing, no edit needed)
- Test: `Tests/NewsBarTests/LocalizationFormatContractTests.swift` (existing, no edit needed)
- Test: `Tests/NewsBarTests/AISearchArchiveStoreTests.swift`

**Interfaces:**
- Produces:
  - `aiEvidenceAssessmentEnabled` and `aiOverviewWebSupplement` toggles.
  - `aiSearchPrivacyAcknowledged.v2` key.
  - archive optional fields `publishedAt`, `adoption`, `type`, `basis`.

- [ ] **Step 1: Add the settings toggles**

`AITab` under "搜索与概览":
- `核验来源可靠性` (one extra AI call per search; default on).
- `页面概览同时检索外部资料` (default on; private reading forces off).

- [ ] **Step 2: Bump the AI search privacy acknowledgement**

Use a new defaults key `aiSearchPrivacyAcknowledged.v2`; update the privacy copy to mention query variants and search providers. Old `true` values do not count, so the notice shows once more.

- [ ] **Step 3: Add all localization keys**

zh and en, same keys, `%ld` for Int. Run:
```bash
swift test --filter "LocalizationParityTests|LocalizationFormatContractTests"
```
Expected: PASS.

- [ ] **Step 4: Extend the archive safely**

Add optional fields to `AISearchArchiveSource` and `AISearchArchiveEntry`. Optional properties decode as nil for old entries. Map `retrieval.basis` and counts if present; otherwise the archive view shows no badge.

- [ ] **Step 5: Verify and commit**

Run: `swift test --filter "Localization|AISearchArchive"`. Expected: PASS.
```bash
git add Sources/NewsBar/Views/Settings/AITab.swift Sources/NewsBar/Models/Localized.swift Sources/NewsBar/Views/Dashboard/AISearchPanel.swift Sources/NewsBar/Views/Dashboard/AISearchPanelModel.swift Sources/NewsBar/Models/AISearchArchiveEntry.swift Tests/NewsBarTests/AISearchArchiveStoreTests.swift
git commit -m "feat: expose evidence settings, privacy copy, and archive metadata"
```

---

### Task 12: Full regression and manual QA

**Files:**
- No production edits unless a test fails.

- [ ] **Step 1: Run the full suite**

```bash
swift test 2>&1 | tail -40
swift build -c release 2>&1 | tail -20
```
Expected: all tests pass; release build exits 0. Record any pre-existing failures separately.

- [ ] **Step 2: Manual QA with mocks**

Checklist:
- Original query returns nothing, a clause variant returns a relevant page → answer uses it.
- All providers fail but the current page has text → `.currentPageOnly` + "联网核验失败".
- Search returns hits, all unreadable → `.currentPageOnly` + "结果均无法读取".
- Assessor rejects every source → `.currentPageOnly` + "未采用外部资料".
- Answer cites nothing → prose preserved with `未通过引用校验`.
- Answer cites a rejected source → no chip, warning.
- Duplicate syndicated page → only one adopted; the other shows "转载/未采用".
- Private reading → no external search; page overview still works.
- Page overview with external sources → source 1 labeled 当前页面; external rows dated.
- Page overview with search failure → still shows the page summary.
- Quota exhausted → clean error, no half-run.

- [ ] **Step 3: Commit any test-only fixes**

```bash
git add Tests
git commit -m "test: cover evidence pipeline regressions"
```

---

## Acceptance Matrix

| Requirement | Test | UI evidence |
|---|---|---|
| Variant finds a page when the original does not | `EvidenceRetrieverTests.testVariantFindsWhenOriginalIsEmpty` | source list shows the adopted page |
| Invented quote rejected | `EvidenceAssessorTests.testQuoteNotInSourceIsRejected` | source marked 未采用 with reason |
| Syndicated copy not independent | `EvidenceReaderTests.testCrossDomainDuplicateIsMarked` | 转载 badge; not counted in 采用 |
| Out-of-range citation not a link | `AISearchTests.testOutOfRangeCitationStaysText` | plain `[9]` |
| No reliable external source still summarizes | `AISearchTests.testCurrentPageAnswerWithZeroCitationsIsPreserved` | 仅基于当前页面 |
| Network failure keeps current content | `PageSummaryTests.testSearchUnavailableStillSummarizesPage` | page summary + note |
| Current page never external verification | `PageSummaryTests.testCurrentPageIsLabeledAsCurrentPage` | 当前页面 label |
| Counts visible | `AISearchTests.testEvidenceCounts` | 检索 N · 读取 M · 采用 K · 引用 C |
| Private reading never searches | `PageSummaryTests.testPrivateOverviewNeverSearches` | no external rows |
| All tests mock-only | `swift test` | no live API calls |

## Risks and Open Decisions

1. **Assessment cost.** The recommended design adds one AI call per run (assessor) plus at most one repair. With `aiEvidenceAssessmentEnabled = false`, the app uses heuristic adoption and `.externalLimited`. Confirm the default (recommended: on).
2. **Page overview default.** Recommended: external supplement on for normal reading, forced off in private reading, with a per-run "仅总结当前页" button. Confirm.
3. **Zero-citation behavior.** Recommended: preserve the prose with an explicit "未通过引用校验" warning, never blank. This changes the current product rule; confirm.
4. **Scope split.** Recommended: ship Milestone 1 (AI search) first, then Milestone 2 (page overview). The shared core is the dependency; the page overview is the riskier consumer.
5. **Release branch.** The worktree has uncommitted thinking-picker changes. Do not implement on top of them without committing or moving to a clean branch first.

---

## 执行记录（2026-11-10，Milestone 1）

已按确认的决策实现 M1，页面概览（M2）未开始。

- 证据评估默认关闭；设置「核验来源可靠性」默认关，文案明确说明一次额外 AI 调用与关闭后的「有限」上限。
- 零引用回答保留原文，标「未通过引用校验」；不再清空 blocks；当前页模式同样保留。
- 查询变体共享 run 级 6 次 ticket；候选上限与读取上限拆分（readLimit + 3）。
- 来源保留 `publishedAt` / `fetchedAt` / `origin` / `provider` / `assessment` / `duplicateOf`；页面正文中的 `[n]` 被转义为全角，避免伪造引用。
- 新增确定性 `QueryPlanner`、`EvidenceRetriever`、`EvidenceReader`、`EvidenceAssessor`、`AnswerValidator`。
- UI：阶段行增加「评估来源」；证据行显示 `检索 / 读取 / 采用 / 引用`；basis 徽标；来源行显示日期、类型、采用状态与原因；未采用行变暗但仍可点开。
- 隐私提示升级为 `aiSearchPrivacyAcknowledged.v2`，文案说明最多 3 条检索词会发给搜索服务，旧确认不再生效。
- `SearchRouter` 注入 `SearchQuotaStore.shared`；AI 搜索现在遵守本地 per-provider 限流。
- `PageSummaryService.summarize` 增加 `client:` 注入缝，供 M2 使用；页面概览行为本身未改。

与计划不同的实现细节：

- `AISearchService.ReadHandler` 返回 `PageReadOutcome`；`SearchHandler` 接收 `SearchQuery + SearchAttemptTicket`。
- `AnswerDocument.retrieval` 为可选，避免离线 / 选中解释画布出现无依据的 basis 徽标。
- 直连页面不足 200 字时，`PageReader.read` 保持旧行为返回文档；证据管线由 `EvidenceReader` 统一按 200 字门槛拒绝。
- 评估关闭时所有可读非重复来源标 `supporting` + `heuristic`，basis 上限 `externalLimited`；文案明确写「未开启来源核验，仅按可读性筛选」。
- 评估 JSON 失败允许一次修复调用；再失败或额度不足时降级为启发式，不阻断搜索。

验证：`swift test` 1886 个测试、0 失败、6 跳过；`swift build -c release` 通过；`git diff --check` 无空白错误。
