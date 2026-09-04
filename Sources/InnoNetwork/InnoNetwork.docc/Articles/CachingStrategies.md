# Caching Strategies

``ResponseCachePolicy`` provides an opt-in executor-level cache for idempotent
`GET` requests. It is disabled by default and requires a ``ResponseCache``
implementation, such as ``InMemoryResponseCache``.

```swift
let cache = InMemoryResponseCache(maxBytes: 10 * 1024 * 1024)

let client = DefaultNetworkClient(
    configuration: .advanced(
        baseURL: URL(string: "https://api.example.com")!,
        cache: CachePack(
            responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
            responseCache: cache
        )
    )
)
```

Available modes:

- `.disabled` keeps the baseline request behaviour.
- `.networkOnly` always goes to the network and skips both cache reads and writes, so an existing cache stays untouched while callers still get fresh data.
- `.cacheFirst(maxAge:)` returns fresh cached data and revalidates stale cached data with `If-None-Match` when an ETag is present.
- `.staleWhileRevalidate(maxAge:staleWindow:)` returns stale data inside the stale window and refreshes it in the background.
- `.staleIfError(wrapping:)` permits an otherwise stale entry to recover an
  eligible transient failure only when the stored response carries a valid
  `stale-if-error=N` directive.
- `.requestOnlyIfCached(wrapping:)` consumes request `only-if-cached` and
  guarantees that the request will either use a reusable entry or fail locally
  without transport.

The two cache-control wrappers are additive opt-ins and may be nested with the
freshness policies in either order. For example:

```swift
let policy = ResponseCachePolicy.requestOnlyIfCached(
    wrapping: .staleIfError(
        wrapping: .rfc9111Compliant(
            wrapping: .cacheFirst(maxAge: .seconds(60))
        )
    )
)
```

`only-if-cached` accepts a fresh cache-first result or a response inside an
explicit stale-while-revalidate window; the latter is returned without its
usual background revalidation. A miss, an expired entry, or an entry marked
for mandatory revalidation throws a typed `NetworkError.configuration` before
signing or transport. Without the wrapper, InnoNetwork leaves the directive
origin-controlled and follows the normal cache/network path.

`stale-if-error` is evaluated after the configured retry policy reaches a
terminal decision. It covers only unacceptable `500`, `502`, `503`, and `504`
responses plus typed timeout and reachability failures. A later successful
retry always wins. Cancellation, trust, configuration, decoding,
response-interceptor, and response-body-limit failures never use the fallback.
Malformed, missing, or duplicate `stale-if-error` values fail closed, as do
`no-store`, `must-revalidate`, and entries beyond the advertised window.

When the server responds with `304 Not Modified`, InnoNetwork substitutes the
cached body before status validation and decoding for conditional cache modes.
GET responses with RFC-cacheable whole-response status codes (`200`, `203`,
`204`, `300`, `301`, `308`, `404`, `405`, `410`, `414`, and `501`) are eligible
for storage. `206 Partial Content` is intentionally excluded because range
semantics require a different representation model.

Cache entries are keyed by HTTP method, absolute URL, and representation
headers that affect privacy or request identity. Credential-like headers such as
`Authorization` and `Cookie` are included as SHA-256 fingerprints rather than raw
values, and `Accept-Language` is included so locale-specific responses do not
cross-pollute. URL fragments are ignored because they are not sent to the server.
Responses to requests carrying `Authorization` are stored only when the origin
explicitly permits it with `Cache-Control: public`, `must-revalidate`, or
`s-maxage`.
The cache-control wrappers do not relax this admission rule or cache-key
partitioning: authenticated stale recovery still requires an admitted entry
for the same credential identity and an explicit origin directive.

## Scope and offline storage

``ResponseCachePolicy`` is an executor-level response reuse policy, not a
general offline database. It is a good fit when:

- the request is an idempotent `GET`
- the response body can be reused as one HTTP representation
- freshness can be expressed with a caller-provided max age, ETag
  revalidation, or stale-while-revalidate window
- cache lifetime can remain process-local through ``InMemoryResponseCache``

Use app-owned persistent storage when cached data needs domain indexing,
offline mutation, conflict resolution, cross-launch browse/search, or user
visible "downloaded for offline" semantics. In those cases, let InnoNetwork
fetch and validate transport responses, then project the decoded model into
SwiftData, Core Data, SQLite, files, or another app-owned store.

Persistent response caching ships as the optional `InnoNetworkPersistentCache`
companion product rather than being part of the core `InnoNetwork` target. Its
first-party disk cache defines these policies explicitly:

- cache key normalization and configurable Vary/identity inputs
- freshness precedence between caller policy, `Cache-Control`, and validators
- eviction by byte budget, age, and user/account boundary
- privacy defaults for credential-derived keys and sensitive payloads
- iOS-family data protection class and explicit deletion hooks. Selecting
  `.none` requests `NSFileProtectionNone` on cache-owned paths on iOS, tvOS,
  watchOS, and visionOS; other platforms treat the class as a no-op.

InnoNetwork honours response cache-control directives that affect storage and
reuse:

- `Cache-Control: no-store` responses are not stored and invalidate the current
  key if an older entry exists.
- `Cache-Control: private` responses are treated as do-not-store by the built-in
  executor and the persistent companion cache.
- `Cache-Control: no-cache` responses may be stored, but every lookup must
  revalidate before reuse even inside the caller-provided freshness window.
- `ResponseCachePolicy.rfc9111Compliant(wrapping:)` additionally consumes
  `Cache-Control: max-age`, `Expires`, and `Last-Modified` as freshness
  signals, using `Expires - Date` or `Expires - storedAt` when no valid
  `max-age` exists and applying the RFC 9111 §4.2.2 10% heuristic when only
  `Last-Modified` is available.
- Successful unsafe methods (`POST`, `PUT`, `PATCH`, `DELETE`, and unknown
  methods) invalidate all cached variants for the normalized target URI. This
  implements the RFC 9111 §4.4 target-URI requirement; `Location` and
  `Content-Location` candidate invalidation remains out of scope.

The response `Vary` header is processed automatically. `Vary: *` responses are
not stored, while concrete `Vary` headers capture a snapshot of the named request
headers and require those values to match on later lookup.

A `304 Not Modified` reply confirms freshness of the stored representation, but
its own `Vary` header describes the variant the origin would have served on a
full `200`. When the 304 carries a `Vary` value that differs from the snapshot
captured when the entry was stored, InnoNetwork preserves the existing entry
verbatim and only refreshes its `storedAt` timestamp instead of rewriting the
entry under the new vary dimension. This keeps the stored representation
addressable through its original vary signature; later 200 responses with the
revised `Vary` are stored as new entries through the normal write path.

Request coalescing can be enabled separately with ``RequestCoalescingPolicy``:

```swift
let client = DefaultNetworkClient(
    configuration: .advanced(
        baseURL: URL(string: "https://api.example.com")!,
        resilience: ResiliencePack(coalescing: .getOnly)
    )
)
```

Coalescing shares one raw transport result among identical in-flight requests;
each waiter still decodes independently. Non-`GET` methods are excluded by the
default `.getOnly` policy.

Use ``CircuitBreakerPolicy`` when repeated per-host failures should short-circuit
before transport:

```swift
let configuration = NetworkConfiguration.advanced(
    baseURL: URL(string: "https://api.example.com")!,
    resilience: ResiliencePack(
        circuitBreaker: CircuitBreakerPolicy(
            failureThreshold: 3,
            windowSize: 5,
            resetAfter: .seconds(30)
        )
    )
)
```

Open-circuit failures are wrapped in ``CircuitBreakerOpenError`` and surfaced
through ``NetworkError/underlying(_:_:)`` so no new ``NetworkError`` enum case is
required.
