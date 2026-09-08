# RFC 9111 Compliance Matrix for `InnoNetworkPersistentCache`

This RFC pins the exact subset of [RFC 9111: HTTP Caching](https://www.rfc-editor.org/rfc/rfc9111)
that `InnoNetworkPersistentCache` and the in-memory `ResponseCachePolicy`
honour in the 6.x contract. The intent is to give operators a single sheet
to reason about cache-driven behavior without re-reading the executor or
the cache actor.

## Header / Directive Coverage

The cache module always reads requests and responses through the
`ResponseCacheKey` / `CachedResponse` value types; this matrix maps RFC
9111 directives to whether the 6.x line consumes, persists, or ignores
them.

| RFC 9111 directive / header | Status | Behavior in 6.x |
| --- | --- | --- |
| `Cache-Control: no-store` (request and response) | ✅ Honored | Skips writes, invalidates an existing key. Applied in `RequestExecutor.storeCacheIfNeeded`. When the policy is wrapped via `ResponseCachePolicy.rfc9111Compliant(wrapping:)`, the directive additionally suppresses cache reads against an entry that was somehow persisted before the wrap (defence in depth). |
| `Cache-Control: no-cache` | ✅ Honored | Stored but flagged as `requiresRevalidation`; the next read forces conditional revalidation. The RFC adapter also derives this requirement from restored headers, so custom caches cannot accidentally make a `no-cache` entry reusable by omitting the convenience flag. |
| `Cache-Control: private` | ✅ Honored | Skips writes, invalidates an existing key. Quoted-form (`private="X-Foo"`) is parsed by `HTTPListParser` and treated identically. |
| `Cache-Control: public` | ✅ Honored for auth storage | Cache is private-by-default for ordinary responses; for requests carrying `Authorization`, `public` is one of the RFC 9111 §3.5 directives that permits storage. |
| `Cache-Control: max-age=N` | ⚠️ Partial | Default policies preserve the directive on disk but drive freshness windows from `ResponseCachePolicy` (`cacheFirst(maxAge:)` etc.). The directive is consumed when the policy is wrapped via `ResponseCachePolicy.rfc9111Compliant(wrapping:)`, which clamps freshness to `min(server max-age, caller window)`. Default consumption remains a future-major candidate. |
| `Cache-Control: s-maxage=N` | ⚠️ Auth storage only | Shared-cache freshness is ignored because the persistent cache is single-process, but `s-maxage` is honoured as an RFC 9111 §3.5 permission directive for storing responses to `Authorization` requests. |
| `Cache-Control: stale-while-revalidate=N` | ⚠️ Partial | The library exposes stale-while-revalidate semantics through `ResponseCachePolicy.staleWhileRevalidate`, but does not currently parse the response directive — operators opt in via the policy. |
| `Cache-Control: stale-if-error=N` | ✅ Opt-in | `ResponseCachePolicy.staleIfError(wrapping:)` requires both caller opt-in and an origin-provided window. It excludes mandatory revalidation and rechecks the final age after retry and transport delay before recovery. |
| `Cache-Control: must-revalidate` | ⚠️ Implicit | Behaves identically to `no-cache` because the cache always revalidates `requiresRevalidation` entries. When the policy is wrapped via `ResponseCachePolicy.rfc9111Compliant(wrapping:)` the directive additionally forces `.returnStaleAndRevalidate` → `.revalidate`, denying the stale window. |
| `Cache-Control: only-if-cached` | ✅ Opt-in | `ResponseCachePolicy.requestOnlyIfCached(wrapping:)` returns a reusable entry without transport and fails locally on a miss or mandatory revalidation. It also suppresses a stale-while-revalidate background leg. |
| `Cache-Control: immutable` | ❌ Not consumed | Tracked as a future-major candidate; safe to ignore because the freshness window is policy-driven. |
| `Expires` | ⚠️ Adapter-only | Consumed by `ResponseCachePolicy.rfc9111Compliant(wrapping:)` when no valid `max-age` exists. The adapter uses `Expires - Date`, falling back to `Expires - storedAt`; invalid values are stale. Default policies remain caller-window driven. |
| `Vary` | ✅ Honored | Captured at write time as `varyHeaders` and consulted on every lookup. `Vary: *` skips the write and invalidates a previous entry for the current key. A changed `Vary` on `304` invalidates the old selection snapshot while the validating caller receives merged response metadata. |
| `Set-Cookie` | ✅ Honored | Refused by default (`storesSetCookieResponses = false`); operators can opt in. |
| `Authorization` (request key) | ✅ Honored | Refused by default (`storesAuthenticatedResponses = false`). Even after opt-in, storage requires `Cache-Control: public`, `must-revalidate`, or `s-maxage` per RFC 9111 §3.5. |
| `ETag` | ✅ Honored | Captured for conditional revalidation via `If-None-Match`. A `304` is matched using RFC 9110 strong/weak entity-tag rules and rejected when its validator cannot identify the stored response. |
| `Last-Modified` | ✅ Honored | When `max-age` and `Expires` are absent, `ResponseCachePolicy.rfc9111Compliant(wrapping:)` applies the RFC 9111 §4.2.2 10% heuristic freshness calculation capped at 24 hours. Stale entries carrying a valid HTTP-date emit `If-Modified-Since`; when `ETag` is also present the request sends both validators. Malformed values are preserved as response metadata but never emitted as conditional request headers. |
| `Age` | ❌ Not emitted | The cache does not synthesize an `Age` header on cached responses. Stored initial age includes origin transport response delay, measured from physical dispatch, but excludes local policy, admission, and quota waits. |

## Unsafe Method Invalidation

RFC 9111 §4.4 requires caches to invalidate stored responses for the
request target URI after a non-error response to an unsafe request method.
InnoNetwork applies that rule in `RequestExecutor` after refresh-token
replay has been decided and before response interceptors or status
validation run. Clients constructed from copies of one configuration share
the mutation fence for their configured cache:

| Trigger | Status | Behavior in 6.x |
| --- | --- | --- |
| `POST`, `PUT`, `PATCH`, `DELETE`, or any safety-unknown method with a `2xx` / `3xx` origin response | ✅ Honored | Calls `ResponseCache.invalidateTargetURI(_:)` for the normalized target URI when `responseCachePolicy.allowsCacheWrite` is true. |
| Unsafe method with `4xx` / `5xx` response or transport failure | ✅ Preserved | Existing cache entries are kept. |
| `.disabled` / `.networkOnly` cache policy | ✅ Preserved | Cache metadata stays untouched, matching the policy contract. |
| `Location` / `Content-Location` candidate URI invalidation | ❌ Not consumed | RFC 9111 marks these invalidations as MAY; 6.x limits the implementation to the mandatory target URI rule. |

## Directive-Aware Adapter (`rfc9111Compliant(wrapping:)`)

The 6.x line retains `ResponseCachePolicy.rfc9111Compliant(wrapping:)` as an
opt-in adapter. It wraps any existing policy
(`cacheFirst(maxAge:)`, `networkFirst`, `staleWhileRevalidate`, …) and
adds directive-aware behavior on top of the inner policy's freshness
window without changing the storage layer:

| Directive | Adapter behavior |
| --- | --- |
| `Cache-Control: no-store` | Forces `prepare(...)` to `.revalidate(nil)` regardless of the cached entry. |
| `Cache-Control: must-revalidate` | Demotes the inner policy's `.returnStaleAndRevalidate` into `.revalidate` — the stale window is denied. Fresh entries are unaffected. |
| `Cache-Control: max-age=N` | Clamps the inner policy's freshness window to `min(server max-age, inner max-age)`. The server can shorten the caller's window but never extend it. |
| `Expires` | When no valid `max-age` exists, derives freshness from `Expires - Date`, or `Expires - storedAt` if `Date` is absent. Invalid `Expires` or malformed/duplicate `max-age` is treated as stale. |
| `Last-Modified` | When no valid `max-age` or `Expires` exists, derives heuristic freshness from 10% of the apparent age (`Date` or `storedAt` minus `Last-Modified`), capped at 24 hours. Invalid or future dates fall back to the inner policy. |

Unknown directives, `private`, and the request-directive
matrix are still handled by the existing executor pipeline; the adapter
is intentionally narrow to keep the contract explicit.

The adapter is the recommended opt-in for clients that talk to backends
which emit cache directives the operator wants honoured (e.g. CDN
fronted by `no-store` on user-specific responses). The default policies
remain RFC 9111 non-compliant for backwards compatibility — see the
`PersistentResponseCache` docstring for the trade-off.

## Status Code Coverage

`PersistentResponseCache` mirrors the `RequestExecutor`'s default
`cacheableStatusCodes` set (RFC 9110 §15) for whole-response cacheability:

```
[200, 203, 204, 300, 301, 308, 404, 405, 410, 414, 501]
```

Notable exclusions:
- `206 Partial Content` is not stored. Range-aware caching is out of scope.
- `307 Temporary Redirect` is not stored even though it is technically
  cacheable when paired with `Cache-Control: max-age`. Storing it would
  silently change observed redirect behaviour, so 6.x refuses
  the cache write.

## Eviction and Privacy

These behaviours sit alongside RFC 9111 but are unique to the InnoNetwork
implementation:

| Behavior | Default | Configuration knob |
| --- | --- | --- |
| Total byte budget | 50 MB | `PersistentResponseCacheConfiguration.maxBytes` |
| Total entry budget | 1,000 | `maxEntries` |
| Per-entry hard cap | 5 MB | `maxEntryBytes` |
| Credential-like request keys | rejected | `storesAuthenticatedResponses`; `Authorization` entries also require `public`, `must-revalidate`, or `s-maxage` |
| `Set-Cookie` responses | rejected | `storesSetCookieResponses` |
| File protection class (iOS, tvOS, watchOS, visionOS) | `.completeUntilFirstUserAuthentication` | `dataProtectionClass` |
| Backup inclusion | cache-owned artifacts excluded; caller-supplied root unchanged | not configurable |
| Index durability | `.onCheckpoint` (no fsync) | `persistenceFsyncPolicy` |

The backup-exclusion boundary covers `bodies/`, `index.json`, a file-backed
HMAC key, and individual body files. It deliberately does not modify the
caller-supplied directory root, which may contain unrelated app data. The
cache reapplies backup-exclusion metadata after atomic writes and while
reopening existing storage. On iOS, tvOS, watchOS, and visionOS it also
reapplies the configured protection class; macOS treats that class as a no-op.

`statistics()` reports cumulative `hitCount` / `missCount` / `evictionCount`
since the actor was constructed; the counters seed from the open-time
scrubbing pipeline so the eviction count covers the entire actor
lifetime, not only post-init activity.

## Deviations Tracked Beyond 6.0

1. **`Cache-Control: max-age` consumption.** A future major could treat the
   response directive as a freshness signal, with `ResponseCachePolicy`
   acting as a per-client cap rather than the sole source of freshness.
2. **`stale-while-revalidate` directive parsing.** The runtime semantics
   already exist; a future major could also accept the response directive
   directly so APIs that emit it transparently get stale-while-revalidate
   behavior.
3. **`Age` header synthesis.** Some downstream caches (or operator tools)
   inspect the `Age` header to detect stale-while-revalidate hits; a future
   release could emit it on cache hits.

The full code path lives in
[`Sources/InnoNetwork/Cache/ResponseCachePolicy.swift`](../../Sources/InnoNetwork/Cache/ResponseCachePolicy.swift)
and
[`Sources/InnoNetworkPersistentCache/PersistentResponseCache.swift`](../../Sources/InnoNetworkPersistentCache/PersistentResponseCache.swift).
