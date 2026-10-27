# Research Center

The research center turns a topic into a verifiable report: it plans queries, searches the web, reads pages, extracts evidence, synthesizes a draft, and validates every quote before the report is marked ready.

## Entry points

- Menu bar popover: the research chip opens the most recent unread report.
- Dashboard: the research section lists recent records; right-click a news row to verify it.
- Reader toolbar: "Verify online" starts a run for the open article.
- Settings → Research: providers, budgets, retention and the Firecrawl key.

## Pipeline

1. **Plan** — the model proposes up to N queries for the selected depth.
2. **Search** — Tavily, Firecrawl and Brave are tried in failover order. Disabled providers are never contacted. A task may send at most 12 search HTTP requests, counting failed attempts.
3. **Read** — inline content → page cache → Firecrawl scrape (only when enabled and keyed) → direct HTTPS. Direct reads reject non-public IPv4/IPv6, re-check every redirect, and stream-cap the body at 4 MB.
4. **Extract** — the model returns claims, quotes and stances; quotes are checked verbatim against the fetched page.
5. **Synthesize** — a JSON report is produced; invalid JSON gets one repair call.
6. **Validate** — only evidence cited by a claim, and only verified quotes, can support it. Unsupported runs stay `unverified`.

A run that loses search, pages or budget still produces a `partial` report instead of failing outright.

## Data

- `records/<id>.json` is authoritative; `index.json` is a rebuildable projection.
- Runs and reports share one record file. Progress writes are throttled to one per second and the index to one per ten seconds.
- Deleting a record writes a tombstone, so a late progress callback cannot recreate it.
- Default retention: 30 days / 200 records (configurable). Pinned and in-flight records are exempt.

## Providers and keys

Keys live in the Keychain, never in `UserDefaults` or logs.

Firecrawl is the only provider that may also read pages. Fill in a personal key to use your own Firecrawl quota; page reads are capped per run. When Firecrawl is disabled, or no key is configured, the app makes **zero** Firecrawl requests and falls back to direct reads. Turning every provider off is valid: reports are generated AI-only and labelled as offline.

## Automation

- `researchAutoEnabled` is the single master switch for burst and keyword research.
- `burstPushEnabled` only controls whether a finished burst report raises a notification.
- Keyword tracking additionally requires `keywordTrackingEnabled`.

## Notifications

A finished report posts one notification: title "Research complete", subtitle = topic, body = one sentence (max 80 characters) derived from the summary, with markup and links stripped. Failures and cancellations post nothing. Clicking opens the report; if the record was deleted, the list opens instead.

## Privacy

Outbound traffic only goes to the enabled search providers, Firecrawl (when enabled and keyed), the configured AI endpoint, and the pages being verified. Consent text lists the actual recipients. The notification body is visible on the lock screen, which is why it is capped and stripped.

## Known limits

- DNS rebinding is narrowed by resolving and checking before connecting, but the session resolves again; a fully pinned connection layer is still future work.
- Firecrawl scrape counts toward your own quota; the settings page shows the per-run page cap.
- Corrupt records are isolated and can be removed from the data section.
