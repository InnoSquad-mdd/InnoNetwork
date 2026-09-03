# API Stability (5.x)

This document defines the compatibility contract for the InnoNetwork 5.x
release line. `5.0.0` is the public compatibility baseline for this contract.

The 5.0.0 baseline removes the deprecated 4.x
`NetworkConfiguration.with(...)` modifier family, replace the type-level
auth-scope markers with an explicit `SessionAuthentication` value on every
endpoint shape, remove the raw-string `NetworkClient.request(_:method:tag:)`
shortcut and `NetworkConfiguration.responseBodyLimit` compatibility alias,
and move the shared `StateReducer` / `StateReduction` lifecycle vocabulary
to package scope.
The WebSocket manager's background-session completion no-op and its unused
`WebSocketConfiguration.sessionIdentifier` compatibility field are also
removed; only `DownloadManager` owns Foundation background transfer
callbacks. The duplicate `DownloadConfiguration.default` and
`WebSocketConfiguration.default` aliases are removed in favor of the existing
`safeDefaults()` factories; zero-argument manager construction remains
unchanged. The direct 21-parameter `WebSocketConfiguration` initializer is
package-owned; explicit tuning goes through thematic packs passed to
`advanced(...)`. Core, Download, and WebSocket configuration values are opaque
commands: their runtime fields are package-owned, while presets, pack inputs,
and documented escape-hatch methods form the public configuration contract.
Interceptor configuration follows the same boundary: callers construct HMAC,
JWT bearer, correlation-ID, and W3C trace interceptors through their named
initializers, while the captured values remain implementation state.
`WebSocketTask`
construction is manager-owned so every public handle has connection and
ownership state. The duplicate `DownloadManager.make(configuration:)` factory
is removed; the throwing initializer is the single construction path.
`PersistentResponseCacheStatistics` remains a public read-only snapshot, but
its cache-owned initializer moves to package scope. The initializer for the
library-produced `CircuitBreakerOpenError` diagnostic is package-owned while
its public domain and read-only fields remain available for inspection.
Task-scoped Download and WebSocket observation uses `events(for:)`; manual
listener subscription tokens and add/remove methods are no longer consumer
API. Any listener-based test plumbing is an implementation detail.
Lifecycle transition tables are also manager-owned, while public state values
retain `isTerminal` for application observation. Optional observability hooks
use `nil` or an empty observer collection instead of public no-op helper types.
5.x adopters should migrate configuration to
`NetworkConfiguration.advanced(baseURL:resilience:auth:observability:cache:transport:)`
and own application reducer types in their feature or architecture layer.

## Stable

- `APIDefinition`
- `CancellationTag`
- `Endpoint`
- `MultipartAPIDefinition`
- `TransportPolicy`
- `RequestEncodingPolicy`
- `ResponseDecodingStrategy`
- `DefaultNetworkClient`
- `DefaultNetworkClient.init(baseURL:)`
- `DefaultNetworkClient.shutdown()`
- `NetworkClient.request(_:)`
- `NetworkClient.request(_:tag:)`
- `UploadNetworkClient.upload(_:)`
- `UploadNetworkClient.upload(_:tag:)`
- `NetworkConfiguration.safeDefaults(baseURL:)`
- `NetworkConfiguration.advanced(baseURL:resilience:auth:observability:cache:transport:)`
- `DownloadConfiguration.safeDefaults()`
- `DownloadConfiguration.safeDefaults(sessionIdentifier:)`
- `DownloadConfiguration.advanced(sessionIdentifier:transfer:retry:observability:persistence:)`
- `DownloadTransferPack`, `DownloadRetryPack`, `DownloadObservabilityPack`, and `DownloadPersistencePack`
- `DownloadConfiguration.cellularEnabled()`
- `DownloadConfiguration.backgroundTransfersEnabled()`
- `WebSocketConfiguration.safeDefaults()`
- `WebSocketConfiguration.advanced(connection:liveness:reconnect:messaging:observability:)`
- `WebSocketConnectionPack`, `WebSocketLivenessPack`, `WebSocketReconnectPack`, `WebSocketMessagingPack`, and `WebSocketObservabilityPack`
- `WebSocketHandshakeRequestAdapter`
- `DownloadManager`
- `WebSocketManager`
- `WebSocketManager.shutdown()`
- `WebSocketManager.retry(_:) -> WebSocketRetryResult?`
- `WebSocketRetryResult`
- `WebSocketTask.id`
- `WebSocketEvent.ping`
- `WebSocketEvent.pong`
- `WebSocketEvent.error(.pingTimeout)`
- `WebSocketPingContext`
- `WebSocketPongContext`
- `TrustPolicy`
- `TrustChallengeOutcome`
- `PublicKeyPinningPolicy`
- `PublicKeyPinningPolicy.HostMatchingStrategy`
- `PublicKeyPinningEvaluator`
- `AnyResponseDecoder`
- `URLQueryEncoder`
- `URLQueryArrayEncodingStrategy`
- `ResponseBodyBufferingPolicy`
- `RequestExecutionPolicy`
- `NetworkErrorCategory`
- `NetworkError.category`
- `NetworkError.isRetriableHint`
- `NetworkError.isUserVisible`
- `HTTPMethod`
- `SessionAuthentication`
- `EventDeliveryPolicy`
- `WebSocketCloseCode`
- `EndpointBuilder`, `EndpointPathEncoding` (promoted from Provisionally Stable in 4.x.x; the path-encoding shape and decoding helpers are SemVer-protected)
- `DecodingInterceptor` (promoted from Provisionally Stable in 4.x.x)
- `WebSocketCloseDisposition` (promoted from Provisionally Stable in 4.x.x)

> **5.0.0 is the compatibility reset for the 5.x line.**
> From this release onward, the Stable ledger will only grow during 5.x;
> entries will not move back into Provisionally Stable, and breaking changes
> will wait for a future major.

## Stable Examples

A subset of `Examples/` participates in the SemVer-protected stable contract.
For each entry below the directory must
exist, contain at least one Swift source file, ship a `README.md`, and compile
against the current package. The exact wording of the example is **not**
contractual. The copyable Swift starting points must
stay source-compatible with the 5.0.0 public API.
The `Scripts/check_stable_examples.sh` gate, wired into the docs-contract
job, fails CI if a stable example is removed, emptied, loses its README, or
stops compiling. The smoke build runs with Swift warnings treated as errors
because these examples are copyable public-contract code, not narrative-only
documentation.

- `Examples/BasicRequest` — request/response fundamentals across HTTP verbs
  and content types.
- `Examples/Auth` — `RefreshTokenPolicy` wiring with a Keychain-backed
  token store and single-flight refresh.
- `Examples/ErrorHandling` — `NetworkError` taxonomy and the
  `do`/`catch` patterns that surface response payloads.

Every other example (`DownloadManager`, `WebSocketChat`,
`EventPolicyObserver`, the consumer smoke packages, …) is designated
Provisionally Stable: structure may evolve across future minors and they are
intentionally **not** enforced by the gate above. README/DocC examples
continue to track the stable APIs they illustrate; their wording is not
part of the compatibility contract.

## Provisionally Stable

Symbols in this section are public in the 5.x line and may evolve by gaining
new cases, parameters, or shape, with each change shipping release notes and a
migration path. The HLS companion products first ship in 5.1.0; the remaining
entries trace to 5.0.0 unless noted. See "Version Pinning Guidance" below.
For budget enforcement, every non-SPI public declaration that is not matched
by the explicit Stable ledger is classified as Provisionally Stable. This
conservative default prevents an undocumented declaration from accidentally
acquiring a 5.x compatibility promise.

- benchmark runner CLI flags and JSON summary presentation details
- troubleshooting guidance and examples in README/DocC
- `InnoNetworkTestSupport` library product and its `public` symbols
  (including `MockURLSession`, `StubNetworkClient`, `WebSocketEventRecorder`,
  and the `VCRCassette` / `VCRURLSession` record-and-replay family)
- `AnyEncodable`, `NetworkContext`, and `CorrelationIDInterceptor`
- `RefreshTokenPolicy`, `RequestCoalescingPolicy`, retry, response cache, redirect, encoding utility, and circuit breaker policy surfaces
- `MultipartResponseDecoder` buffered multipart response parsing surface
- `MultipartStreamingResponseDecoder` streaming multipart response parsing surface
- `InnoNetworkOpenAPI` companion product
- `InnoNetworkUpload` companion product and its public file-upload, progress, restoration, bounded response, event, and error symbols
- `InnoNetworkHLS` companion product and its public playlist, variant selection, single-file download, offline package, event, and error symbols
- `InnoNetworkHLSLive` companion product and its public live reload, bounded DVR recording, snapshot, configuration, and error symbols
- `InnoNetworkHLSAVFoundation` companion product and its public download, offline readiness, playback configuration, timed metadata, playback metrics, playback health, interstitial and integrated-timeline observation, and FairPlay symbols
- `InnoNetworkHLSAudio` companion product and its Xcode 27 / Swift 6.4 public decoded PCM plus full-mix processing configuration, callback, lifecycle, pacing, sample, and error symbols
- `@APIDefinition(method:path:auth:)` and the default-enabled `Macros` package trait
- `PersistentResponseCache` statistics and telemetry surfaces
- `WebSocketError.unsupportedProtocolFeature`
- `WebSocketProtocolFeature`
- `RequestSigner` and `RequestBody` late body-aware signing contract
- `JWTBearerInterceptor` reference signer for request-minted JWT bearer tokens
- `InnoNetworkAuthAWS` companion product and `AWSSigV4Interceptor` reference signer for single-shot AWS SigV4 signing
- `StreamingBufferingPolicy`, `StreamingOutputSequence`, `TraceContextInterceptor`, `W3CTraceContext`, `CurlCommandOptions`, `IdempotencyKeyPolicy`, and `RequestPriority`
- `HTTPHeaderName<Variant>` phantom-typed header key surface and its predefined `SingleValueHeader` / `RepeatableHeader` markers (also referenced as `HTTPHeaderName` / `HTTPHeaderVariant` for contract-sync purposes)
- `MultipartUploadStrategy.threshold(bytes:)`
- `PersistentResponseCacheStatistics.hitCount` / `missCount` / `evictionCount`
- `DownloadTask.generation` / `attempt` observation accessors
- `NetworkErrorCode` SSOT enum (4.0.0 baseline) — owns every `NetworkError.errorCode` raw value; new cases may be added in 5.x minors when `NetworkError` itself adds a case
- `NetworkError.reachability(_:_:_:)` and `ReachabilityReason` (4.0.0 baseline)
- `MultipartUploadStrategy.inMemory(maxBytes:)` (4.0.0 baseline) — the explicit cap and encoder accumulator guard are part of the contract
- `DownloadTransferPack.init(...taskInactivityTimeout:...)` and `DownloadTask.lastProgressAt` (4.0.0 behavior carried into the 5.0 pack contract)
- `ResponseCachePolicy.rfc9111Compliant(wrapping:)` directive-aware adapter (4.0.0 baseline)
- `DownloadPersistencePack.init(...sharedContainerIdentifier:...)` (4.0.0 behavior carried into the 5.0 pack contract)
- `ResponseCache.invalidateTargetURI(_:)` and RFC 9111 unsafe-method target URI invalidation (4.0.0 baseline)
- `TransportPack.init(...streamingLineByteLimit:...)` (4.0.0 behavior carried into the 5.0 pack contract)

## 5.x Evolution Boundaries

Per-symbol compatibility boundaries for the 5.x line follow.
Stable entries describe commitments that stay source-compatible throughout
5.x; Provisionally Stable entries describe their explicitly allowed evolution.

Promotion from Provisionally Stable to Stable requires all of the following:

- The symbol has DocC or README coverage for the intended stable usage.
- Contract tests or smoke examples exercise the source shape that is being
  promoted.
- The CHANGELOG and migration notes describe the promotion and any required
  adopter action.
- Stable examples or generated-client recipes are updated when the promoted
  surface is a recommended entry point.
- The symbol is moved into the Stable ledger above; once promoted, it cannot
  move back to Provisionally Stable within the 5.x line.

| Surface | Promotion target | Required evidence |
| --- | --- | --- |
| `EndpointBuilder` runtime-composed path | Stable since 4.0.0 | Runtime-composed request examples, stable example smoke, and migration cookbook shapes stay green. |
| `InnoNetworkAuthAWS` | 5.x minor after adopter validation | AWS SigV4 vector tests, product README/DocC scope, and explicit "reference signer, not AWS SDK replacement" wording. |
| `PersistentResponseCache` statistics and telemetry | 5.x minor | Reentrancy invariant docs plus persistent cache key-rotation/statistics tests. |
| `ResponseCachePolicy.rfc9111Compliant(wrapping:)` | 5.x minor | The subset is documented as RFC 9111-aware, with directive tests for the supported rules. |
| Root `@APIDefinition` macro | No automatic promotion | Promote only after the explicit-struct expansion, diagnostics, and trait opt-out have sustained adopter validation. |

- `default` aliases — may add new defaults; never removed within 5.x.
- Benchmark runner CLI flags and JSON keys — may evolve to reflect new
  metrics; baseline contents are operational policy.
- README/DocC examples — track the stable APIs they illustrate; their
  exact wording is not part of the compatibility contract.
- `InnoNetworkTestSupport` — additional helpers may be added; existing
  symbols stay source-compatible within 5.x. VCR-style cassette helpers are
  intended for test targets and may gain new matching/redaction knobs.
- `EndpointBuilder`, `AnyEncodable`, `NetworkContext`, `CorrelationIDInterceptor` —
  builder shape may grow new chainable methods.
- `EndpointPathEncoding` — may add new helpers for placeholder encoding;
  existing entry points remain source-compatible. The set of percent-encoded
  characters tracks RFC 3986 reserved/unreserved updates and may widen
  encoding for newly disallowed scalars without prior deprecation.
- `URLQueryEncoder` — the default array convention remains indexed brackets
  for 4.0.0 compatibility, while ``URLQueryArrayEncodingStrategy`` can opt in
  to bracketed or repeated-key arrays per provider.
- `HTTPMethod` — the 5.0 value type accepts any valid, case-sensitive
  RFC 9110 method token through its failable `init(rawValue:)`; the standard
  GET, HEAD, POST, PUT, PATCH, DELETE, CONNECT, OPTIONS, and TRACE constants
  will remain available throughout 5.x. URLSession-backed execution fails
  before transport if Foundation cannot preserve a token's exact spelling;
  retry, redirect, cache, coalescing, and diagnostics never normalize method
  case on the caller's behalf.
- `ResponseBodyBufferingPolicy` — the default inline request path is
  streaming. Its `streaming(maxBytes:)` and `buffered(maxBytes:)` cases are
  the single source of truth for collection mode and byte ceiling.
- `TransportPack.init(...streamingLineByteLimit:...)` — controls the maximum
  UTF-8 byte length for one line-delimited streaming frame. The preset default
  remains 1 MiB, and values below 1 are normalized to 1.
- `RequestExecutionPolicy` — custom policies may observe and wrap raw
  transport attempts or adapt their responses. `RequestExecutionNext.execute()`
  always forwards the executor-owned request; request mutation belongs in a
  `RequestInterceptor`. Built-in retry, refresh, cache, coalescing, and circuit
  breaker behavior remains provided by `NetworkConfiguration`.
- `SessionAuthentication` — every buffered, multipart, streaming, macro, and
  OpenAPI endpoint carries one explicit runtime policy. `.anonymous` skips
  `RefreshTokenPolicy`, `.optional` applies it only when configured, and
  `.required` fails before transport when no policy or token can be obtained.
  Request interceptors and signers remain orthogonal capabilities.
- `WebSocketCloseDisposition` — additional enum cases may appear as new
  close-code classifications are formalized.
- `RefreshTokenPolicy`, `RequestCoalescingPolicy`, retry, response cache,
  redirect, encoding utility, and circuit breaker policy — built-in knobs may
  add fields, helper cases, or sensitive-header defaults with
  source-compatible behavior; the generic execution pipeline stays
  package/internal. Retry defaults treat `GET`, `HEAD`, `OPTIONS`, and
  `TRACE` as safe, while `PUT` and `DELETE` require `Idempotency-Key` or an
  explicit method-agnostic policy. Response cache writes for requests carrying
  `Authorization` require both the caller's privacy opt-in and an RFC 9111
  permission directive (`public`, `must-revalidate`, or `s-maxage`). Core
  URLSession transports clear session-configured additional-header values on
  cross-origin redirects while preserving them on same-origin hops.
- `NetworkConfigurationFailureReason` — typed payload for
  ``NetworkError/configuration(reason:)``. Carries
  `invalidBaseURL` / `invalidRequest` / `offline` cases. The standalone
  `NetworkError.invalidBaseURL` and
  `NetworkError.invalidRequestConfiguration` cases are not part of the
  5.x surface; adopters switch on this reason payload directly.
- `ReachabilityCheckExecutionPolicy` — `RequestExecutionPolicy` that
  consults a `NetworkMonitoring` source and short-circuits requests
  when the path is `.unsatisfied`. `.requiresConnection` waits up to
  `suspensionWaitTimeout` before forwarding, surfacing offline, or
  throwing ``NetworkError/transportSuspended``; unobserved snapshots fall
  through. Offline rejections surface as
  ``NetworkError/configuration(reason:)`` with
  ``NetworkConfigurationFailureReason/offline(_:)``.
- `ConcurrencyLimitExecutionPolicy` — `RequestExecutionPolicy` that
  funnels each transport attempt through a package-owned FIFO admission queue
  with cancellation-aware acquire / awaited-release semantics. Construct it
  with `init(maxConcurrent:)` and register it via
  `ResiliencePack.customExecutionPolicies`. Reuse the same policy value across
  configurations to share one cap. The raw semaphore is not public, preventing
  interceptor pairs that leak capacity when transport errors skip response
  processing.
- `ResiliencePack`, `AuthPack`, `ObservabilityPack`, `CachePack`,
  `TransportPack` — configuration packs accepted as named arguments by
  `NetworkConfiguration.advanced(baseURL:resilience:auth:observability:cache:transport:)`.
  Each pack groups a thematic axis of options; the underlying builder
  is now `package`-only. The pack APIs stay source-compatible throughout
  5.x; future minors may add fields to existing packs without
  breaking call sites because every field defaults to `nil`.
- Download and WebSocket configuration packs — immutable thematic values
  accepted by each optional product's `advanced(...)` factory. Their
  initializers retain complete advanced-preset defaults so callers can set one
  named argument without publishing a mutable mirror of every configuration
  property. The underlying builders are package-only.
- `HMACRequestInterceptor` — reference HMAC body-signing interceptor
  (SHA-256 / SHA-384 / SHA-512). Header names and key id are
  provider-tunable; data and stable file bodies are supported while opaque
  `httpBodyStream` values remain intentionally unsupported.
- `MultipartResponseDecoder` and `MultipartStreamingResponseDecoder` — the
  buffered API remains source-compatible; the streaming event vocabulary may
  gain additive diagnostic events as more long-lived multipart deployments are
  exercised.
- `InnoNetworkOpenAPI` — adapter protocols may add optional requirements with
  default implementations to track Swift OpenAPI Generator and HTTPTypes
  conventions without exposing HTTPTypes through the core public
  request/header/response model. The direct `swift-http-types` dependency
  remains owned by the optional companion target. Its generated-client
  transport owns task redirect decisions, repeats URL admission on every hop,
  and rejects background URLSession instances that cannot provide that
  callback; rejection errors remain payload-free so target URLs are not added
  to diagnostics.
- `PersistentResponseCache` statistics and telemetry — event reasons may grow
  as additional scrub cases are surfaced.
- `ResponseCache.invalidateTargetURI(_:)` — the protocol requirement has a
  default implementation for source compatibility; built-in caches remove all
  variants for the normalized target URI, while custom caches may override the
  default to match their own key layout.
- `ResponseCachePolicy.rfc9111Compliant(wrapping:)` — the adapter may tighten
  read-side freshness handling as RFC 9111 coverage expands. `max-age`
  remains higher priority than `Expires`, which remains higher priority than
  the `Last-Modified` heuristic; invalid or duplicate freshness directives
  are treated as stale rather than extending cache reuse.
- `NetworkErrorCode` — raw values use the
  `com.innosquad.innonetwork.NetworkError` domain exclusively; Foundation
  `URLError` codes are preserved only as underlying metadata.
- `WebSocketError.unsupportedProtocolFeature` and `WebSocketProtocolFeature`
  — feature cases may grow as optional transports add or reject more protocol
  extensions.
- `@APIDefinition(method:path:auth:)` — the signature may add optional
  arguments, but `APIResponse` and authentication intent remain explicit.
- `DecodingInterceptor` — protocol may grow new optional hooks with
  default implementations as additional decode-boundary use cases
  surface.
- `StreamingBufferingPolicy` — bounded buffering cases may gain additional
  policy knobs, but `stream(_:)` stays lossless and backpressured by default
  for 5.x. Explicit bounded buffers remain incompatible with
  `StreamingResumePolicy.lastEventID`; explicit `.unbounded` remains the
  producer-nonsuspending, lossless opt-out.
- `stream(_:)` / `stream(_:bufferingPolicy:)` — every failure the returned
  ``StreamingOutputSequence`` finishes with is a `NetworkError`. Its iterator
  exposes typed `throws(NetworkError)` on every supported platform floor, so
  callers do not need a cast to exhaustively switch over the failure.
- `TraceContextInterceptor` and `W3CTraceContext` — W3C header propagation
  remains additive; future minors may add richer correlation helpers without
  changing `NetworkEvent` case shape.
- `CurlCommandOptions` — every header value and query value remains redacted,
  and request bodies remain omitted by default. Callers can explicitly opt
  into header values, query values, or bodies for controlled local debugging.
- `IdempotencyKeyPolicy` — retry attempts reuse one request-scoped key for
  unsafe methods; future minors may add provider hooks without changing the
  request-ID invariant.
- `RequestPriority` and network-condition request controls — additional
  platform mappings may be added while preserving current defaults.
- `NetworkConfiguration` response buffering — the 5.0 baseline caps inline
  response collection at 5 MiB in `safeDefaults` and the `advanced` preset;
  explicit nil limits remain the opt-out.
- `NetworkConfiguration.init(...)` — the direct 32-parameter public
  construction surface was removed before the 4.0.0 baseline and is not part
  of the planned 5.x stable API. Use presets and the named configuration packs
  passed to `NetworkConfiguration.advanced(...)` instead.
- Core, Download, and WebSocket configuration runtime fields are package-owned.
  Configuration values are immutable commands, not readable state mirrors;
  applications that need inspection retain their own input model and build a
  configuration through presets and packs.
- `DownloadConfiguration.backgroundTransfersEnabled()` — the single public
  opt-in for Foundation-managed background continuation. The underlying
  foreground/background mode remains package-owned so the public contract
  does not expose a second configuration vocabulary.
- `DownloadConfiguration.init(...)` — the direct 22-parameter construction
  surface is package-owned in 5.0. Use `safeDefaults(sessionIdentifier:)` or
  `advanced(sessionIdentifier:transfer:retry:observability:persistence:)` so
  the secure preset defaults and manager
  identity remain explicit.
- `DownloadPersistencePack.init(...sharedContainerIdentifier:...)` — additive
  App Group background-session storage knob. Default stays `nil`; future
  minors may add preset helpers while preserving the pack input.
- `HTTPHeader`, `HTTPHeaders`, and default header providers — default
  `User-Agent` / `Accept-Language` values are evaluated at request-build time
  so applications can inject bundle or locale ownership without relying on a
  process-start snapshot.

## Version Pinning Guidance

Applications using only Stable API may consume the tagged 5.x line:

```swift
.package(url: "https://github.com/InnoSquadCorp/InnoNetwork", .upToNextMajor(from: "5.1.0"))
```

Applications using Provisionally Stable API should prefer a minor-bound range:

```swift
.package(url: "https://github.com/InnoSquadCorp/InnoNetwork", .upToNextMinor(from: "5.1.0"))
```

Pin the exact `5.1.0` version when a reproducible release build must not accept
any dependency update.

## Public Declaration Ledger

The docs-contract gate extracts public symbols from Swift symbol graphs and
compares them with `Scripts/symbols/*.allowlist`. That catches nested public
types and members in addition to top-level declarations. The grouped ledger
below keeps the high-level compatibility classification readable for the
5.x release line.

The machine-checked snapshot currently partitions all 3,185 declarations into
305 Stable consumer declarations, 2,847 Provisionally Stable consumer
declarations, and 33 opt-in SPI declarations. The three sets are disjoint and
exhaustive. `Scripts/symbols/stable-rules.tsv` maps the Stable ledger to symbol
paths, while the compiler-authored SPI flag is snapshotted in
`Scripts/symbols/spi-symbols.tsv`; anything else defaults to Provisionally
Stable.

### InnoNetwork

- `APIDefinition`, `AnyEncodable`, `AnyRequestExecutionPolicy`,
  `AnyResponseDecoder`,
  `CachedResponse`, `CacheRevalidationState`, `CancellationTag`,
  `CircuitBreakerOpenError`, `CircuitBreakerPolicy`,
  `ConcurrencyLimitExecutionPolicy`,
  `ContentType`, `CorrelationIDInterceptor`, `CurlCommandOptions`,
  `DecodingStage`,
  `DefaultNetworkClient`, `DefaultRedirectPolicy`,
  `DefaultNetworkLogger`, `EmptyParameter`, `EmptyResponse`,
  `EndpointPathEncoding`, `Endpoint`,
  `HTTPEmptyResponseDecodable`, `HTTPHeader`, `HTTPHeaders`, `HTTPMethod`,
  `IdempotencyKeyPolicy`, `InMemoryResponseCache`, `MultipartAPIDefinition`, `MultipartFormData`,
  `MultipartPart`, `MultipartResponseDecoder`,
  `MultipartStreamingEvent`, `MultipartStreamingResponseDecoder`,
  `MultipartUploadStrategy`,
  `NetworkClient`, `UploadNetworkClient`, `NetworkConfiguration`,
  `NetworkContext`, `NetworkError`,
  `NetworkErrorCategory`,
  `NetworkEvent`, `NetworkEventObserving`, `NetworkInterfaceType`,
  `NetworkLoggingOptions`, `NetworkLogger`, `NetworkMetricsReporting`,
  `NetworkMonitor`, `NetworkMonitoring`, `NetworkReachabilityStatus`,
  `NetworkUnsatisfiedReason`,
  `NetworkRequestContext`, `NetworkSnapshot`,
  `OSLogNetworkEventObserver`,
  `RedirectPolicy`, `RefreshFailureCooldown`, `RefreshTokenPolicy`,
  `RequestCoalescingPolicy`, `RequestEncodingPolicy`,
  `RequestPriority`, `RequestBody`,
  `RequestInterceptor`, `RequestSigner`, `Response`, `ResponseCache`, `ResponseCacheKey`,
  `RequestExecutionContext`, `RequestExecutionInput`, `RequestExecutionNext`,
  `RequestExecutionPolicy`, `ResponseBodyBufferingPolicy`,
  `ResponseCachePolicy`,
  `ResponseDecodingStrategy`, `ResponseInterceptor`,
  `RetryDecision`, `RetryIdempotencyPolicy`, `RetryPolicy`,
  `RFC3986Encoding`, `EndpointBuilder`, `SendableUnderlyingError`, `ServerSentEvent`,
  `ServerSentEventDecoder`, `SessionAuthentication`,
  `StreamingAPIDefinition`, `StreamingBufferingPolicy`,
  `StreamingResumePolicy`, `TimeoutReason`, `TraceContextInterceptor`,
  `TransportPolicy`, `TrustChallengeOutcome`, `TrustEvaluating`, `TrustFailureReason`, `TrustPolicy`,
  `URLQueryArrayEncodingStrategy`, `URLQueryCustomKeyTransform`,
  `URLQueryEncoder`, `URLQueryFloatEncodingStrategy`,
  `URLQueryKeyEncodingStrategy`, and
  `W3CTraceContext`.
- Event-pipeline observability declarations: `EventDeliveryPolicy`,
  `EventPipelineAggregateSnapshotMetric`,
  `EventPipelineConsumerDeliveryLatencyMetric`,
  `EventPipelineConsumerStateMetric`, `EventPipelineHubKind`,
  `EventPipelineMetric`, `EventPipelineMetricsReporting`,
  `EventPipelineOverflowPolicy`, `EventPipelinePartitionStateMetric`, and
  `ExponentialBackoffRetryPolicy`.

### InnoNetworkDownload

- `DownloadConfiguration`, `DownloadError`, `DownloadEvent`,
  `DownloadManager`, `DownloadManagerError`,
  `DownloadProgress`, `DownloadState`, and `DownloadTask`.

### InnoNetworkUpload

- `UploadConfiguration`, `UploadError`, `UploadEvent`, `UploadManager`,
  `UploadOperation`, `UploadProgress`, `UploadReceipt`, `UploadState`, and
  `UploadTask`.

### InnoNetworkHLS

- Playlist and inspection: `HLSByteRange`, `HLSClosedCaptionReference`,
  `HLSDateRange`, `HLSDateRangeCue`, `HLSDateRangePreload`,
  `HLSDateRangeResource`, `HLSDateRangeSchedule`,
  `HLSDateRangeScheduleEntry`, `HLSPreloadedDateRangeResource`,
  `HLSInterstitial`, `HLSInterstitialContentVariability`,
  `HLSInterstitialNavigationRestriction`,
  `HLSInterstitialSkipControl`, `HLSInterstitialSource`,
  `HLSInterstitialTimelineOccupancy`, `HLSInterstitialTimelineStyle`,
  `HLSMediaCharacteristic`,
  `HLSMediaCharacteristicPreference`, `HLSMediaContainer`,
  `HLSMediaPlaylistType`, `HLSPlaylist`, `HLSPlaylistDiagnostic`,
  `HLSPlaylistInspection`,
  `HLSPlaylistInspectionPack`, `HLSPreferredStartPosition`,
  `HLSPresentationConformanceRevision`, `HLSPresentationDiagnostic`,
  `HLSPresentationGraphInspection`, `HLSPresentationInspectionError`,
  `HLSPresentationInspectionLimitPack`, `HLSPresentationInspectionPack`,
  `HLSPresentationPlaylistInspection`, `HLSPresentationPlaylistRole`,
  `HLSProgramDateTime`, `HLSRendition`, `HLSRenditionKind`,
  `HLSRenditionSelectionPolicy`, `HLSRequiredVideoLayout`,
  `HLSSegmentBitrate`, `HLSSubtitleProvenancePolicy`,
  `HLSUnsupportedMediaFeature`, `HLSVariant`,
  `HLSVariantSelectionPolicy`, `HLSVideoChannelLayout`,
  `HLSVideoProjection`, `CustomMediaSelector`, `PlaylistResolver`,
  `RenditionSelector`, and `VariantSelector`.
- Session, Low-Latency HLS, and Content Steering:
  `HLSAllowedContentProtectionConfiguration`, `HLSContentSteering`,
  `HLSContentSteeringEvent`,
  `HLSContentSteeringEventObserving`, `HLSContentSteeringHealthPolicy`,
  `HLSContentSteeringPack`, `HLSContentSteeringPathwayAvailability`,
  `HLSContentSteeringPathwaySnapshot`, `HLSContentSteeringPhase`,
  `HLSContentSteeringSelectionReason`, `HLSCustomMediaSelectionPreferences`,
  `HLSCustomMediaSelectionScheme`, `HLSDeltaUpdate`,
  `HLSEncryptionKeyPreload`, `HLSHDCPLevel`, `HLSLanguageDecoration`,
  `HLSLowLatencyMetadata`, `HLSMediaPresentationSelector`,
  `HLSMediaPresentationSetting`, `HLSMediaPresentationType`,
  `HLSPartialSegment`, `HLSPreloadHint`, `HLSPreloadHintType`,
  `HLSRenditionReport`, `HLSServerControl`, `HLSSessionData`,
  `HLSSessionDataContent`, `HLSSessionDataFormat`, `HLSSessionDataValue`, and
  `HLSSessionKey`.
  LL-HLS resource contexts follow the same parallel-key-format selection as
  complete segments and retain the active selection at each PART, MAP, or
  preload boundary.
- External resources: `HLSChapter`, `HLSChapterCatalog`, `HLSChapterImage`,
  `HLSChapterMetadata`, `HLSChapterMetadataValue`, `HLSChapterTitle`,
  `HLSExternalResourceError`, `HLSExternalResourcePack`,
  `HLSExternalResourceResolver`, `HLSInterstitialAsset`,
  `HLSInterstitialAssetResolution`, and
  `HLSLocalizedRenditionNameCatalog`. The resolver's
  public Date Range operations load
  bounded preload bytes and resolve nested schedules with explicit collision,
  depth, and entry-count boundaries.
- Request policy and observation: `HLSRequestContext`, `HLSRequestEvent`,
  `HLSRequestEventObserving`, `HLSRequestFailure`, `HLSRequestPolicy`, and
  `HLSRequestPurpose`.
- Single-file download: `HLSDiskCapacityPolicy`, `HLSDownloadConfiguration`,
  `HLSDownloadError`, `HLSDownloadErrorCode`, `HLSDownloader`,
  `HLSDownloadEvent`, `HLSDownloadPreparation`, `HLSDownloadProgress`,
  `HLSDownloadReceipt`, `HLSPlaybackCapabilities`, `HLSResumePolicy`,
  `HLSSessionKeyPreloadPolicy`, `HLSStoragePack`, and `HLSTransferPack`.
  Parallel media key formats remain independent: an identity AES-128
  alternative is selected regardless of declaration order, and a resource
  observed with only unsupported formats still fails typed.
  Opt-in session-key preloading starts at most four identity AES-128 requests
  during media-playlist resolution, reuses only selected-media keys, and
  performs no key I/O during preparation.
- Offline packages:
  `HLSLocalPlaybackSource`, `HLSLocalPlaybackSourceError`,
  `HLSOfflinePackageConfiguration`, `HLSOfflinePackageDownloader`,
  `HLSOfflinePackageEvent`, `HLSOfflinePackagePreparation`,
  `HLSOfflinePackageReceipt`, `HLSOfflinePackageStore`,
  `HLSOfflinePackageStoragePack`, `HLSOfflinePackageTrack`,
  `HLSOfflinePackageTrackKind`,
  `HLSOfflineRenditionPack`, and `HLSOfflineRenditionSelectionPolicy`.

### InnoNetworkHLSAVFoundation

- `HLSAssetDownload`, `HLSAssetDownloadContentPack`,
  `HLSAssetDownloadEvent`, `HLSAssetDownloadEvictionPriority`,
  `HLSAssetDownloadLibrary`, `HLSAssetDownloadLibraryError`,
  `HLSAssetDownloadLibraryItem`, `HLSAssetDownloadRequest`,
  `HLSAssetDownloadSession`, `HLSAssetDownloadSessionError`,
  `HLSAssetDownloadSessionPack`, `HLSAssetDownloadStorage`,
  `HLSAssetDownloadStorageError`, `HLSAssetDownloadStoragePolicy`,
  `HLSAssetDownloadSummary`, `HLSAssetDownloadVariantSummary`,
  `HLSAssetDownloadVariantSelection`,
  `HLSFairPlayAdvisoryKeyPolicy`,
  `HLSFairPlayAssetID`, `HLSFairPlayContentKeyRequestOrigin`,
  `HLSFairPlayContentKeyRequestOriginResolver`,
  `HLSFairPlaySession`, `HLSFairPlaySessionError`, `HLSStoredAsset`, and
  `HLSStoredAssetAvailability`.
- Offline readiness: `HLSOfflineAssetInspector`,
  `HLSOfflineAssetReadinessSnapshot`, `HLSOfflineAssetReadinessState`,
  `HLSOfflineCustomMediaSelectionCoverage`,
  `HLSOfflineMediaSelectionGroupSnapshot`, and
  `HLSOfflineMediaSelectionOptionSnapshot`. Inspection distinguishes package
  presence from AVFoundation's offline-playable cache state and exposes only
  bounded value snapshots while package bytes and FairPlay keys remain
  application-owned.
- Application-owned local playback: `HLSLocalPlaybackAsset` and
  `HLSLocalPlaybackAssetError`. The main-actor owner exposes a caller-owned
  AVURLAsset backed by a bounded loopback-only package bridge and must remain
  alive for the player-item lifetime.
- FairPlay persistent keys: `HLSFairPlayKeyID`,
  `HLSFairPlayDeviceIdentifierPolicy`,
  `HLSFairPlayLicenseRequest`, `HLSFairPlayLicenseTransporting`,
  `HLSFairPlayPersistentKeyAcquisition`,
  `HLSFairPlayPersistentKeyConfiguration`,
  `HLSFairPlayPersistentKeyDisposition`, `HLSFairPlayPersistentKeyError`,
  `HLSFairPlayPersistentKeyLimitPack`, `HLSFairPlayPersistentKeyStoring`, and
  `HLSFairPlayPersistentKeyWorkflow`. The workflow coordinates bounded
  restore-or-create requests while transport, secure storage, expiry,
  invalidation, and deletion remain application-owned.
- FairPlay streaming keys: `HLSFairPlayLicenseRequestPurpose`,
  `HLSFairPlayAdvisoryKeyPolicy`,
  `HLSFairPlayDeviceIdentifierPolicy`,
  `HLSFairPlayStreamingKeyAcquisition`,
  `HLSFairPlayStreamingKeyConfiguration`,
  `HLSFairPlayStreamingKeyLimitPack`, `HLSFairPlayStreamingKeyWorkflow`,
  `HLSFairPlayStreamingKeyError`, `HLSFairPlayContentKeyEvent`,
  `HLSFairPlayContentKeyRetryReason`, and
  `HLSFairPlayContentKeyFailureReason`. The workflow bounds SPC and CKC
  material for initial and renewal requests while application code retains
  transport, credentials, acceptance callbacks, and retry policy. iOS 27
  streaming-only sessions can opt into advisory-key reuse through the session
  factory; unsupported environments fail typed and persistent-key acquisition
  remains isolated in a separate session.
- Playback configuration: `HLSCommonMediaClientDataPolicy`,
  `HLSCommonMediaClientDataStatus`, `HLSPlaybackAppliedMediaSelection`,
  `HLSPlaybackAssetConfigurator`,
  `HLSPlaybackConfiguration`, `HLSPlaybackConfigurationError`,
  `HLSPlaybackConfigurationResult`, `HLSPlaybackConfigurator`,
  `HLSPlaybackInterstitialPolicy`, `HLSPlaybackLivePack`,
  `HLSPlaybackMediaKind`, `HLSPlaybackMediaPreference`,
  `HLSPlaybackMediaSelection`, `HLSPlaybackMediaSelectionResolution`, and
  `HLSPlaybackVariantPack`.
- Legible media: `HLSLegibleMediaCatalog`, `HLSLegibleMediaFeature`,
  `HLSLegibleMediaKind`, `HLSLegibleMediaOption`,
  `HLSLegibleMediaOptionID`, `HLSLegibleMediaProvenance`, and
  `HLSLegibleMediaSelection`. Catalogs expose value-only custom-player state;
  opaque option identifiers remain asset-scoped and nonpersistent.
- Timed metadata: `HLSTimedMetadataConfiguration`, `HLSTimedMetadataError`,
  `HLSTimedMetadataEvent`, `HLSTimedMetadataField`,
  `HLSTimedMetadataGroup`, `HLSTimedMetadataIdentifier`,
  `HLSTimedMetadataItem`, `HLSTimedMetadataMonitor`,
  `HLSTimedMetadataSource`, `HLSTimedMetadataValue`, and
  `HLSTimedMetadataValueExposure`. The monitor requires an explicit identifier
  allowlist, defaults to identifier-only events, bounds callback and
  subscriber delivery, and excludes raw data, URL objects, and load errors.
- Playback metrics: `HLSPlaybackMetricContext`, `HLSPlaybackMetricEvent`,
  `HLSPlaybackMetricMediaType`, `HLSPlaybackMetrics`,
  `HLSPlaybackMetricsError`, `HLSPlaybackMetricSummary`, `HLSPlaybackMode`,
  `HLSPlaybackBufferMetric`, `HLSPlaybackMetricDelivery`,
  `HLSPlaybackRenditionSelectionMetric`,
  `HLSPlaybackRateChangeMetric`, `HLSPlaybackRateChangeReason`,
  `HLSPlaybackReadinessMetric`, `HLSPlaybackStartupMetric`,
  `HLSPlaybackTransferMetric`, `HLSPlaybackVariantBitrateMetric`,
  `HLSPlaybackVariantSwitchMetric`, and `HLSPlaybackVariantSwitchPhase`. The
  bridge emits bounded, independently cancellable streams and removes
  transport identifiers, arbitrary errors, and non-finite numeric values.
  Startup diagnostics preserve exact request counts while bounding
  chronological request details. Readiness diagnostics cover both initial and
  subsequent likely-to-keep-up events. Rate-change diagnostics distinguish
  ordinary changes, stalls, and seek boundaries while preserving selected
  variant bitrates. Sequenced delivery exposes bounded-buffer loss through
  zero-based monotonically increasing positions, and the health analyzer
  retains the cumulative loss count without interpreting diagnostic pressure
  as playback impairment. Readiness, startup, and detailed switch metrics
  retain at most 256 valid loaded time ranges; detailed switch metrics expose
  only bitrate values and validated stable rendition IDs, never playlist URLs.
- Playback health: `HLSPlaybackHealthAnalyzer`,
  `HLSPlaybackHealthConfiguration`, `HLSPlaybackHealthIssue`,
  `HLSPlaybackHealthSnapshot`, `HLSPlaybackHealthStatus`, and
  `HLSPlaybackHealthThresholdPack`. The value reducer keeps rolling counts
  bounded, reconciles delivered summaries, and leaves observation, UI, and
  alerting policy with the application.
- Interstitial playback: `HLSInterstitialAssetListStatus`,
  `HLSInterstitialEventSnapshot`, `HLSInterstitialPlaybackMonitor`,
  `HLSInterstitialRuntimeEvent`, and `HLSInterstitialSkippableState`. The
  observation-only bridge emits bounded, value-redacted lifecycle streams
  while AVFoundation owns scheduling and system skip controls.
- Integrated timeline: `HLSIntegratedTimelineMonitor`,
  `HLSIntegratedTimelineSegmentKind`,
  `HLSIntegratedTimelineSegmentSnapshot`, `HLSIntegratedTimelineSnapshot`,
  `HLSIntegratedTimelineUpdate`, and `HLSIntegratedTimelineUpdateReason`. The
  version-gated, observation-only bridge emits bounded value snapshots of
  primary and interstitial ranges while the application owns playback,
  seeking, scheduling, and navigation policy.

### InnoNetworkHLSAudio

- The product remains present in the Swift 6.2 package graph so older
  toolchains can validate the rest of InnoNetwork, but its public declarations
  require the Xcode 27 SDK and Swift 6.4 compiler. Xcode 26 builds only the
  empty compatibility module and exposes no HLS-audio symbols.
- `HLSDecodedAudioConfiguration`, `HLSDecodedAudioError`,
  `HLSDecodedAudioOutput`, `HLSDecodedAudioSample`,
  `HLSDecodedAudioPacingConfiguration`, and
  `HLSDecodedAudioPacedSequence`. This version 27-only bridge provides one
  demand-driven decoded-PCM read at a time plus an optional non-prefetching,
  player-clock-paced sequence while the application owns the player, format
  conversion, processing, storage, UI, and protected-content policy.
- `HLSAudioMixProcessingCallbacks`, `HLSAudioMixProcessingContext`,
  `HLSAudioMixProcessingError`, `HLSAudioMixProcessingPosition`,
  `HLSAudioMixPreparationContext`, `HLSAudioMixProcessingTap`, and
  `HLSAudioMixStreamFlags`. On version 27 macOS, iOS, tvOS, and visionOS, the
  tap installs an exclusive full-mix processor with a preferred PCM format,
  reports the actual preparation format, and preserves replacement audio
  mixes during terminal detachment. The application owns real-time callback
  safety and protected-content policy; FairPlay audio is unavailable to the
  system tap.

### InnoNetworkHLSLive

- `HLSLiveCDNTuneInPack`, `HLSLiveConfiguration`,
  `HLSLiveEncryptionKeyPreloading`, `HLSLiveError`,
  `HLSLiveHTTPFreshness`, `HLSLivePartialSegment`, `HLSLiveReloadMode`,
  `HLSLiveEdgePosition`,
  `HLSLiveHealthAnalyzer`, `HLSLiveHealthConfiguration`,
  `HLSLiveHealthIssue`, `HLSLiveHealthSnapshot`, `HLSLiveHealthStatus`,
  `HLSLiveHealthThresholdPack`, `HLSLiveDVRConfiguration`, `HLSLiveDVRError`,
  `HLSLiveDVREvent`, `HLSLiveDVRInterstitialFailurePolicy`,
  `HLSLiveDVRInterstitialPack`, `HLSLiveDVRInterstitialPolicy`,
  `HLSLiveDVRInterstitialStatistics`, `HLSLiveDVRLimitPack`,
  `HLSLiveDVRPartCapturePolicy`,
  `HLSLiveDVRPartPack`, `HLSLiveDVRPreloadPack`, `HLSLiveDVRPreloadPolicy`,
  `HLSLiveDVRPreloadResourceStatistics`, `HLSLiveDVRPreloadStatistics`,
  `HLSLiveDVRProgress`, `HLSLiveDVRRecoveryPack`,
  `HLSLiveDVRRecoveryPolicy`, `HLSLiveDVRRetentionPolicy`,
  `HLSLiveDVRRetentionStatistics`,
  `HLSLiveDVRReceipt`, `HLSLiveDVRRecorder`, `HLSLiveDVRRecording`,
  `HLSLiveDVRRenditionPack`,
  `HLSLiveDVRRenditionSelectionPolicy`, `HLSLiveDVRStartPosition`,
  `HLSLiveDVRTrack`, `HLSLiveDVRTrackKind`, `HLSLiveDVRUnsupportedFeature`,
  `HLSLivePlaylistClient`, `HLSLivePlaylistSnapshot`, `HLSLiveReloadPack`, and
  `HLSLiveSegment`.
- `HLSLiveCDNTuneInPack` bounds or disables the Appendix C initial freshness
  requests. The client commits only fully parsed, mergeable responses and
  otherwise retains the newest valid snapshot.
- `HLSLiveDVRRecording.capturePlaybackSnapshot(to:)` publishes an immutable
  local VOD package at the next coherent segment boundary. Its bounded request
  lifecycle is represented by `HLSLiveDVRError.playbackSnapshotUnavailable`
  and
  `HLSLiveDVRError.playbackSnapshotRequestLimitExceeded(limit:)`; these symbols
  remain in the companion product's Provisionally Stable tier.
- `HLSLiveDVRConfiguration.advanced(...interstitials:)` preserves the existing
  overload family while opting into bounded package-local Apple HLS
  interstitial retention. Complete-event failure policy, retained statistics,
  and the typed interstitial limit failures remain in the companion product's
  Provisionally Stable tier.

### InnoNetworkWebSocket

- `JSONWebSocketMessageCodec`, `WebSocketCloseCode`,
  `WebSocketCloseDisposition`, `WebSocketConfiguration`,
  `WebSocketDecodedMessages`, `WebSocketError`, `WebSocketEvent`,
  `WebSocketFrame`, `WebSocketFrameKind`,
  `WebSocketHandshakeRequestAdapter`, `WebSocketManager`,
  `WebSocketMessageCodec`, `WebSocketMessageCodingError`,
  `WebSocketPingContext`, `WebSocketPongContext`, `WebSocketProtocolFeature`,
  `WebSocketSendOverflowPolicy`, `WebSocketState`, `WebSocketTask`,
  `WebSocketTypedChannel`, and `WebSocketTypedSendError`.

### InnoNetworkTrust

- `PublicKeyPinningEvaluator`, `PublicKeyPinningPolicy`, and
  `PublicKeyPinningPolicy.HostMatchingStrategy`.

### InnoNetworkAuthAWS

- `AWSSigV4Interceptor`.

### InnoNetworkPersistentCache

- `PersistentResponseCache`, `PersistentResponseCacheConfiguration`,
  `PersistentResponseCacheEvictionReason`, `PersistentResponseCacheStatistics`,
  and `PersistentResponseCacheTelemetryEvent`.

### InnoNetworkOpenAPI

- `OpenAPIRestOperation`, `OpenAPIRequest`, `InnoNetworkClientTransport`,
  and `InnoNetworkClientTransportError`.

### InnoNetworkTestSupport

- `MockURLSession`, `StubBehavior`, `StubNetworkClient`, `StubRequestKey`,
  `MockURLSessionResponse`, `VCRCassette`, `VCRInteraction`, `VCRMode`,
  `VCRRedactionPolicy`, `VCRRequest`, `VCRResponse`, `VCRURLSession`, and
  `WebSocketEventRecorder`.

### Root Macro Surface (Provisionally Stable)

- `APIDefinition(method:path:auth:)` attached macro.
- The default-enabled `Macros` package trait and `traits: []` opt-out.

The macro's `auth:` argument consumes the Stable `SessionAuthentication`
values. Their compatibility tier does not inherit the macro surface's
Provisionally Stable status.

The root `InnoNetwork` product exports the macro declaration when `Macros` is
enabled; no separate package or import is required. Expansion is
source-generation behavior, not a replacement runtime client API. The
annotated struct remains the endpoint contract and must declare
`APIResponse`; the macro derives conformance, method, path, explicit session
authentication, and the supported simple payload witnesses. A complete
`Parameter` + `parameters` pair remains authoritative for advanced endpoint
shapes.

The attached macro emits witnesses at the type's visibility (`public`,
`package`, or implicit internal). It fails closed on incomplete or ambiguous
definitions, including omitted auth, missing response type, invalid path
placeholders, and conflicting generated witnesses. Optional aliases used by a
path placeholder receive a targeted generated-code diagnostic without adding
a runtime or public helper symbol. An unannotated struct cannot expose endpoint
intent at its declaration; passing one to either `NetworkClient.request`
overload instead emits a targeted unavailable-overload diagnostic requesting
the macro or a manual conformance. The removed 4.x
`endpoint(_:_:as:)` expression macro has no 5.x compatibility contract;
``EndpointBuilder`` is the runtime-composed alternative.

`traits: []` removes the macro declaration and compiler plug-in products from
the consumer target graph and compilation. SwiftPM still resolves package-level
manifest dependencies and may resolve or fetch `swift-syntax`. Traits are
unified per package across a resolved graph, so another dependency enabling
the default `Macros` trait re-enables it for the shared package instance.

### SPI

InnoNetwork exposes a small set of execution-pipeline hooks through
`@_spi(GeneratedClientSupport)` for generated clients (for example, OpenAPI
adapters) that need to plug their own serialization and decoding into the
shared retry, refresh, and observability machinery. These symbols are
**best-effort**: they are not part of the default SwiftPM import contract,
they are not ABI-stable across releases, and they may evolve in any minor
release without a deprecation window. Callers must opt in with
`@_spi(GeneratedClientSupport) import InnoNetwork`.

| Symbol | Visibility | Stability |
|---|---|---|
| `LowLevelNetworkClient` | `@_spi(GeneratedClientSupport) public` | Best-effort, no ABI guarantee |
| `DefaultNetworkClient.perform(_:)` | `@_spi(GeneratedClientSupport) public` | Best-effort, no ABI guarantee |
| `DefaultNetworkClient.perform(executable:)` | `@_spi(GeneratedClientSupport) public` | Best-effort, no ABI guarantee |
| `SingleRequestExecutable` | `@_spi(GeneratedClientSupport) public` | Best-effort, no ABI guarantee |
| `RequestPayload` | `@_spi(GeneratedClientSupport) public` | Best-effort, no ABI guarantee |

See `Examples/WrapperSmoke` and `Examples/GeneratedClientRecipe` for the
intended usage shape.

Generated clients should prefer the stable `APIDefinition` wrapper path. The
SPI path is reserved for code generators that own custom serialization or
decoding and can pin an InnoNetwork revision.

#### `@_spi(GeneratedClientSupport)` Compatibility Contract

This subsection is the canonical contract for the
`@_spi(GeneratedClientSupport)` surface. It is referenced from
`Sources/InnoNetwork/InnoNetwork.docc/Articles/GeneratedClientRecipe.md` and
from `Examples/GeneratedClientRecipe` so generated-client authors have a
single entry point for the rules.

**1. SPI may break in any release, including minor releases.**

The symbols listed in the SPI table above sit *outside* the
SemVer contract that governs the `Stable` and `Provisionally Stable`
sections. They may be renamed, resigned, removed, or replaced in any
minor release (for example `5.1 → 5.2`) without a deprecation window
and without a `[Breaking]` callout in `CHANGELOG.md`. SPI changes still
appear in the changelog, but in a dedicated `[SPI]` subsection that
does not require a major version bump.

**2. The root macro does not bridge the generated-client SPI.**

`@APIDefinition` derives only stable/provisional endpoint protocol witnesses
and does not import `@_spi(GeneratedClientSupport)`. SPI changes therefore do
not require a corresponding macro expansion migration. Third-party generators
(custom OpenAPI adapters, in-house DSLs, hand-written `@_spi` imports) must
still validate their integration against each new InnoNetwork release.

**3. External `@_spi` imports are opt-in and unsupported.**

Code outside the `InnoNetwork` package that writes:

```swift
@_spi(GeneratedClientSupport) import InnoNetwork
```

is opting into a pre-release-grade surface. We do not run breakage
audits against external `@_spi` consumers, and Issues that report
"`@_spi` symbol X disappeared in 5.y" will be closed with a pointer to
this section. Specifically:

- **Build errors** after a minor bump are expected and not regressions.
- **Pin an exact released tag** if you import `@_spi`; a moving branch or
  `.upToNextMinor` is *not* tight enough.
- **Treat `@_spi` upgrades as code-level reviews** — diff the SPI
  surface in `Sources/InnoNetwork/...` and re-run your generator.

**4. Stable wrapper path is the supported escape hatch.**

If your generator does not need to own custom serialization or decoding,
prefer the stable `APIDefinition` / `MultipartAPIDefinition` wrapper
path. That path follows the standard `Stable` SemVer contract and never
requires `@_spi` import.

## Internal/Operational

- event pipeline metric payload and aggregation format
- append-log persistence format (`checkpoint.json`, `events.log`)
- reconnect taxonomy internal types and close disposition rules
- `InnoNetworkProtobuf` package composition and protobuf adapter surface
- package/internal request/response policy layers
- package/internal request execution pipeline stages that power auth refresh,
  coalescing, response cache, and circuit breaker features
- package-scoped `APISingleRequestExecutable` and
  `MultipartSingleRequestExecutable` adapters used only by the built-in client
- package-scoped `StateReducer` / `StateReduction` lifecycle vocabulary used
  by shipping modules; it is not part of the planned consumer-facing 5.x API
- benchmark baseline contents and update cadence
- lower-level execution hooks that are present in source but not part of the
  proposed 5.0 stable public contract

## Notes

- Stable items follow semantic versioning for the 5.0.0 line once it is tagged.
- `default` aliases are convenience entry points and should be treated as `safeDefaults` aliases.
- Configuration packs are public and supported; their operational tuning
  defaults are not guaranteed to stay numerically identical across releases.
  The underlying advanced builders are package implementation details.
- `LowLevelNetworkClient`, `perform(_:)`, `perform(executable:)`,
  `SingleRequestExecutable`, and `RequestPayload` are SPI surfaces.
  They are best-effort, are not part of the default SwiftPM import contract,
  and may evolve in any minor release without a deprecation window — see the
  SPI table under "Public Declaration Ledger" for the full list.
- `PublicKeyPinningPolicy.HostMatchingStrategy.unionAllMatches` preserves the
  existing host pin lookup behavior. `mostSpecificHost` is stable as an
  opt-in stricter matching mode for operators who separate parent and
  subdomain pins.
- `WebSocketCloseDisposition` is **Stable**; the observation property is
  SemVer-protected. Additional enum cases may be added in minor releases
  as new close-code classifications are formalised, but existing cases
  remain source-compatible.
- `WebSocketPingContext` and `WebSocketPongContext` public fields are stable
  because they are payloads of stable heartbeat events; their package-scoped
  initializers are construction details owned by the library.
- `WebSocketManager.retry(_:)` is an explicit logical restart. A successful
  call returns `WebSocketRetryResult`, whose `task` has a fresh `id` and whose
  bounded `events` stream is registered before the replacement transport can
  resume. The terminal source task and its listeners/streams remain bound to
  the retired identity. Automatic reconnect is a different operation: it
  preserves the public task and `id` while replacing the underlying
  `URLSessionWebSocketTask` for each transport generation.
- Explicit retry is accepted at most once for a terminal source task and only
  by the manager that owns it. It returns `nil` for a nonterminal, already
  claimed, foreign-manager, or post-shutdown source. If shutdown wins after
  retry admission, the non-`nil` result's task can already be terminal with the
  manager-shutdown connection error; its pre-registered stream carries that
  terminal outcome.
- `WebSocketTask.attemptedReconnectCount` may transiently observe
  `maxReconnectAttempts + 1` during the failure transition that emits
  `.error(.maxReconnectAttemptsExceeded)`. The counter is bumped **before**
  the cap check so the rejected attempt itself is counted ("we tried and even
  this attempt was over the limit"), and the same one-off overshoot applies
  when `.error(.reconnectWindowExceeded)` ends the duration-limited path.
  Observability layers that alert on the counter should treat values up to
  `max + 1` as in-spec and use the public error event to disambiguate the
  exhausted budget.
- Resilience policies are opt-in and provisionally stable.
  `RequestExecutionPolicy` is the stable custom hook for one transport
  attempt. It may invoke `RequestExecutionNext.execute()` zero, one, or
  multiple times, but cannot replace the request captured for that attempt.
  Retry scheduling, auth refresh replay, response-cache substitution,
  coalescing, and circuit-breaker state remain owned by built-in pipeline
  stages that may evolve internally.
- The root `@APIDefinition` macro is default-enabled by the `Macros` package
  trait. Core-only consumers can request `traits: []` consistently across the
  graph to exclude the macro declaration and compiler plug-in compilation;
  SwiftPM may still resolve or fetch manifest-level `swift-syntax` sources.
- Persistence and telemetry formats are not external storage contracts.
- Benchmark guard thresholds, guarded benchmark selection, and baseline
  contents are operational policy rather than public compatibility surface.
- Internal/Operational items may change in minor releases without separate deprecation windows.
- `NetworkError` is a `public` non-`@frozen` enum: new cases may be
  added in minor releases, with each addition documented in the
  changelog. Consumers who write exhaustive `switch` statements over
  `NetworkError` should add `@unknown default` to keep their code
  forward-compatible across minor bumps.
- `NetworkError.errorDescription` localization keys are intended to be a
  Provisionally Stable behaviour contract in 5.x. The package ships the
  English catalogue;
  applications own end-user localization. Existing key meanings are not
  repurposed without a changelog entry.

## Deprecation Policy

- Stable public APIs require a documented replacement before deprecation.
- Deprecations stay available for at least one minor release after the
  replacement ships, unless a security issue forces a faster removal.
- Provisionally stable APIs can change in minor releases, but each change must
  be called out in release notes with a migration path or an explicit statement
  that no source-compatible replacement exists yet.
- Internal/Operational items can change without deprecation because they are not
  part of the default SwiftPM import contract.

## 4.0.0 Migration Notes

These notes describe behaviour changes that landed during the 4.0.0
preparation cycle, where the published shape removes earlier
foot-guns. Each subsection captures the breaking change and its
rationale. This section is the *rationale record*; the canonical
step-by-step source migration lives in
[docs/Migration-4.0.0.md](docs/Migration-4.0.0.md) — when the two
disagree, the migration guide wins and this section should be
corrected. The matching `CHANGELOG.md` entries live under `[4.0.0]`.

### `DownloadManager.shared` removed

- **What changed.** `DownloadManager.shared` is removed. There is no
  global singleton; every `DownloadManager` is constructed explicitly
  through `DownloadManager(configuration:)`.
- **Why.** The 4.x accessor trapped via `fatalError` on duplicate
  session identifiers, then briefly mitigated to an Optional that hid
  the failure mode behind a silent `nil`. Both shapes forced every
  feature in a process onto a single `DownloadConfiguration` and made
  the failure path either fatal or invisible. Removing the singleton
  keeps the failure shape (`DownloadManagerError.duplicateSessionIdentifier`)
  visible at the call site and lets each feature own its own
  configuration.
- **Migration.** Replace `DownloadManager.shared` with an injected
  manager owned by the feature module:

  ```swift
  let manager = try DownloadManager(
      configuration: .safeDefaults(sessionIdentifier: "com.example.media")
  )
  ```

  Pass that manager to whatever component performs the download
  (typically via initializer injection). For tests, construct a manager
  with a UUID-suffixed session identifier to avoid cross-test
  collisions.

### Client capabilities migrate to `throws(NetworkError)`

- **What changed.** Every `NetworkClient` and `UploadNetworkClient` primitive
  now declares `async throws(NetworkError)`. The default forwarders in the
  protocol extensions match. `NetworkError.mapTransportError(_:)` is
  promoted from `internal` to `public` so out-of-package conformers can
  map foreign errors (`URLError`, `CancellationError`, custom transport
  failures) to the canonical `NetworkError` representation.
- **Why.** `RetryCoordinator` already normalises every classified
  failure into `NetworkError`, and `DefaultNetworkClient` maps the
  remaining foreign errors at the boundary. The untyped `throws` was
  the only thing forcing callers to write `catch let error as
  NetworkError` plus a redundant `default` arm; making the contract
  explicit collapses the boilerplate without changing observable
  semantics.
- **Migration.** Call sites using `try await client.request(...)`
  compile unchanged. Conformers (mocks, fakes, decorators) must update
  their method signatures to `async throws(NetworkError) -> ...`
  and convert any `throw error` that re-throws an arbitrary `Error`
  into either a `NetworkError` case or
  `NetworkError.mapTransportError(error)`.

### Client capabilities expose `tag:` overloads

- **What changed.** `NetworkClient` declares `request(_:tag:)`, while
  `UploadNetworkClient` declares `upload(_:tag:)`, alongside their untagged
  forwarders. The primitive methods accept an optional
  `CancellationTag` so callers can group requests for bulk cancellation
  via `DefaultNetworkClient.cancelAll(matching:)`.
- **Why.** `DefaultNetworkClient` already exposed the tagged path; the
  protocol omitted it, which meant code that programmed against
  `NetworkClient` could not opt into grouped cancellation without a
  cast. The 4.x asymmetry surfaced repeatedly in test stubs and
  generated clients.
- **Migration.** Existing call sites compile unchanged. Capability protocol
  conformers must implement their tagged primitive explicitly so grouped
  cancellation cannot be silently dropped by a default forwarding
  implementation. Stubs that do not own cancellable runtime work may
  forward to their untagged path, but wrappers around another
  matching capability protocol should preserve the tag when delegating.

### Request and multipart upload capabilities are independent

- **What changed.** `NetworkClient` contains only `APIDefinition` request
  execution. Multipart execution moves to the independent
  `UploadNetworkClient` protocol. `DefaultNetworkClient` and
  `StubNetworkClient` conform to both.
- **Why.** Request-only clients, decorators, and test doubles no longer need
  placeholder upload implementations. Upload-only boundaries likewise depend
  on the smallest contract they consume.
- **Migration.** Most concrete `DefaultNetworkClient` call sites are unchanged.
  Change an existential that invokes `upload` from `any NetworkClient` to
  `any UploadNetworkClient`; require `any NetworkClient & UploadNetworkClient`
  only when one dependency truly needs both capabilities.

### `Endpoint` extracted from endpoint protocols

- **What changed.** A new `Endpoint` protocol now captures the
  HTTP envelope surface (`method`, `path`, `headers`, `logger`,
  `requestInterceptors`, `responseInterceptors`,
  `acceptableStatusCodes`, `transport`) shared by `APIDefinition` and
  `MultipartAPIDefinition`. Both protocols inherit from `Endpoint`
  and only declare their body-strategy surface (`parameters` /
  `multipartFormData` + `uploadStrategy`).
- **Why.** The two endpoint protocols duplicated identical
  requirements and identical default implementations. Consolidating
  them onto `Endpoint` removes a class of drift bugs (defaults
  silently diverging on one protocol but not the other) and gives
  generated clients a single vocabulary for "the envelope" without
  reaching for two parallel protocols.
- **Migration.** Endpoint conformances do not need to change. The
  shared defaults moved to an `Endpoint` extension, so any
  `APIDefinition` or `MultipartAPIDefinition` written against 4.x
  compiles unchanged. Only code that explicitly enumerated the parent
  protocol's requirements (for example, library-internal generic
  helpers) needs to redirect to `Endpoint`.

### `NetworkError.objectMapping` split into `decoding(stage:)`

- **What changed.** The `NetworkError.objectMapping(_:_:)` enum case
  and its compatibility static factory are both removed. Decode
  failures now surface exclusively as
  `NetworkError.decoding(stage:underlying:response:)` carrying a
  `DecodingStage` (`.responseBody`, `.streamFrame`) so the failure
  site is explicit. A new `NetworkError.isDecodingFailure` helper
  makes "decode failures are not retried" expressible without pattern
  matching.
- **Why.** `objectMapping` collapsed every decode-related failure —
  buffered body and per-frame streaming decode — into one case.
  Retry policies could not distinguish "the stream framing was
  malformed" from "the JSON body had a missing field",
  and observability layers had to inspect the underlying error to
  classify the stage. Splitting the case lets policies and metrics
  branch on stage directly.
- **Migration.** Replace construction sites that called
  `.objectMapping(underlying, response)` with
  `.decoding(stage: .responseBody, underlying: underlying, response: response)`.
  Pattern-matching `case .objectMapping(let underlying, let response)`
  must be migrated to
  `case .decoding(let stage, let underlying, let response)`. Callers
  that previously branched on "decode failure vs other" can use
  `error.isDecodingFailure` instead of pattern matching.

### `MultipartUploadStrategy.platformDefault` is now the default

- **What changed.** `MultipartAPIDefinition.uploadStrategy`'s default
  is now `MultipartUploadStrategy.platformDefault`, a memory-aware
  `streamingThreshold` that picks **16 MiB** on iOS, watchOS, and tvOS
  and **50 MiB** on macOS and visionOS. The 4.x default was an
  unconditional 50 MiB threshold across every platform.
- **Why.** iOS and tvOS jetsam, and watchOS extension memory limits,
  routinely killed apps that uploaded 30–40 MiB media payloads. The
  unconditional 50 MiB ceiling let `inMemory` encoding allocate well
  above the platform's working-set headroom before the streaming
  fallback kicked in. Splitting the default by platform aligns the
  encoded body's peak memory with the host OS's tolerance.
- **Migration.** Multipart endpoints that did not override
  `uploadStrategy` get the new behavior automatically. On iOS,
  watchOS, and tvOS, bodies between 16 MiB and 50 MiB now stream to
  a temp file instead of being held in `Data`; this trades a small
  amount of disk I/O for a much lower memory footprint. Endpoints
  that need the previous 50 MiB threshold on every platform should
  override `uploadStrategy` with
  `.streamingThreshold(bytes: 50 * 1024 * 1024)`. Endpoints that
  already explicitly chose `.inMemory`, `.alwaysStream`, or a
  specific `.streamingThreshold(bytes:)` are unaffected.

### `TimeoutReason.resourceTimeout` is metrics-aware

- **What changed.** The transport mapper now formally produces
  `TimeoutReason.resourceTimeout` when callers supply
  `URLSessionTaskMetrics` and the configured resource-timeout
  interval. The metrics-aware overload returns `.resourceTimeout` for
  `URLError.timedOut` only when the task interval reaches the
  resource budget; otherwise it falls back to `.requestTimeout`.
- **Why.** Earlier 4.x snapshots reserved `.resourceTimeout` for
  higher-level transports without producing it from the built-in
  mapper, so callers could not branch on the resource-vs-request
  distinction reliably.
- **Migration.** None for the single-argument mapper, which retains
  its prior behaviour. Callers that already constructed
  `NetworkError.timeout(reason: .resourceTimeout, …)` directly are
  unaffected.
