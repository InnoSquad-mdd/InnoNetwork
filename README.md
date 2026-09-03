# InnoNetwork

[![CI](https://github.com/InnoSquadCorp/InnoNetwork/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/InnoSquadCorp/InnoNetwork/actions/workflows/ci.yml)
[![TSAN Nightly](https://github.com/InnoSquadCorp/InnoNetwork/actions/workflows/tsan.yml/badge.svg?branch=main)](https://github.com/InnoSquadCorp/InnoNetwork/actions/workflows/tsan.yml)
[![Nightly Live Smoke](https://github.com/InnoSquadCorp/InnoNetwork/actions/workflows/nightly-live.yml/badge.svg?branch=main)](https://github.com/InnoSquadCorp/InnoNetwork/actions/workflows/nightly-live.yml)
[![codecov](https://codecov.io/gh/InnoSquadCorp/InnoNetwork/branch/main/graph/badge.svg)](https://codecov.io/gh/InnoSquadCorp/InnoNetwork)
[![DocC](https://img.shields.io/badge/docs-DocC-blue)](https://innosquadcorp.github.io/InnoNetwork/)
[![Swift](https://img.shields.io/badge/Swift-6.2-orange)](https://swift.org)
[![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen)](https://swift.org/package-manager)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2016%20%7C%20macOS%2014%20%7C%20tvOS%2016%20%7C%20watchOS%209%20%7C%20visionOS%201-lightgrey)](#platform-matrix)
[![Supply Chain](https://img.shields.io/badge/supply%20chain-SHA--pinned%20Actions%20%2B%20Dependabot-blue)](#production-checklist)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

InnoNetwork is a Swift package for type-safe networking on Apple platforms.
Most applications import only the root `InnoNetwork` product and use three
concepts:

1. an explicit endpoint `struct` that owns inputs and `APIResponse`
2. `@APIDefinition` to derive and validate repetitive protocol witnesses
3. `DefaultNetworkClient.request(_:)` to execute the typed request

Everything else—including the 6.0 contract preview, Download, Upload, raw or system-managed HLS, WebSocket,
persistent cache, OpenAPI, AWS signing, pinning, and test support—is an
optional product selected only when that capability is required.

> **Release status:** `5.1.0` is the latest tagged stable release and the
> actively security-supported line. The API examples below describe the 5.x
> contract and may not compile against 4.x.

## Product Selection Guide

| Product | Use When |
| --- | --- |
| `InnoNetwork` | Start here for named typed HTTP endpoints and the async request pipeline. Advanced policy remains opt-in. |
| `InnoNetworkNext` | Preview the 6.0 operation, failure, and configuration contracts while reusing existing 5.x endpoints and clients. |
| `InnoNetworkAuthAWS` | You need the optional AWS SigV4 reference signer. It is a single-shot signer, not an AWS SDK replacement. |
| `InnoNetworkDownload` | You need foreground/background download lifecycle management with pause, resume, retry, persistence, and event streams. |
| `InnoNetworkUpload` | You need file-backed foreground/background uploads with progress, restoration, bounded responses, and typed decoding. |
| `InnoNetworkHLS` | You need bounded HLS playlist resolution, deterministic variant selection, browser-free non-DRM VOD assembly, or typed retry and recovery diagnostics. |
| `InnoNetworkHLSLive` | You need blocking reloads, delta-window reconstruction, bounded snapshots, or atomic live DVR capture. |
| `InnoNetworkHLSAVFoundation` | You need AVFoundation-managed background HLS persistence, media selections, a value-only integrated interstitial timeline, playback health, an app-owned FairPlay content-key setup, or system-download lifecycle diagnostics. |
| `InnoNetworkHLSAudio` | You need demand-driven decoded PCM or in-place full-mix processing from an HLS player item on supported version 27 platforms. This product requires Xcode 27 and Swift 6.4. |
| `InnoNetworkWebSocket` | You need long-lived bidirectional connections with heartbeat, reconnect, close taxonomy, and event delivery. |
| `InnoNetworkPersistentCache` | You want `ResponseCache` backed by disk with conservative RFC-aware storage guards and data protection. |
| `InnoNetworkOpenAPI` | Use `OpenAPIRequest` when generated or hand-written operations should run through the full `DefaultNetworkClient` pipeline. Use `InnoNetworkClientTransport` when an OpenAPI Runtime client needs a thin URLSession-backed transport and the full pipeline is not required. |
| `InnoNetworkTrust` | You need optional public-key pinning via `PublicKeyPinningEvaluator` and `TrustPolicy.custom(_:)`. |
| `InnoNetworkTestSupport` | You need consumer-test helpers such as `MockURLSession`, `StubNetworkClient`, or WebSocket recorders. Do not link it into production binaries. |

For application API catalogs, start with an explicit endpoint struct and the
default-enabled `@APIDefinition` macro. The struct remains the source of truth;
the macro derives repetitive witnesses and fails the build when method, path,
payload, response, or auth declarations are incomplete. Use `EndpointBuilder`
for one-off or runtime-composed requests that do not deserve a named contract.

### Small-app baseline

Start with only the `InnoNetwork` product and
`DefaultNetworkClient(baseURL:)`. A named endpoint struct plus
`@APIDefinition` needs no configuration pack or optional product. Add an
advanced pack only when a concrete retry, auth, cache, transport, or
observability requirement appears; add the 6.0 preview, Download, Upload, WebSocket, persistent cache,
the HLS assembler, AVFoundation HLS, OpenAPI, AWS auth, or pinning products only
for the capability named in the table above. If the application has only one
or two uncomplicated requests and no shared policy, direct `URLSession` is
intentionally the smaller choice.

Applications that prefer manual `APIDefinition` conformances can disable the
macro target with `traits: []`. This is an opt-out for build topology, not a
second runtime API.

The packages are built around Swift Concurrency, explicit transport
policies, and operational visibility that can scale from app prototypes
to production clients.

## Why InnoNetwork

Five things that differentiate this library from the usual URLSession
wrapper or Alamofire-style helper:

- **`typed throws` end-to-end** — `NetworkClient.request(_:)` is declared as
  `async throws(NetworkError)`, so call-sites get a concrete error type
  in `catch` without losing classification. Foreign errors are mapped at
  a single narrow boundary so the typed-throws invariant holds.
- **Phantom-typed HTTP headers** — `HTTPHeader<Value>` keys carry their
  value type at compile time (e.g. `.contentType`, `.authorization`,
  custom phantom keys). Typos and value/type mismatches fail at build,
  not at runtime.
- **Explicit session authentication** — every endpoint declares
  `SessionAuthentication` as `.anonymous`, `.optional`, or `.required`.
  Required endpoints fail before transport when no refresh policy can provide
  a token; the single-flight `RefreshTokenPolicy` only refreshes endpoints
  that opted in and can isolate token, refresh, generation, and cooldown state
  with a per-request `AuthenticationRealm`.
- **Single-flight refresh + idempotency-aware retry** — concurrent 401s
  coalesce into one refresh call (`RefreshTokenCoordinator`). Retries
  follow RFC 9110: `GET`, `HEAD`, `OPTIONS`, and `TRACE` retry by default;
  unsafe methods retry only when an `Idempotency-Key` header is present.
  `Retry-After` is parsed for all three RFC 9110 formats with a
  maximum-clamp against malicious headers.
- **RFC 9111-aware cache adapter + first-class test support** — opt into
  `rfc9111Compliant(wrapping:)` to get the documented directive subset, or
  drop in `MockURLSession` / `VCRURLSession` / `StubNetworkClient` from
  `InnoNetworkTestSupport` (a top-level product, not a hidden helper).

Production controls remain composable: use `RateLimitExecutionPolicy` for
client-side fixed-window pacing and `SemanticNetworkEventAdapter` to translate
redacted request lifecycle events into exporter-neutral semantic attributes.

See `API_STABILITY.md` for the Stable / Provisionally Stable contract
around each of these.

> ⚠️ **Apple platforms only by design.** InnoNetwork builds on URLSession, `OSAllocatedUnfairLock`, OSLog, and Network.framework, none of which match Apple-platform behaviour on Linux. Linux/server-side Swift is **not** a supported target. See [docs/PlatformSupport.md](docs/PlatformSupport.md) for the rationale and for guidance on sharing models with Linux server code (e.g. Vapor).

> 📚 **API Reference (DocC):** https://innosquadcorp.github.io/InnoNetwork/
> 🇰🇷 **한국어 문서:** [docs/ko/README.md](docs/ko/README.md)

## Choosing the Right Entry Point

InnoNetwork ships several layers. Pick the highest one that preserves the
contract your application needs. Most app teams should use macro-assisted,
explicit `APIDefinition` structs for their API catalog.

```text
Does this endpoint belong in the application's named API catalog?
├─ yes ─► @APIDefinition on an explicit struct
│          (the struct owns inputs, APIResponse, and any custom policy)
└─ no
   │
   Is it a one-off or runtime-composed HTTP request?
   ├─ yes ─► EndpointBuilder
   └─ no
      │
      Does it need multipart, streaming, or generated OpenAPI transport?
      ├─ yes ─► MultipartAPIDefinition / StreamingAPIDefinition / InnoNetworkOpenAPI
      └─ no
         │
         Are you building an SDK or library wrapper that needs raw
         transport hooks (no decoding, no interceptors)?
         └─ yes ─► LowLevelNetworkClient (@_spi(GeneratedClientSupport))
                   — minor-version-mutable surface, see API_STABILITY.md
```

### When NOT to use InnoNetwork

- **Linux / server-side Swift.** InnoNetwork is Apple-platform-only by
  design (URLSession, `OSAllocatedUnfairLock`, OSLog, Network.framework).
  Use AsyncHTTPClient or a server framework on Linux.
- **One-off scripts where URLSession's three-line GET is enough.** The
  type-safety surface only pays off once you have shared interceptors,
  retry/coalescing/cache policies, or a fleet of endpoints.
- **Push-style protocols outside HTTP and WebSocket.** gRPC, MQTT,
  WebTransport are out of scope; pair InnoNetwork with a dedicated
  client.
- **You need synchronous APIs.** The package is built on Swift
  Concurrency end-to-end; there is no `DispatchQueue`/completion-handler
  fallback.

## Quick Start

### Install

For released applications, consume the tagged 5.x line:

```swift
dependencies: [
    .package(
        url: "https://github.com/InnoSquadCorp/InnoNetwork.git",
        .upToNextMajor(from: "5.1.0")
    )
]
```

> InnoNetwork also intentionally requires Swift 6.2+ and current Apple OS
> baselines (iOS 16, macOS 14, tvOS 16, watchOS 9, visionOS 1). That keeps
> the package aligned with strict concurrency and modern URLSession behavior,
> but apps with older deployment targets should keep a thin compatibility
> client until they can raise their platform floor.

### First 30 Minutes: Explicit Endpoints, Macro-Assisted

The following API uses the released 5.x contract. For the previous 4.x API,
start with the 4.0 release and migration documents instead.

```swift
import Foundation
import InnoNetwork

struct User: Decodable, Sendable {
    let id: Int
    let name: String
}

struct CreatePost: Encodable, Sendable {
    let title: String
    let body: String
}

struct Post: Decodable, Sendable {
    let id: Int
    let title: String
}

@APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
struct GetUser {
    typealias APIResponse = User

    let id: Int
}

@APIDefinition(method: .post, path: "/posts", auth: .anonymous)
struct CreatePostEndpoint {
    typealias APIResponse = Post

    let body: CreatePost
}

let client = DefaultNetworkClient(
    baseURL: URL(string: "https://api.example.com/v1")!
)

let user = try await client.request(GetUser(id: 1))
let created = try await client.request(
    CreatePostEndpoint(body: CreatePost(title: "Hello", body: "World"))
)

print(user)
```

`GetUser` and `CreatePostEndpoint` remain ordinary, explicit value types. The
macro adds `APIDefinition` conformance, `method`, `path`, and the simple
`Parameter` / `parameters` witnesses. `APIResponse` stays visible, and every
attribute must choose `auth: .anonymous`, `.optional`, or `.required`; the
macro never guesses a security boundary. A stored `query` is inferred for GET
and HEAD; a stored `body` is inferred only for POST, PUT, PATCH, and DELETE.
OPTIONS, CONNECT, TRACE, custom, and dynamic methods require a complete
`Parameter` + `parameters` payload contract.

Path placeholder values must be non-optional. Direct `T?`, `Optional<T>`, and
`Swift.Optional<T>` spellings fail during macro expansion; aliases that resolve
to an Optional fail at the generated call site with the same targeted guidance
to unwrap the value and define its nil behavior.

Use `EndpointBuilder` when a request is genuinely local or runtime-composed:

```swift
let previewPath = "/users/preview"
let preview = try await client.request(
    EndpointBuilder<User>
        .get(previewPath)
        .authentication(.anonymous)
)
```

`DefaultNetworkClient(baseURL:)` is exactly the `safeDefaults` client path.
Move to `init(configuration:)` only when the server contract requires an
explicit policy. `EndpointBuilder<Response>.get/post/...` infers the default
JSON response decoder from `Response`; the existing `.decoding(_:)` promotion
remains available when builder composition starts from `EmptyResponse`.

For a custom payload, declare the complete `Parameter` + `parameters` pair.
It is the authoritative escape hatch; headers, interceptors, transport,
decoding, and policy overrides likewise stay explicit on the struct.

```swift
struct UserPatch: Encodable, Sendable {
    let displayName: String
}

@APIDefinition(method: .patch, path: "/me", auth: .anonymous)
struct UpdateUser {
    typealias Parameter = UserPatch
    typealias APIResponse = User

    let patch: UserPatch

    var parameters: Parameter? { patch }

    var transport: TransportPolicy<User> {
        .json(decoder: snakeCaseDecoder)
    }
}
```

`APIDefinition` exposes one transport-shape entry point —
`transport: TransportPolicy<APIResponse>`. For macro-assisted simple payloads,
GET and HEAD use `.query()`, while POST, PUT, PATCH, and DELETE use `.json()`.
Other methods keep their payload and any non-default transport explicit on the
endpoint struct.

```swift
let patched = try await client.request(
    UpdateUser(patch: UserPatch(displayName: "Taylor"))
)
```

The macro comes from `import InnoNetwork` through the package's default
`Macros` trait. No separate codegen package or import is required. Consumers
that never use macros can set `traits: []` on the InnoNetwork package
dependency; this removes the macro declaration and compiler plug-in products
from their target graph and compilation. SwiftPM may still resolve or fetch
the package-level `swift-syntax` dependency while evaluating the manifest.
Traits are unified per package across the resolved graph, so every dependency
path must keep `Macros` disabled; another dependency that enables the default
trait re-enables it for that package instance.

Tuist XcodeProj integration must include SwiftPM package-trait support. The
5.0 adopter smoke is verified with Tuist 4.202.5; Tuist 4.67.2 ignores the
conditional macro dependency and reports `unknown attribute 'APIDefinition'`.
Upgrade Tuist (or use Xcode's native SwiftPM integration) before migrating a
Tuist-generated project.

### Advanced Surfaces

Use these after the first request path is stable:

- `MultipartAPIDefinition` for upload payloads that need explicit part
  boundaries, metadata, and retry idempotency.
- `StreamingAPIDefinition` for SSE, NDJSON, logs, or other line-delimited
  long-lived responses.
- `InnoNetworkWebSocket` for bidirectional realtime flows.
- `InnoNetworkOpenAPI` for generated clients or OpenAPI Runtime transport.
- `InnoNetworkPersistentCache` when an API needs on-disk RFC-aware response
  caching beyond the in-memory default.

### Download

```swift
import Foundation
import InnoNetworkDownload

// Construct one DownloadManager per feature (or per policy). Each
// instance binds a unique URLSession identifier and DownloadConfiguration,
// so a media downloader can be WiFi-only and resumable while a documents
// downloader uses a different retry budget.
let manager = try DownloadManager(
    configuration: .safeDefaults(sessionIdentifier: "com.example.app.media")
)
let task = await manager.download(
    url: URL(string: "https://example.com/file.zip")!,
    toDirectory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
)

for await event in await manager.events(for: task) {
    print(event)
}

// The owner closes the lifecycle explicitly. This cancels and removes
// persisted in-flight work, drains admitted callbacks/events, and releases
// the manager's session and persistence scope.
await manager.shutdown()
```

`safeDefaults` and `advanced` use the secure foreground session mode. Call
`backgroundTransfersEnabled()` on the finished configuration only when
transfers must continue outside the app process; see the background-mode
redirect trade-off below and in the
[background download guide](Sources/InnoNetworkDownload/InnoNetworkDownload.docc/Articles/BackgroundDownloads.md).

> The 4.0.0 line removes the global `DownloadManager.shared` singleton —
> every feature now constructs and owns its own manager via
> ``DownloadManager/init(configuration:)`` with a unique session identifier.
> The throwing initializer surfaces ``DownloadManagerError`` (e.g.,
> `duplicateSessionIdentifier`) directly so the failure mode is explicit.

#### Destination filename policy

`download(url:toDirectory:fileName:)` resolves the destination as:

- If `fileName:` is provided, it is trimmed and used only when it is a safe
  single path component.
- Otherwise the URL's last path component (`url.lastPathComponent`) is used
  when it is a safe single path component.
- Empty names, `.`, `..`, or names containing `/`, `\`, or NUL fall back to a
  generated `download-<UUID>` filename under `directory`.
- The library does **not** rename on collision — if a file already exists at the resolved
  path, the download will overwrite it once it completes. Pass an explicit `fileName:` (for
  example, prefixed with the task UUID) when concurrent or repeated downloads to the same
  directory must coexist.

For absolute control over the destination path, use `download(url:to:)` instead and
construct the target URL yourself.

### WebSocket

```swift
import Foundation
import InnoNetworkWebSocket

let manager = WebSocketManager(configuration: .safeDefaults())
let task = await manager.connect(
    url: URL(string: "wss://echo.example.com/socket")!
)

for await event in await manager.events(for: task) {
    print(event)
}
```

## Products

### `InnoNetwork`

- async/await request execution
- type-safe `APIDefinition` modeling
- JSON, form-url-encoded, and multipart request support
- retry coordination, stable idempotency keys, auth refresh, request coalescing, response cache, and circuit breaker policies
- streaming-by-default inline response buffering and public `RequestExecutionPolicy` hooks
- W3C `traceparent` propagation and curl command export helpers
- explicit `.anonymous`, `.optional`, and `.required` session authentication
  through `APIDefinition` and `EndpointBuilder`
- trust policy support and request lifecycle observability

### `InnoNetworkDownload`

- foreground and background download orchestration
- pause, resume, retry, and listener retention across retries
- append-log persistence for durable task restoration
- `AsyncStream` and listener-based event delivery

### `InnoNetworkUpload`

- file-backed foreground and background `URLSessionUploadTask` orchestration
- pre-registered progress and terminal event streams
- background system-task restoration through opaque logical identifiers
- bounded response capture with `AnyResponseDecoder` integration
- HTTPS-only admission, foreground redirect checks, and background rejection
  of redirect-sensitive authorization or cookie headers

### `InnoNetworkHLS`

- bounded UTF-8 HLS playlist fetch and parsing through the shared transport
  policy
- value-redacted structured playlist inspection with deterministic severity,
  operation scope, one-based source lines, and separate single-file/offline
  capability flags
- bounded presentation-graph inspection that fetches referenced variants and
  renditions with deterministic indices, then diagnoses draft-22 target,
  playlist type, timeline, program-date-time, Date Range, discontinuity, and
  server-control consistency without loading media segments
- opt-in Apple-oriented authoring guidance for target duration, independent
  segments, TLS, variant ordering, codecs, average bandwidth, resolution,
  frame rate, mixed dynamic range, score consistency, caption language,
  Content Steering identity, LL-HLS timeline/hold-back, and feature-compatible
  protocol versions without changing runtime capability
- HLS 2nd Edition `EXT-X-DEFINE` substitution for local values, explicit
  multivariant-to-media imports, and final-redirect URL query parameters,
  with compatibility-version and expanded-size validation
- typed multivariant `EXT-X-SESSION-DATA` and `EXT-X-SESSION-KEY` inspection,
  including resolved resource URLs, language variants, key formats and IVs,
  without fetching or persisting key bytes
- HLS 2nd Edition draft-22 inspection for media target, media/discontinuity
  sequences, playlist mutability, per-segment `EXT-X-BITRATE`, plus typed
  variant `HDCP-LEVEL`, `ALLOWED-CPC`, and specialized
  `REQ-VIDEO-LAYOUT`; unsupported video ranges/layouts make only the affected
  variant ineligible
- typed Low-Latency HLS server control, partial-segment targets and ranges,
  preload hints, rendition reports, and delta-update metadata with
  relationship validation and operation-scoped persistence diagnostics
- bounded HLS Content Steering manifest resolution with TTL/reload caching,
  declared and cloned pathway priority, host/query/stable-ID URI replacement,
  deterministic playlist-resolution failover, conservative transfer-time
  failover for stable-ID/resource-plan-equivalent pathways, session-scoped
  failure penalty/cooldown recovery, value-redacted pathway health and typed
  selection-reason events, and explicit opt-outs
- relative variant URL resolution and explicit highest-quality,
  lowest-bandwidth, resolution-cap, bandwidth-cap, or declared playback-
  capability selection
- typed audio/video/subtitle/closed-caption rendition metadata and
  deterministic default, name, or BCP 47 language selection; HLS 2nd Edition
  stable IDs, associated languages, accessibility characteristics, audio
  format hints, author score, supplemental codecs, pathway metadata, and a
  separate I-frame trick-play variant collection; generated and translated
  characteristics are typed, with an opt-in subtitle exclusion/preference
  policy that composes with explicit language and name selection
- bounded-parallel MPEG transport-stream or fragmented-MP4 prefetch with
  playlist-ordered assembly
- per-resource and whole-download byte budgets, required/best-effort/disabled
  destination-volume capacity policy with write-time reservation, and
  determinate/indeterminate progress
- automatic, destination-scoped resume checkpoints at durable media-resource
  boundaries, with stale-plan invalidation and opt-out
- core `RetryPolicy`-driven transient media-resource retry, backoff, and retry
  event delivery through `NetworkRequestContext`
- caller-injected sessions plus purpose-aware request policy for entry/media
  playlists, live reloads, media payloads, AES keys, Steering manifests,
  Session Data, localized rendition names, chapter documents, interstitial
  asset lists, Date Range preloads, and schedules; typed HLS
  request events are value-redacted by construction, while the existing
  untyped authentication adapter remains source-compatible
- opt-in `HLSExternalResourceResolver` for inline or bounded JSON/raw Session
  Data, typed localized rendition names, Apple JSON chapters, and ordered
  Apple interstitial asset lists, with explicit byte,
  localization/chapter/asset-entry, timeout, schema, and HTTP-status failures;
  rendition-name lookup follows ordered locale preferences and authored-name
  fallback, while chapter image references resolve from the final JSON
  response URL without HTTPS downgrade or URL credentials and chapter
  catalogs expose preferred-language titles, image-category lookup, available
  title languages, and overlap-aware active chapters for custom player UI
- typed interstitial coordinated-playback variability, timeline
  occupancy/style, navigation restrictions, and skip-control presentation
  metadata, including bounded asset-list overrides for custom player UI
- in-process and OS-backed cross-process destination admission, with atomic
  final-file or offline-package commit
- strict byte-range/CMAF response validation and contiguous-range coalescing
- identity-format AES-128-CBC/PKCS#7 decryption with exact 16-byte key
  validation, explicit or media-sequence IVs, post-adapter `no-store`
  memory-only key handling, and key-fingerprint-bound resume invalidation;
  parallel `KEYFORMAT` declarations stay isolated across complete and LL-HLS
  resource contexts, and a usable identity alternative wins independent of
  declaration order; an opt-in `HLSTransferPack` policy overlaps at most four
  identity `EXT-X-SESSION-KEY` requests with media-playlist resolution, reuses
  only selected-media keys, and leaves `prepare()` free of key I/O
- typed rejection for live, SAMPLE-AES/FairPlay, separate-audio,
  discontinuous, gapped, I-frame-only, or multiple-initialization layouts
  during raw single-file assembly
- AVFoundation-readable MPEG-TS and fragmented-MP4 assembly fixtures, pinned
  by SHA-256 and container/packet structure checks
- deterministic parser mutations, sub-quadratic large-playlist scaling,
  concurrent live-stream isolation, and AVFoundation event terminal-race
  gates, plus an actual loopback HTTP `AVPlayer` decoded-PCM smoke on macOS 27
  or newer; run them independently with
  `bash Scripts/run_hls_quality_gates.sh`. Older hosts report the runtime smoke
  as `NOT RUN`
- opt-in Apple Media Stream Validator and HLS Report validation for the pinned
  MPEG-TS, video fragmented-MP4, and audio fragmented-MP4 fixtures. Install
  Apple's separate HTTP Live Streaming Tools download, then run
  `bash Scripts/run_hls_quality_gates.sh --require-apple-tools`; ordinary runs
  print `NOT RUN` when the tools are absent, while the full local release
  preflight requires both Apple conformance and the supported runtime smoke
- stable `HLSDownloadErrorCode`/`CustomNSError` telemetry and preserved
  `SendableUnderlyingError` transport context
- advisory `prepare` metadata before destination selection, event-stream
  downloads for progress, committed receipts, and `downloadFile` for URL-only
  one-shot callers
- atomic offline package directories for a selected primary stream plus
  opt-in external video and I-frame trick-play streams alongside audio and
  subtitle renditions, with local media/master playlists, exact byte-range
  localization, a URL-free schema 3 manifest, preserved rendition
  accessibility/audio-format metadata, and per-file SHA-256 records
- stateless offline-package reopening and validation through
  `HLSOfflinePackageStore`; current packages verify structure, local playlist
  closure, exact file membership, and checksums while schema 1/2 packages
  receive legacy structural validation
- Content-Steered offline planning requires stable variant and external-
  rendition IDs across every eligible pathway before media transfer; retained
  I-frame variants receive the same cloning, failover, and stable-ID checks
- explicit plural rendition policy (`defaultOrFirst`, preferred languages,
  names, all, or disabled), generated/translated subtitle filtering, typed
  provenance retained in the manifest, and package-level preparation,
  progress, and receipt surfaces
- destination-scoped offline-package resume checkpoints at durable individual-
  resource boundaries; stale playlist, rendition, resource, validator, or
  AES-key plans are discarded, while partial state remains implementation-
  private and final directory commit stays atomic
- local package receipts expose a typed playback source for the companion's
  loopback-only `HLSLocalPlaybackAsset`; arbitrary `file://` HLS trees remain
  unsupported, while system-managed downloads remain available for native
  background persistence

### `InnoNetworkHLSLive`

- direct media or multivariant live entry with deterministic variant
  selection, selected-pathway/rendition metadata, one-shot snapshots, and a
  bounded-memory `AsyncThrowingStream`
- negotiated `_HLS_msn`, `_HLS_part`, and `_HLS_skip` requests based on typed
  `EXT-X-SERVER-CONTROL` capabilities
- freshness-aware LL-HLS CDN tune-in: an initial cached `Age` response drives
  bounded `_HLS_msn`/`_HLS_part` estimation from target and part durations;
  the full entry request removes prior `_HLS_*` reload directives while
  preserving other caller query items;
  malformed or failed optional responses retain the latest valid snapshot,
  while `HLSLiveCDNTuneInPack` can tune or disable the behavior
- media-sequence reconstruction of skipped complete segments and active Date
  Ranges, with one query-clean full-reload recovery when history is missing
- per-snapshot reload-mode attribution plus a pure, caller-clocked live-health
  analyzer for edge regression, stagnation, hold-back latency, repeated delta
  recovery, pathway instability, typed HTTP freshness, and live-window loss
  risk; raw header strings stay private and recovery/UI policy remain
  application-owned
- polling fallback with finite timing bounds when blocking reload is not
  advertised
- uncached reload transport, typed `livePlaylistReload` request purpose, and
  inherited URL admission, redirect, request-policy, and playlist body limits
- final `EXT-X-ENDLIST` snapshot delivery followed by deterministic stream
  completion
- compatible Content Steering recovery for reload failures, requiring stable
  variant identity and using matching rendition reports for low-latency
  tune-in, retaining compatible candidates for cooldown re-entry without
  exposing signed request values in pathway events
- bounded record-from-now or current-window DVR capture for complete TS and
  fMP4 segments, with exact byte-range validation, URL-free local VOD
  playlists, progress events, cross-process destination leases, and atomic
  directory commit
- opt-in LL-HLS DVR part staging from an independent part zero, with count and
  byte bounds, exact range validation, temporary-progress metadata, parent-
  duration proof before promotion, and complete-segment fallback without
  exposing partial files in the committed package
- opt-in clear-media `PART` and `MAP` hint preloading with per-resource and
  aggregate byte bounds, open-ended range validation, exact discontinuity,
  initialization-map, and encryption-context confirmation, cancellation-safe
  temporary storage, and ordinary-request fallback on every mismatch or
  transfer failure; progress and receipts expose separate value-redacted
  request, completion, confirmation, reuse, miss, failure, cancellation,
  discard, and byte counters for parts and initialization maps
- recording-scoped, memory-only identity AES-128 key reuse and rotation,
  explicit or media-sequence IV decryption, encrypted fMP4 maps, and plaintext-
  only local packages that never persist key declarations or source key URLs
- fMP4 initialization-map rotation for primary and external rendition tracks,
  with deduplicated local map files, segment-accurate `EXT-X-MAP` boundaries,
  and map-aware LL-HLS part promotion
- complete `EXT-X-GAP` preservation for primary and external rendition tracks;
  unavailable media is never requested or synthesized, local playlists retain
  the timeline with safe placeholder paths, and primary progress plus receipts
  expose a typed gap count
- opt-in rolling DVR retention that evicts a complete oldest presentation
  prefix while recording continues; sequence-stable local names prevent reuse,
  unreferenced fMP4 maps and aligned rendition resources are reclaimed only
  after a replacement checkpoint is durable, and progress plus receipts expose
  cumulative primary count, duration, and all-track byte eviction statistics
- on-demand in-progress DVR playback snapshots at the next coherent complete-
  segment boundary; each request atomically publishes an independent URL-free
  VOD package for the existing local-playback bridge while recording and
  rolling eviction continue, with eight bounded outstanding requests, isolated
  cancellation, and typed terminal or capacity failures
- opt-in Apple HLS interstitial DVR packaging that rewrites direct assets and
  ordered asset lists into complete package-local offline HLS assets; event,
  asset, playlist, resource, and aggregate byte bounds stay explicit,
  complete-event omission never publishes a partial reference, and progress
  plus receipts expose value-redacted retained and omitted statistics
- Apple Date Range Schedules expand through the same bounded resolver when
  interstitial packaging is enabled; nested members preserve server order,
  reloads reuse one in-memory resolution, source changes fail closed, and no
  schedule `X-URI` reaches the recording or recovery checkpoint
- eligible `com.apple.hls.preload` declarations can seed a later Date Range
  Schedule without a second request; at most 32 bounded 256 KiB resources are
  retained in memory, failed or stale preloads fall back to the authoritative
  schedule URL, and preload bytes never enter the package or checkpoint
- rolling interstitial expiry removes each event directory atomically;
  recovery checkpoints keep only query-free source hashes and local file
  proofs, and in-progress playback snapshots freeze the complete asset-list
  and playlist graph before publication
- bounded external audio, alternate-video, and subtitle selection by default,
  preferred languages, exact names, or all referenced renditions; URL-free
  local master playlists expose one package entry point plus typed local-track
  metadata, and Content Steering failover requires stable rendition identity
- retained Program Date Time and self-contained standard Date Ranges for the
  recorded interval, with atomic rejection when redacted extension values,
  non-schedule external timeline resources, or an incomplete rendition cannot
  be preserved
- configurable destination-capacity enforcement plus typed key status,
  key-length, decryption, and storage failures
- opt-in, URL-free recovery checkpoints at coherent complete-segment
  boundaries; rolling multi-track snapshots align before publication, and
  signed query values may rotate while source path, selected
  variant, renditions, per-segment initialization-map assignments, file sizes,
  and SHA-256 digests are revalidated before resume, and AES-128 keys are always
  fetched again
- one-shot or controllable resume with a caller-supplied current source URL,
  plus explicit checkpoint discard; a moved live window fails with the typed
  `liveWindowAdvanced` result and final publication remains one atomic move
- typed rejection of DRM/sample encryption, unsupported timeline metadata,
  missing maps, retroactive map or gap-availability changes, incomplete
  renditions, and live-window loss instead of silently committing an
  incomplete presentation
- local DVR receipts expose the same typed, loopback-only playback bridge as
  offline-package receipts without claiming direct `file://` playback

### `InnoNetworkHLSAVFoundation`

- a main-actor local-playback owner that serves validated raw offline and DVR
  packages over a random, loopback-only HTTP endpoint; reachable playlists are
  bounded and frozen before listening, package-local interstitial asset lists
  are frozen with their reachable playlists, remote/package-escaping
  references and symbolic links are rejected, and GET, HEAD, and single byte
  ranges are supported for AVPlayer
- caller-owned `AVURLAsset` CMCD opt-in with typed availability status while
  AVFoundation retains ownership of generated request-header values; watchOS
  reports the feature as unavailable because it does not expose asset resource
  loaders
- typed, value-based `AVPlayerItem` configuration for variant/network-cost
  limits, live-edge offset, server interstitial policy, automatic/disabled
  media groups, and Custom Media Selection preferences. The caller keeps
  player ownership; version 26 systems use the native authored scheme while
  earlier systems select a compatible media option
- a `Sendable` legible-media catalog for custom subtitle and caption UI, with
  localized display names, BCP 47 languages, current/default state,
  generated/translated provenance, accessibility features, and opaque exact
  selection IDs that never expose AVFoundation objects
- an allowlist-first timed-metadata monitor built on
  `AVPlayerItemMetadataOutput`, with identifier-only safe defaults, explicit
  bounded text/number/date opt-in, sequence-flush and callback-overflow
  events, and no raw data, URL object, or underlying-error exposure
- a main-actor, read-only interstitial monitor that emits bounded,
  cancellation-safe lifecycle streams as value-redacted `Sendable` events;
  AVFoundation retains schedule and system skip-control ownership
- a version-gated integrated-timeline monitor for primary and interstitial
  segments, sampled playhead progress, wall-clock mapping, loaded ranges, and
  native structural invalidations; snapshots cap segment, range, and
  identifier storage while the application retains playback and seeking policy
- a pure, bounded playback-health analyzer that reduces delivered metric
  events into stable healthy/degraded/critical snapshots while applications
  retain UI, alerting, and policy ownership
- independently cancellable, URL-free playback metric streams plus an opt-in
  initial-startup view that correlates bounded chronological playlist,
  segment, and content-key request details while preserving exact request
  counts, and a detailed variant-switch view that exposes source/destination
  bitrates plus validated stable rendition IDs on version 26 systems; both
  detailed views include bounded, URL-free loaded-buffer snapshots, while a
  readiness stream covers both initial and later likely-to-keep-up events and
  a rate-change stream correlates variant bitrate with stalls and seeks;
  zero-based sequenced delivery makes bounded-buffer loss observable and the
  playback-health analyzer retains that diagnostic completeness count
- reconnectable AVFoundation background HLS downloads with typed content
  selection, interstitial retention, bounded event replay, and version 26
  URL-free download-summary metrics with bounded selected-variant details
- persistable validated `.movpkg` references plus a cancellation-safe
  `AVAssetCache` readiness inspector that distinguishes missing, invalid,
  unrecognized, incomplete, and offline-playable packages; bounded snapshots
  report cached standard media choices, safe language tags, and Custom Media
  Selection coverage without retaining native objects
- best-effort system eviction policy and symlink-safe idempotent package
  removal on supported platforms
- a bounded, versioned, Codable offline-asset library with stable ordering,
  duplicate ID/location rejection, availability inspection, and missing-entry
  pruning while applications retain metadata-persistence ownership
- native `AVAssetDownloadURLSession` background persistence with a
  reconnectable, application-owned session identifier
- main-actor configuration of AVFoundation media selections and variant
  qualifiers without crossing a non-`Sendable` boundary
- task restoration, progress and terminal event streams, pause, resume, and
  cancellation, plus replayable URL-free variant-selection snapshots before
  transfer progress
- application-delegate background completion handoff and optional app-group
  shared container support
- `HLSFairPlaySession` for delegate retention, HTTPS asset admission,
  pre-load `AVContentKeySession` recipient attachment, explicit detachment,
  downloaded `.movpkg` reattachment, normal expiration, and version 26
  URL-free request-origin correlation through caller-known opaque asset IDs,
  plus bounded streaming-key initial/renewal and restore-or-create
  persistent-key workflows
  with app-injected SPC/CKC transport, secure storage, typed redacted lifecycle
  events, opt-in FairPlay protocol-version negotiation after KSM validation,
  version 26 anonymized device-ID randomization with typed availability and
  seed validation, and iOS 27 streaming-only advisory-key reuse through a
  session-matched workflow; credentials, Keychain schema, key files, seed
  generation, expiry, and deletion remain application-owned
- an isolated, opt-in physical-iOS FairPlay acceptance gate that requires SPC
  version 3, waits for AVFoundation acceptance of both initial and renewing
  responses, then proves a protected system download reopens and advances from
  its local package without another KSM request; no acceptance credentials or
  key material are stored in the repository
- HTTPS admission and bounded artwork input; AVFoundation remains responsible
  for media requests, redirects, trust, content keys, and the asset location
- available on iOS, macOS, watchOS, and visionOS where
  `AVAssetDownloadURLSession` is supported; unavailable on tvOS

### `InnoNetworkHLSAudio`

- a version 27-only HLS-audio companion isolated from the core network,
  raw HLS, live reload, and broader AVFoundation playback products
- an explicit Xcode 27 and Swift 6.4 toolchain boundary; Xcode 26 continues to
  build the package and compatibility test target but does not expose these
  SDK-only declarations
- validated custom linear PCM formats plus a concise Float32 convenience
  configuration for common waveform, level, speech, and assistance pipelines
- one demand-driven async read at a time, with typed rejection of overlapping
  reads instead of an automatically drained, unbounded stream
- an optional non-prefetching paced sequence that admits the next read only
  when the previous sample is within a bounded lead of the player-item clock;
  pause, backward seek, cancellation, and terminal detachment remain explicit
- typed `Sendable` Core Media buffers that preserve marker-only samples,
  output presentation time, duration, sample count, and sequence restarts
- explicit, idempotent detachment while the application retains its player,
  conversion, processing, storage, and UI responsibilities
- an optional `MTAudioProcessingTapCreateWithPreferredFormat` bridge on macOS,
  iOS, tvOS, and visionOS for modifying the complete audio mix in place before
  or after the player's other effects; watchOS has no corresponding system API
- an authoritative preparation callback for the actual processing format and
  a synchronous processing callback whose real-time safety remains explicitly
  application-owned
- no DRM bypass or promise that protected audio will yield decoded samples;
  Apple does not supply FairPlay-protected audio to the full-mix tap

### `InnoNetworkWebSocket`

- heartbeat and pong timeout handling
- reconnect policies with handshake-aware close taxonomy
- listener retention across automatic reconnect transport generations
- explicit `retry(_:)` returns a fresh task and pre-registered bounded event
  stream in `WebSocketRetryResult`, preventing immediate retry events from
  racing consumer registration
- `AsyncStream` and listener-based event delivery

### `InnoNetworkPersistentCache`

- actor-backed `ResponseCache` implementation for on-disk GET caching
- default 50 MB / 1000 entry / 5 MB per-entry caps
- refuses authenticated, `Cache-Control: private`, and `Set-Cookie` responses by default
- applies `.completeUntilFirstUserAuthentication` data protection to cache files by default on iOS-family platforms
- excludes cache-owned indexes, keys, and bodies from backup while leaving the caller-supplied directory root unchanged
- `dataProtectionClass: .none` requests `NSFileProtectionNone` for cache-owned paths on iOS-family platforms
- versioned index and hashed body files with corrupt-entry eviction

### `InnoNetworkOpenAPI`

- `OpenAPIRequest` for running generated or hand-written operations through the full `DefaultNetworkClient` pipeline
- `OpenAPIRestOperation` bridge for generated operation metadata
- `InnoNetworkClientTransport` for thin `swift-openapi-runtime` transport when URLSession-level behavior is enough
- generated-client redirects use the default redirect policy plus per-hop URL
  admission; background URLSession is rejected because Foundation bypasses
  that callback

### `InnoNetworkTrust`

- public-key pinning evaluator split from the core product
- `PublicKeyPinningPolicy` host rules and SPKI matching
- `TrustPolicy.custom(_:)` integration for HTTP and WebSocket trust evaluation

### `InnoNetworkTestSupport`

- `MockURLSession` for deterministic request capture in consumer tests
- `StubNetworkClient` for testing app layers without touching transport
- `WebSocketEventRecorder` for websocket integration assertions
- intended for test targets, not production binaries

### Macro Support

- default-enabled `@APIDefinition(method:path:auth:)` from `import InnoNetwork`
- explicit endpoint structs remain the source of truth
- `APIResponse` and authentication intent stay mandatory and visible
- simple GET/HEAD `query` or POST/PUT/PATCH/DELETE `body` properties derive
  payload witnesses
- OPTIONS, CONNECT, TRACE, custom, and dynamic methods require a complete
  `Parameter` + `parameters` payload contract
- complete `Parameter` + `parameters` declarations remain authoritative
- compile-time diagnostics reject incomplete or ambiguous definitions
- `traits: []` excludes macro APIs and compiler plug-in compilation for
  core-only consumers

## Platform Matrix

- iOS 16.0+
- macOS 14.0+
- tvOS 16.0+
- watchOS 9.0+
- visionOS 1.0+
- Swift 6.2+

The package intentionally targets current Apple platform releases. That lets the codebase rely on modern Swift Concurrency semantics, stricter Sendable checking, and the latest URLSession and platform APIs without compatibility shims.

## Protocol Buffers

Protocol Buffers support moved to the separate `InnoNetworkProtobuf` package. Consumers that need protobuf request and response modeling must add `InnoNetworkProtobuf` alongside `InnoNetwork` in the same package manifest.

```swift
dependencies: [
    .package(url: "https://github.com/InnoSquadCorp/InnoNetwork.git", branch: "main"),
    .package(url: "https://github.com/InnoSquadCorp/InnoNetworkProtobuf.git", branch: "main")
]
```

`InnoNetworkProtobuf` is being prepared for its first tagged release; until
then, follow its `main` branch. This pair is a preview configuration, not a
tagged production dependency.

## Configuration

Use `safeDefaults` as the secure baseline for prototypes, tests, and production
clients that do not yet have measured reasons for additional policy. Use
`advanced` only when the integration explicitly needs retry, cache, auth,
observability, or transport tuning. There is intentionally no universal
"production" preset: retry, circuit-breaker, and idempotency semantics depend
on the server contract and should not be enabled by a generic label.

In the 5.x contract, `safeDefaults` and the `advanced` preset cap collected
responses, including file-upload responses, at 5 MiB by default.
Set an explicit `.streaming(maxBytes: nil)` or `.buffered(maxBytes: nil)` only
when an unbounded response is a deliberate, reviewed choice.

For inline requests, `.buffered(maxBytes:)` validates the size only after
`URLSession.data(for:)` has buffered the response; it bounds what proceeds to
cache storage and decoding, not peak transport buffering. Bounded streaming
and bounded file-upload responses inspect the body while it arrives and cancel
the underlying task as soon as a known or observed limit is exceeded. A
bounded file upload therefore uses a streamed data task with an explicit
`Content-Length`; an explicitly unbounded file upload preserves the native
file-backed upload-task path.

```swift
import Foundation
import InnoNetwork

let network = NetworkConfiguration.safeDefaults(
    baseURL: URL(string: "https://api.example.com")!
)

let tunedNetwork = NetworkConfiguration.advanced(
    baseURL: URL(string: "https://api.example.com")!,
    resilience: ResiliencePack(
        retry: ExponentialBackoffRetryPolicy(),
        coalescing: .getOnly
    ),
    cache: CachePack(
        responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
        responseCache: InMemoryResponseCache(),
        sensitiveHeaderNames: ["X-Tenant-Token"]
    ),
    transport: TransportPack(
        timeout: 30,
        redirectPolicy: DefaultRedirectPolicy(),
        trustPolicy: .systemDefault
    )
)
```

Auth refresh, coalescing, caching, and circuit breaking are opt-in. The
request execution pipeline stays internal. Configuration values are opaque
immutable commands: use presets and named pack inputs, and keep an
application-owned settings model only when product code must inspect the
chosen values. Optional Download and WebSocket products follow the same
`safeDefaults`-first rule.

### Transport security defaults

Core request clients and downloads default to HTTPS-only construction and safe
redirect handling:

- `DefaultRedirectPolicy` rejects HTTPS-to-HTTP downgrade redirects.
- Any cross-origin redirect that retains an unsafe method such as POST, PUT,
  PATCH, or DELETE is rejected, including nonstandard 301/302 proposals as
  well as 307/308 replay.
- Other cross-origin redirects strip every header prepared on the original
  request, plus common authorization, cookie, API-key, CSRF/session-token, and
  temporary AWS credential headers. Core URLSession transports also clear
  every value from `URLSessionConfiguration.httpAdditionalHeaders` on a
  cross-origin hop so Foundation cannot re-inject a removed session default;
  same-origin redirects retain those values. Register proprietary credential
  carriers with `additionalSensitiveHeaders` when using the policy outside
  that transport integration; built-in protection remains enabled.
- Plain `http://` base URLs fail before transport unless the client opts in
  with `allowsInsecureHTTP = true`.
- Foreground downloads — the configuration default — re-admit every redirect
  target through the same URL guard. A rejected
  downgrade, unsafe cross-origin replay, or traversal target fails as
  `DownloadError.invalidURL` without consuming retry budget.
- `backgroundTransfersEnabled()` is the one explicit opt-in that trades that
  per-hop preflight for process-independent continuation. Foundation follows
  background redirects automatically without consulting the redirect
  delegate. Initial and final URLs are still validated where Foundation
  exposes them, but that validation cannot prevent an intermediate background
  redirect from being contacted.
- Download progress callbacks are coalesced before entering the actor, while
  completion callbacks remain lossless and FIFO. Final completed, failed, and
  cancelled events seal their task partition so late progress cannot displace
  the terminal outcome under a bounded overflow policy.
- App-facing download callbacks use a per-task ordered delivery lane. A slow
  progress or terminal callback does not hold the URLSession delegate FIFO or
  delay the system background-session completion handler. The pre-transport
  `waiting` and `downloading` state callbacks remain admission hooks, and
  external `shutdown()` still drains every accepted callback before returning.
- Base URLs with embedded `user:password@host` credentials or fragments are
  rejected; put credentials in an interceptor or `RefreshTokenPolicy` instead.

```swift
let redirectPolicy = DefaultRedirectPolicy(
    additionalSensitiveHeaders: ["X-Tenant-Secret"]
)
```

Two explicit compatibility switches exist for controlled legacy or LAN
environments. Enabling them weakens the default boundary, so scope the policy
to a dedicated client; sensitive headers are still stripped across origins:

```swift
let controlledLegacyRedirects = DefaultRedirectPolicy(
    allowsHTTPSDowngrade: true,
    allowsCrossOriginUnsafeMethodRedirects: true
)
```

Keep the HTTP opt-in scoped to local development or a controlled LAN-only
client:

```swift
let local = NetworkConfiguration.advanced(
    baseURL: URL(string: "http://localhost:8080")!,
    transport: TransportPack(allowsInsecureHTTP: true)
)
```

```swift
let refreshPolicy = RefreshTokenPolicy(
    currentToken: { try await tokenStore.currentAccessToken() },
    refreshToken: { try await authService.refreshAccessToken() }
)

let client = DefaultNetworkClient(
    configuration: .advanced(
        baseURL: URL(string: "https://api.example.com")!,
        resilience: ResiliencePack(
            circuitBreaker: CircuitBreakerPolicy(failureThreshold: 3)
        ),
        auth: AuthPack(refreshToken: refreshPolicy)
    )
)
```

### Tag-based cancellation

`request(_:tag:)` and `upload(_:tag:)` register the dispatched task under a
`CancellationTag` so a screen, feature, or user session can drop just its own
requests when it goes away. `cancelAll()` continues to drain every in-flight
request when no granularity is required.

```swift
let feed: CancellationTag = "feed"

async let posts = client.request(GetPosts(), tag: feed)
async let banner = client.request(GetBanner(), tag: feed)

// User leaves the feed screen — only feed-tagged requests stop:
await client.cancelAll(matching: feed)
```

Untagged requests, and requests registered with a different tag, are left
alone by `cancelAll(matching:)`.

### Response cache and Vary handling

The opt-in `ResponseCachePolicy` honours the response `Vary` header
automatically (RFC 9111 §4.1):

- `Vary: *` responses are not stored — the cache cannot prove a future
  request would match.
- A concrete `Vary` header (for example `Vary: Accept-Language`) captures the
  named request headers when the response is stored. The next lookup matches
  only when those same header values are present, so two clients with
  different `Accept-Language` values do not see each other's payloads.
- Responses without a `Vary` header use the existing per-identity key
  (Authorization, etc.) when the response is eligible for storage.
- GET responses with whole-response cacheable status codes (`200`, `203`,
  `204`, `300`, `301`, `308`, `404`, `405`, `410`, `414`, and `501`) can be
  stored; `206 Partial Content` is excluded.
- `Cache-Control: no-store` and `Cache-Control: private` invalidate the current
  cache key and skip writes, including quoted directives such as
  `private="Set-Cookie, Authorization"`. `Cache-Control: no-cache` stores the
  response but forces revalidation before every reuse.
- Responses to requests carrying `Authorization` are stored only when the
  origin explicitly permits it with `Cache-Control: public`, `must-revalidate`,
  or `s-maxage`.
- Successful unsafe methods (`POST`, `PUT`, `PATCH`, `DELETE`, and unknown
  methods) invalidate every cached variant for the normalized target URI per
  RFC 9111 §4.4. `.disabled` and `.networkOnly` still leave cache metadata
  untouched.

`InnoNetworkPersistentCache` is **not** a full RFC 9111 cache by
default — storage directives are enforced by the executor, while
the freshness window is normally driven by `ResponseCachePolicy`
(`cacheFirst(maxAge:)` etc.). Clients that need directive-aware
behavior (`no-store` suppression, `must-revalidate` stale denial,
server `max-age` clamping, `Expires` fallback, and `Last-Modified` heuristic freshness)
should wrap their policy with
`ResponseCachePolicy.rfc9111Compliant(wrapping:)`:

```swift
let cache = CachePack(
    responseCachePolicy: .rfc9111Compliant(
        wrapping: .cacheFirst(maxAge: .seconds(300))
    ),
    responseCache: InMemoryResponseCache()
)
```

See `docs/rfcs/RFC9111-Compliance.md` for the exact directive coverage
and the trade-offs.

### Macro-First Endpoint Definitions

The default `Macros` trait exposes `@APIDefinition` directly from
`import InnoNetwork`:

```swift
import InnoNetwork

@APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
struct GetUser {
    typealias APIResponse = User

    let id: Int
}
```

The attribute derives conformance, method, percent-encoded path,
`sessionAuthentication`, and simple payload witnesses. It does not hide the
response model or endpoint policy: `APIResponse`, stored inputs, headers,
interceptors, transport, and decoding choices remain visible on the struct. A
complete `Parameter` + `parameters` pair overrides body/query inference for
advanced endpoints.

Invalid definitions fail at compile time with a diagnostic and, where safe, a
Fix-It. If an otherwise ordinary struct omits `@APIDefinition`, Swift cannot
know its intent at the declaration. Passing it to either `request` overload is
the first provable endpoint boundary and produces a targeted error that asks
for the macro or a manual `APIDefinition` conformance. The 4.x `#endpoint`
expression macro is removed; use `EndpointBuilder` when a request does not need
an explicit endpoint type.

See [Using Macros](Sources/InnoNetwork/InnoNetwork.docc/Articles/UsingMacros.md)
for payload rules, diagnostics, and core-only trait opt-out.

## Error Handling

InnoNetwork favors explicit transport errors over opaque failures.

```swift
do {
    let user = try await client.request(GetUser(id: 42))
    print(user)
} catch {
    switch error {
    case .configuration(reason: .invalidBaseURL(let url)):
        print("Invalid base URL: \(url)")
    case .configuration(reason: .invalidRequest(let message)):
        print("Invalid request configuration: \(message)")
    case .configuration(reason: .offline(let message)):
        print("Offline: \(message)")
    case .statusCode(let response):
        print("Unexpected status code: \(response.statusCode)")
    case .decoding(let stage, let underlying, _):
        print("Decoding failed (\(stage)): \(underlying)")
    case .trustEvaluationFailed(let reason):
        print("Trust evaluation failed: \(reason)")
    case .cancelled:
        print("Request cancelled")
    default:
        print(error)
    }
}
```

`.configuration(reason: .invalidRequest(...))` usually means request shape and policy do not match. Common examples are:

- sending a top-level scalar or array query without `queryRootKey`
- mismatching `contentType` and request payload semantics
- putting query or fragment components directly in an endpoint `path`
- using a malformed multipart payload

Request construction follows a fixed contract: endpoint paths are appended after
the `baseURL` path even when they start with `/`; endpoint paths must not include
`?` or `#`; query values must flow through `parameters` and `queryEncoder`; and
`Content-Type` is attached only for body, multipart, or file-upload payloads.
Header precedence is library defaults, endpoint headers, automatic body
`Content-Type`, request interceptors, then `RefreshTokenPolicy` authorization.

Choose `HTTPHeaders.add` only when a repeated field value is intentional, such
as accept negotiation or other comma-combinable metadata. Prefer
`HTTPHeaders.update`, subscript assignment, or `URLRequest.setValue` for
single-value request fields such as `Authorization`, `Content-Type`, `Cookie`,
and `Host`; `URLRequest.headers` and `URLSessionConfiguration.headers` apply
single-value names with last-write-wins semantics while preserving repeatable
header values.

For operational tuning, see [Examples](Examples/README.md) and [API Stability](API_STABILITY.md).
Teams migrating an existing client can start with
[Migration Guides](docs/MigrationGuides.md), then use the focused
[Alamofire cookbook](docs/MigrationFromAlamofire.md) or
[Moya cookbook](docs/MigrationFromMoya.md) for 30-minute before/after
examples.

## Stability

Public releases follow semantic versioning. `5.1.0` is the latest tagged
stable release; `5.0.0` remains the compatibility baseline for the 5.x
contract.

- Stable public API: [API_STABILITY.md](API_STABILITY.md)
- Release rules and compatibility policy: [docs/RELEASE_POLICY.md](docs/RELEASE_POLICY.md)
- Migration expectations: [docs/MIGRATION_POLICY.md](docs/MIGRATION_POLICY.md)

`safeDefaults` is the canonical secure entry point. The duplicate legacy
configuration aliases are absent from the 5.x contract; examples and new
integrations use the named factory so the selected policy is visible.

`NetworkClient.request` and `UploadNetworkClient.upload` are the recommended
capability boundaries (`DefaultNetworkClient` supports both). Use
`RequestExecutionPolicy` to observe or wrap a transport attempt and to adapt
its response. Execution policies cannot replace the executor-owned request;
use `RequestInterceptor` for URL, header, or body mutation. SPI lower-level
execution hooks remain outside the stable public contract.

For long-lived line-delimited transports (Server-Sent Events, NDJSON, log
streams), use `DefaultNetworkClient.stream(_:)` together with a
`StreamingAPIDefinition`. The default stream is lossless and reads at most one
decoded output ahead of its consumer; the explicit buffering-policy overload
offers unbounded or lossy delivery when that trade-off is intentional. To
cancel every in-flight request and stream
(for example, on logout or backgrounding), call
`DefaultNetworkClient.cancelAll()`. See the
[5.1 release notes](docs/releases/5.1.0.md) for the HLS companion products and
the
[5.0 migration guide](docs/Migration-5.0.0.md) for source changes.

## Benchmarks

The repository includes a dedicated benchmark runner for quick local comparisons.

```bash
swift run -c release InnoNetworkBenchmarks --quick
swift run -c release InnoNetworkBenchmarks --json-path /tmp/innonetwork-bench.json
```

Benchmark governance, baseline policy, and CI posture are documented in [Benchmarks/README.md](Benchmarks/README.md).

Current guarded quick-baseline highlights from
[`Benchmarks/Baselines/default.json`](Benchmarks/Baselines/default.json)
(`generatedAt`: `2026-07-14T17:50:26Z`):

| Area | Guarded benchmark | Iterations | Baseline ops/sec |
| --- | --- | ---: | ---: |
| Request pipeline | `client/request-pipeline` | 2,000 | 8,058 |
| Request coalescing | `client/request-coalescing-shared-get` | 2,000 | 8,844 |
| Cache lookup | `cache/response-cache-lookup` | 200,000 | 3,051,671 |
| Cache revalidation | `cache/response-cache-revalidation` | 200,000 | 4,559,491 |
| Event fan-out | `events/task-event-fanout-single` | 2,000 | 48,157 |
| Download restore | `persistence/download-persistence-restore` | 50 | 380 |
| WebSocket close classification | `websocket/websocket-close-disposition-classify` | 500,000 | 75,500,668 |

## Production Checklist

Operational items to verify before shipping a client built on InnoNetwork.

### Trust & Transport Security

- **TLS pinning rotation.** When using `TrustPolicy.custom(PublicKeyPinningEvaluator(...))`
  (from `import InnoNetworkTrust`), ship at least two pins (current + next) and document the
  rotation cadence so the app keeps validating after certificate replacement. Consider
  feature-gated rollback to `.systemDefault` for emergency recovery.
- **Redirect credential leakage.** Keep the default `DefaultRedirectPolicy`
  unless you have a stricter allowlist. Any custom policy must preserve the
  cross-origin stripping of `Authorization`, `Cookie`, and
  `Proxy-Authorization`.
- **Pinning host matching.** Keep the default `.unionAllMatches` if parent-domain pins should
  act as backup pins for subdomains. Use `.mostSpecificHost` when `example.com` and
  `api.example.com` pins must be operated as separate trust scopes.
- **App Transport Security (ATS).** The default `safeDefaults` configuration assumes ATS is
  enabled. Avoid `NSAllowsArbitraryLoads` in production `Info.plist`. If a non-HTTPS host is
  unavoidable, scope an `NSExceptionDomains` entry to that host only and set
  `allowsInsecureHTTP = true` only on the matching client configuration.
- **Custom trust evaluation.** A `TrustEvaluating` implementation runs before request bodies are
  ever decoded, so a rejected challenge becomes `NetworkError.trustEvaluationFailed`. Surface
  the failure to a user-facing recovery path; do not auto-retry on trust failure.

### Background Operation

- **Foreground is the secure default.** `DownloadConfiguration.safeDefaults`
  and `advanced` permit per-hop redirect admission. Call
  `backgroundTransfersEnabled()` only when the product requires transfers to
  continue outside the app process and accepts Foundation-managed redirects.
- **Background download Info.plist.** A background `URLSession` download does
  not itself require `UIBackgroundModes`. Declare a mode only for a separate
  wake-up mechanism owned by the app, such as `remote-notification`.
- **Session identifier uniqueness.** Each `sessionIdentifier` passed to a
  download configuration factory must be unique among live managers in the
  app process. The library rejects reuse with
  `DownloadManagerError.duplicateSessionIdentifier`; for background sessions,
  the identifier is also the Foundation background-session identifier. App
  Groups do not make concurrent app/extension ownership safe: coordinate so
  exactly one process owns a given identifier at a time.
- **Destination ownership.** Assign one active logical download to each final
  file path. Different sessions or processes are not serialized merely because
  they share an App Group container.
- **Background completion handler.** Wire the system-provided completion handler (delivered to
  `application(_:handleEventsForBackgroundURLSession:completionHandler:)`) into
  `DownloadManager` so the OS releases the app suspension promptly. The handler
  is paired only with a `urlSessionDidFinishEvents` that occurs after that batch
  is registered; an earlier unscoped finish is never carried forward.

### Observability & Privacy

- **Redaction defaults.** `NetworkEvent` never carries headers or bodies. Before any observer
  receives an event, URL user-info and fragments are removed, query values are redacted, and
  JWT-like path values are masked; failures use stable payload-free categories. The secure
  `NetworkLogger` additionally redacts every header value, cookie, body, query value, and
  free-form error description. `NetworkLoggingOptions.verbose` is an explicit local-debugging
  opt-in and must not be used in CI, shared logs, or production.
- **cURL export.** `URLRequest.curlCommand()` omits request bodies and redacts every header and
  query value by default. `includesHeaderValues`, `includesQueryValues`, and `includesBody` are
  independent explicit opt-ins for a controlled local diagnostic path. URL user-info and
  fragments are never exported.
- **Failure payload capture.** `NetworkError.decoding(stage:, underlying:, response:)` carries a `Response`;
  by default that `response.data` is redacted to empty data unless you opt in via
  `CachePack(captureFailurePayload: true)` in an advanced configuration. Keep
  that flag off in release configurations to avoid storing PII inside crash
  logs or analytics.
- **Event observer attachment.** Attach observers (`NetworkEventObserving`) at app start and
  detach on logout / account switch. Observers receive every request event, including ones
  triggered after a user-initiated cancellation.

### Resilience

- **Cancel-on-logout.** Call `DefaultNetworkClient.cancelAll()` when the user logs out,
  switches accounts, or backgrounds. Streaming requests (SSE/NDJSON) only stop when their
  parent task is cancelled.
- **Retry budget.** `ExponentialBackoffRetryPolicy.maxTotalRetries` is the absolute cap that
  network-monitor recovery does not reset. Budget per user session, not per request.
- **Retry idempotency.** The built-in retry policy retries `GET`/`HEAD` by
  default. `POST`, upload, and multipart requests retry only when they carry an
  `Idempotency-Key`, unless the client opts into `.methodAgnostic`.
- **Auth refresh.** Prefer `RefreshTokenPolicy` over response interceptors for
  `401` refresh + replay. The policy single-flights concurrent refreshes and
  replays each fully adapted request at most once.
- **Cache and circuit breaker.** Enable `ResponseCachePolicy` and
  `CircuitBreakerPolicy` per client only after deciding the cache freshness
  and host-failure budget for that API. Cache keys include an `Authorization`
  fingerprint, `Cookie`/credential-like headers are fingerprinted when present,
  and `Accept-Language` is included by default; the response `Vary` header
  further refines lookups, `Vary: *` responses are skipped, and
  `Cache-Control: no-store` / `private` / `no-cache` are honoured.
- **WebSocket reconnect cap.** `maxReconnectAttempts` limits successive automatic attempts.
  After exhaustion, surface the failure to the UI rather than reconnect on every app
  foreground.

### Push & Lifecycle Refresh

- **Background fetch friendly.** Streaming or websocket products expect explicit
  `disconnect()` calls before app suspension. Implement `applicationDidEnterBackground`
  cleanup; the OS will not gracefully close sockets on your behalf.
- **Token refresh.** Let `RefreshTokenPolicy` apply the current access token and
  own `401` refresh + replay. Keep tenant headers, request IDs, and other
  unsigned metadata in `RequestInterceptor`s; use `RequestSigner` for
  body-dependent signatures that must be recomputed after refresh.

### Pre-flight Test Plan

| Area | Smoke check |
|------|-------------|
| Trust | Hit a host pinned to a wrong certificate and verify `NetworkError.trustEvaluationFailed`. |
| Retry | Stub a `503 Retry-After: 30` response and confirm the policy honours the header. |
| Background download | Kill the app mid-download, relaunch, and verify `DownloadRestoreCoordinator` resumes. |
| WebSocket reconnect | Drop the network for >10s, restore, and verify only the configured number of attempts ran. |
| Cancel-all | Trigger `cancelAll()` while a stream and an upload are in flight; both must terminate with `.cancelled`. |

## Documentation

- DocC API Reference: https://innosquadcorp.github.io/InnoNetwork/
- Examples: [Examples/README.md](Examples/README.md)
- API Stability: [API_STABILITY.md](API_STABILITY.md)
- Client Architecture: [docs/ClientArchitecture.md](docs/ClientArchitecture.md)
- Policy Interactions: [docs/PolicyInteractions.md](docs/PolicyInteractions.md)
- Operational Guides: [docs/OperationalGuides.md](docs/OperationalGuides.md)
- Platform Support: [docs/PlatformSupport.md](docs/PlatformSupport.md)
- Release Policy: [docs/RELEASE_POLICY.md](docs/RELEASE_POLICY.md)
- Migration Policy: [docs/MIGRATION_POLICY.md](docs/MIGRATION_POLICY.md)
- Migration Guides: [docs/MigrationGuides.md](docs/MigrationGuides.md)
- 5.0 Migration Guide: [docs/Migration-5.0.0.md](docs/Migration-5.0.0.md)
- 5.1 Release Notes: [docs/releases/5.1.0.md](docs/releases/5.1.0.md)
- Alamofire Migration Cookbook: [docs/MigrationFromAlamofire.md](docs/MigrationFromAlamofire.md)
- Moya Migration Cookbook: [docs/MigrationFromMoya.md](docs/MigrationFromMoya.md)
- DocC Deployment: [docs/DocC_Deployment.md](docs/DocC_Deployment.md)
- Query Encoding Reference: [docs/QueryEncoding.md](docs/QueryEncoding.md)
- WebSocket Lifecycle: [docs/WebSocketLifecycle.md](docs/WebSocketLifecycle.md)
- Task Ownership: [docs/TaskOwnership.md](docs/TaskOwnership.md)
- 5.0 Release Notes: [docs/releases/5.0.0.md](docs/releases/5.0.0.md)
- Roadmap: [docs/ROADMAP.md](docs/ROADMAP.md)
- 한국어 문서: [docs/ko/README.md](docs/ko/README.md)

## Adoption

Verified production users are listed only after maintainers have explicit
permission to name the company or team publicly.

If you use InnoNetwork in production, please open a pull request with the
company or team name, the modules in use (Core / Download / WebSocket /
PersistentCache), and one line about what helped your adoption decision.

## Support

InnoNetwork follows a lightweight maintainer model.

- Support policy: [SUPPORT.md](SUPPORT.md)
- Contributing guide: [CONTRIBUTING.md](CONTRIBUTING.md)
- Security reporting: [SECURITY.md](SECURITY.md)
- Changelog: [CHANGELOG.md](CHANGELOG.md)
- Code of Conduct: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)

## License

MIT. See [LICENSE](LICENSE).
