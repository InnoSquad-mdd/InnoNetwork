# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and the project follows Semantic
Versioning.

## [Unreleased]

### Added

- `NetworkSnapshot` now reports Low Data Mode, expensive-path, DNS, IPv4,
  IPv6, and typed unsatisfied-reason state. `NetworkMonitoring.snapshots()`
  provides a latest-state stream that replays the current snapshot when one is
  available.
- `WebSocketMessageCodec`, `JSONWebSocketMessageCodec`, and the lazy
  `WebSocketDecodedMessages` sequence add typed application-message send and
  receive paths without introducing another relay task or message buffer.
- The new `InnoNetworkUpload` product adds file-backed foreground and
  background uploads with pre-registered progress streams, system-task
  restoration, bounded response capture, and `AnyResponseDecoder` integration.
  Background requests reject redirect-sensitive authorization and cookie
  headers because Foundation cannot expose every background redirect hop.
- `RefreshTokenPolicy` can now resolve an `AuthenticationRealm` per request.
  Refresh single-flight state, generations, and failure cooldowns are isolated
  by realm while the original single-token initializer keeps its behavior.
- `SemanticNetworkEventAdapter` maps lifecycle events to vendor-neutral HTTP
  semantic attributes without adding an exporter SDK dependency.
- Experimental `RateLimitExecutionPolicy` adds cancellation-aware fixed-window
  request pacing around each transport attempt, including retries.

## [5.1.0] - 2026-09-03

### Fixed

- Xcode 26 once again builds and tests the package by compiling the
  `InnoNetworkHLSAudio` product as an empty compatibility module;
  the actual decoded-audio and full-mix declarations remain validated with
  Xcode 27 and Swift 6.4 in required CI, release, and DocC lanes.
- The local release preflight now isolates Swift-package `xcodebuild` actions
  from co-located Xcode projects and workspaces so unrelated generated files
  cannot shadow the `InnoNetwork-Package` scheme.
- `HLSFairPlaySession` now compiles at the package's watchOS 9 floor by
  excluding its stored-asset overload together with the storage and offline
  readiness types that are intentionally unavailable on watchOS. Remote HTTPS
  FairPlay asset attachment remains available there.

### Added

- `HLSPlaybackHealthAnalyzer.ingest(_:)` accepts sequenced metric deliveries
  and reports their cumulative bounded-buffer loss through
  `HLSPlaybackHealthSnapshot.droppedMetricEventCount` without treating
  diagnostic backpressure as playback impairment.
- `HLSPlaybackMetrics.sequencedEvents()` wraps the existing URL-free playback
  metrics in a zero-based delivery sequence, allowing bounded-stream consumers
  to measure initial and subsequent event loss without an unbounded side
  channel.
- `HLSPlaybackMetrics.rateChangeEvents()` preserves finite previous/current
  rates, URL-free selected-variant bitrates, and typed rate-change, stall, seek
  start, or seek-completion reasons without expanding the existing general
  metric event shape.
- `HLSPlaybackMetrics.readinessEvents()` exposes bounded, URL-free selected
  variant bitrates and loaded-buffer snapshots for both initial and subsequent
  likely-to-keep-up events, without expanding the existing general metric
  event shape.
- `HLSPlaybackMetrics.variantSwitchEvents()` adds URL-free source and
  destination bitrate metrics for HLS variant switches. Version 26 systems
  also expose bounded, grammar-validated `STABLE-RENDITION-ID` values for the
  selected video, audio, and subtitle renditions without exposing their
  playlist URLs. Detailed startup and switch metrics also retain a shared,
  URL-free buffer snapshot with exact reported counts and at most 256 valid
  loaded time ranges; startup metrics include the selected variant bitrate.
  The existing general metric stream remains unchanged.
- `HLSPlaybackMetrics.startupEvents()` exposes the URL-free playlist,
  media-segment, and content-key request events that AVFoundation correlates
  with initial likely-to-keep-up. Counts remain exact when chronological
  request details exceed the caller-controlled bounded retention limit, and
  the existing general metric stream remains behaviorally unchanged.
- iOS 27 streaming-only `HLSFairPlaySession` instances can opt into FairPlay
  advisory keys and create a policy-matched `HLSFairPlayStreamingKeyWorkflow`.
  Cached advisory-key hits bypass license transport and response submission
  with a typed `fulfilledByAdvisoryKey` event; existing sessions remain
  non-advisory by default, and unsupported environments fail before delegate
  installation.
- `HLSFairPlaySession` can assign an opaque `HLSFairPlayAssetID` while it
  creates online or stored assets, then classify version 26 content-key
  requests as having no recipient, attached to a known asset, or initiated by
  an unrecognized recipient. The mapping exposes neither native recipients
  nor asset URLs and fails typed when an active identifier is reused.
- `HLSAssetDownloadEvent.variantSelection` exposes AVFoundation's chosen
  download variants before transfer progress. The replayable snapshot retains
  at most 64 URL-free bitrate and media-kind summaries plus the pre-truncation
  count; native variants and their media-playlist URLs remain private.
- FairPlay streaming and persistent-key acquisitions can opt into version 26
  anonymized device-ID randomization through
  `HLSFairPlayDeviceIdentifierPolicy`. The default preserves AVFoundation's
  existing behavior; unsupported systems and non-16-byte app-generated seeds
  fail with typed, localized errors before SPC generation.
- `HLSAssetDownloadSummary` exposes AVFoundation's version 26 offline HLS
  download summary through the existing bounded task event stream. Counts,
  downloaded bytes, finite duration, error presence, and at most 64 selected
  variant summaries cross the public boundary; URLs, task metrics, native
  objects, and underlying errors remain private. Earlier systems retain the
  existing event sequence without emitting a summary.
- `InnoNetworkHLSAVFoundation` adds a bounded streaming FairPlay key workflow
  for both initial and renewing requests, with typed response-submitted,
  response-accepted, retry, and value-redacted failure events. Downloaded
  `.movpkg` references can now be attached to a recreated FairPlay session for
  offline playback. An isolated, opt-in physical-iOS acceptance package
  requires SPC v3, actual KSM responses, AVFoundation success callbacks, and a
  protected download/reopen/playback cycle whose reopened store is paired with
  a rejecting transport. Certificates, credentials, authorization, KSM
  policy, and production key storage remain application-owned.
- `HLSOfflineAssetInspector` distinguishes missing, invalid, unrecognized,
  incomplete, and offline-playable AVFoundation `.movpkg` references. Its
  bounded `Sendable` snapshot includes the media choices and safe language
  tags that `AVAssetCache` reports as cached, plus typed Custom Media Selection
  coverage on version 26 systems. Inspection preserves task cancellation,
  opens only the stored file URL, and leaves package bytes and FairPlay key
  validity application-owned.
- `HLSIntegratedTimelineMonitor` adds a read-only bridge for AVFoundation's
  primary and interstitial playback timeline on macOS 15, iOS and tvOS 18,
  watchOS 11, and visionOS 2. Bounded `Sendable` snapshots preserve source and
  integrated ranges, loaded ranges, current-segment identity, and typed change
  reasons without exposing player items, assets, URLs, attributes, or response
  bodies. Each subscriber receives sampled playhead changes plus native
  schedule invalidations through an independently cancellable newest-value
  buffer.
- `HLSTimedMetadataMonitor` adds an allowlist-first
  `AVPlayerItemMetadataOutput` bridge. Identifier-only safe defaults load no
  values; explicit text, number, and date fields map into bounded `Sendable`
  events with sequence-flush and callback-overflow signals. Raw data, URL
  objects, underlying load errors, non-finite numbers, unsafe identifiers, and
  oversized text or language values do not cross the public boundary.
- `InnoNetworkHLSAudio` adds a version 27-only, optional decoded-PCM
  companion around `AVPlayerItemSampleBufferOutput`. It validates linear PCM
  requests, offers a concise Float32 configuration, preserves marker and
  sequence-restart metadata in typed `Sendable` samples, allows only one
  demand-driven read, and offers an optional non-prefetching sequence that
  paces read admission against the player-item clock with a bounded lead.
  On macOS, iOS, tvOS, and visionOS it also offers an exclusive, preferred-
  format full-mix processing tap with explicit real-time callbacks and safe,
  terminal detachment that preserves an application replacement audio mix.
  Player ownership, audio conversion, processing, storage, UI, and protected-
  content policy remain with the application; FairPlay audio is unavailable
  to the system processing tap.
- `HLSPlaybackAssetConfigurator` enables AVFoundation-managed CMCD request
  headers on caller-owned URL assets and reports unsupported operating systems
  (including watchOS, which has no asset resource-loader API) without exposing
  or generating transport header values itself.
- Apple interstitial metadata now types `X-CONTENT-MAY-VARY`, preserving its
  coordinated-playback guarantee while treating missing or future values as
  content that may vary, as required by the current HLS draft.
- HLS Media Characteristic tags now expose an extensible value type plus
  generated and translated conveniences. An opt-in subtitle provenance policy
  composes exclusion and preference with existing language, name, and default
  selection. Offline packages apply the same policy and preserve the exact
  typed characteristics after manifest reopening.
- Content Steering now applies an app-tunable, session-scoped pathway health
  policy to VOD, offline-package, and live resolution. Consecutive failures
  temporarily penalize a pathway, compatible alternatives remain reusable,
  and cooldown expiry permits deterministic re-entry. Value-redacted health
  snapshots expose attempts, success rate, availability, and typed selection-
  reason counts without copying request URLs, headers, or query values.
- `HLSPlaybackConfigurator` applies an immutable, value-typed command to a
  caller-owned `AVPlayerItem`. It configures variant and expensive-network
  limits, live-edge offset, server interstitial handling, and validated media
  commands without taking over player lifecycle. Version 26 systems use
  native Custom Media Selection Schemes; earlier systems deterministically
  match BCP 47 language and authored media characteristics.
- `HLSInterstitialPlaybackMonitor` exposes the caller-owned player's
  interstitial schedule, current event, asset-list status, system skip state,
  and terminal lifecycle as bounded, cancellation-safe `Sendable` events. The
  read-only bridge redacts asset URLs, response bodies, custom attributes, and
  underlying errors while AVFoundation retains schedule and skip-control
  ownership.
- `InnoNetworkHLSLive` adds an optional live-presentation reload companion.
  It accepts direct media or multivariant entry URLs, performs deterministic
  variant and Content Steering selection, preserves parent variable imports,
  and exposes selected variant, pathway, and rendition metadata on each
  snapshot. Compatible stable-variant pathways recover failed reloads, using
  rendition reports for bounded LL-HLS tune-in. It negotiates blocking reload
  and delta updates from typed server-control metadata, reconstructs skipped
  segments and Date Ranges by media sequence, falls back once to a query-clean
  full reload when history is unavailable, disables HTTP caching for every
  reload, and closes its bounded-memory snapshot stream at `EXT-X-ENDLIST`.
  Valid HTTP `Date`, `Age`, and `Last-Modified` metadata now becomes typed,
  value-only freshness evidence on each snapshot. The pure health analyzer
  reports tunable stale-response degradation and risk without exposing raw
  header strings or changing reload policy.
  Reload requests retain the shared typed request-policy, URL-admission,
  redirect, body-boundary, and value-redacted pathway-observation behavior.
- LL-HLS initial tune-in now follows the HLS 2nd Edition CDN algorithm when a
  cache supplies `Age`: it estimates a newer `_HLS_msn`/`_HLS_part` from
  `TARGETDURATION` and `PART-TARGET`, includes the subsecond safety margin,
  removes stale `_HLS_*` directives from the full entry request while
  retaining other query items, and validates each response before replacing
  the latest snapshot. A
  dedicated pack bounds or disables the best-effort additional requests.
- Media `EXT-X-KEY` state is now isolated by `KEYFORMAT`. Identity-format
  AES-128 remains downloadable when FairPlay or another packaged-key
  alternative appears before or after it, while resources that had only an
  unsupported format remain typed failures and `METHOD=NONE` clears every
  active alternative.
- LL-HLS `PART`, `MAP`, and resource-preload contexts now use the same
  `KEYFORMAT`-isolated key state as complete media resources. Identity AES-128
  selection is declaration-order independent, while every context freezes the
  active key at its own playlist boundary.
- VOD and offline-package transfers can opt into bounded identity AES-128
  `EXT-X-SESSION-KEY` preloading through `HLSTransferPack`. Up to four keys
  overlap media-playlist resolution, only selected-media keys are awaited and
  reused, unused work is cancelled, and failed single-attempt speculation
  falls back to the configured demand retry path. `prepare()` remains key-I/O
  free.
- `HLSLiveDVRRecorder` captures complete live TS or fMP4 segments into a
  bounded, URL-free local VOD package. It supports record-from-now and
  current-window starts, exact byte-range validation, progress events,
  in-process plus cross-process destination exclusion, and atomic commit.
  An opt-in bounded preload pack speculatively fetches clear `PART` and `MAP`
  hints, reuses bytes only after exact range and presentation-context
  confirmation, and otherwise falls back to the ordinary DVR transfer path.
  Progress and committed receipts expose separate, value-redacted preload
  request, completion, confirmation, reuse, miss, failure, cancellation,
  discard, and byte counters for partial segments and initialization maps.
  Fragmented MP4 DVR now preserves initialization-map rotation across primary
  and external rendition tracks, deduplicates repeated maps, emits local map
  boundaries per segment, and resumes both legacy single-map and new multi-map
  checkpoints.
  Complete `EXT-X-GAP` entries now retain primary and external-rendition
  timelines without requesting or synthesizing unavailable media. Primary
  progress and receipts expose a gap count, recovery checkpoints preserve gap
  state, and retroactive availability changes fail explicitly.
  `HLSLiveDVRRetentionPolicy` now offers opt-in rolling-window retention with
  complete-prefix eviction across primary media, external renditions, gaps,
  and rotated fMP4 maps. Durable checkpoints publish the replacement suffix
  before old files are reclaimed, recovery preserves cumulative typed eviction
  statistics, and the existing stop-at-limit behavior remains the default.
  Controllable recordings can now capture the next coherent complete-segment
  boundary as an independent, atomically published local VOD package without
  stopping ingestion. Snapshot publication stays isolated from rolling
  eviction and the final destination, outstanding requests are bounded to eight,
  and caller cancellation or snapshot-only storage failure does not cancel the
  recording.
  Encrypted
  media, external timeline resources, missing or retroactively changed
  initialization maps, and lost live-window history still fail without
  exposing a partial package.
- `HLSExternalResourceResolver` resolves inline or bounded remote
  `EXT-X-SESSION-DATA` plus Apple interstitial `ASSETS` JSON. Typed request
  purposes let authentication distinguish Session Data from asset lists;
  finite byte, asset-count, and timeout boundaries precede JSON validation,
  while direct interstitial assets require no network request.
- Apple `_hls.localized-rendition-names` Session Data now resolves into a
  bounded typed catalog. Primary-language translations match ordered locale
  preferences and fall back to the authored `EXT-X-MEDIA` name, while name
  decoration remains application- or AVKit-owned.
- Apple `com.apple.hls.chapters` Session Data now resolves into bounded typed
  chapters, localized titles, admitted image references, and recursive
  metadata values. Omitted durations follow source order, image references use
  the final redirected JSON URL, and explicit chapter/entry/depth limits reject
  malformed or excessive documents before they reach application code. The
  catalog also exposes authored title languages, preferred-language title and
  image-category selection, and overlap-aware active chapters for player UI.
- Date Range preload resources and `com.apple.hls.daterange-schedule` JSON are
  typed and opt-in. Matching preloaded bytes avoid a duplicate schedule
  request; nested schedules preserve server order while enforcing parent
  bounds, cue semantics, playlist-wide identifier uniqueness, live-join
  offsets, and finite byte, entry-count, and depth limits.
- `EXT-X-PRELOAD-HINT:TYPE=KEY` now exposes method, key-format, format-version,
  range, and estimated first-use metadata. The live companion accepts an
  opt-in application key preloader and spreads one callback across the
  projected first-use window without requesting or storing key bytes itself.
- `_hls.media-presentation-settings` Session Data now resolves into a bounded
  Custom Media Selection Scheme. Typed selectors, localized setting names,
  language decorations, and deterministic language/selector-priority matching
  let applications build custom rendition controls without parsing JSON or
  raw `EXT-X-MEDIA` attributes.
- HLS release validation now pins embedded media fixtures by SHA-256 and
  container structure, runs deterministic parser mutations, rejects
  quadratic large-playlist scaling, and repeats live-stream plus
  AVFoundation event-delivery races. The bounded release shard inventory now
  includes all four HLS test products. A checked-in audio fragmented-MP4
  fixture and ephemeral loopback server now prove real `AVPlayer` playback and
  decoded PCM delivery on supported hosts. A fail-closed full-release gate
  validates the pinned MPEG-TS, video fragmented-MP4, and audio fragmented-MP4
  fixtures with Apple's separately installed Media Stream Validator and HLS
  Report, rejects validator errors and report `Must Fix` findings, and retains
  diagnostic artifacts.

- `InnoNetworkHLSAVFoundation` adds an optional native companion for
  system-managed HLS persistence. It owns a reconnectable
  `AVAssetDownloadURLSession`, restores tasks by a caller-stable background
  identifier, exposes bounded event streams plus pause/resume/cancel controls,
  and hands background completion back to the host application. A synchronous
  main-actor configuration closure covers media selection without crossing a
  non-`Sendable` AVFoundation boundary. A bounded, versioned Codable library
  groups validated `.movpkg` references without taking metadata-persistence
  ownership. `HLSFairPlaySession` retains the application key delegate,
  validates and attaches assets before loading, and exposes explicit detach
  and expiration while SPC/CKC transport and persistent-key storage remain
  application-owned. HTTPS admission, optional app-group storage, artwork
  bounds, duplicate-session rejection, and invalidation-safe lifecycle gates
  make the platform limitations explicit. The companion also bridges
  `AVPlayerItem.allMetrics()` into bounded, independently cancellable playback
  streams whose typed events remove URLs, headers, session identifiers, task
  metrics, arbitrary error values, and non-finite measurements.
  `HLSPlaybackHealthAnalyzer` deterministically reduces those delivered events
  into bounded rolling counters, stable diagnostic issues, and
  healthy/degraded/critical snapshots without taking observation, UI, or
  alerting ownership.
  `HLSFairPlayPersistentKeyWorkflow` adds a bounded stored-key-first
  restore-or-create path with app-injected license transport and secure
  storage, typed value-redacted failures, cancellation preservation, updated
  key forwarding, and no library-owned credentials, Keychain schema, or key
  files.

- `InnoNetworkHLS` adds an optional companion product with bounded playlist
  resolution, explicit quality/bandwidth variant policies, browser-free VOD
  segment download, ordered TS or fragmented-MP4 assembly events, caller-
  injected transport policy, per-resource and whole-download byte budgets,
  required/best-effort/disabled destination-capacity policy, observable core
  retry-policy backoff, explicit indeterminate progress, bounded parallel
  prefetch, stable error codes with preserved underlying transport context,
  event-stream and one-shot download surfaces, and exclusive destination
  commits. Single-file capability validation rejects discontinuities, gaps,
  I-frame-only playlists, and multiple initialization sections before media
  transfer. Byte-range and CMAF resources use exact partial-response validation
  and bounded contiguous-range coalescing. Destination-scoped checkpoints
  resume interrupted VODs at durable resource boundaries, while shared
  write-time capacity reservations prevent parallel staging and assembly from
  overcommitting the configured free-space floor. Real MPEG-TS and
  fragmented-MP4 fixtures verify AVFoundation readability. Bundle the matching
  disk-space Required Reason API privacy manifest. Multivariant parsing now
  exposes typed audio/subtitle renditions and codec, frame-rate, subtitle-group,
  and video-range metadata; deterministic rendition selection and an opaque
  playback-capabilities pack support language- and device-aware planning.
  Advisory preparation snapshots expose the selected media plan without
  creating files, while committed receipts report the output size, container,
  selected variant, and resumed transfer count. A multi-rendition offline
  package path now preserves the selected primary stream plus explicit
  external audio and subtitle renditions as separate local playlists and
  resources. It rewrites byte ranges to complete local files, generates a
  local multivariant entry playlist and URL-free manifest, enforces one shared
  media-byte budget, bounds external rendition fan-out per kind, and atomically
  commits or removes the complete directory. Both download paths now combine
  their in-process destination registry with a crash-safe OS advisory lock so
  app, extension, and helper processes sharing a container fail fast with
  `destinationInUse` instead of writing the same destination concurrently.
  Identity-format `METHOD=AES-128` VOD resources now use exact 16-byte key
  responses plus explicit or media-sequence-derived IVs for streaming
  AES-CBC/PKCS#7 decryption before assembly. Keys remain memory-only, key
  fingerprints invalidate stale resume boundaries, encrypted byte ranges keep
  independent IV boundaries, and localized offline playlists remove source
  key declarations. SAMPLE-AES and FairPlay key formats remain typed
  unsupported cases.
- HLS transport customization now has a purpose-aware
  `HLSRequestPolicy`. Entry and media playlists, media resources, AES-128 keys,
  and Content Steering manifests receive typed request contexts without URL
  suffix inference. Optional HLS request observers receive only request IDs,
  purpose, resource/retry indexes, HTTP status, and stable failure
  classifications; URLs, headers, query values, bodies, and arbitrary error
  messages are absent by construction. Existing untyped request adapters
  remain source-compatible.
- `InnoNetworkHLS` offline packages now use manifest schema 3 with exact file
  membership, byte counts, and streaming SHA-256 integrity records.
  `HLSOfflinePackageStore` reopens committed packages as receipts and rejects
  traversal, symbolic links, missing or unreferenced files, malformed local
  playlists, checksum mismatches, and unknown schemas. Schema 1/2 packages
  remain readable with structural validation; checksums detect corruption but
  are not an authenticity signature.
- Offline package downloads now default to destination-scoped automatic resume.
  Each completed resource receives a constant-size durable checkpoint, retained
  files are checksum-validated before reuse, and any source, playlist identity,
  rendition, resource, HTTP validator, or AES-key-plan change restarts cleanly.
  `HLSOfflinePackageStoragePack` accepts `.disabled`, receipts report the reused
  transfer count, and only the complete package directory remains public.
- `InnoNetworkHLS` now exposes HLS 2nd Edition selection metadata including
  playlist protocol version and independent-segment signaling, video and
  closed-caption renditions, stable rendition/variant IDs, associated
  languages, accessibility characteristics, audio channel/bit-depth/sample-
  rate hints, author scores, supplemental codecs, and pathway IDs. Attribute
  lists reject duplicate or malformed fields. Offline package manifests
  preserve applicable rendition and variant metadata without retaining source
  URLs.
- HLS 2nd Edition draft-22 inspection now exposes media target duration,
  media/discontinuity sequences, `EVENT`/`VOD` mutability, applied
  `EXT-X-BITRATE` values, and typed variant HDCP, allowed content-protection,
  and required video-layout metadata. Content Steering clones and offline
  package manifests preserve the new variant constraints. Apple authoring
  inspection additionally checks TLS, frame rate, mixed-range declarations,
  score consistency, caption language, steered identity, and LL-HLS
  program-date-time/partial hold-back guidance.
- HLS playlist resolution now supports bounded HLS 2nd Edition
  `EXT-X-DEFINE` substitution across URI, quoted-string, and hexadecimal
  values. Explicit media-playlist imports receive only variables declared by
  their multivariant parent, `QUERYPARAM` reads the final redirected playlist
  URL, protocol compatibility is enforced, and offline packages remove
  definitions and signed values from persisted playlists.
- HLS multivariant resolution now executes bounded Content Steering manifests,
  including TTL and reload caching, initial-pathway fallback, ordered pathway
  failover, data URLs, and VERSION 1 pathway cloning with host, query, stable-
  variant, and stable-rendition URI replacement. Both single-file and offline
  planners share the same steering catalog; offline steering additionally
  rejects pathway sets that cannot prove stable variant and rendition identity.
- Single-file HLS downloads can now recover from a transient media-resource
  failure by lazily activating a lower-priority Content Steering pathway after
  normal retries are exhausted. Recovery requires stable variant identity and
  an equivalent resource plan, shares concurrent pathway activation, can be
  disabled independently, and emits value-redacted typed decision events.
- `InnoNetworkHLSAVFoundation` now provides validated, Codable `.movpkg`
  references and an actor-isolated storage lifecycle surface for availability,
  automatic-purge policy, and idempotent removal. Policy calls fail safely in
  unidentified host processes and removal rejects symbolic-link packages.
- Playlist resolution and inspection now expose typed Low-Latency HLS server
  control, partial segments, preload hints, rendition reports, and delta
  updates. Cross-field timing/range/version rules are validated, while
  resource-bearing LL-HLS tags explicitly block persistence paths that do not
  retain them.
- Playlist inspection now accepts an opt-in
  `HLSPlaylistInspectionPack.appleAuthoring` profile. It emits line-addressable
  advisory findings for target duration, independent segments, variant
  ordering, codecs, average bandwidth, resolution, and protocol versions while
  keeping runtime capability decisions separate.
- Multivariant parsing now exposes typed `EXT-X-SESSION-DATA` and
  `EXT-X-SESSION-KEY` metadata with language-aware identity, resolved resource
  URLs, key formats, versions, and IVs. Playlist inspection never fetches key
  bytes, and diagnostics remain value-redacted.
- Low-Latency HLS relationship checks now follow feature-specific
  compatibility versions, require valid skip/hold-back bounds, enforce partial
  duration exceptions and VOD preload constraints, and accept advisory or
  inherited rendition-report forms without over-rejecting valid playlists.
- HLS multivariant parsing now exposes `EXT-X-I-FRAME-STREAM-INF` entries as a
  separate trick-play variant collection. Content Steering clones and fails
  over those variants with the regular pathway catalog. Offline rendition
  packs can opt into external VIDEO renditions and I-frame-only playlists,
  including alternative I-frame video groups; generated package indexes,
  durable resume plans, schema 3 manifests, reopen validation, preparation,
  and receipts preserve the selected layout. Raw single-file assembly still
  rejects I-frame-only media.
- HLS playlist inspection now returns value-redacted structured diagnostics
  with stable codes, severity, operation scope, and optional one-based source
  lines. Callers can distinguish document validity from raw single-file and
  offline-package capability without copying source URLs, attributes, or signed
  query values into diagnostic payloads.
- HLS terminal failures now match the core client's diagnostic ergonomics:
  English and Korean descriptions, actionable recovery suggestions,
  conservative retry hints, and user-visibility guidance are available from
  `HLSDownloadError` and its `NSError` bridge. AVFoundation session admission
  and lifecycle failures provide the same localized recovery guidance and a
  narrow retry hint for transient task-creation failure.

## [5.0.0] - 2026-07-21

### Breaking

- `DefaultNetworkClient.stream(_:)` and `stream(_:bufferingPolicy:)` now return
  `StreamingOutputSequence`, whose iterator uses typed
  `throws(NetworkError)`, instead of exposing the standard library's
  `AsyncThrowingStream<Output, Error>` failure erasure.
- `WebSocketManager.send(_:message:)`, `send(_:string:)`, and `ping(_:)` use
  typed throws: `async throws(WebSocketError)`. Transport failures that
  previously escaped `send` as raw `URLError` values are now funnelled
  through the shared error mapper, and lifecycle-gate cancellation surfaces
  as `WebSocketError.cancelled` instead of `CancellationError`, matching the
  core client's `throws(NetworkError)` contract.
- `NetworkClient` is request-only. Multipart execution moves to the independent
  `UploadNetworkClient` capability; `DefaultNetworkClient` and
  `StubNetworkClient` conform to both. Existentials that invoke `upload` must
  depend on `any UploadNetworkClient`, or on the composition only when they
  genuinely consume both capabilities.
- `ConcurrencyTokenBucket` is package-owned. Configure bounded transport
  concurrency with `ConcurrencyLimitExecutionPolicy(maxConcurrent:)`; reuse
  the same policy value across configurations when clients should share one
  cap. This removes the unsafe public acquire/release pairing surface while
  preserving FIFO admission and cancellation behavior.
- `NetworkConfiguration.recommendedForProduction(baseURL:)` is removed. Start
  with `safeDefaults(baseURL:)` and add only server-approved policies through
  the named `advanced(...)` packs.
- Configuration-pack stored properties are no longer public mutable surface;
  construct immutable packs through their named initializers. The package-only
  `NoOpNetworkLogger`, redirect sensitive-header set, and diagnostic URL helper
  also leave the public contract. Generated-client SPI executables inherit
  logger and empty-interceptor defaults when those witnesses are omitted.
- HMAC, JWT bearer, correlation-ID, and W3C trace interceptors now expose only
  their construction and protocol behavior; constructor-captured fields are
  implementation state rather than duplicate read-only API. WebSocket close
  handshake and automatic-reconnect flags are likewise manager-owned runtime
  state; observe `WebSocketTask.state`, errors, close disposition, and reconnect
  counters instead.
- Download and WebSocket advanced configuration now use immutable thematic
  packs, matching Core. Their mutable `AdvancedBuilder` types are package-only;
  configuration values remain public read-only properties on the final
  configuration structs.
- The nested `Packages/InnoNetworkCodegen` package and `#endpoint` expression
  macro are removed. `@APIDefinition(method:path:auth:)` now comes from
  `import InnoNetwork`, requires an explicit `.anonymous` / `.optional` /
  `.required` `SessionAuthentication` choice, and requires
  `typealias APIResponse` on the annotated struct.
- Every buffered, multipart, streaming, OpenAPI, and macro-assisted endpoint
  now carries explicit `SessionAuthentication`. `.required` fails before
  transport if no refresh policy or usable token is available; manual endpoint
  definitions and generated execution adapters no longer inherit anonymous
  authentication implicitly.
- Public optional overloads of
  `EndpointPathEncoding.percentEncodedSegment(_:)` are removed. Unwrap optional
  path values and define their nil behavior before encoding.
- The raw-string `NetworkClient.request(_:method:tag:)` convenience is removed.
  Use a named macro-assisted or manual `APIDefinition` for catalog requests, or
  an `EndpointBuilder` with an explicit authentication choice for one-off and
  runtime-composed requests.
- `NetworkConfiguration.responseBodyLimit` is removed. Configure collection
  mode and its optional byte ceiling together with
  `ResponseBodyBufferingPolicy.streaming(maxBytes:)` or
  `.buffered(maxBytes:)`.
- The no-op
  `WebSocketManager.handleBackgroundSessionCompletion(_:completion:)` method
  is removed. WebSockets do not use Foundation background sessions; route
  download callbacks to `DownloadManager` and complete unrelated identifiers
  at the application boundary.
- `WebSocketConfiguration.sessionIdentifier` and the matching advanced
  builder field are removed. The value was never applied to the default
  foreground `URLSession` used by WebSockets and provided no isolation or
  restoration semantics.
- `DownloadConfiguration.default` and `WebSocketConfiguration.default` are
  removed because they duplicate `safeDefaults()`. Use the named factory when
  passing a configuration explicitly; `DownloadManager()` and
  `WebSocketManager()` keep their zero-argument defaults.
- `DownloadManager.make(configuration:)` is removed because it exactly
  forwards to the public throwing initializer. Use
  `DownloadManager(configuration:)` as the single construction path.
- `PersistentResponseCacheStatistics` construction is package-owned. Obtain
  authoritative snapshots from `await cache.statistics()`; the public
  properties remain readable for dashboards and back-pressure decisions.
- `CircuitBreakerOpenError` construction is package-owned because the built-in
  breaker alone produces it. Its public `errorDomain` and read-only fields stay
  available for diagnostics.
- The direct 21-parameter `WebSocketConfiguration` initializer is
  package-owned. Use `safeDefaults()` for the secure preset or the named packs
  accepted by `advanced(...)` for explicit tuning.
- `WebSocketTask` construction is package-owned. Obtain handles from
  `WebSocketManager.connect(url:subprotocols:)` or an accepted explicit retry
  so every task is registered with its owning manager.
- `HTTPMethod` is now an extensible, `RawRepresentable` value type. Standard
  methods remain static constants; custom methods use the failable
  `init(rawValue:)`, which accepts only nonempty RFC 9110 tokens. Code that
  exhaustively switched over the former enum must use semantic helpers or a
  default branch. Retry, redirect, cache, coalescing, and curl diagnostics
  preserve exact method-token case. URLSession-backed entry points fail before
  transport when Foundation would silently rewrite the requested spelling.
- `RequestExecutionNext.execute(_:)` is replaced by
  `RequestExecutionNext.execute()`. Request mutation belongs in a
  `RequestInterceptor`; execution policies can observe, short-circuit, or
  replay only the executor-owned request.
- The seven deprecated `NetworkConfiguration.with(...)` modifiers are removed.
  Compose `ResiliencePack`, `AuthPack`, `ObservabilityPack`, `CachePack`, and
  `TransportPack` through `NetworkConfiguration.advanced(...)`.
- The process-wide mutable `ResponseCacheHeaderPolicy` registry is removed.
  Pass proprietary identity headers through
  `CachePack(sensitiveHeaderNames:)` or
  `ResponseCacheKey(..., sensitiveHeaderNames:)`; built-in credential headers
  remain protected automatically.
- The unused public streaming resume-strategy protocol is removed. It had one
  conformer and no client injection point, so `StreamingResumePolicy` now keeps
  buffering compatibility as a package-owned validation detail without changing
  reconnect behavior.
- `URLSessionProtocol` is package-owned. Production clients inject a concrete
  Foundation `URLSession`; consumer tests import `InnoNetworkTestSupport` and
  keep passing `MockURLSession` or `VCRURLSession` through focused overloads.
- `StateReducer` and `StateReduction` are package implementation vocabulary,
  not public API. Adopters should own reducer types at their feature boundary.
- Redirect defaults deny HTTPS downgrade and every cross-origin proposal that
  retains an unsafe method. Other cross-origin hops strip every caller-prepared
  original header plus built-in and configured sensitive session headers.
  Signed requests reject every automatic redirect.
- Core, OpenAPI, download, and WebSocket entry points reject malformed,
  origin-changing, traversal-bearing, or insecure absolute URLs by default.
  Plain HTTP and WebSocket connections require their explicit configuration
  opt-ins.
- Body-dependent authentication uses `RequestSigner` and `RequestBody` after
  interceptors and refresh-token application. Signed requests bypass response
  caches, request coalescing, and URLSession cache storage.
- `WebSocketHandshakeRequestAdapter.adapt(_:)` is `async throws`; connection
  setup awaits adapter completion and revalidates the resulting request before
  opening a transport.
- `WebSocketManager.retry(_:)` returns an optional `WebSocketRetryResult` with
  a fresh task and bounded event stream. The stream is registered before the
  replacement transport resumes, the source task stays terminal, and automatic
  reconnect still preserves its task ID.
- Download presets now use secure foreground sessions. Process-independent
  continuation is the explicit `backgroundTransfersEnabled()` opt-in, and
  `DownloadTask` construction is manager-owned rather than publicly
  fabricatable. The direct 22-parameter `DownloadConfiguration` initializer is
  package-owned; use `safeDefaults(sessionIdentifier:)` or
  `advanced(sessionIdentifier:_:)`.

See [`docs/Migration-5.0.0.md`](docs/Migration-5.0.0.md) for before/after
examples and [`docs/releases/5.0.0.md`](docs/releases/5.0.0.md) for the
release summary.

### Added

- An independent `OpenAPIAdopterSmoke` package now executes an
  `OpenAPIRestOperation` through the public `InnoNetworkOpenAPI`, core, and
  test-support products in CI, release validation, and local preflight.
- `DownloadManager.cancelAll(matching:)` cancels only the downloads whose
  `download(url:to:tag:)` / `download(url:toDirectory:fileName:tag:)` start
  carried the given `CancellationTag`, mirroring the core client's grouped
  cancellation for per-screen teardown. Tags are runtime-scoped and not
  persisted; tasks restored from a background session carry no tag.
- `stream(_:)` and `stream(_:bufferingPolicy:)` now document a concrete
  failure-type contract: every failure the returned stream finishes with is a
  `NetworkError`, so `catch let error as NetworkError` is exhaustive. The
  channel stays declared as `any Error` only because the standard library
  constrains `AsyncThrowingStream` construction to that failure type.
- `DefaultNetworkClient(baseURL:)` creates the ordinary safe-default client
  without exposing configuration policy to small integrations.
- Typed one-off requests can start directly from
  `EndpointBuilder<Response>.get/post/put/patch/delete`; the existing
  `EndpointBuilder<EmptyResponse>.decoding(_:)` composition remains available.
- The root package's default `Macros` trait enables macro-assisted explicit
  endpoint structs. GET/HEAD `query` and POST/PUT/PATCH/DELETE `body` stored
  properties derive payload witnesses, while a complete manual `Parameter` +
  `parameters` pair remains authoritative. Fail-closed diagnostics reject
  incomplete, unsafe, traversal-bearing, or ambiguous declarations, and reject
  custom-method simple payload inference.
- Passing an unannotated endpoint struct to either `NetworkClient.request`
  overload now produces an actionable error requesting `@APIDefinition` or a
  manual conformance instead of a generic protocol-conformance diagnostic.
- Macro method and authentication arguments accept contextual, type-qualified,
  and module-qualified standard members. Recognized members are canonicalized
  before generation so aliases and caller-owned lookalike types cannot change
  the inferred payload or authentication contract. The macro implementation is
  split into argument, declaration, payload, and path components, and an
  independent consumer harness measures Core-only and 0/10/50/200-endpoint
  clean and incremental builds with both SwiftPM and Xcode.
- The public macro declaration's DocC now states those same accepted method and
  authentication spellings, and the docs contract fails if it regresses to the
  former contextual-only wording.
- Five-repeat SwiftPM and Xcode consumer-build baselines now cover Core-only
  and macro-enabled 0/10/50/200-endpoint profiles. Raw samples, provenance,
  medians, and phase completeness are committed and validated in CI, release,
  and local preflight without treating machine-specific absolute time as a
  portable failure threshold.
- Macro expansion is covered by an end-to-end test that executes the generated
  endpoint through `DefaultNetworkClient`, including path substitution, query
  encoding, explicit authentication, and response decoding.
- `RequestSigner` and `RequestBody` provide late, body-aware authentication
  after request encoding, interceptors, and refresh-token application. The
  HMAC, request-minted JWT, and AWS SigV4 reference implementations support
  stable data and file payloads through this contract.
- Release provenance validation now requires annotated unprefixed SemVer tags
  on `origin/main`, deterministic default-trait and core-only CycloneDX 1.5
  SBOMs, and signed benchmark/SBOM release artifacts.
- CI builds DocC for all eight public products and fails closed when core or
  macro coverage artifacts are missing, empty, or contain absolute
  source paths.
- `docs/public-docc-products.txt` now owns the ordered DocC product contract.
  Local preflight, release validation, and Pages publication require exactly
  one archive for every SwiftPM library product; fixture tests reject missing,
  duplicate, or package-divergent product declarations.
- `Scripts/run_local_release_preflight.sh` provides one pre-tag entry point for
  deterministic contracts, every consumer example, the OpenAPI generator, and
  bounded tests. Its `--full` mode also generates coverage and both SBOM
  profiles, enforces the 20% benchmark guards, verifies all eight public DocC
  archives, and builds macOS, iOS, tvOS, watchOS, and visionOS locally.
- `Scripts/build_consumer_examples.sh` is now the shared CI, release, and local
  builder for every independent `Examples/*/Package.swift`. New examples are
  discovered automatically after their deployment floors pass validation,
  instead of requiring duplicated workflow step updates.
- `Benchmarks/guarded-benchmarks.txt` is the reviewed source of truth for the
  protected performance set. A shared runner injects that ordered set into CI,
  scheduled/manual benchmarks, release validation, contributor docs, and the
  local preflight, eliminating five repeated CLI declarations. The contract
  fails closed when a consumer bypasses the runner or a guard is absent from
  the default baseline.
- CI and release validation now cross-compile every public library product for
  the declared tvOS, watchOS, and visionOS device SDKs at the package's
  deployment floors as required gates. Every independent example manifest is
  checked against the same floors, its consumer smoke target builds on the
  host, generalized macro compile-failure fixtures run, and dependency review
  failures remain fail-closed in the workflow.
- `Scripts/check_apple_platform_build_contract.py` derives all five deployment
  floors from `Package.swift` and rejects CI, release, local-preflight, or
  cross-build-helper destinations and target triples that drift from them.
- The root `Package.resolved` is tracked as the repository's reproducible
  dependency input. CI rejects lock drift and deletion/untracked recreation;
  independent example and tool lock files remain ignored. Main and PR
  dependency submission now share a strict `Package.resolved` converter, and
  every `main` SHA receives a baseline snapshot while release CycloneDX
  generation remains independent. A privileged
  `workflow_run` follow-up checks out only trusted main code, reads the exact PR
  head lockfile as bounded data, and never executes PR code; this also covers
  Dependabot without granting the ordinary PR workflow write access. The
  read-only `Dependency Review` job requires a present, empty snapshot-warning
  header before review, so a missing Swift snapshot can no longer pass as an
  empty false green. Same-version revision substitutions are rejected before
  submission instead of disappearing from the version-based dependency diff.

### Fixed

- Persistent-cache best-effort maintenance failures now emit privacy-redacted
  OSLog diagnostics with a stable operation label. Cache hits and invalidation
  remain non-throwing, and no new public observability surface is introduced.
- Explicit shutdown now finishes accepted event-metrics input, drains pending
  reports, and stops periodic snapshot work for `DefaultNetworkClient`,
  `DownloadManager`, and `WebSocketManager`, even when callers retain the
  owning object after shutdown returns.
- An empty streaming event ID now performs the documented cursor reset and
  permits the next resume attempt without a `Last-Event-ID` header. Invalid
  cursor values still disable resume for the current attempt.
- Bounded file-upload responses now collect through the same chunk-granular
  transport bridge as inline requests, replacing byte-wise
  `URLSession.AsyncBytes` iteration on the upload path. The file body still
  streams from disk without loading into memory, and framing validation,
  redirect, and trust behavior are unchanged.
- The default `.streaming` response buffering policy now collects bodies
  through a chunk-granular, delegate-driven transport bridge instead of
  iterating `URLSession.AsyncBytes` one byte per call. Byte-wise iteration
  crossed Foundation's resilience boundary once per byte and measured well
  under 1 MiB/s; the chunked bridge collects the same bounded body at
  transport speed (measured ~2.5 GiB/s end to end) while enforcing the byte
  ceiling incrementally inside the transport, so buffered memory stays
  bounded regardless of consumer pacing. Package-owned test transport
  implementations keep the byte-wise fallback. A
  `client/streaming-collect-1mib` benchmark pins the collection path.
- `InnoNetworkClientTransportError` now conforms to `Sendable` and
  `LocalizedError`, matching every other public error type in the package.
  Transport failures can cross isolation boundaries under Swift 6 strict
  checking, and `localizedDescription` carries the transport diagnostic
  instead of the generic Foundation fallback.
- `@APIDefinition` path placeholders whose property typealiases resolve to
  Optional now fail with targeted unwrap-and-define-nil-behavior guidance
  instead of exposing the generated path encoder's generic constraint error.
- Core URLSession transports now suppress every
  `URLSessionConfiguration.httpAdditionalHeaders` value on cross-origin
  redirects. Foundation otherwise re-injected session defaults after the
  redirect policy removed them; same-origin redirects continue to receive the
  configured values.
- `InnoNetworkClientTransport` now applies the default redirect policy and URL
  admission to every generated-client redirect hop, strips caller-prepared
  headers and clears session-configured header values across origins, rejects
  unsafe cross-origin replay and HTTPS downgrade, and refuses background
  URLSession instances whose redirects Foundation does not expose to the task
  delegate.
- Persistent-cache index reads are capped at 16 MiB before JSON decoding;
  oversized indexes now cold-reset only cache-owned state instead of allowing
  unbounded initialization memory growth.
- Download persistence now anchors its owned root and session with directory
  file descriptors and performs lock, checkpoint, append-log, temporary, and
  quarantine operations through `openat`-family calls with no-follow and inode
  checks. Pre-existing managed-file symlinks, hard links, and FIFOs are rejected,
  while replacing the visible session parent cannot redirect metadata I/O outside
  the retained directory descriptor. The boundary assumes one cooperating owner;
  a caller-provided base path remains the explicitly trusted, canonicalized anchor.
- Download persistence now distinguishes malformed bytes from storage-access
  failures. Data Protection, permission, lock, and transient I/O errors fail
  initialization without quarantining valid state, while corrupt append-log
  recovery durably commits the valid prefix before moving or resetting the
  authoritative log.
- Persistent response-cache initialization now treats only a missing index as
  empty and resets only successfully read malformed or unsupported index data.
  Index symlinks, directories, FIFOs, and other non-regular entries are rejected
  without following or blocking on them.
  Protected-data, permission, and transient I/O failures preserve index/body
  files and fail initialization; transient live body reads return a miss while
  retaining the entry for a later retry.
- The API stability contract now classifies core `HTTPMethod` and
  `SessionAuthentication` as Stable only, and keeps Stable and Provisionally
  Stable code spans disjoint so symbols cannot silently receive contradictory
  5.x compatibility promises.
- `NetworkMonitor` now keeps `NWPathMonitor` actor-isolated instead of relying
  on its newer OS-only `Sendable` conformance, preserving clean compilation at
  the declared iOS 16, tvOS 16, and watchOS 9 deployment floors.
- Inline response collection through `safeDefaults` and the `advanced` preset
  is bounded to 5 MiB by default. Explicit
  `.streaming(maxBytes: nil)` or `.buffered(maxBytes: nil)` remains the
  deliberate unbounded opt-out, and byte-count arithmetic fails closed on
  overflow.
- `InnoNetworkTestSupport`'s `MockURLSession` and VCR replay mode remain
  compatible with the bounded `safeDefaults` profile. Their already-buffered
  fixtures are rejected at the transport boundary before response events,
  execution-policy response handling, auth refresh, cache, or interceptors.
  VCR record mode and arbitrary custom sessions without streaming support fail
  closed under bounded streaming policies.
- OpenAPI transport treats HEAD responses, successful CONNECT `2xx`,
  informational `1xx`, and statuses `204`, `205`, and `304` as bodyless, while
  preserving base paths and query ordering when adapting requests.
- WebSocket handshake redirects now pass through per-hop URL admission. Secure
  handshakes cannot downgrade to plain WS, traversal targets fail terminally
  without reconnect, and cross-origin redirects strip every caller-prepared
  header plus built-in credential fields while preserving CFNetwork's required
  handshake and subprotocol negotiation fields. The credential boundary stays
  fixed to the original handshake origin across multi-hop redirects.
- Curl export and observability redact query values, request bodies, URL
  credentials, fragments, sensitive path tokens, and error payload details by
  default. Controlled debugging can opt into query values or bodies explicitly.
- Persistent cache and download-owned state apply backup exclusion on Darwin
  after directory creation, atomic replacement, and reopen. On iOS, tvOS,
  watchOS, and visionOS they also apply
  `.completeUntilFirstUserAuthentication` Data Protection. Caller-owned final
  download files are not relabeled.
- Download persistence and completion staging no longer use a path-like,
  uppercase, oversized, empty, or non-ASCII `sessionIdentifier` as a raw path
  component. Those identifiers map to one deterministic SHA-256 component,
  preventing case-insensitive filesystem aliases, while conventional lowercase
  reverse-DNS identifiers keep their existing layout and Foundation still
  receives the original value.
- Download completion staging, pause/resume transactions, temporary-file
  cleanup, and shutdown behavior are bounded and cancellation-safe.
- WebSocket disconnect and shutdown teardown are bounded. The final terminal
  outcome is forced into every snapshotted consumer queue even under
  `.dropNewest` saturation, then the partition and registry close before
  snapshotted manager callbacks run.
- WebSocket reconnect-budget exhaustion emits one authoritative public error,
  and pong publication is attempted before its snapshotted manager handler;
  ordinary overflow and asynchronous listener delivery still apply.
- Refresh generations, shared cache lookups, and circuit-breaker half-open
  hysteresis preserve their state under cancellation and concurrent replay.
- Request event partitions preserve terminal events already queued behind a
  slow observer. Finish waits for partition-to-observer handoff without making
  request completion depend on observer handler latency.

### Changed

- `DefaultNetworkClient.stream(_:)` now applies one-output producer
  backpressure instead of accumulating an unbounded decoded-output queue.
  Explicit `.unbounded`, `.bufferingNewest`, and `.bufferingOldest` policies
  keep their existing opt-in semantics.
- `DownloadManager` and `WebSocketManager` keep their existing actor-owned
  lifecycle guarantees while their transfer commands, shutdown coordination,
  messaging, observation, and destination resolution are split into focused
  implementation units. This is an internal responsibility-boundary change;
  the public manager APIs and event ordering remain unchanged.
- `InnoNetworkOpenAPI` declares its direct `swift-http-types` dependency with a
  compatible 1.x range from 1.6.0 instead of relying on
  `swift-openapi-runtime` to expose it transitively. The floor matches OpenAPI
  Runtime 1.12's use of the `FoundationURL` trait. HTTPTypes remains confined
  to the optional `InnoNetworkOpenAPI` boundary; the core `InnoNetwork` public
  request, header, and response models do not expose it.
- Response-cache keys preserve query-item ordering, and persistent cache format
  version 4 HMAC-protects the complete raw query while retaining that ordering
  in the digest input. Version-3-or-older indexes cold-reset so legacy raw query
  material is not retained.
- `APISingleRequestExecutable` snapshots its transport policy once so request
  encoding and decoding observe one policy value.
- Scheduler-sensitive cancellation, refresh, and WebSocket tests use explicit
  gates; CI runs the complete root suite in serial coverage mode and across
  four bounded target shards.
- External WebSocket shutdown waits for already-admitted manager callbacks;
  reentrant shutdown from one of those callbacks initiates teardown and returns
  so a later external call can await the full boundary.
- Guarded benchmarks build in release mode, and the 5.0 release establishes an
  explicit API, migration, macro-trait, and release-integrity contract.
- Hosted benchmark baselines are recalibrated from a complete release-mode
  artifact after the systematic shift was confirmed across three successful
  runs, so debug-build overhead no longer distorts regression deltas.
- CI installs checksum-pinned Periphery and Codecov CLI releases, isolates
  Codecov OIDC to artifact-only upload jobs, bounds concurrent tests to four
  serial target shards, and skips only hosted platform components that the
  pinned runner does not install.
- Periphery now analyzes test-target references instead of baselining package
  test seams. Fourteen unused internal helpers are removed, 40 stale baseline
  entries are pruned, and seven protocol-shape or synthesized-`Equatable`
  analyzer false positives are added explicitly.

## [4.0.0] - 2026-05-02

InnoNetwork's first public release. The detailed 4.0.0 changelog has
been archived to [`docs/releases/4.0.0.md`](docs/releases/4.0.0.md) —
that document carries the curated release notes (originally a
one-pager) together with the full per-line CHANGELOG section that
previously lived here, plus the 49-item hardening coverage table and
release-quality matrix. The migration guide at
[`docs/Migration-4.0.0.md`](docs/Migration-4.0.0.md) remains the entry
point for upgrade work.

This `CHANGELOG.md` retains only the `Unreleased` window and the
archive pointers below; older releases (when they exist) follow the
same pattern.

### Older releases

Per-version detail is captured under [`docs/releases/`](docs/releases/).
The current archive is [`4.0.0.md`](docs/releases/4.0.0.md).
