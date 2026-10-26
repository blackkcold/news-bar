# Recommendation Explainer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: subagent-driven-development. The user explicitly requests multiple subagents; file-disjoint implementation may run concurrently. No agent may commit or spawn further subagents.

**Goal:** Deliver a truthful local recommendation explanation center with an offline guide and tested data-quality fixes.

**Architecture:** Keep the existing settings navigation and InterestController authority. The guide uses a bundled single source; explanation UI reads a frozen ranking/profile snapshot. Existing learned state stays backward compatible; new event attribution is optional.

**Tech Stack:** Swift / SwiftUI / AppKit, macOS 15+, Swift Package Manager, SQLite; no new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-26-recommendation-explainer-design.md`.

## Global Constraints

- Work only in the current `feature/recommendation-explainer` worktree. Keep all carried changes. No commits/push/release/install/network/real profile reads.
- Edit with patch. Use independent files by ownership below. No sub-subagents. Do not suppress diagnostics.
- TDD: add targeted assertions, show a meaningful red result, implement minimally, then run covering tests. Keep test fixtures synthetic and stores isolated.
- No fabricated embeddings, causal edges, probabilities, hard source caps or full deletion claims. Display actual state and explain unknowns.
- No arbitrary wholesale scoring-weight retuning. Current scalar components are not the final selected score; maintain a real selection trace.
- Prefer short, separate shell commands; rejected complex backup commands must not be repeated. Backup/migration already completed.
- Shared `.build` verification is coordinated by the parent. Workers may run focused tests after files are coherent; do not use separate full-build scratch trees or run release scripts.

## Review Focus

1. An inactive interval must break continuous exposure; changing key window is not proof that the feed is visible.
2. Existing v1 event/state payloads must remain decodable after optional attribution additions.
3. Explicit saving/blocking must not silently grant consent to behavioral learning.
4. Clearing from corrupt storage must work, while write failure must not claim success.
5. Explanation, guide resources and actual re-ranking must agree; viewing settings must have no learning/network side effects.

## File ownership and cross-task interfaces

| Tasks | Producer / consumer | Decision |
|---|---|---|
| A telemetry ↔ B rank | Existing LocalInterestState fields consumed by rank | A owns state/store/controller; B must not edit them. Optional event attribution additions preserve current signatures with defaults. |
| B rank ↔ C UI | `ScoredRecommendation.trace: RecommendationTrace?` | B produces trace described below; C reads it or shows unavailable, never reconstructs missing trace. |
| D guide ↔ C UI | `RecommendationGuide.sections(language:)`, `.markdown(language:)` | D produces the types below; C only consumes. |
| A telemetry ↔ C settings | Existing controller methods; clear stops learning after successful reset | A owns control behavior; C owns truthful copy/settings entry. C does not replace controller logic. |
| D guide ↔ packaging | Package resource bundle copied to local/release app Resources | D owns Package.swift and script changes; no other worker edits them. |

### Task A: Telemetry, consent and rule correctness

**Own:** `Models/LocalInterest.swift`, `Services/InterestController.swift`, `Services/LocalInterestStore.swift`, `Services/ReaderSessionTracker.swift`, `Services/NewsNavigationRouter.swift`, `Views/Dashboard/RecommendationFeedView.swift`, and minimal hunks in `Views/Dashboard/NewsReaderView.swift` / `DashboardWindow.swift` if necessary. Tests: `LocalInterestTests.swift`, `ReaderPolicyTests.swift`, new `InterestAttributionTests.swift`. Do not edit settings or RecommendationEngine.

- [ ] Add regression tests for exposure active gap, scoped feedback idempotence, off/paused explicit rules without learning, raw-event retention with strongest profile signal, attribution roundtrip, clear contents/archive and stop-learning, corrupt reset recovery.
- [ ] Use own-window + list/reader visibility, one consistent gate and real inactive updates. Do not claim exact unobstructed screen pixels can be inferred by NSWindow.
- [ ] Add optional attribution metadata and bounded event dedupe. Keep feed session separate from reader session; retain old Codable payloads. Keep impression as zero-strength.
- [ ] Preserve open attempt/result distinction; only successfully loaded navigation contributes opened evidence. Preserve user's existing reader/transition/layout changes.
- [ ] Scope rules by source/cluster/topic/content, permit explicit non-learning actions when automatic learning is off, and prevent those actions rebuilding a profile without consent.
- [ ] Define public metadata as cache in copy/API, clear it on personal reset, document that normal refresh can recreate public cache. Clear should stop learning and keep only explicitly requested bookmarks.
- [ ] Implement application-owned recoverable store reset for damaged/unknown schema without modifying real user files in tests. Verify persisted reset before announcing success.
- [ ] Run `swift test --filter 'LocalInterestTests|ReaderPolicyTests|InterestAttributionTests'`, report actual red/green evidence and remaining runtime caveats.

### Task B: Ranking trace, aliases and replay checks

**Own:** `Services/RecommendationEngine.swift`, new `Models/RecommendationTrace.swift`, `Tests/NewsBarTests/RecommendationTests.swift`, new `RecommendationTraceTests.swift`. Do not edit LocalInterest/controller/UI.

**Produces:** `ScoredRecommendation.trace: RecommendationTrace?` (default nil for source compatibility). `RecommendationTrace: Sendable` with readable `contributions: [String: Double]`, `personalScore: Double`, `baselineScore: Double`, `confidence: Double`, `readPenalty: Double`, `feedbackPenalty: Double`, `rawScore: Double`, `selectionScore: Double`, `sourcePenalty: Double`, `topicPenalty: Double`, `diversityPenalty: Double`, `rankBeforeDiversity: Int`, `finalRank: Int` (both 1-based), `selectionPolicy: String`. Contributions include both personal and baseline terms, so their sum minus read/feedback penalties equals rawScore. For source-rotation slots selection is lexicographic, not invented additive scoring; state this in selectionPolicy/copy.

- [ ] Tests pin contribution sum, baseline/personal mixing, missing heat, actual selected policy, before/after ranks, deterministic replay, scoped hard blocks, and alias-follow transfer.
- [ ] Implement trace from the actual ranking pass, not a second approximate scorer.
- [ ] Share lexicon aliases for explicit known-topic follows without dropping arbitrary literal keywords. Keep unrelated short Latin substrings rejected.
- [ ] Label exploration honestly as source rotation, retaining stable behavior unless a tested minimal correction is needed; no new randomness/ML.
- [ ] Test tagged/un-tagged/missing-date/cross-source cases; retain the current coefficients pending broader evidence. Increment policy version if actual behavior changes.
- [ ] Run `swift test --filter 'RecommendationTests|RecommendationTraceTests'`. Report which broader calibration experiments remain recommendations rather than implemented claims.

### Task C: Native settings explanation center

**Own:** `Views/Settings/InterestPrivacySection.swift`, new `Views/Settings/RecommendationExplanationView.swift` and focused helper view/model files under that folder; new `RecommendationExplanationTests.swift`. Do not edit engine/controller/guide/resources/Localized.swift/Dashboard.

**Consumes:** current InterestController / InterestProfile / RecommendationSnapshot, Task B trace, Task D guide. Inject synthetic state/snapshot for tests; avoid singleton preparation in render tests.

- [ ] Add the entry inside the existing local-interest Section; no ninth settings tab or second consent controller.
- [ ] Four secondary segments: overview, interests, ranking process, data/privacy. Sheet respects available parent space with single-column scrolling at narrow widths.
- [ ] Tag weights show topic/entity/followed distinction. Selected label highlights bounded evidence/tag/candidate relationships with exact text alternative; coordinates never encode semantic distance. Do not use full title histories beyond available local data.
- [ ] Drill into current snapshot article: raw components vs actual contribution vs selection policy/penalties/ranks, using the real trace. Missing trace is explicitly unavailable.
- [ ] Off/empty/paused/private/storage error states are truthful. View snapshot does not call rebuild/record or use network. Clear remains explicit, with accurate scope and continued-learning state copy.
- [ ] Use native controls and existing theme modifiers, shared shape, keyboard/VoiceOver, reduced motion; Chinese/English.
- [ ] Include bundled offline guide using Task D API. Render tests for narrow/modern/retro/English/empty and model tests for dimension labels; no real profile reads.
- [ ] Run `swift test --filter RecommendationExplanationTests` and report any visual verification not performed.

### Task D: Single-source offline guide and bundle support

**Own:** `Package.swift`, new `Sources/NewsBar/Resources/recommendation-guide.json`, new `Sources/NewsBar/Services/RecommendationGuide.swift`, `docs/recommendations-explained.md`, optional English counterpart, README guide links, `scripts/package-local.sh` and minimal resource-copy hunks in `scripts/build.sh`, new guide sync/check script, new `RecommendationGuideTests.swift`. Do not edit policy/models/settings.

**Produces:** `RecommendationGuideSection: Identifiable` exposing `id: String`, `title: String`, `body: String`. `RecommendationGuide.sections(language: AppLanguage) -> [RecommendationGuideSection]`; `RecommendationGuide.markdown(language: AppLanguage) -> String`. Loader is offline with bundled resource; error is explicit and must not silently show invented guide text. Add `RecommendationGuide.isAvailable: Bool` if useful.

- [ ] JSON sections (stable IDs overview/features/scoring/diversity/telemetry/privacy/controls/limitations) contain bilingual shared prose; generate repository Markdown from the same source and add deterministic `--check` support.
- [ ] Explain dynamic normalization, public baseline and scalar tag feature alignment; semantic embeddings remain evaluation-only. Do not duplicate tunable weight numbers in multiple independent sources; point to live diagnostics/source for current values.
- [ ] Explain local event/profile storage versus AI/search/translation title disclosure, public metadata cache, raw/profile retention, pause/off/re-enable, clear-and-stop default, bookmark preservation, separate browser-data scope. Do not claim encryption/secure erasure/all traces removed.
- [ ] Bundle resources using SPM, copy the generated resource bundle to app Resources in both package paths, and verify loader support for packaged binary, not only swift test.
- [ ] Add tests for bilingual completeness, required disclosures, resource availability, generated doc consistency and packaged bundle layout behavior.
- [ ] Run guide tests and sync `--check`. Do not invoke build.sh, remove artifacts, create DMG, sign remote identities or publish.

## Integration and independent review

- [ ] Each worker reports changed files, tested commands/results, red evidence, constraints and uncertainties to `.context/recommendation-explainer/task-X-report.md` (only its own report file).
- [ ] Parent reviews each owned diff against the preflight backup; independent reviewer checks spec compliance and quality. Fixes resume the same implementer session; stop/revert only that worker's new edits after three consecutive failed fixes, never revert carried changes.
- [ ] Run full `swift build` / `swift test`, guide `--check`, and local release build/resource packaging checks without overwriting existing artifacts. Record pre-existing warnings separately.
- [ ] Preserve plan/ledger and all uncommitted work; final report lists verified results and honest deferred experiments. No commit/merge/push/cleanup.
