# How NewsBar Recommends

> Generated from Sources/NewsBar/Resources/recommendation-guide.json. Run scripts/sync-recommendation-guide.sh to update; do not edit by hand.

## Overview

This guide explains how NewsBar orders recommendations and what interest information stays on this Mac. It describes the most recent ranking snapshot you are looking at, not a prediction or a final judgment of article quality.

Ranking runs locally and needs no cloud profile. With local learning on, NewsBar summarizes your reactions to titles and sources into an interest profile, then mixes that with public heat, recency and novelty. With learning off, only public information is used, but explicit mutes, not-interested and hides still filter content.

## Interest features

Ranking uses title terms and sources, not full-text semantics. A topic and entity lexicon maps titles to scalar tags, such as a subject or brand. Followed keywords match literally, while known topics also accept synonym aliases. Long-term and short-term interests accumulate separately; tag strength is normalized against the current strongest tag before mixing, so the same number of reads can produce different strength under a different profile.

Impressions are recorded at zero strength. Only a successfully loaded open provides positive evidence; a failed open does not. Public heat exists only for built-in sources that expose a ranking. When RSS has no heat, it is treated as unknown rather than a negative vote. The current semantic embedding model is evaluation-only and does not affect live ranking.

## Scoring and baseline

For each candidate, available features produce a personal score and a public baseline score. The two are blended by profile confidence: more evidence gives the personal score more weight, while sparse evidence or learning off stays closer to the public baseline. Tag matches use scalar strength normalized against the current peak, so scores are comparable only within the same candidate batch, not across days or people.

Already-read items are down-weighted, and while learning is on, reducing a topic also lowers its score. These are ranking adjustments, not deletion. Current coefficients, normalization peaks and caps change between versions; consult the in-app recommendation diagnostics and RecommendationEngine source for live values. This guide does not duplicate tunable numbers.

## Diversity and source rotation

Diversity adjustments follow the initial ranking. Repeated sources or topics receive a soft penalty, and a source protection cap varies with list length rather than acting as a fixed quota; source filtering only changes which items are displayed, while ranking and diversity penalties still use the full candidate pool. At fixed positions, the list prefers a less-used source. This is source rotation (source backfill): it selects by source count and a deterministic order, not random exploration and not a semantic model.

Other fixed positions prefer public heat or fresh content so personalization does not fully hide the public ranking. Source share is therefore a soft constraint produced by penalties and a cap, and equal shares per source are not guaranteed.

## Local records

Learning events (impressions, successful opens, reading time and explicit feedback) are stored in a local SQLite database and used to compute the interest profile. Raw events are kept for roughly 30 days, profile evidence for roughly 180 days and public content metadata for roughly 7 days; each has a count limit and ages out beyond it. Bookmarks, followed keywords and explicit block/topic rules persist until you change or clear them; other records roll off over time.

NewsBar does not upload events or profiles to its own servers, and there is no persistent device identifier or cross-device sync. The event stream is stored separately from the strongest same-day profile evidence, so upgrades do not discard legitimate funnel events merely to save space.

## Data and privacy

Behavior records and the interest profile stay on this Mac. When you actively use AI summaries, title translation or online search, the relevant titles and necessary context are sent to the provider you configured and are subject to that provider's privacy policy. A deep research run you start also sends its titles, topics and search results to that provider. The reader may also load original pages according to your settings.

The local interest store is not encrypted and relies on file permissions, so no promise can be made that nothing remains in disk images or system backups. Clearing personal data deletes events, the profile, followed keywords and reading sessions, and stops learning by default. If you keep bookmarks, they remain but no longer feed the profile. Clearing affects only this app's interest store; it does not delete browser cookies, history, caches or system backups. Browser data is managed separately in the reader settings.

## Controls and clearing

You can stop learning at any time. Turning learning off stops collecting new evidence and stops personalized ranking, but does not delete the existing profile. Turning it back on resumes with the retained profile. Pausing is temporary and also keeps the profile; private reading records no learning events. Clearing personal data stops learning by default, and you must enable it again before new learning starts.

Bookmarks, mutes and hides still work (and explicit blocks still filter content while learning is off); reducing a topic, more like this and follows require learning on. Public content cache (titles, sources, timestamps and similar fields) supports offline display and deduplication; it is not part of the personal profile and normal refresh may rebuild it after clearing. To stop personalization entirely, turn learning off. To reset the profile, use clear. Clearing only browser data does not reset the interest profile, and the reverse is also true.

## Limits and unknowns

Semantic vector ranking is not enabled, and no causal graph or probability confidence is shown. Relationship views only indicate title-tag and profile-evidence matches; they do not represent semantic distance. Explanations come from the latest snapshot and may change after a refresh or profile update. When a selection trace is missing, the app says it is unavailable.

A recommendation score is not an article quality rating and does not predict what you will enjoy. Source diversity is a soft constraint, so balanced coverage is not guaranteed. The app cannot infer whether the window is fully occluded; it only uses its own window, list visibility and reader occlusion to judge exposure, so explanations describe observable state only.

