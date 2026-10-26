# Local Interest Engine Implementation Plan

> Execute inline in the primary session. No subagents, Git commits, paid API tests or silent model downloads.

**Goal:** Add a local, consent-gated interest engine and isolated Dashboard reader, sharing selection with summaries, research and notifications.

**Architecture:** Preserve source order and existing NewsItem IDs. Add canonical content identity, bounded SQLite persistence, pure feature/ranking/read-evidence policies, a main-actor controller and a single navigation router. Summary inputs are immutable manifests; source links always refer to generation-time items.

**Tech Stack:** macOS 15, SwiftUI, WebKit, NaturalLanguage, system SQLite, XCTest; no third-party runtime dependencies.

**Spec:** User-supplied “NewsBar 个性化推荐与内嵌阅读设计方案”, confirmed in this session.

## Global Constraints
- No behavior collection until explicit in-app consent. Pause/private reading stop new evidence. Clear rotates consent epoch and rejects old events.
- No browser cookies/history imports, cloud history uploads, model downloads, ATS relaxation or automatic new paid requests.
- Keep public heat separate from relevance; unknown publication time remains unknown.
- Model output is disabled until pre-labelled bilingual evaluation beats the tag baseline.
- Optional phase D is not part of this implementation.

## Review Focus
- Delayed saves and page callbacks after data clearing must not resurrect personal data.
- SPA / redirects / login pages must not continue attribution to the original article.
- HTTP/private-network navigation, downloads and popups must fail visibly without external app launches.
- Summary citations must survive input refresh, cache restoration and mixed source order.
- Sparse candidates / missing features must retain useful public ordering without fabricated heat or semantic capability.

## Tasks
1. **Identity and storage** — `Models/LocalInterest.swift`, `Services/LocalInterestStore.swift`, system SQLite target, optional publication dates in NewsItem/RSS. Tests: aliases preserve business queries; source IDs unchanged; first-seen preserved; consent/pause/epoch, restart persistence and retention. `swift test --filter LocalInterest` RED → GREEN.
2. **Reader and routing** — `Services/NewsNavigationRouter.swift`, `Services/ReaderSessionTracker.swift`, `Views/Dashboard/NewsReaderView.swift`, AppDelegate and all seven link surfaces. Test policy/time aggregation/navigation replacement; compile UI with `swift test`. Isolated ephemeral WebKit data and isolated minimal script world; conservative unsupported-site evidence.
3. **Features and recommendations** — `Services/RecommendationEngine.swift`, `Services/InterestController.swift`, Dashboard recommendation view and settings controls. Tests: word boundaries, decay, evidence upgrades/caps, undo, hard blocks, cold start, dedup/diversity and full-candidate exploration; 500-candidate timing measurement. Distinct snapshots never mutate source arrays.
4. **Shared consumers** — `Models/SummaryManifest.swift`, summary service/parser/cache/orchestrator, persisted research states, notification deep links. Test mixed-index citations, configuration cache identity, frozen input, restart suppression and no behavior-triggered generation. Existing request-budget tests remain green.
5. **Semantic gate** — `Services/TextEmbeddingProvider.swift`, labelled evaluation tests and availability report. Probe only already-installed system capabilities, never download. Keep ranking degraded if no validated provider is available.
6. **Acceptance/package** — run full XCTest suite and release build, self-review diff, create new versioned `output/` app without overwriting existing releases, ad-hoc sign and verify signature/plist, reveal folder in Finder. Record limitations honestly.

## Execution ledger
- Task 6: `swift test -c release` → 417 tests, 0 failures; cached 500-candidate maximum 50.8 ms. `scripts/package-local.sh` built arm64 release, validated plist and ad-hoc signature in a new output directory. App was not launched (avoids unrequested automatic AI calls).
- Acceptance notes and honest coverage limits: `output/v2.4.1_local-interest-20261023-104729/验证说明.md`. Suggested exhaustive analytics events, event-split UI and full real-site manual acceptance are not claimed complete.
- Task 4: frozen summary manifests, explicit citation index sets, bounded selection, persistent research/cooldowns, title-fallback notification deep links and durable pre-dispatch request ledgers integrated. Cancellation/clear epochs stop follow-up requests.
- Task 5: installed Apple system sentence model covered all 12 fixed bilingual triplets; 9 correct versus tag baseline 4. The 80% gate failed (75%); semantic ranking remains explicitly degraded/off. No model downloaded.
- Final self-review (user prohibited subagents): fixed explicit source blocks when learning is off, bookmarks learning without a preceding click, final heartbeat emission, reading-session terminal aggregates, cached metadata falsely advancing observation time, and research notification restoration before opening details.
- Final review verification: `swift test` → 417 tests, 0 failures (2026-10-23). Cached 500-candidate debug ranking: 10-sample maximum 148.3 ms; cold pass 193.4 ms. This is a local timing smoke test, not a real-world uplift claim.
- Ruling: cache content features in a bounded 4,096-entry, lock-protected in-memory cache; report cold and cached timing separately because the specification's target is cached-feature ranking.
- Ruling: SQLite stores one bounded, versioned transactional state document rather than premature per-entity normalized tables. Schema mismatch fails closed; no historical schema migration was necessary for this first schema.
- Tasks 1–3: 397 XCTest tests passed after implementation. Canonical IDs, publisher dates, SQLite epochs, consent/clear, isolated WebKit routing, read evidence and recommendation/privacy UI integrated. 500-candidate debug ranking: 10-sample maximum 78.6 ms.
- Reader integration caught unsupported WebKit regex disjunctions; split into independent content rules and verified real rule compilation.
- Ruling: public-navigation DNS checks plus literal-host subresource rules are defense-in-depth, not a universal DNS-rebinding/subresource firewall. Do not claim complete WebKit network isolation.
- Ruling: “more like this” stays in memory for the current list session; retained bookmarks do not automatically rebuild a cleared profile.
- Baseline: 374 XCTest tests passed, 0 failures. Clean checkout; created local branch `feature/local-interest-engine`.
- Ruling: use the existing checkout on a feature branch (no extra worktree); user requested all work in the main session.
- Ruling: self-review only because user expressly prohibited subagents; no independent review claimed.
- Ruling: package into a new output directory rather than invoke `scripts/build.sh`, whose unconditional `rm -rf` and release overwrites are outside the requested safe packaging path.
- Ruling: event clustering starts conservatively with exact normalized-title relationships, not unverified semantic merges. Unknown sites get weak time-only evidence, never claimed article completion.
