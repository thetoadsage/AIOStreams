# Metadata preparation and Cinemeta reliability

Issue [#1150](https://github.com/Viren070/AIOStreams/issues/1150) exposed two independent problems: shared metadata could consume a built-in addon's execution deadline, and a cold Cinemeta request could delay that metadata even when other sources were usable.

## Timeout accounting

On a stream-cache miss, the wrapper prepares metadata for local routes using `BaseDebridAddon` before starting its foreground/background execution deadlines. External addons still start immediately; the fetcher's parallel/sequential grouping and inclusion conditions are unchanged. Direct Library item IDs do not need this preparation. The actual built-in URL configuration determines metadata credentials, including full-manifest overrides pointing at a supported local route.

Preparation uses the existing maximum HTTP timeout (`userLimits.timeouts.maxTimeout`, default 50 seconds) as a separate waiting ceiling, including the first anime-database lookup. An execution with five seconds of metadata preparation and a four-second addon timeout therefore gets four seconds to execute after preparation. This is **not** a four-second total Stremio response deadline. One cold dependent addon can take up to its preparation budget plus execution budget, in addition to setup, other sequential groups, and processing. Overall client/reverse-proxy deadlines still apply; no new global client deadline is introduced.

TorBox's ID-based searches start their internal HTTP request concurrently with preparation. The wrapper defers its execution deadline until metadata is ready, then enforces the normal foreground/background budgets. An earlier transport success/failure returns immediately and releases a late preparation lease when it arrives. The shared request lock includes the preparation allowance, while coalesced callers each retain an execution deadline. This preserves overlap between ID searches and metadata instead of making TorBox wait before searching. Failed preparation also respects existing stale stream-cache fallback.

A reference-counted metadata lease retains the result until the resource operation finishes, including intentional cache-warming background work. The built-in handler reuses this snapshot instead of depending on the distributed lock's two-second completed-result retention. Copies protect active consumers from shared mutation. Metadata keys include a digest of effective provider credentials so different configurations cannot share the wrong prepared result.

Leases are process-local, like the existing metadata single-flight lock. The normal built-in loopback path runs in that process. Routing `INTERNAL_URL` across multiple worker processes is not covered by this lifetime guarantee.

## Cinemeta cache

Raw responses live in the existing SQL cache table, under `cinemeta:v2`, even when Redis is configured. SQLite or Postgres must be persisted as usual; no separate database, service, dependency, or schema migration is needed. Successful loads and retry state use the cache's force-write path. Persistence remains best effort: the existing SQL backend logs/requeues database write failures and skips values exceeding `MAX_CACHE_VALUE_BYTES` (default 2,000,000 bytes). The shared row cap (default 100,000) and LRU eviction apply; expired rows are deleted on read and by existing hourly maintenance. Eviction, oversized values, and failed writes can produce cold misses. A storage error does not turn a successful provider response into a provider failure.

The cache key is media type plus IMDb ID, without season/episode, so concurrent requests for different episodes in one process share a fetch. Concurrent SQL reads are also coalesced, and refresh rechecks the stored entry before replacing a potentially outdated snapshot. Fetches retain the existing five-second transport timeout. Non-success HTTP responses, mismatched metadata and missing titles are rejected before caching; HTTP error bodies are cancelled to release connections.

| Content | Refresh on access after | Fresh through | Stale while revalidating through | Stale if error through |
| --- | --- | --- | --- | --- |
| Ongoing or unknown series | 45 minutes | 1 hour | 1 day | 7 days |
| Completed series / movies | 6 days | 7 days | 14 days | 30 days |

All ages are measured from the last successful fetch, not the latest read or failure. Unknown series use the short policy. Explicit ended/cancelled status or a closed, non-future release-year range marks a completed series; explicit ongoing status and scheduled/future videos override the year-range classification.

Refresh is demand-driven: requests near expiry start refresh without waiting. There is no new recurring job or scanning service. At most four background refreshes run per process, without an unbounded queue. Failed requests back off from one minute exponentially to one hour; retry state survives restarts. Requests outside the revalidation window attempt foreground refresh and use eligible stale data only on failure or during retry backoff. Failure never extends a last-good record's maximum age.

For episode-specific requests, stale data is only eligible if that exact season/episode exists with an already-aired, valid release date. Missing or future episodes require a fresh lookup; failures propagate to the existing metadata merger so it can use alternative providers. A newly fetched response legitimately missing an episode is reused for at most one minute before another missing-episode lookup; this prevents repeated requests for unusual numbering from hammering Cinemeta. It never invents an episode or enables stale missing-episode fallback. Late refreshes update future reads, never mutate an active request's metadata.

## Compatibility and limits

Cinemeta remains enabled and retains its current season-count priority, aliases, release dates, and episode-numbering checks. This change does not race the first successful metadata source or return incomplete episode metadata early. Cold requests can still wait for Cinemeta; their required preparation no longer consumes the local built-in execution budget. The old `cinemeta` cache namespace is not reused because it has no freshness/last-good timestamps.

The execution change does not add end-to-end cancellation to built-in routes. Existing deliberate background resource requests and builtin search refresh policies remain intact. An outer timeout can still leave downstream searches or shared metadata work running. Raw Cinemeta single-flight and the background limit are per process; SQL entries are persistent and shared, but simultaneous workers can issue duplicate HTTP calls or race writes. This is not a distributed compare-and-swap cache. The per-process preparation lease requires loopback requests to reach the same process; a load-balanced `INTERNAL_URL` does not have that guarantee.

The existing season-count priority remains Cinemeta, then TMDB, then Skyhook. Exact stale-episode eligibility protects against inventing numbering; it cannot prove that cached metadata has not since been corrected upstream. Undated specials and missing/future episodes lose Cinemeta's contribution during an outage and retain the existing alternative-provider fallback behavior, whose numbering may differ. No title/date/numbering resolver was replaced with a first-provider-wins race.

## Validation

Run `pnpm -F @aiostreams/core test`, `pnpm -F @aiostreams/core build`, and `pnpm -F @aiostreams/server build`. Focused regression files are `metadata/preparation.test.ts`, `metadata/cinemeta-cache.test.ts`, and `metadata/cinemeta.integration.test.ts` under `packages/core/src`.

The tests use mocked HTTP endpoints and isolated temporary SQLite databases. They cover a real five-second metadata/four-second execution timeline, immediate independent work, real HTTP wrapper grouping, foreground/background timer paths, cache hits, shared leases, timeout cleanup, credential isolation, 504 fallback, delayed Cinemeta transport timeout, concurrent episodes, database reopen and separate-process cache reads, stale episode safety, refresh limits, and persisted retry state. No live provider credentials or production configuration are used.

## Production-readiness audit (2026-10-19)

The audit fixed stale stream fallback on preparation failure, waiting unnecessarily after an early TorBox response, late-lease cleanup, preparation deadlines that excluded the first anime lookup, the short metadata lock lease, and mutable ordinary metadata consumers sharing a lock result. A delayed memory-lock owner now checks identity before releasing a replacement lock. Cache fixes keep storage failures separate from provider failures, recheck outdated SQL snapshots, coalesce reads, briefly reuse freshly absent episodes, and respect explicit ongoing status. Local project memory and the pnpm store are excluded from Docker build context.

The reduced [Goosebumps fixture](../packages/core/src/metadata/__fixtures__/goosebumps-1995.json) was captured from the public [Cinemeta metadata endpoint](https://v3-cinemeta.strem.io/meta/series/tt0111987.json) on 2026-10-19. It has 19/25/22/8 episodes across seasons 1–4, with three undated specials. A 504 regression checks the unchanged season counts, split-episode numbering, aliases, release date and release-year merging. Separate tests cover continuous anime numbering, `number` fallback, season/episode zero, and enrichment offsets across the loopback boundary. These are regression fixtures, not proof that different providers agree on every episode.

Validation uses Node 26.11.1 locally. Core and server TypeScript builds pass. All 51 focused metadata/lock tests pass; the full core suite passes 164 of 165 tests. The existing RemuxDB `maps audio and subtitle tracks` expectation fails independently of this work and was previously reproduced against clean HEAD. Formatting and diff checks pass.

**Readiness:** suitable for an isolated single-process staging trial with persisted SQLite and a loopback `INTERNAL_URL`. Production runtime behavior is not yet certified: Docker/Node 24, live PostgreSQL/Redis, load-balanced internal routing, client/proxy response budgets, and sustained high-concurrency workloads have not been exercised. Before rollout, measure cold/warm request latency, missing episodes and cache hit/write behavior in that isolated environment. Verify restart persistence and actual client timeouts without involving production configuration or live indexer searches in automated tests.
