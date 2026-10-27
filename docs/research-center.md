# Research Center

The research center turns a topic into a verifiable report: it plans queries, searches the web, reads pages, extracts evidence, synthesizes a draft, and validates every quote before the report is marked ready.

## Entry points

- Menu bar popover: the research chip opens the most recent unread report.
- Dashboard: the research section lists recent records; right-click a news row to verify it.
- Reader toolbar: "Verify online" starts a run for the open article.
- Settings → Research: providers, budgets, retention and the Firecrawl key.

## Pipeline

1. **Plan** — the model proposes up to N queries for the selected depth.
2. **Search** — Tavily, Firecrawl and Brave are tried in failover order. Disabled providers are never contacted. A task may dispatch at most 12 search HTTP requests. Each dispatched request consumes one slot before it leaves the process; cache hits, skipped providers and cooldowns consume none. The same count is charged whether the call succeeds, fails or is cancelled after dispatch.
3. **Read** — inline content → page cache → Firecrawl scrape (only when enabled and keyed) → direct HTTPS. Direct reads reject non-public IPv4/IPv6, re-check every redirect, and stream-cap the body at 4 MB.
4. **Extract** — the model returns claims, quotes and stances; quotes are checked verbatim against the fetched page.
5. **Synthesize** — a JSON report is produced; invalid JSON gets one repair call.
6. **Validate** — only evidence cited by a claim, and only verified quotes, can support it. Unsupported runs stay `unverified`.

A run that loses search, pages or budget still produces a `partial` report instead of failing outright.

## Data

- `records/<id>.json` is authoritative; `index.json` is a rebuildable projection.
- Runs and reports share one record file. Progress writes are throttled to one per second and the index to one per ten seconds.
- Deleting a record writes a tombstone, so a late progress callback cannot recreate it.
- Default retention: 30 days / 200 records (configurable). Pinned, in-flight, corrupt and newer-schema records are exempt.
- Record, index, meta, cache, ledger and clear-intent files are created owner-only (0600) *before* content is written, via a same-directory temporary file and an atomic rename. A failed write leaves the previous file intact. The same writer covers translation caches, AI summary caches, the encrypted key store, the machine UUID, reading history and the request budget.
- Every record and index write states `schemaVersion: 1`. A missing version is read as v1; a higher version is projected read-only and is never overwritten by an older build. Corrupt, unreadable and newer-version records cannot be pinned, marked read or rewritten; they can still be deleted.
- The ledger is versioned and reports `available / corrupt / ioUnavailable / unsupportedVersion`. Anything other than `available` fails closed and the UI shows “—” instead of a fake zero. A reset archives a corrupt file (0600) first, refuses while a research task is running, and never restores provider-side quota.

## Providers and keys

Keys live in the app's owner-only encrypted file (AES-GCM, machine-bound), never in `UserDefaults` or logs. The Keychain is read only for the one-time legacy migration.

Settings shows a per-provider state: off, key missing, not tried yet, last call succeeded, authentication rejected, access refused, cooling down, or last call failed temporarily. A 401 is remembered only when a key was actually sent; a keyless 401 is not a permanent block. A 403 is not retried within the same research pass but is not remembered across passes. 402/429 keep the 15/30-minute cooldown. “Retry authentication” only clears that provider's auth block: it sends nothing, keeps cooldowns and does not reset the ledger. Saving or clearing a key refreshes the state without lifting a quota cooldown.

Firecrawl is the only provider that may also read pages. Fill in a personal key to use your own Firecrawl quota; page reads are capped per run. When Firecrawl is disabled, or no key is configured, the app makes **zero** Firecrawl requests and falls back to direct reads. Turning every provider off is valid: reports are generated AI-only and labelled as offline.

## Automation

- `researchAutoEnabled` is the single master switch for burst and keyword research.
- `burstPushEnabled` only controls whether a finished burst report raises a notification.
- Keyword tracking additionally requires `keywordTrackingEnabled`.

## Clearing history

Every "clear research history" entry point uses one staged flow: write a durable clear intent, stop new research, persist the legacy-import marker, clear the search and page caches, delete authoritative records, clear legacy research artifacts (notification de-duplication sets, other interest data, keys and the ledger stay), verify each stage, and remove the intent last. A crash or relaunch resumes from the intent and never re-imports discarded artifacts. A failed stage keeps the intent and is reported instead of showing success. The legacy import derives stable identities from the artifact key (including titles that normalize to nothing) and only writes its one-time marker when every artifact is persisted or provably equivalent.

This is a logical deletion: it does not promise forensic erasure of SQLite free pages, WAL files, system backups or synced copies.

## Notifications

A finished report posts one notification: title "Research complete", subtitle = topic, body = one sentence (max 80 characters) derived from the summary, with markup and links stripped. Failures and cancellations post nothing. Clicking opens the report; if the record was deleted, the list opens instead.

## Privacy

Outbound traffic only goes to the enabled search providers, Firecrawl (when enabled and keyed), the configured AI endpoint, and the pages being verified. Consent text lists the actual recipients. The notification body is visible on the lock screen, which is why it is capped and stripped.

## Known limits

- DNS rebinding is narrowed by resolving and checking before connecting, but the session resolves again; a fully pinned connection layer is still future work.
- Firecrawl scrape counts toward your own quota; the settings page shows the per-run page cap.
- Corrupt records are isolated and can be removed from the data section.
