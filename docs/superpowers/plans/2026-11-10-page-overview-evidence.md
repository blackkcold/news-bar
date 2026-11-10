# Page Overview External Corroboration (M2) — Plan & Execution Record

**Goal:** Let the reader's page overview optionally corroborate the current page with 1–3 external sources. The current page is always source 1; external sources are numbered 2...n. If external search fails, returns nothing, is unreadable, or is rejected, the overview still summarizes the current page — never blank, never an error state.

**Status:** Milestone 2 implemented on 2026-11-10. M1 evidence core and AI search are unchanged except for shared vocabulary (`RetrievalNote`, `SourceAssessment`, `EvidenceConflict`). Not committed (working tree WIP preserved).

## Decisions

| Topic | Decision |
|---|---|
| Assessment | Reuses `aiEvidenceAssessmentEnabled`; default off. With it off, every readable non-duplicate external source is `supporting`/`heuristic`, and the overview caps at `externalLimited`. |
| Privacy | Page overview external supplement defaults on for normal reading; private reading forces it off at the policy, model and prompt layers. Page text goes to the AI provider; page title/opening sentence/queries go to search providers only when the toggle is on. |
| Citations | Current page `[1]`; external `[2]...[n]`. Parser accepts `[n]` and `[#n]`. Rejected citations stay plain text. |
| Cache | Page-only 7 days; external success 24 hours; external attempted but failed 1 hour. `forceRefresh` bypasses the lookup (regenerate). |
| Localization | Whole `PageSummaryPanel` migrated to `reader.overview.*`; source type/adoption/reason reuse `answer.source.*`; notes reuse `answer.note.*`. |
| Stage row | Compact `检索外部资料 › 读取 x/y › 评估 › 总结` during generation when external search is on; assessment step only when enabled. |
| M2.1 | AI search archive basis/retrieval/source metadata deferred; does not block the overview. |

## Architecture

```
PageSummaryModel
  ├─ resolve AI configuration
  ├─ PageSummaryEvidencePolicy.shouldSearch(private, toggle, scope)
  ├─ PageSummaryEvidenceFactory → PageSummaryEvidenceProvider
  │    ├─ QueryPlanner.planOverview(title, excerpt)         // max 2 queries
  │    ├─ EvidenceRetriever (ticket 4, candidateCap 5)
  │    ├─ EvidenceReader (readLimit 3, dedup)
  │    ├─ EvidenceAssessor (optional; indices still 1...n)
  │    └─ renumber external sources to 2...n+1, conflicts +1
  ├─ PageSummaryService.prepare / summarize / parse (prompt v3)
  └─ PageSummaryCacheStore.save(ttl:) / load
```

## Key implementation facts

- `PageSummaryEvidencePolicy` is a pure policy: private/off/list never search; TTL is 7d/24h/1h.
- `PageSummaryEvidenceProvider` runs assessment **before** renumbering. `EvidenceAssessor` matches payload indices against `1...n`; renumbering first would drop every item.
- Ticket 4 is exactly 2 queries × 2 dispatches. `QueryPlanner.planOverview` caps at 2 queries.
- `PageSummary` new fields (`sources`, `basis`, `retrieval`) are optional `var` properties; old v2 cache JSON still decodes. `PageSummaryPoint` keeps `citationIndex` and adds optional `citationIndices`; `resolvedCitationIndices` bridges both.
- `PageSummarySource` stores the exact `SourceAdoption` so the UI can say 采用 / 仅佐证 / 未采用 instead of a Bool.
- `PageSummaryBasis` is separate from `AnswerBasis`: an overview has no answer citation validation, and `AnswerBasis.noVerifiedCitations` would be false.
- `PageSummaryCacheStore.Entry` gained optional `expiresAt`; old entries fall back to the historical 7-day sliding `lastUsedAt` window.
- Cache key includes page content, title, model/provider, thinking style, prompt version, `webSupplement`, enabled search providers, and `aiEvidenceAssessmentEnabled`. It does **not** include an evidence fingerprint: computing that would require the search the cache is meant to avoid.
- Private reading is forced off in three places: `PageSummaryEvidencePolicy.shouldSearch`, `PageSummaryModel` (before provider creation), and `PageSummaryService.prepare` (external sources are absent).
- External pages are sent to the AI provider only for the overview/assessment; page text is never cached. Source metadata (title/url/host/date/type/adoption) is cached with the summary.
- Disclosure copy now states: page text → AI provider; with external supplement, page title/opening sentence/queries → search providers, fetched text → AI provider; page-only 7d / external 24h cache; private reading never searches.

## Deviations from the reviewed M2 sketch

1. **Evidence fingerprint is not in the cache lookup key.** It cannot be known before retrieval; the key uses page content digest + webSupplement + providers + assessment flag. The fingerprint is unnecessary for correctness because the 24h TTL bounds staleness.
2. **Failed external search gets a 1-hour cache entry**, not 7 days, so the next open can retry.
3. **`PageSummarySource.adoption` is the exact enum**, not a Bool; the UI needs 采用/仅佐证/未采用.
4. **`PageSummary` new fields are optional**, protecting the whole cache file from a schema-drift wipe (`try? decode ?? [:]`).
5. **Assessment runs before renumbering**; conflicts are shifted +1 afterwards.
6. **Full panel L10n migration** (not just new strings) because the panel previously had zero keys.
7. **Disclosure acknowledgement stays per-URL and in-memory**; no version key is needed because it is not persisted across launches. The new copy naturally shows for each new page.
8. **The ready state keeps a page-only escape hatch** as a small doc icon next to "重新生成"; the disclosure/ready-to-generate states show the full "仅总结当前页" button.

## Verification

- `swift test`: **1910 tests, 0 failures, 6 skipped**.
- `swift build -c release`: exit 0.
- `git diff --check`: clean.
- Offscreen PNGs inspected at 332×520 (`overview-external-zh.png`, `overview-disclosure-zh.png`, `overview-ready-to-generate-zh.png`): basis line, citation chip, current-page-first source list, external date/type/adoption, external toggle, three disclosure buttons, footer retrieval time, and page-only icon all fit the rail width. Prominent button/switch tint in the offscreen window is an inactive-window artifact; the real window uses the accent color.

## New / modified files

**New**
- `Sources/NewsBar/Services/PageSummary/PageSummaryEvidencePolicy.swift`
- `Sources/NewsBar/Services/PageSummary/PageSummaryEvidenceProvider.swift`
- `Tests/NewsBarTests/PageSummaryEvidenceTests.swift`
- `Tests/NewsBarTests/PageSummaryExternalTests.swift`

**Modified**
- `Models/PageSummary.swift` (sources/basis/retrieval, multi-citation, cache key, L10n errors)
- `Services/PageSummary/PageSummaryService.swift` (prompt v3, external prompt, parse, basis)
- `Services/PageSummary/PageSummaryCacheStore.swift` (per-entry expiry, TTL)
- `Services/Evidence/QueryPlanner.swift` (`planOverview`)
- `Views/Dashboard/PageSummaryModel.swift` (orchestration, stage, toggle, force refresh, TTL)
- `Views/Dashboard/ReaderAuxiliaryModel.swift` (toggle default, page-only generate, force refresh)
- `Views/Dashboard/ReaderAuxiliaryRail.swift` (panel wiring)
- `Views/Dashboard/NewsReaderView.swift` (default from settings)
- `Views/Dashboard/PageSummaryPanel.swift` (full L10n, stage row, basis, sources, toggle, page-only)
- `Models/AppSettings.swift`, `Views/Settings/AITab.swift` (`aiOverviewWebSupplement`, default on)
- `Models/Localized.swift` (reader.overview.* + ai.overview.* keys)
- `Tests/NewsBarTests/PageSummaryPanelRenderingTests.swift`, `QueryPlannerTests.swift`

## Remaining

- Manual QA with real search providers/API keys: normal external overview, no search key, network off, quota exhausted, private reading (spy/network trace), cache hit, force refresh, 400pt rail in light/dark/retro.
- M2.1: AI search archive `basis`/`retrieval`/source metadata with optional decoding.
- No commits were made; M1 + M2 changes remain in the working tree with the pre-existing WIP.
