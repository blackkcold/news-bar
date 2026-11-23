# Research Workspace

The research workspace keeps a topic, its events, its evidence and its reports on one timeline. The old Research Center and Event Monitor windows are now one window; legacy entry points, notification payloads and records still work.

## Entry points

- Menu bar popover: the research chip opens the subject behind the newest unread report.
- Dashboard: the research section and a news row's "verify online" action open the same workspace.
- Reader toolbar and ⌘K: ⌘K returns local topics, reports, evidence and historical answers. Web search remains an explicit action.
- Settings → News events → "Open Research Workspace" opens the same window and prefers the most recent event subject.
- Legacy research/event notification clicks still resolve `recordID` / `eventID`; the additive `subjectID` opens the linked subject. A legacy payload without a subject is reconciled locally instead of opening a blank window.

## Working with a subject

- **New topic** creates local state only. It starts no AI and fetches no page. An optional seed link only seeds the first run and is never treated as evidence.
- **Follow** makes the existing RSS refresh collect matching new items as leads. It adds no network request and no timer, and it never starts AI research.
- **Check updates** uses only RSS sources enabled in Settings. It never calls search or AI. One click checks one feed by default (eight is a ceiling), so a single click cannot consume the whole rolling-hour budget; a just-finished shared check is reused. A 304 is a successful check.
- **Budget and backoff**: checks and event tracking share one rolling-hour budget and one single-flight slot. Failures back off over 5/10/20/40/60 minutes, and clicking again does not bypass the backoff. Results show actual source coverage, budget usage and the next eligible time.
- **Research**: manual, burst-automatic and keyword research all use one launcher and the same admission/quota gates. Manual runs keep their completion notification; automatic runs follow the research-completion notification switch.
- **Versions**: every successful report replacement archives a version. Failed or partial runs do not fabricate a version. If archiving the previous report fails, the old report is kept and the run is marked failed.
- **Archive** stops new lead collection and notifications while keeping all evidence, reports and versions. Unarchiving resumes collection. Nothing is deleted.

## Report reader

The popup and the workspace's research record share one reader, in a fixed four-chapter order:

1. **Conclusion** — the full summary, never truncated and never repeated by the 80-character notification line. A data strip follows (timeline nodes and span, sources and domains, verified quotes, independent sources), then the first two "still to confirm" items and a collapsed "Background".
2. **Timeline** — the report's own event order, with each node's source state (verified / unverified / no source). A report without one offers an "open event timeline" action instead of a blank chapter.
3. **Verification** — the claim ledger, conflicts, gaps and limitations, keeping quote verification and claim support apart instead of hiding them behind a 0/4 score.
4. **Sources** — collapsed into an index grouped by domain. Expanding a row reveals the quote, stance, tier and an "open original" action.

- An `E1` chip opens that source's card (title, domain, verbatim quote, verification state, open original); it never switches tab.
- The popup is 760×760 by default and 620×560 minimum, with a fixed header and 01–04 navigation; only the body scrolls.
- The workspace's research-record tab is called "Report". A subject with a report opens there when no tab has been chosen yet; historical versions come from the version menu in the run strip and stay read-only.
- At a detail width of 820 pt or more (roughly a 1380 pt window) the sources become a 220 pt index column on the right and the reader stops drawing chapter 04; below that the column disappears and the collapsed sources chapter returns.

## Linking and "no automatic AI"

- New research records and events link locally by explicit ID, normalized title/alias and report evidence URLs. Two events with the same subject but different times are not merged by title alone.
- When an event has evidence newer than a ready report, the subject is marked `needs review`. That is a prompt only; no research starts.
- Followed topics collect leads only during a normal successful RSS refresh. No extra request is made for lead collection.
- **Monitoring itself never starts AI, search or page fetches.** Only an explicit "start/update research/verify online" action, or a burst/keyword rule the user already enabled, runs the research pipeline.

## Notifications

- Event progress wins. For one subject and one update, an event-progress and a research-completion notice are not both sent within 30 minutes; the report is still visible in the workspace.
- There is no blanket six-hour suppression of the same kind. Genuine new progress, corrections and explicitly requested new research still notify.
- The same report version is never notified twice. An event's semantic de-duplication key is claimed only after the workspace allows delivery, so a suppressed workspace notice cannot consume the key and hide a later real update.
- Archived subjects send no new notifications and say why; old evidence is kept. New progress resumes after unarchiving.
- Payloads keep `type`, `recordID` and `eventID`; `subjectID` is additive. Notification bodies stay on the lock screen, so they carry only a completion notice, never report conclusions.

## Migration

- No file migration: existing `ResearchRecord`, `NewsEvent`, indexes and event snapshots decode unchanged. The workspace index is a separate, rebuildable layer.
- Old records/events gain a subject on first open or first local linking; the original record file is not rewritten.
- Legacy Research Center / Event Monitor views stay compiled but are no longer window roots. Every entry goes through `openResearchWorkspace`.
- Legacy `research` / `newsEvent` / `burst` notification clicks keep their original keys and prefer the new `subjectID` when present.

## Pipeline and data

1. Plan queries → 2. search enabled providers (disabled providers are never contacted; at most 12 dispatches per task) → 3. read pages (inline/cache/Firecrawl/direct HTTPS, rejecting private networks and oversized bodies) → 4. extract claims, quotes and stances → 5. synthesize JSON → 6. validate every quote and claim.
2. Only evidence cited by the claim and verified verbatim can support it; otherwise it stays `unverified`. Partial failures produce a `partial` report instead of a fake success.
3. `records/<id>.json` is authoritative and `index.json` is a rebuildable projection. Workspace index, report versions and analysis state live under `Research/workspace/`.
4. Records, indexes, caches, ledgers and clear intents use 0600 atomic writes. Corrupt or newer-version files are isolated read-only and are never overwritten by an older build.
5. "Clear research history" keeps its staged flow: durable intent → stop research → clear caches → delete records → clear workspace versions/state → verify → remove intent. Event evidence is preserved.

## Privacy and known limits

- Outbound traffic goes only to enabled search providers, Firecrawl (when enabled and keyed), the configured AI endpoint and pages the user explicitly verifies. RSS checks request only enabled RSS URLs.
- DNS rebinding is narrowed by resolving and checking before connecting, but the system resolves again; a fully pinned connection layer is still future work.
- The workspace rebuilds its local search index once on first open for a large library, then updates after coalesced notifications.
- Changes are verified by compilation and code review, not by a manual UI acceptance run. First live use should check split-view compression at 1040 pt, long-report scrolling and notification click targeting.
