#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
export LC_ALL=C

api_stability="$repo_root/API_STABILITY.md"
readme="$repo_root/README.md"
security_policy="$repo_root/SECURITY.md"
roadmap="$repo_root/docs/ROADMAP.md"
docs_release_state_validator="$repo_root/Scripts/validate_docs_release_state.sh"
six_release_state_validator="$repo_root/Scripts/validate_6_release_state.sh"

[[ -f "$docs_release_state_validator" ]] \
  || { echo "docs release-state validator is missing: $docs_release_state_validator" >&2; exit 1; }
[[ -f "$six_release_state_validator" ]] \
  || { echo "6.0 release-state validator is missing: $six_release_state_validator" >&2; exit 1; }
# The 5.x documentation contract is historical and remains covered by the
# validator's fixture tests. The working tree now describes the 6.0 draft, so
# current documentation checks apply the last released 5.x state explicitly.
docs_release_state="ready"
bash "$six_release_state_validator" --expect draft

# Per-module public-symbol allowlists. Keeping one
# `Scripts/symbols/*.allowlist` file per shipping module keeps PR diffs
# readable when only one module's surface changes. The script concatenates
# them into a single temporary allowlist so the rest of the validation logic
# stays unchanged.
public_symbols_dir="$repo_root/Scripts/symbols"
public_symbols_allowlist="$(mktemp)"
trap 'rm -f "$public_symbols_allowlist"' EXIT

if [[ ! -d "$public_symbols_dir" ]]; then
  echo "public symbol allowlist directory is missing: $public_symbols_dir" >&2
  exit 1
fi

shopt -s nullglob
allowlist_parts=("$public_symbols_dir"/*.allowlist)
shopt -u nullglob
if (( ${#allowlist_parts[@]} == 0 )); then
  echo "public symbol allowlist directory $public_symbols_dir contains no *.allowlist files" >&2
  exit 1
fi
cat "${allowlist_parts[@]}" > "$public_symbols_allowlist"
required_meta_docs=(
  "$repo_root/CONTRIBUTING.md"
  "$repo_root/CODE_OF_CONDUCT.md"
  "$repo_root/SECURITY.md"
  "$repo_root/SUPPORT.md"
  "$repo_root/CHANGELOG.md"
  "$repo_root/docs/RELEASE_POLICY.md"
  "$repo_root/docs/MIGRATION_POLICY.md"
  "$roadmap"
  "$repo_root/docs/Migration-5.0.0.md"
  "$repo_root/docs/Migration-6.0.0.md"
  "$repo_root/docs/releases/4.0.0.md"
  "$repo_root/docs/releases/5.0.0.md"
  "$repo_root/docs/releases/6.0.0.md"
)
required_feature_docs=(
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/Articles/EventDeliveryGuide.md"
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/Articles/OpenAPIGeneratorAdapter.md"
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/Articles/AuthRefresh.md"
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/Articles/CachingStrategies.md"
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/Articles/UsingMacros.md"
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/InnoNetwork.md"
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/MigrationTo6.md"
  "$repo_root/Sources/InnoNetworkOpenAPI/InnoNetworkOpenAPI.docc/InnoNetworkOpenAPI.md"
  "$repo_root/Sources/InnoNetworkDownload/InnoNetworkDownload.docc/Articles/BackgroundDownloads.md"
  "$repo_root/Sources/InnoNetworkDownload/InnoNetworkDownload.docc/Articles/Persistence.md"
  "$repo_root/Sources/InnoNetworkUpload/InnoNetworkUpload.docc/InnoNetworkUpload.md"
  "$repo_root/Sources/InnoNetworkWebSocket/InnoNetworkWebSocket.docc/Articles/FeatureScopedManagers.md"
  "$repo_root/Sources/InnoNetworkWebSocket/InnoNetworkWebSocket.docc/Articles/CloseCodes.md"
  "$repo_root/Sources/InnoNetworkWebSocket/InnoNetworkWebSocket.docc/Articles/Reconnect.md"
  "$repo_root/docs/WebSocketLifecycle.md"
)
example_docs=(
  "$repo_root/Examples/BasicRequest/README.md"
  "$repo_root/Examples/ErrorHandling/README.md"
  "$repo_root/Examples/README.md"
)

fail() {
  echo "docs-contract-sync: $1" >&2
  exit 1
}

# Assertion primitives shared with the helper unit tests.
# shellcheck source=Scripts/_docs_contract_helpers.sh
source "$repo_root/Scripts/_docs_contract_helpers.sh"

require_line "## Stable" "$api_stability"
require_line "## Provisionally Stable" "$api_stability"
require_line "## Internal/Operational" "$api_stability"
require_contains 'baseline caps inline' "$api_stability"
require_contains '`safeDefaults` and the `advanced` preset' "$api_stability"
require_line '## 6.0.0 Release Boundary' "$roadmap"
require_line '## 6.1.0 Candidate Scope' "$roadmap"
require_contains 'No item in the 6.1' "$roadmap"
require_contains 'HLS parsing, playback, download, FairPlay, and live DVR remain owned by' "$roadmap"

if [[ "$docs_release_state" == "draft" ]]; then
  require_contains 'branch: "main"' "$api_stability"
  require_contains 'branch: "main"' "$readme"
fi

expected_stable=(
'`APIDefinition`'
'`@APIDefinition(method:path:auth:)` and the default-enabled `Macros` package trait (promoted to Stable in 6.0.0; `traits: []` remains the supported opt-out)'
'`CancellationTag`'
'`Endpoint`'
'`MultipartAPIDefinition`'
'`TransportPolicy`'
'`RequestEncodingPolicy`'
'`ResponseDecodingStrategy`'
'`DefaultNetworkClient`'
'`DefaultNetworkClient.init(baseURL:)`'
'`DefaultNetworkClient.shutdown()`'
'`NetworkClient.request(_:)`'
'`NetworkClient.request(_:tag:)`'
'`UploadNetworkClient.upload(_:)`'
'`UploadNetworkClient.upload(_:tag:)`'
'`NetworkConfiguration.safeDefaults(baseURL:)`'
'`NetworkConfiguration.advanced(baseURL:resilience:auth:observability:cache:transport:)`'
'`DownloadConfiguration.safeDefaults()`'
'`DownloadConfiguration.safeDefaults(sessionIdentifier:)`'
'`DownloadConfiguration.advanced(sessionIdentifier:transfer:retry:observability:persistence:)`'
'`DownloadTransferPack`, `DownloadRetryPack`, `DownloadObservabilityPack`, and `DownloadPersistencePack`'
'`DownloadConfiguration.cellularEnabled()`'
'`DownloadConfiguration.backgroundTransfersEnabled()`'
'`WebSocketConfiguration.safeDefaults()`'
'`WebSocketConfiguration.advanced(connection:liveness:reconnect:messaging:observability:)`'
'`WebSocketConnectionPack`, `WebSocketLivenessPack`, `WebSocketReconnectPack`, `WebSocketMessagingPack`, and `WebSocketObservabilityPack`'
'`WebSocketHandshakeRequestAdapter`'
'`DownloadManager`'
'`WebSocketManager`'
'`WebSocketManager.shutdown()`'
'`WebSocketManager.retry(_:) -> WebSocketRetryResult?`'
'`WebSocketRetryResult`'
'`WebSocketTask.id`'
'`WebSocketEvent.ping`'
'`WebSocketEvent.pong`'
'`WebSocketEvent.error(.pingTimeout)`'
'`WebSocketPingContext`'
'`WebSocketPongContext`'
'`TrustPolicy`'
'`TrustChallengeOutcome`'
'`PublicKeyPinningPolicy`'
'`PublicKeyPinningPolicy.HostMatchingStrategy`'
'`PublicKeyPinningEvaluator`'
'`AnyResponseDecoder`'
'`URLQueryEncoder`'
'`URLQueryArrayEncodingStrategy`'
'`ResponseBodyBufferingPolicy`'
'`RequestExecutionPolicy`'
'`NetworkErrorCategory`'
'`NetworkError.category`'
'`NetworkError.isRetriableHint`'
'`NetworkError.isUserVisible`'
'`HTTPMethod`'
'`SessionAuthentication`'
'`EventDeliveryPolicy`'
'`WebSocketCloseCode`'
'`EndpointBuilder`, `EndpointPathEncoding` (promoted from Provisionally Stable in 4.x.x; the path-encoding shape and decoding helpers are SemVer-protected)'
'`DecodingInterceptor` (promoted from Provisionally Stable in 4.x.x)'
'`WebSocketCloseDisposition` (promoted from Provisionally Stable in 4.x.x)'
)

documented_stable=()
while IFS= read -r line; do
  documented_stable+=("$line")
done < <(
  awk '
    /^## Stable$/ { in_section = 1; next }
    /^## / { if (in_section) exit }
    in_section && /^- / {
      sub(/^- /, "")
      print
    }
  ' "$api_stability"
)

expected_sorted="$(printf '%s\n' "${expected_stable[@]}" | sort)"
documented_sorted="$(printf '%s\n' "${documented_stable[@]:-}" | sort)"
[[ "$expected_sorted" == "$documented_sorted" ]] || {
  echo "Expected Stable symbols:" >&2
  printf '%s\n' "${expected_stable[@]}" >&2
  echo "Documented Stable symbols:" >&2
  printf '%s\n' "${documented_stable[@]:-}" >&2
  fail "Stable symbol list in API_STABILITY.md does not match expected allowlist"
}

expected_provisionally=(
'benchmark runner CLI flags and JSON summary presentation details'
'troubleshooting guidance and examples in README/DocC'
'`InnoNetworkTestSupport` library product and its `public` symbols'
'`AnyEncodable`, `NetworkContext`, and `CorrelationIDInterceptor`'
'`RefreshTokenPolicy`, `RequestCoalescingPolicy`, retry, response cache, redirect, encoding utility, and circuit breaker policy surfaces'
'`MultipartResponseDecoder` buffered multipart response parsing surface'
'`MultipartStreamingResponseDecoder` streaming multipart response parsing surface'
'`InnoNetworkOpenAPI` companion product'
'`InnoNetworkUpload` companion product and its public file-upload, progress, restoration, bounded response, event, and error symbols'
'operation-first `NetworkClientConfiguration`, `OperationNetworkClient`,'
'bounded companion transport contracts: `BoundedNetworkTransfer`,'
'`PersistentResponseCache` statistics and telemetry surfaces'
'`WebSocketError.unsupportedProtocolFeature`'
'`WebSocketProtocolFeature`'
'`RequestSigner` and `RequestBody` late body-aware signing contract'
'`JWTBearerInterceptor` reference signer for request-minted JWT bearer tokens'
'`InnoNetworkAuthAWS` companion product and `AWSSigV4Interceptor` reference signer for single-shot AWS SigV4 signing'
'`StreamingBufferingPolicy`, `StreamingOutputSequence`, `TraceContextInterceptor`, `W3CTraceContext`, `CurlCommandOptions`, `IdempotencyKeyPolicy`, and `RequestPriority`'
'`HTTPHeaderName<Variant>` phantom-typed header key surface and its predefined `SingleValueHeader` / `RepeatableHeader` markers (also referenced as `HTTPHeaderName` / `HTTPHeaderVariant` for contract-sync purposes)'
'`MultipartUploadStrategy.threshold(bytes:)`'
'`PersistentResponseCacheStatistics.hitCount` / `missCount` / `evictionCount`'
'`DownloadTask.generation` / `attempt` observation accessors'
'`NetworkErrorCode` SSOT enum (4.0.0 baseline) — owns every `NetworkError.errorCode` raw value; new cases may be added in 5.x minors when `NetworkError` itself adds a case'
'`NetworkError.reachability(_:_:_:)` and `ReachabilityReason` (4.0.0 baseline)'
'`MultipartUploadStrategy.inMemory(maxBytes:)` (4.0.0 baseline) — the explicit cap and encoder accumulator guard are part of the contract'
'`DownloadTransferPack.init(...taskInactivityTimeout:...)` and `DownloadTask.lastProgressAt` (4.0.0 behavior carried into the 5.0 pack contract)'
'`ResponseCachePolicy.rfc9111Compliant(wrapping:)` directive-aware adapter (4.0.0 baseline)'
'`DownloadPersistencePack.init(...sharedContainerIdentifier:...)` (4.0.0 behavior carried into the 5.0 pack contract)'
'`ResponseCache.invalidateTargetURI(_:)` and RFC 9111 unsafe-method target URI invalidation (4.0.0 baseline)'
'`TransportPack.init(...streamingLineByteLimit:...)` (4.0.0 behavior carried into the 5.0 pack contract)'
)

stable_code_spans="$(
  printf '%s\n' "${expected_stable[@]}" \
    | awk -F'`' '{ for (field_index = 2; field_index <= NF; field_index += 2) print $field_index }' \
    | sort -u
)"
provisional_code_spans="$(
  printf '%s\n' "${expected_provisionally[@]}" \
    | awk -F'`' '{ for (field_index = 2; field_index <= NF; field_index += 2) print $field_index }' \
    | sort -u
)"
overlapping_code_spans="$(comm -12 <(printf '%s\n' "$stable_code_spans") <(printf '%s\n' "$provisional_code_spans"))"
if [[ -n "$overlapping_code_spans" ]]; then
  echo "Code spans present in both stability ledgers:" >&2
  printf '%s\n' "$overlapping_code_spans" >&2
  fail "Stable and Provisionally Stable ledgers must be disjoint"
fi

expected_shipping_public_declarations=(
  APIDefinition
  AnyEncodable
  AnyRequestExecutionPolicy
  AnyResponseDecoder
  AWSSigV4Interceptor
  CachedResponse
  CacheRevalidationState
  CancellationTag
  CircuitBreakerOpenError
  CircuitBreakerPolicy
  ContentType
  CorrelationIDInterceptor
  CurlCommandOptions
  DecodingInterceptor
  DecodingStage
  DefaultNetworkClient
  DefaultNetworkLogger
  DefaultRedirectPolicy
  DownloadConfiguration
  DownloadError
  DownloadEvent
  DownloadManager
  DownloadManagerError
  DownloadProgress
  DownloadState
  DownloadTask
  BoundedNetworkTransfer
  EmptyParameter
  EmptyResponse
  EndpointPathEncoding
  Endpoint
  EventDeliveryPolicy
  EventPipelineAggregateSnapshotMetric
  EventPipelineConsumerDeliveryLatencyMetric
  EventPipelineConsumerStateMetric
  EventPipelineHubKind
  EventPipelineMetric
  EventPipelineMetricsReporting
  EventPipelineOverflowPolicy
  EventPipelinePartitionStateMetric
  ExponentialBackoffRetryPolicy
  HTTPEmptyResponseDecodable
  HTTPHeader
  HTTPHeaders
  HTTPMethod
  IdempotencyKeyPolicy
  InMemoryResponseCache
  MultipartAPIDefinition
  MultipartFormData
  MultipartPart
  MultipartResponseDecoder
  MultipartStreamingEvent
  MultipartStreamingResponseDecoder
  MultipartUploadStrategy
  NetworkClient
  NetworkConfiguration
  NetworkContext
  NetworkErrorCategory
  NetworkErrorCode
  NetworkError
  NetworkEvent
  NetworkEventObserving
  NetworkInterfaceType
  NetworkLoggingOptions
  NetworkLogger
  NetworkMetricsReporting
  NetworkMonitor
  NetworkMonitoring
  NetworkReachabilityStatus
  NetworkRetryExecutor
  NetworkUnsatisfiedReason
  NetworkRequestContext
  NetworkSnapshot
  NetworkURLPolicy
  NetworkURLValidator
  OSLogNetworkEventObserver
  PersistentResponseCache
  PersistentResponseCacheConfiguration
  PersistentResponseCacheEvictionReason
  PersistentResponseCacheStatistics
  PersistentResponseCacheTelemetryEvent
  OpenAPIRestOperation
  OpenAPIRequest
  PublicKeyPinningPolicy
  RedirectPolicy
  ReachabilityReason
  RefreshFailureCooldown
  RefreshTokenPolicy
  RequestCoalescingPolicy
  RequestEncodingPolicy
  RequestExecutionContext
  RequestExecutionInput
  RequestExecutionNext
  RequestExecutionPolicy
  RequestInterceptor
  RequestPriority
  RequestBody
  RequestSigner
  RFC3986Encoding
  Response
  ResponseBodyBufferingPolicy
  ResponseCache
  ResponseCacheKey
  ResponseCachePolicy
  ResponseDecodingStrategy
  ResponseInterceptor
  RetryDecision
  RetryIdempotencyPolicy
  RetryPolicy
  EndpointBuilder
  SendableUnderlyingError
  ServerSentEvent
  ServerSentEventDecoder
  SessionAuthentication
  StreamingAPIDefinition
  StreamingBufferingPolicy
  StreamingResumePolicy
  TimeoutReason
  TraceContextInterceptor
  TransportPolicy
  TrustChallengeOutcome
  TrustEvaluating
  TrustFailureReason
  TrustPolicy
  PublicKeyPinningEvaluator
  URLQueryCustomKeyTransform
  URLQueryEncoder
  URLQueryFloatEncodingStrategy
  URLQueryKeyEncodingStrategy
  URLQueryArrayEncodingStrategy
  W3CTraceContext
  UploadConfiguration
  UploadError
  UploadEvent
  UploadManager
  UploadOperation
  UploadProgress
  UploadReceipt
  UploadState
  UploadTask
  NetworkClientConfiguration
  NetworkFailure
  NetworkFailureKind
  NetworkOperation
  NetworkOperationEvent
  NetworkRecoveryDisposition
  OperationNetworkClient
  JSONWebSocketMessageCodec
  WebSocketCloseCode
  WebSocketCloseDisposition
  WebSocketConfiguration
  WebSocketDecodedMessages
  WebSocketError
  WebSocketEvent
  WebSocketFrame
  WebSocketFrameKind
  WebSocketHandshakeRequestAdapter
  WebSocketManager
  WebSocketMessageCodec
  WebSocketMessageCodingError
  WebSocketPingContext
  WebSocketPongContext
  WebSocketProtocolFeature
  WebSocketSendOverflowPolicy
  WebSocketState
  WebSocketTask
  WebSocketTypedChannel
  WebSocketTypedSendError
)

# Top-level type declarations exposed under
# `@_spi(GeneratedClientSupport)`. These are part of the contract
# documented under API_STABILITY.md ("@_spi(GeneratedClientSupport)
# Compatibility Contract") and are surfaced by passing
# `--include-spi-symbols` to `swift package dump-symbol-graph` below.
# `validate_spi_allowlist_drift` greps the InnoNetwork module and
# fails the docs contract check when the source set drifts away from
# this allowlist — i.e. a new SPI type is added or an existing one is
# removed without updating this array and API_STABILITY.md.
expected_spi_public_declarations=(
  LowLevelNetworkClient
  RequestPayload
  SingleRequestExecutable
)

expected_test_support_public_declarations=(
  MockURLSession
  StubBehavior
  StubNetworkClient
  StubRequestKey
  VCRCassette
  VCRInteraction
  VCRMode
  VCRRedactionPolicy
  VCRRequest
  VCRResponse
  VCRURLSession
  WebSocketEventRecorder
)

validate_protocol_symbol() {
  local protocol_name="$1"
  local target="$2"
  local expected="$3"

  # Compare on whitespace-collapsed text so reformatting (line wraps,
  # extra spaces, tabs) does not break the contract check. Public API
  # tokens are still compared exactly; only horizontal whitespace
  # variations are normalized away.
  awk -v protocol_name="$protocol_name" -v expected="$expected" '
    function normalize(s) {
      gsub(/[ \t\r\n]+/, " ", s)
      sub(/^ /, "", s)
      sub(/ $/, "", s)
      return s
    }
    BEGIN { norm_expected = normalize(expected); body = "" }
    $0 ~ "^public protocol " protocol_name ": Sendable \\{$" { in_protocol = 1; next }
    in_protocol && /^\}$/ {
      norm_body = normalize(body)
      if (index(norm_body, norm_expected) > 0) { found = 1 }
      exit
    }
    in_protocol { body = body " " $0 }
    END { exit found ? 0 : 1 }
  ' "$target" || fail "symbol '$expected' is not present in $protocol_name protocol"
}

validate_benchmark_docs() {
  require_contains 'swift run -c release InnoNetworkBenchmarks --quick' "$readme"
  require_contains 'swift run -c release InnoNetworkBenchmarks --json-path /tmp/innonetwork-bench.json' "$readme"
  require_contains 'JSON summary' "$repo_root/Benchmarks/README.md"
  require_contains '"results"' "$repo_root/Benchmarks/README.md"
}

validate_doc_smoke_coverage() {
  local doc_smoke="$repo_root/SmokeTests/InnoNetworkDocSmoke/main.swift"
  require_contains 'import InnoNetwork' "$doc_smoke"
  require_contains 'NetworkClientConfiguration.secure' "$doc_smoke"
  require_contains 'OperationNetworkClient<DefaultNetworkClient>.self' "$doc_smoke"
  require_contains 'BoundedNetworkTransfer.self' "$doc_smoke"
  require_contains 'NetworkRetryExecutor()' "$doc_smoke"
  require_contains 'NetworkURLPolicy.http()' "$doc_smoke"
  require_contains 'import InnoNetworkPersistentCache' "$doc_smoke"
  require_contains 'import InnoNetworkOpenAPI' "$doc_smoke"
  require_contains 'import InnoNetworkUpload' "$doc_smoke"
  require_contains 'UploadState.self' "$doc_smoke"
  require_contains 'PersistentResponseCacheConfiguration' "$doc_smoke"
  require_contains '"InnoNetworkPersistentCache"' "$repo_root/Package.swift"
  require_contains '"InnoNetworkOpenAPI"' "$repo_root/Package.swift"
  require_contains '"InnoNetworkUpload"' "$repo_root/Package.swift"
  require_contains 'compileBackgroundDownloadArticleExamples' "$doc_smoke"
  require_contains 'waitForRestoration()' "$doc_smoke"
  require_contains 'DownloadPersistencePack' "$doc_smoke"
  require_contains 'compileWebSocketArticleExamples' "$doc_smoke"
  require_contains 'WebSocketManager(configuration:' "$doc_smoke"
  require_contains 'WebSocketLivenessPack' "$doc_smoke"
  require_contains 'FeatureScopedManagers' \
    "$repo_root/Sources/InnoNetworkWebSocket/InnoNetworkWebSocket.docc/InnoNetworkWebSocket.md"
}

validate_test_support_product() {
  require_contains 'name: "InnoNetworkTestSupport"' "$repo_root/Package.swift"
  require_contains 'targets: ["InnoNetworkTestSupport"]' "$repo_root/Package.swift"
  require_contains 'public final class WebSocketEventRecorder' \
    "$repo_root/Sources/InnoNetworkTestSupport/WebSocketEventRecorder.swift"
  require_contains 'public enum StubBehavior: Sendable, Equatable' \
    "$repo_root/Sources/InnoNetworkTestSupport/StubNetworkClient.swift"
  require_contains 'public struct StubRequestKey: Hashable, Sendable' \
    "$repo_root/Sources/InnoNetworkTestSupport/StubNetworkClient.swift"
  require_contains 'public final class StubNetworkClient' \
    "$repo_root/Sources/InnoNetworkTestSupport/StubNetworkClient.swift"
  require_contains 'public final class MockURLSession' \
    "$repo_root/Sources/InnoNetworkTestSupport/MockURLSession.swift"
  require_contains 'public final class VCRURLSession' \
    "$repo_root/Sources/InnoNetworkTestSupport/VCRURLSession.swift"
  require_contains 'public struct VCRCassette' \
    "$repo_root/Sources/InnoNetworkTestSupport/VCRURLSession.swift"
}

validate_resilience_public_api() {
  require_contains 'public struct RefreshTokenPolicy' \
    "$repo_root/Sources/InnoNetwork/Auth/RefreshTokenPolicy.swift"
  require_contains 'public struct RefreshFailureCooldown' \
    "$repo_root/Sources/InnoNetwork/Auth/RefreshTokenPolicy.swift"
  require_contains 'public struct RequestCoalescingPolicy' \
    "$repo_root/Sources/InnoNetwork/RequestCoalescing/RequestCoalescingPolicy.swift"
  require_contains 'public protocol RetryPolicy' \
    "$repo_root/Sources/InnoNetwork/RetryPolicy.swift"
  require_contains 'public struct RetryIdempotencyPolicy' \
    "$repo_root/Sources/InnoNetwork/RetryPolicy.swift"
  require_contains 'public struct ExponentialBackoffRetryPolicy' \
    "$repo_root/Sources/InnoNetwork/RetryPolicy.swift"
  require_contains 'safeMethods: Set<String>' \
    "$repo_root/Sources/InnoNetwork/RetryPolicy.swift"
  require_contains '"GET"' \
    "$repo_root/Sources/InnoNetwork/RetryPolicy.swift"
  require_contains '"HEAD"' \
    "$repo_root/Sources/InnoNetwork/RetryPolicy.swift"
  require_contains '"OPTIONS"' \
    "$repo_root/Sources/InnoNetwork/RetryPolicy.swift"
  require_contains '"TRACE"' \
    "$repo_root/Sources/InnoNetwork/RetryPolicy.swift"
  require_contains 'public enum ResponseCachePolicy' \
    "$repo_root/Sources/InnoNetwork/Cache/ResponseCachePolicy.swift"
  require_contains 'public protocol ResponseCache' \
    "$repo_root/Sources/InnoNetwork/Cache/ResponseCachePolicy.swift"
  require_contains 'public actor InMemoryResponseCache' \
    "$repo_root/Sources/InnoNetwork/Cache/ResponseCachePolicy.swift"
  require_contains 'public protocol RedirectPolicy' \
    "$repo_root/Sources/InnoNetwork/RedirectPolicy.swift"
  require_contains 'public struct DefaultRedirectPolicy' \
    "$repo_root/Sources/InnoNetwork/RedirectPolicy.swift"
  require_contains 'public enum CacheRevalidationState' \
    "$repo_root/Sources/InnoNetwork/NetworkObservability.swift"
  require_contains 'public enum RFC3986Encoding' \
    "$repo_root/Sources/InnoNetwork/RFC3986Encoding.swift"
  require_contains 'public enum URLQueryFloatEncodingStrategy' \
    "$repo_root/Sources/InnoNetwork/URLQueryEncoder.swift"
  require_contains 'public struct CircuitBreakerPolicy' \
    "$repo_root/Sources/InnoNetwork/CircuitBreaker/CircuitBreakerPolicy.swift"
  require_contains 'public struct CircuitBreakerOpenError' \
    "$repo_root/Sources/InnoNetwork/CircuitBreaker/CircuitBreakerPolicy.swift"
  require_contains 'public struct IdempotencyKeyPolicy' \
    "$repo_root/Sources/InnoNetwork/IdempotencyKeyPolicy.swift"
  require_contains 'refreshTokenPolicy: RefreshTokenPolicy? = nil' \
    "$repo_root/Sources/InnoNetwork/NetworkConfiguration.swift"
  require_contains 'idempotencyKeyPolicy: IdempotencyKeyPolicy = .disabled' \
    "$repo_root/Sources/InnoNetwork/NetworkConfiguration.swift"
  require_contains 'requestCoalescingPolicy: RequestCoalescingPolicy = .disabled' \
    "$repo_root/Sources/InnoNetwork/NetworkConfiguration.swift"
  require_contains 'responseCachePolicy: ResponseCachePolicy = .disabled' \
    "$repo_root/Sources/InnoNetwork/NetworkConfiguration.swift"
  require_contains 'circuitBreakerPolicy: CircuitBreakerPolicy? = nil' \
    "$repo_root/Sources/InnoNetwork/NetworkConfiguration.swift"
  require_contains 'redirectPolicy: any RedirectPolicy = DefaultRedirectPolicy()' \
    "$repo_root/Sources/InnoNetwork/NetworkConfiguration.swift"
}

validate_operational_dx_public_api() {
  require_contains 'public enum StreamingBufferingPolicy' \
    "$repo_root/Sources/InnoNetwork/StreamingAPIDefinition.swift"
  require_contains 'bufferingPolicy: StreamingBufferingPolicy' \
    "$repo_root/Sources/InnoNetwork/DefaultNetworkClient.swift"
  require_contains 'public struct TraceContextInterceptor: RequestInterceptor' \
    "$repo_root/Sources/InnoNetwork/TraceContextInterceptor.swift"
  require_contains 'public struct W3CTraceContext: Sendable, Equatable' \
    "$repo_root/Sources/InnoNetwork/TraceContextInterceptor.swift"
  require_contains 'public struct CurlCommandOptions: Sendable, Equatable' \
    "$repo_root/Sources/InnoNetwork/CurlCommand.swift"
  require_contains 'func curlCommand(options: CurlCommandOptions = CurlCommandOptions()) -> String' \
    "$repo_root/Sources/InnoNetwork/CurlCommand.swift"
  require_contains 'public enum RequestPriority: Sendable, Equatable' \
    "$repo_root/Sources/InnoNetwork/RequestPriority.swift"
}

validate_multipart_response_api() {
  require_contains 'public struct MultipartPart' \
    "$repo_root/Sources/InnoNetwork/Multipart/MultipartResponseDecoder.swift"
  require_contains 'public struct MultipartResponseDecoder' \
    "$repo_root/Sources/InnoNetwork/Multipart/MultipartResponseDecoder.swift"
}

validate_multipart_streaming_api() {
  require_contains 'public enum MultipartStreamingEvent' \
    "$repo_root/Sources/InnoNetwork/Multipart/MultipartStreamingResponseDecoder.swift"
  require_contains 'public struct MultipartStreamingResponseDecoder' \
    "$repo_root/Sources/InnoNetwork/Multipart/MultipartStreamingResponseDecoder.swift"
}

validate_openapi_companion_product() {
  require_contains 'name: "InnoNetworkOpenAPI"' "$repo_root/Package.swift"
  require_contains 'targets: ["InnoNetworkOpenAPI"]' "$repo_root/Package.swift"
  require_contains 'https://github.com/apple/swift-http-types' "$repo_root/Package.swift"
  require_contains '.upToNextMajor(from: "1.6.0")' "$repo_root/Package.swift"
  require_contains 'https://github.com/apple/swift-openapi-runtime' "$repo_root/Package.swift"

  local package_dump
  package_dump="$(xcrun swift package dump-package)" \
    || fail "unable to inspect Package.swift dependency ownership"
  if ! PACKAGE_DUMP="$package_dump" python3 - <<'PYEOF'
import json
import os
import sys

manifest = json.loads(os.environ["PACKAGE_DUMP"])
target = next(
    (target for target in manifest["targets"] if target["name"] == "InnoNetworkOpenAPI"),
    None,
)
if target is None:
    print("InnoNetworkOpenAPI target is missing", file=sys.stderr)
    sys.exit(1)

products = {
    (dependency["product"][0], dependency["product"][1])
    for dependency in target["dependencies"]
    if "product" in dependency
}
required = {
    ("HTTPTypes", "swift-http-types"),
    ("OpenAPIRuntime", "swift-openapi-runtime"),
}
missing = required - products
if missing:
    print(
        "InnoNetworkOpenAPI is missing direct product dependencies: "
        + ", ".join(f"{product} ({package})" for product, package in sorted(missing)),
        file=sys.stderr,
    )
    sys.exit(1)
PYEOF
  then
    fail "InnoNetworkOpenAPI must directly own its HTTPTypes and OpenAPIRuntime imports"
  fi

  require_contains 'public protocol OpenAPIRestOperation' \
    "$repo_root/Sources/InnoNetworkOpenAPI/OpenAPIAdapter.swift"
  require_contains 'public struct OpenAPIRequest' \
    "$repo_root/Sources/InnoNetworkOpenAPI/OpenAPIAdapter.swift"
}

validate_persistent_cache_operations_api() {
  require_contains 'public struct PersistentResponseCacheStatistics' \
    "$repo_root/Sources/InnoNetworkPersistentCache/PersistentResponseCacheTelemetry.swift"
  require_contains 'public enum PersistentResponseCacheTelemetryEvent' \
    "$repo_root/Sources/InnoNetworkPersistentCache/PersistentResponseCacheTelemetry.swift"
  require_contains 'public static func appGroupDirectoryURL' \
    "$repo_root/Sources/InnoNetworkPersistentCache/PersistentResponseCacheConfiguration.swift"
}

validate_macro_surface() {
  local macro_declaration="$repo_root/Sources/InnoNetwork/APIDefinition+Macro.swift"

  [[ ! -e "$repo_root/Packages/InnoNetworkCodegen/Package.swift" ]] \
    || fail "the retired Packages/InnoNetworkCodegen package manifest must not be restored"
  require_contains 'name: "Macros"' "$repo_root/Package.swift"
  require_contains '.default(enabledTraits: ["Macros"])' "$repo_root/Package.swift"
  require_contains 'name: "InnoNetworkMacros"' "$repo_root/Package.swift"
  require_contains 'condition: .when(traits: ["Macros"])' "$repo_root/Package.swift"
  require_contains 'https://github.com/swiftlang/swift-syntax.git' "$repo_root/Package.swift"
  require_contains '.upToNextMinor(from: "603.0.1")' "$repo_root/Package.swift"
  require_not_contains 'exact: "603.0.' "$repo_root/Package.swift"
  require_contains '#if Macros' "$macro_declaration"
  require_contains 'public macro APIDefinition(' "$macro_declaration"
  require_contains 'auth: SessionAuthentication' "$macro_declaration"
  require_contains 'contextual (`.get`), type-qualified (`HTTPMethod.get`), or' \
    "$macro_declaration"
  require_contains 'module-qualified (`InnoNetwork.HTTPMethod.get`) form' \
    "$macro_declaration"
  require_contains '(`SessionAuthentication.anonymous`), or module-qualified' \
    "$macro_declaration"
  require_contains '(`InnoNetwork.SessionAuthentication.anonymous`) form' \
    "$macro_declaration"
  require_contains '#externalMacro(module: "InnoNetworkMacros", type: "APIDefinitionMacro")' \
    "$macro_declaration"
  require_not_contains 'public macro endpoint' "$macro_declaration"
  require_contains '`@APIDefinition(method:path:auth:)`' "$api_stability"
  require_contains '`SessionAuthentication`' "$api_stability"
  require_contains '`Macros` package trait' "$api_stability"
  require_contains '### Root Macro Surface (Stable in 6.0)' "$api_stability"
  require_contains '## Stability contract' \
    "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/Articles/UsingMacros.md"
  require_contains 'protocol-composed endpoint metadata matching production catalog usage' \
    "$repo_root/Examples/MacroAdopterSmoke/README.md"

  local legacy_macro_pattern='#endpoint|public[[:space:]]+macro[[:space:]]+endpoint'
  if has_rg; then
    if rg -n --glob '*.swift' "$legacy_macro_pattern" \
      "$repo_root/Package.swift" "$repo_root/Sources" > /dev/null; then
      rg -n --glob '*.swift' "$legacy_macro_pattern" \
        "$repo_root/Package.swift" "$repo_root/Sources" >&2
      fail "the removed #endpoint macro surfaced in a shipping manifest or source target"
    fi
  elif grep -ERn --include='*.swift' "$legacy_macro_pattern" \
    "$repo_root/Package.swift" "$repo_root/Sources" > /dev/null; then
    grep -ERn --include='*.swift' "$legacy_macro_pattern" \
      "$repo_root/Package.swift" "$repo_root/Sources" >&2
    fail "the removed #endpoint macro surfaced in a shipping manifest or source target"
  fi
}

collect_public_symbols() {
  command -v python3 > /dev/null 2>&1 || fail "python3 is required for symbol graph public surface validation"

  find "$repo_root/.build" -path '*/symbolgraph/*.symbols.json' -type f -delete 2> /dev/null || true

  local dump_status
  set +e
  # `--include-spi-symbols` is intentional: the symbol-graph diff is
  # how the docs contract notices when a new `@_spi(GeneratedClientSupport)`
  # type silently joins the surface. The corresponding top-level type
  # allowlist lives at `expected_spi_public_declarations` and is
  # enforced by `validate_spi_allowlist_drift`.
  # Xcode 27's SwiftPM Xcode build path does not forward
  # `--include-spi-symbols` to swiftc by itself. The explicit compiler flag
  # keeps the emitted graph equivalent to the command's declared contract.
  swift package -Xswiftc -include-spi-symbols dump-symbol-graph \
    --minimum-access-level public \
    --include-spi-symbols \
    --skip-synthesized-members > /dev/null
  dump_status=$?
  set -e

  python3 "$repo_root/Scripts/collect_public_symbols.py" "$repo_root"

  if [[ "$dump_status" -ne 0 ]]; then
    echo "docs-contract-sync: swift package dump-symbol-graph exited with $dump_status after emitting required library symbol graphs; ignoring non-contract target extraction failure." >&2
  fi
}

validate_spi_allowlist_drift() {
  # Cross-check `expected_spi_public_declarations` against the source.
  # A regex find is sufficient — only top-level type declarations
  # (`protocol`, `struct`, `enum`, `class`, `actor`) count; SPI-tagged
  # extensions and members ride on the underlying type and don't
  # introduce a new contract surface.
  local actual_file actual_raw_file expected_file
  actual_file="$(mktemp)"
  actual_raw_file="$(mktemp)"
  expected_file="$(mktemp)"

  local grep_status
  grep_status=0
  grep -rhoE \
    '@_spi\(GeneratedClientSupport\) public (protocol|struct|enum|class|actor) [A-Z][A-Za-z0-9_]*' \
    "$repo_root/Sources/InnoNetwork" > "$actual_raw_file" || grep_status=$?
  if [[ "$grep_status" -gt 1 ]]; then
    rm -f "$actual_file" "$actual_raw_file" "$expected_file"
    fail "failed to scan @_spi(GeneratedClientSupport) declarations"
  fi

  awk '{ print $NF }' "$actual_raw_file" | sort -u > "$actual_file"

  printf '%s\n' "${expected_spi_public_declarations[@]}" \
    | sort -u > "$expected_file"

  if ! diff -u "$expected_file" "$actual_file" >&2; then
    rm -f "$actual_file" "$actual_raw_file" "$expected_file"
    fail "@_spi(GeneratedClientSupport) declarations drifted; update Scripts/check_docs_contract_sync.sh::expected_spi_public_declarations and API_STABILITY.md"
  fi

  rm -f "$actual_file" "$actual_raw_file" "$expected_file"
}

validate_ledger_to_allowlist_parity() {
  # Reverse-direction parity gate: every backtick-quoted type name listed
  # under `## Public Declaration Ledger` in API_STABILITY.md must
  # correspond to a real entry in `Scripts/symbols/*.allowlist`. The
  # forward direction (allowlist → ledger) is already enforced by
  # `validate_public_surface_ledger`. Adding this reverse check closes
  # the loop so a ledger entry cannot drift past a renamed or deleted
  # public type without surfacing in CI.
  local ledger_file allowed_types
  ledger_file="$(mktemp)"
  allowed_types="$(mktemp)"

  # Extract the bullet-list body of the ledger section. Stops at the
  # next `## ` heading. `### SPI` and `### …Package` headings inside
  # the section are preserved as plain content — their bullets are
  # parsed identically.
  awk '
    /^## Public Declaration Ledger$/ { in_section = 1; next }
    /^## / { if (in_section) exit }
    in_section { print }
  ' "$api_stability" > "$ledger_file"

  # Pull every `BacktickedName` token that appears inside a bullet item
  # (`- … `) under a `### <Module>` subsection. The ledger contains
  # explanatory prose between subsection headings — file paths, version
  # specifiers, and attribute spellings — that is not a symbol claim
  # and must be filtered out to keep the parity check signal-only.
  python3 - "$ledger_file" > "$allowed_types".raw <<'PYEOF'
import re
import sys

lines = open(sys.argv[1], "r", encoding="utf-8").read().splitlines()
in_subsection = False
buffered = []   # accumulate continuation lines of the current bullet

def flush(buffered, out):
    if not buffered:
        return
    bullet_text = " ".join(buffered)
    for match in re.findall(r"`([^`]+)`", bullet_text):
        token = match.strip()
        if not token:
            continue
        # Strip a trailing parenthesized signature to its base identifier.
        # The allowlist tracks both type-level names and callable declarations;
        # the exact public macro shape is additionally owned by
        # validate_macro_surface.
        token = re.sub(r"\(.*\)$", "", token)
        token = token.rstrip(".,;:")
        out.append(token)

out = []
for line in lines:
    if line.startswith("### "):
        flush(buffered, out)
        buffered = []
        # InnoNetwork 6 keeps the former HLS declaration ledgers as migration
        # history after those products moved to InnoStream. They are no longer
        # declarations of this package and therefore do not participate in
        # current symbol-graph parity.
        in_subsection = not line.startswith("### Historical 5.x ")
        continue
    if not in_subsection:
        continue
    stripped = line.lstrip()
    if stripped.startswith("- "):
        flush(buffered, out)
        buffered = [stripped[2:]]
    elif buffered and stripped and not stripped.startswith("#"):
        # Wrapped continuation of the current bullet (Markdown allows
        # bullets to span multiple indented lines).
        buffered.append(stripped)
    else:
        flush(buffered, out)
        buffered = []

flush(buffered, out)
print("\n".join(out))
PYEOF
  sort -u "$allowed_types".raw > "$allowed_types"
  rm -f "$allowed_types".raw "$ledger_file"

  # Build the set of acceptable identifiers from the allowlist. Both
  # bare type names (`Foo`) and dotted member names (`Foo.Bar`) count
  # — the ledger embeds either form.
  local accepted_file
  accepted_file="$(mktemp)"
  awk -F'\t' 'NF >= 3 && $0 !~ /^#/ { print $3 }' "$public_symbols_allowlist" \
    | sed -E 's/\(.*\)$//' \
    | sort -u > "$accepted_file"

  # Allowlist of ledger tokens that are intentionally prose, not symbols.
  # Keep this list small — every entry here is a place where the gate
  # cannot catch drift, so add only terms that have no allowlist
  # representative and would otherwise be removed from documentation.
  local prose_tokens=(
    'default'
    'public'
    'package'
    'open'
    'internal'
    'fileprivate'
    'private'
    'some'
    'any'
    'static let'
    'static var'
    'typealias'
    'where'
    'AuthPack'
    'EmptyResponse'
    # SwiftPM trait tokens are manifest contracts validated by
    # validate_macro_surface; they do not have symbol-graph entries.
    'Macros'
    'traits: []'
    # Swift attribute / SwiftPM / file-path references appear in
    # explanatory bullets within the ledger and have no symbol-graph
    # counterpart.
    '@_spi'
    '.exact'
    '.upToNextMinor'
    'Sources/InnoNetwork/'
  )
  local prose_file
  prose_file="$(mktemp)"
  printf '%s\n' "${prose_tokens[@]}" | sort -u > "$prose_file"

  local missing_file
  missing_file="$(mktemp)"
  comm -23 "$allowed_types" "$accepted_file" \
    | comm -23 - "$prose_file" \
    | grep -v '^$' > "$missing_file" || true

  if [[ -s "$missing_file" ]]; then
    echo "API_STABILITY.md Public Declaration Ledger lists names with no matching public symbol in Scripts/symbols/*.allowlist:" >&2
    sed 's/^/  - /' "$missing_file" >&2
    echo "Either add the missing symbols to the appropriate allowlist file, or remove the ledger entries." >&2
    rm -f "$allowed_types" "$accepted_file" "$prose_file" "$missing_file"
    exit 1
  fi

  rm -f "$allowed_types" "$accepted_file" "$prose_file" "$missing_file"
}

validate_public_surface_ledger() {
  [[ -f "$public_symbols_allowlist" ]] || fail "public symbol allowlist is missing: $public_symbols_allowlist"
  require_line $'InnoNetwork\tswift.type.method\tNetworkConfiguration.advanced(baseURL:resilience:auth:observability:cache:transport:)' "$public_symbols_allowlist"
  require_line $'InnoNetwork\tswift.struct\tAuthPack' "$public_symbols_allowlist"

  local expected_file
  local actual_file
  local expected_spi_file
  local actual_spi_file
  expected_file="$(mktemp)"
  actual_file="$(mktemp)"
  expected_spi_file="$(mktemp)"
  actual_spi_file="$(mktemp)"

  awk 'NF && $0 !~ /^#/ { print }' "$public_symbols_allowlist" | sort -u > "$expected_file"
  collect_public_symbols > "$actual_file"

  if ! diff -u "$expected_file" "$actual_file" >&2; then
    fail "public symbol graph drifted; update Scripts/symbols/*.allowlist and API_STABILITY.md"
  fi

  awk 'NF && $0 !~ /^#/ { print }' "$public_symbols_dir/spi-symbols.tsv" \
    | sort -u > "$expected_spi_file"
  python3 "$repo_root/Scripts/collect_public_symbols.py" "$repo_root" --only-spi \
    > "$actual_spi_file"
  if [[ ! -s "$actual_spi_file" && -s "$expected_spi_file" ]]; then
    # Xcode 27's SwiftPM Xcode build path currently accepts
    # `--include-spi-symbols` but does not forward
    # `-symbol-graph-include-spi` to swiftc. Keep the source-level SPI
    # declaration drift check above and the compile-time SPI consumer tests,
    # but do not report every established SPI member as deleted solely
    # because this toolchain emitted no SPI metadata at all.
    echo "docs-contract-sync: active Swift toolchain emitted no SPI symbol metadata; source and compile-time SPI guards remain active." >&2
  elif ! diff -u "$expected_spi_file" "$actual_spi_file" >&2; then
    fail "SPI symbol graph drifted; update Scripts/symbols/spi-symbols.tsv and API_STABILITY.md"
  fi

  rm -f "$expected_file" "$actual_file" "$expected_spi_file" "$actual_spi_file"

  for declaration in "${expected_shipping_public_declarations[@]}" "${expected_spi_public_declarations[@]}" \
    "${expected_test_support_public_declarations[@]}"; do
    require_contains "\`$declaration\`" "$api_stability"
  done

  while IFS=$'\t' read -r _module kind declaration; do
    case "$kind" in
      swift.class|swift.enum|swift.protocol|swift.struct)
        [[ "$declaration" == *.* ]] && continue
        require_contains "\`$declaration\`" "$api_stability"
        ;;
    esac
  done < <(awk 'NF && $0 !~ /^#/ { print }' "$public_symbols_allowlist")
}

validate_public_surface_snapshot() {
  local snapshot="$public_symbols_dir/README.md"
  local entries=(
    'core.allowlist|`InnoNetwork` (core)'
    'websocket.allowlist|`InnoNetworkWebSocket`'
    'download.allowlist|`InnoNetworkDownload`'
    'upload.allowlist|`InnoNetworkUpload`'
    'testsupport.allowlist|`InnoNetworkTestSupport`'
    'cache.allowlist|`InnoNetworkPersistentCache`'
    'openapi.allowlist|`InnoNetworkOpenAPI`'
    'trust.allowlist|`InnoNetworkTrust`'
    'authaws.allowlist|`InnoNetworkAuthAWS`'
  )

  (( ${#allowlist_parts[@]} == ${#entries[@]} )) \
    || fail "public surface snapshot does not cover every module allowlist"

  local entry
  local file_name
  local product
  local count
  local total=0
  for entry in "${entries[@]}"; do
    IFS='|' read -r file_name product <<< "$entry"
    count="$(awk 'NF && $0 !~ /^#/ { count += 1 } END { print count + 0 }' \
      "$public_symbols_dir/$file_name")"
    require_line "| $product | $count |" "$snapshot"
    total=$((total + count))
  done

  local formatted_total
  formatted_total="$(python3 - "$total" <<'PY'
import sys
print(f"{int(sys.argv[1]):,}")
PY
)"
  require_line "| **Total** | **$formatted_total** |" "$snapshot"
  require_contains "$formatted_total public" "$snapshot"
}

validate_oss_readiness_public_api() {
  require_contains 'public struct EndpointBuilder<Response: Decodable & Sendable>: APIDefinition' \
    "$repo_root/Sources/InnoNetwork/Endpoint.swift"
  require_contains 'public enum EndpointPathEncoding' \
    "$repo_root/Sources/InnoNetwork/EndpointPathEncoding.swift"
  require_contains 'public struct AnyEncodable: Encodable, Sendable' \
    "$repo_root/Sources/InnoNetwork/AnyEncodable.swift"
  require_contains 'public struct NetworkContext: Sendable' \
    "$repo_root/Sources/InnoNetwork/NetworkContext.swift"
  require_contains 'public struct CorrelationIDInterceptor: RequestInterceptor' \
    "$repo_root/Sources/InnoNetwork/CorrelationIDInterceptor.swift"
}

validate_troubleshooting_and_examples_docs() {
  require_contains 'Examples: [Examples/README.md](Examples/README.md)' "$readme"
  require_contains 'API Stability: [API_STABILITY.md](API_STABILITY.md)' "$readme"
  if [[ "$docs_release_state" == "draft" ]]; then
    require_contains 'Draft 5.0 Release Notes: [docs/releases/5.0.0.md](docs/releases/5.0.0.md)' "$readme"
  else
    require_contains '5.0 Release Notes: [docs/releases/5.0.0.md](docs/releases/5.0.0.md)' "$readme"
  fi
  require_contains '### 1. [BasicRequest](./BasicRequest)' "$repo_root/Examples/README.md"
  require_contains '### 2. [ErrorHandling](./ErrorHandling)' "$repo_root/Examples/README.md"
  require_contains '### 3. [Auth](./Auth)' "$repo_root/Examples/README.md"
  require_contains '### [ConsumerSmoke](./ConsumerSmoke)' "$repo_root/Examples/README.md"
  require_contains '### [CoreSmoke](./CoreSmoke)' "$repo_root/Examples/README.md"
  require_contains '### [MacroAdopterSmoke](./MacroAdopterSmoke)' "$repo_root/Examples/README.md"
  require_contains '### [OpenAPIAdopterSmoke](./OpenAPIAdopterSmoke)' "$repo_root/Examples/README.md"
  require_contains '### [TestSupportSmoke](./TestSupportSmoke)' "$repo_root/Examples/README.md"
  require_contains '### [WrapperSmoke](./WrapperSmoke)' "$repo_root/Examples/README.md"
}

validate_agent_guidelines_doc() {
  # CLAUDE.md is the AI-agent and contributor entry point (AGENTS.md resolves
  # to it), but it was previously the one contributor document outside this
  # guard and its snippets drifted off the 5.0 API. Anchor the shapes that
  # drifted so a future API change fails closed here instead of silently
  # misleading the next contributor or agent.
  local claude_md="$repo_root/CLAUDE.md"
  # The macro-first catalog shape is the documented default endpoint style.
  require_contains '@APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)' "$claude_md"
  # Client construction is the non-throwing baseURL initializer.
  require_contains 'let client = DefaultNetworkClient(' "$claude_md"
  require_not_contains 'try DefaultNetworkClient(' "$claude_md"
  # The removed 4.x configuration modifier family must not resurface.
  require_not_contains 'NetworkConfiguration.with(' "$claude_md"
  # Download construction stays the throwing initializer with safeDefaults.
  require_contains '.safeDefaults(sessionIdentifier:' "$claude_md"
  # package-scoped test helpers are documented as internal, not consumer API.
  require_contains 'package`-scoped' "$claude_md"
}

validate_release_quality_gates() {
  local docc_product_loop_count
  require_contains 'bash Scripts/check_guarded_benchmark_contract.sh' \
    "$repo_root/.github/workflows/benchmarks.yml"
  require_contains 'bash Scripts/check_guarded_benchmark_contract.sh' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'bash Scripts/check_guarded_benchmark_contract.sh' \
    "$repo_root/.github/workflows/release.yml"
  require_contains 'bash Scripts/check_guarded_benchmark_contract.sh' \
    "$repo_root/Scripts/run_local_release_preflight.sh"
  require_contains 'python3 Scripts/check_macro_build_baseline_contract.py' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'python3 Scripts/check_macro_build_baseline_contract.py' \
    "$repo_root/.github/workflows/release.yml"
  require_contains 'python3 Scripts/check_macro_build_baseline_contract.py' \
    "$repo_root/Scripts/run_local_release_preflight.sh"
  require_contains 'python3 Scripts/tests/test_check_macro_build_baseline_contract.py' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'python3 Scripts/tests/test_check_macro_build_baseline_contract.py' \
    "$repo_root/.github/workflows/release.yml"
  require_contains 'python3 Scripts/tests/test_check_macro_build_baseline_contract.py' \
    "$repo_root/Scripts/run_local_release_preflight.sh"
  require_contains 'python3 Scripts/tests/test_check_public_api_tiers.py' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'python3 Scripts/tests/test_check_public_api_tiers.py' \
    "$repo_root/.github/workflows/release.yml"
  require_contains 'python3 Scripts/tests/test_check_public_api_tiers.py' \
    "$repo_root/Scripts/run_local_release_preflight.sh"
  require_contains 'python3 Scripts/check_required_status_checks.py' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'python3 Scripts/check_required_status_checks.py' \
    "$repo_root/.github/workflows/release.yml"
  require_contains 'python3 Scripts/check_required_status_checks.py' \
    "$repo_root/Scripts/run_local_release_preflight.sh"
  require_contains 'python3 Scripts/tests/test_check_required_status_checks.py' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'python3 Scripts/tests/test_check_required_status_checks.py' \
    "$repo_root/.github/workflows/release.yml"
  require_contains 'python3 Scripts/tests/test_check_required_status_checks.py' \
    "$repo_root/Scripts/run_local_release_preflight.sh"
  require_contains 'bash Scripts/tests/test_check_guarded_benchmark_contract.sh' \
    "$repo_root/.github/workflows/benchmarks.yml"
  require_contains 'bash Scripts/tests/test_check_guarded_benchmark_contract.sh' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'bash Scripts/tests/test_check_guarded_benchmark_contract.sh' \
    "$repo_root/.github/workflows/release.yml"
  require_contains 'python3 Scripts/tests/test_run_with_guarded_benchmarks.py' \
    "$repo_root/.github/workflows/benchmarks.yml"
  require_contains 'python3 Scripts/tests/test_run_with_guarded_benchmarks.py' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'python3 Scripts/tests/test_run_with_guarded_benchmarks.py' \
    "$repo_root/.github/workflows/release.yml"
  require_contains 'python3 Scripts/tests/test_run_with_guarded_benchmarks.py' \
    "$repo_root/Scripts/run_local_release_preflight.sh"
  require_contains 'bash Scripts/tests/test_run_same_runner_benchmarks.sh' \
    "$repo_root/.github/workflows/benchmarks.yml"
  require_contains 'bash Scripts/tests/test_run_same_runner_benchmarks.sh' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'bash Scripts/tests/test_run_same_runner_benchmarks.sh' \
    "$repo_root/.github/workflows/release.yml"
  require_contains 'bash Scripts/tests/test_run_same_runner_benchmarks.sh' \
    "$repo_root/Scripts/run_local_release_preflight.sh"
  require_contains 'bash Scripts/run_same_runner_benchmarks.sh' \
    "$repo_root/docs/CI_DoC.md"
  require_contains 'guarded-benchmarks.txt' \
    "$repo_root/Benchmarks/README.md"
  require_contains 'bash Scripts/run_local_release_preflight.sh --full' \
    "$repo_root/docs/CI_DoC.md"
  require_contains 'bash Scripts/run_local_release_preflight.sh --full' \
    "$repo_root/docs/RELEASE_POLICY.md"
  require_contains 'bash Scripts/run_bounded_parallel_tests.sh' \
    "$repo_root/Scripts/run_local_release_preflight.sh"
  require_contains 'bash Scripts/tests/test_run_local_release_preflight.sh' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'bash Scripts/tests/test_run_local_release_preflight.sh' \
    "$repo_root/.github/workflows/release.yml"
  require_contains 'bash Scripts/tests/test_validate_release_candidate.sh' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'bash Scripts/tests/test_validate_release_candidate.sh' \
    "$repo_root/.github/workflows/release.yml"
  require_contains 'bash Scripts/tests/test_validate_release_candidate.sh' \
    "$repo_root/Scripts/run_local_release_preflight.sh"
  require_contains 'python3 Scripts/check_release_workflow_contract.py' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'python3 Scripts/check_release_workflow_contract.py' \
    "$repo_root/Scripts/run_local_release_preflight.sh"
  require_contains 'python3 Scripts/tests/test_check_release_workflow_contract.py' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'python3 Scripts/tests/test_check_release_workflow_contract.py' \
    "$repo_root/.github/workflows/release.yml"
  require_contains 'PERIPHERY_VERSION: "3.8.0"' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'periphery scan --config .periphery.yml -- --build-system native' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'retain_equatable_properties: true' \
    "$repo_root/.periphery.yml"
  require_contains 'retain_hashable_properties: true' \
    "$repo_root/.periphery.yml"
  require_contains 'Periphery 3.8 on Xcode 27' \
    "$repo_root/docs/CI_DoC.md"
  require_contains 'workflow_dispatch:' "$repo_root/.github/workflows/release.yml"
  require_contains 'Scripts/validate_release_candidate.sh' \
    "$repo_root/docs/RELEASE_POLICY.md"
  require_contains 'Scripts/check_release_workflow_contract.py' \
    "$repo_root/docs/CI_DoC.md"
  require_contains 'run_package_xcodebuild docbuild' \
    "$repo_root/Scripts/run_local_release_preflight.sh"
  require_contains 'bash Scripts/check_docc_archives.sh' \
    "$repo_root/Scripts/run_local_release_preflight.sh"
  require_contains 'bash Scripts/check_docc_archives.sh' \
    "$repo_root/.github/workflows/docc-pages.yml"
  require_contains 'bash Scripts/check_docc_archives.sh' \
    "$repo_root/.github/workflows/release.yml"
  require_contains 'bash Scripts/check_docc_archives.sh' \
    "$repo_root/docs/DocC_Deployment.md"
  require_contains 'bash Scripts/tests/test_check_docc_archives.sh' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'bash Scripts/tests/test_check_docc_archives.sh' \
    "$repo_root/.github/workflows/docc-pages.yml"
  require_contains 'bash Scripts/tests/test_check_docc_archives.sh' \
    "$repo_root/.github/workflows/release.yml"
  require_contains 'bash Scripts/tests/test_check_docc_archives.sh' \
    "$repo_root/Scripts/run_local_release_preflight.sh"
  require_contains 'docs/public-docc-products.txt' \
    "$repo_root/.github/workflows/docc-pages.yml"
  docc_product_loop_count="$(grep -F -c \
    'done < docs/public-docc-products.txt' \
    "$repo_root/.github/workflows/docc-pages.yml")"
  if [[ "$docc_product_loop_count" != "3" ]]; then
    fail "DocC Pages must use docs/public-docc-products.txt in all three product loops"
  fi
  require_contains 'Sources/InnoNetworkPersistentCache' "$repo_root/Scripts/check_unchecked_sendable.sh"
  require_contains 'Sources/InnoNetworkMacros' "$repo_root/Scripts/check_unchecked_sendable.sh"
  require_contains 'Sources/InnoNetworkMacros' "$repo_root/Scripts/check_production_force_unwraps.sh"
  require_contains 'Sources/InnoNetworkMacros' "$repo_root/Scripts/check_no_print_in_production.sh"
  require_contains 'bash Scripts/check_unchecked_sendable.sh' "$repo_root/.github/workflows/ci.yml"
  require_contains 'bash Scripts/check_production_force_unwraps.sh' "$repo_root/.github/workflows/ci.yml"
  require_contains 'bash Scripts/check_macro_compile_failures.sh' "$repo_root/.github/workflows/ci.yml"
  require_contains 'bash Scripts/check_macro_compile_failures.sh' "$repo_root/.github/workflows/release.yml"
  require_contains 'bash Scripts/check_production_force_unwraps.sh' "$repo_root/docs/CI_DoC.md"
  require_contains 'git ls-files --error-unmatch Package.resolved' "$repo_root/.github/workflows/ci.yml"
  require_contains 'git ls-files --error-unmatch Package.resolved' "$repo_root/.github/workflows/release.yml"
  require_contains 'git ls-files --error-unmatch Package.resolved' "$repo_root/docs/CI_DoC.md"
  require_contains 'Dependency Review' "$repo_root/docs/CI_DoC.md"
  require_contains 'Scripts/generate_dependency_snapshot.py' \
    "$repo_root/.github/workflows/dependency-submission.yml"
  require_contains '--package-resolved' \
    "$repo_root/.github/workflows/dependency-submission.yml"
  require_contains 'contents: write' "$repo_root/.github/workflows/dependency-submission.yml"
  require_not_contains 'paths:' "$repo_root/.github/workflows/dependency-submission.yml"
  require_contains 'swift-dependency-submission-${{ github.sha }}' \
    "$repo_root/.github/workflows/dependency-submission.yml"
  require_contains 'workflow_run:' \
    "$repo_root/.github/workflows/pr-dependency-submission.yml"
  require_contains 'types: [requested, in_progress]' \
    "$repo_root/.github/workflows/pr-dependency-submission.yml"
  require_contains 'permissions: {}' \
    "$repo_root/.github/workflows/pr-dependency-submission.yml"
  require_contains 'contents: write' \
    "$repo_root/.github/workflows/pr-dependency-submission.yml"
  require_contains 'persist-credentials: false' \
    "$repo_root/.github/workflows/pr-dependency-submission.yml"
  require_contains 'github.workflow_sha' \
    "$repo_root/.github/workflows/pr-dependency-submission.yml"
  require_contains 'DEPENDENCY_SNAPSHOT_SHA' \
    "$repo_root/.github/workflows/pr-dependency-submission.yml"
  require_contains 'DEPENDENCY_SNAPSHOT_REF' \
    "$repo_root/.github/workflows/pr-dependency-submission.yml"
  require_contains '--verify-package-resolved-transition' \
    "$repo_root/.github/workflows/pr-dependency-submission.yml"
  require_contains 'Package.resolved as untrusted data' \
    "$repo_root/.github/workflows/pr-dependency-submission.yml"
  require_contains "steps.fetch.outputs.current == 'true'" \
    "$repo_root/.github/workflows/pr-dependency-submission.yml"
  require_contains '--package-resolved' \
    "$repo_root/.github/workflows/pr-dependency-submission.yml"
  require_not_contains 'pull_request_target' \
    "$repo_root/.github/workflows/pr-dependency-submission.yml"
  require_contains 'bash Scripts/tests/test_generate_dependency_snapshot.sh' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'Verify resolved dependency snapshot' "$repo_root/.github/workflows/ci.yml"
  require_contains 'Wait for complete dependency snapshots' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'Verify immutable dependency transition' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains '--verify-package-resolved-transition' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'x-github-dependency-graph-snapshot-warnings' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'retry-on-snapshot-warnings: true' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'bash Scripts/tests/test_generate_dependency_snapshot.sh' \
    "$repo_root/.github/workflows/release.yml"
  require_contains 'Swift Dependency Submission' "$repo_root/docs/CI_DoC.md"
  require_contains 'python3 Scripts/check_example_platform_floors.py' "$repo_root/.github/workflows/ci.yml"
  require_contains 'python3 Scripts/check_example_platform_floors.py' "$repo_root/.github/workflows/release.yml"
  require_contains 'python3 Scripts/check_example_platform_floors.py' "$repo_root/docs/CI_DoC.md"
  require_contains 'bash Scripts/build_consumer_examples.sh' "$repo_root/.github/workflows/ci.yml"
  require_contains 'bash Scripts/build_consumer_examples.sh' "$repo_root/.github/workflows/release.yml"
  require_contains 'bash Scripts/build_consumer_examples.sh' \
    "$repo_root/Scripts/run_local_release_preflight.sh"
  require_contains 'bash Scripts/build_consumer_examples.sh' "$repo_root/docs/CI_DoC.md"
  require_contains 'xcrun swift run --package-path Examples/MacroAdopterSmoke' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'xcrun swift run --package-path Examples/MacroAdopterSmoke' \
    "$repo_root/.github/workflows/release.yml"
  require_contains 'xcrun swift run --package-path Examples/MacroAdopterSmoke' \
    "$repo_root/Scripts/run_local_release_preflight.sh"
  require_contains 'Examples/MacroAdopterSmoke' "$repo_root/docs/CI_DoC.md"
  require_contains 'xcrun swift run --package-path Examples/OpenAPIAdopterSmoke' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'xcrun swift run --package-path Examples/OpenAPIAdopterSmoke' \
    "$repo_root/.github/workflows/release.yml"
  require_contains 'xcrun swift run --package-path Examples/OpenAPIAdopterSmoke' \
    "$repo_root/Scripts/run_local_release_preflight.sh"
  require_contains 'Examples/OpenAPIAdopterSmoke' "$repo_root/docs/CI_DoC.md"
  require_contains 'bash Scripts/tests/test_build_consumer_examples.sh' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'bash Scripts/tests/test_build_consumer_examples.sh' \
    "$repo_root/.github/workflows/release.yml"
  require_contains 'bash Scripts/tests/test_build_consumer_examples.sh' \
    "$repo_root/Scripts/run_local_release_preflight.sh"
  require_contains 'python3 Scripts/tests/test_check_example_platform_floors.py' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'python3 Scripts/tests/test_check_example_platform_floors.py' \
    "$repo_root/.github/workflows/release.yml"
  require_contains 'python3 Scripts/tests/test_check_example_platform_floors.py' \
    "$repo_root/Scripts/run_local_release_preflight.sh"
  require_contains 'python3 Scripts/check_apple_platform_build_contract.py' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'python3 Scripts/check_apple_platform_build_contract.py' \
    "$repo_root/.github/workflows/release.yml"
  require_contains 'python3 Scripts/check_apple_platform_build_contract.py' \
    "$repo_root/Scripts/run_local_release_preflight.sh"
  require_contains 'python3 Scripts/tests/test_check_apple_platform_build_contract.py' \
    "$repo_root/.github/workflows/ci.yml"
  require_contains 'python3 Scripts/tests/test_check_apple_platform_build_contract.py' \
    "$repo_root/.github/workflows/release.yml"
  require_contains 'python3 Scripts/tests/test_check_apple_platform_build_contract.py' \
    "$repo_root/Scripts/run_local_release_preflight.sh"
  require_contains 'Tools/openapi-to-innonetwork' "$repo_root/.github/workflows/release.yml"
  require_contains 'Tools/openapi-to-innonetwork' "$repo_root/docs/CI_DoC.md"
  [[ -x "$repo_root/Scripts/check_production_force_unwraps.sh" ]] \
    || fail "production force-unwrap gate is not executable"
  [[ -x "$repo_root/Scripts/check_unchecked_sendable.sh" ]] \
    || fail "unchecked-sendable gate is not executable"
  [[ -x "$repo_root/Scripts/check_macro_compile_failures.sh" ]] \
    || fail "macro compile-failure gate is not executable"
  [[ -x "$repo_root/Scripts/check_macro_build_baseline_contract.py" ]] \
    || fail "macro build baseline gate is not executable"
}

documented_provisionally=()
while IFS= read -r line; do
  documented_provisionally+=("$line")
done < <(
  awk '
    /^## Provisionally Stable$/ { in_section = 1; next }
    /^## / { if (in_section) exit }
    in_section && /^- / {
      sub(/^- /, "")
      print
    }
  ' "$api_stability"
)

expected_provisionally_sorted="$(printf '%s\n' "${expected_provisionally[@]}" | sort)"
documented_provisionally_sorted="$(printf '%s\n' "${documented_provisionally[@]:-}" | sort)"
[[ "$expected_provisionally_sorted" == "$documented_provisionally_sorted" ]] || {
  echo "Expected Provisionally Stable symbols:" >&2
  printf '%s\n' "${expected_provisionally[@]}" >&2
  echo "Documented Provisionally Stable symbols:" >&2
  printf '%s\n' "${documented_provisionally[@]:-}" >&2
  fail "Provisionally Stable symbol list in API_STABILITY.md does not match expected allowlist"
}

for symbol in "${expected_stable[@]}"; do
  case "$symbol" in
    '`APIDefinition`')
      pattern='public protocol APIDefinition'
      target="$repo_root/Sources/InnoNetwork/APIDefinition.swift"
      ;;
    '`@APIDefinition(method:path:auth:)` and the default-enabled `Macros` package trait (promoted to Stable in 6.0.0; `traits: []` remains the supported opt-out)')
      validate_macro_surface
      continue
      ;;
    '`CancellationTag`')
      pattern='public struct CancellationTag'
      target="$repo_root/Sources/InnoNetwork/CancellationTag.swift"
      ;;
    '`Endpoint`')
      pattern='public protocol Endpoint: Sendable'
      target="$repo_root/Sources/InnoNetwork/EndpointShape.swift"
      ;;
    '`MultipartAPIDefinition`')
      pattern='public protocol MultipartAPIDefinition'
      target="$repo_root/Sources/InnoNetwork/APIDefinition.swift"
      ;;
    '`TransportPolicy`')
      pattern='public struct TransportPolicy'
      target="$repo_root/Sources/InnoNetwork/TransportPolicy.swift"
      ;;
    '`RequestEncodingPolicy`')
      pattern='public enum RequestEncodingPolicy'
      target="$repo_root/Sources/InnoNetwork/RequestEncodingPolicy.swift"
      ;;
    '`ResponseDecodingStrategy`')
      pattern='public enum ResponseDecodingStrategy'
      target="$repo_root/Sources/InnoNetwork/ResponseDecodingStrategy.swift"
      ;;
    '`DefaultNetworkClient`')
      pattern='public final class DefaultNetworkClient'
      target="$repo_root/Sources/InnoNetwork/DefaultNetworkClient.swift"
      ;;
    '`DefaultNetworkClient.init(baseURL:)`')
      pattern='    public convenience init(baseURL: URL)'
      target="$repo_root/Sources/InnoNetwork/DefaultNetworkClient.swift"
      ;;
    '`DefaultNetworkClient.shutdown()`')
      pattern='    public func shutdown() async'
      target="$repo_root/Sources/InnoNetwork/DefaultNetworkClient.swift"
      ;;
    '`NetworkClient.request(_:)`')
      pattern='    func request<T: APIDefinition>(_ request: T) async throws(NetworkError) -> T.APIResponse'
      target="$repo_root/Sources/InnoNetwork/DefaultNetworkClient.swift"
      ;;
    '`NetworkClient.request(_:tag:)`')
      pattern='    func request<T: APIDefinition>(_ request: T, tag: CancellationTag?) async throws(NetworkError) -> T.APIResponse'
      target="$repo_root/Sources/InnoNetwork/DefaultNetworkClient.swift"
      ;;
    '`UploadNetworkClient.upload(_:)`')
      pattern='    func upload<T: MultipartAPIDefinition>(_ request: T) async throws(NetworkError) -> T.APIResponse'
      target="$repo_root/Sources/InnoNetwork/DefaultNetworkClient.swift"
      ;;
    '`UploadNetworkClient.upload(_:tag:)`')
      pattern='    func upload<T: MultipartAPIDefinition>(_ request: T, tag: CancellationTag?) async throws(NetworkError) -> T.APIResponse'
      target="$repo_root/Sources/InnoNetwork/DefaultNetworkClient.swift"
      ;;
    '`NetworkConfiguration.safeDefaults(baseURL:)`')
      pattern='public static func safeDefaults(baseURL: URL)'
      target="$repo_root/Sources/InnoNetwork/NetworkConfiguration.swift"
      ;;
    '`NetworkConfiguration.advanced(baseURL:resilience:auth:observability:cache:transport:)`')
      pattern='public static func advanced('
      target="$repo_root/Sources/InnoNetwork/NetworkConfiguration.swift"
      ;;
    '`DownloadConfiguration.safeDefaults()`')
      pattern='public static func safeDefaults()'
      target="$repo_root/Sources/InnoNetworkDownload/DownloadConfiguration.swift"
      ;;
    '`DownloadConfiguration.safeDefaults(sessionIdentifier:)`')
      pattern='public static func safeDefaults(sessionIdentifier: String)'
      target="$repo_root/Sources/InnoNetworkDownload/DownloadConfiguration.swift"
      ;;
    '`DownloadConfiguration.advanced(sessionIdentifier:transfer:retry:observability:persistence:)`')
      pattern='public static func advanced('
      target="$repo_root/Sources/InnoNetworkDownload/DownloadConfiguration.swift"
      ;;
    '`DownloadTransferPack`, `DownloadRetryPack`, `DownloadObservabilityPack`, and `DownloadPersistencePack`')
      for pack in DownloadTransferPack DownloadRetryPack DownloadObservabilityPack DownloadPersistencePack; do
        require_contains "public struct $pack: Sendable" \
          "$repo_root/Sources/InnoNetworkDownload/DownloadConfigurationPacks.swift"
      done
      continue
      ;;
    '`DownloadConfiguration.cellularEnabled()`')
      pattern='public func cellularEnabled()'
      target="$repo_root/Sources/InnoNetworkDownload/DownloadConfiguration.swift"
      ;;
    '`DownloadConfiguration.backgroundTransfersEnabled()`')
      pattern='public func backgroundTransfersEnabled()'
      target="$repo_root/Sources/InnoNetworkDownload/DownloadConfiguration.swift"
      ;;
    '`WebSocketConfiguration.safeDefaults()`')
      pattern='public static func safeDefaults()'
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketConfiguration.swift"
      ;;
    '`WebSocketConfiguration.advanced(connection:liveness:reconnect:messaging:observability:)`')
      pattern='public static func advanced('
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketConfiguration.swift"
      ;;
    '`WebSocketConnectionPack`, `WebSocketLivenessPack`, `WebSocketReconnectPack`, `WebSocketMessagingPack`, and `WebSocketObservabilityPack`')
      for pack in WebSocketConnectionPack WebSocketLivenessPack WebSocketReconnectPack WebSocketMessagingPack WebSocketObservabilityPack; do
        require_contains "public struct $pack: Sendable" \
          "$repo_root/Sources/InnoNetworkWebSocket/WebSocketConfigurationPacks.swift"
      done
      continue
      ;;
    '`WebSocketHandshakeRequestAdapter`')
      pattern='public struct WebSocketHandshakeRequestAdapter'
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketConfiguration.swift"
      ;;
    '`DownloadManager`')
      pattern='public actor DownloadManager'
      target="$repo_root/Sources/InnoNetworkDownload/DownloadManager.swift"
      ;;
    '`WebSocketManager`')
      pattern='public actor WebSocketManager'
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketManager.swift"
      ;;
    '`WebSocketManager.shutdown()`')
      pattern='public func shutdown() async'
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketManager.swift"
      ;;
    '`WebSocketManager.retry(_:) -> WebSocketRetryResult?`')
      pattern='public func retry(_ task: WebSocketTask) async -> WebSocketRetryResult?'
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketManager.swift"
      ;;
    '`WebSocketRetryResult`')
      pattern='public struct WebSocketRetryResult: Sendable'
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketEventTypes.swift"
      ;;
    '`WebSocketTask.id`')
      pattern='public nonisolated let id: String'
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketTask.swift"
      ;;
    '`WebSocketEvent.ping`')
      pattern='case ping(WebSocketPingContext)'
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketEventTypes.swift"
      ;;
    '`WebSocketEvent.pong`')
      pattern='case pong(WebSocketPongContext)'
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketEventTypes.swift"
      ;;
    '`WebSocketEvent.error(.pingTimeout)`')
      pattern='case error(WebSocketError)'
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketEventTypes.swift"
      ;;
    '`WebSocketPingContext`')
      pattern='public struct WebSocketPingContext'
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketEventTypes.swift"
      ;;
    '`WebSocketPongContext`')
      pattern='public struct WebSocketPongContext'
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketEventTypes.swift"
      ;;
    '`TrustPolicy`')
      pattern='public enum TrustPolicy'
      target="$repo_root/Sources/InnoNetwork/TrustPolicy.swift"
      ;;
    '`TrustChallengeOutcome`')
      pattern='public enum TrustChallengeOutcome'
      target="$repo_root/Sources/InnoNetwork/TrustPolicy.swift"
      ;;
    '`PublicKeyPinningPolicy`')
      pattern='public struct PublicKeyPinningPolicy'
      target="$repo_root/Sources/InnoNetworkTrust/PublicKeyPinning.swift"
      ;;
    '`PublicKeyPinningPolicy.HostMatchingStrategy`')
      pattern='public enum HostMatchingStrategy: Sendable, Equatable'
      target="$repo_root/Sources/InnoNetworkTrust/PublicKeyPinning.swift"
      ;;
    '`PublicKeyPinningEvaluator`')
      pattern='public struct PublicKeyPinningEvaluator'
      target="$repo_root/Sources/InnoNetworkTrust/PublicKeyPinning.swift"
      ;;
    '`AnyResponseDecoder`')
      pattern='public struct AnyResponseDecoder'
      target="$repo_root/Sources/InnoNetwork/AnyResponseDecoder.swift"
      ;;
    '`URLQueryEncoder`')
      pattern='public struct URLQueryEncoder'
      target="$repo_root/Sources/InnoNetwork/URLQueryEncoder.swift"
      ;;
    '`URLQueryArrayEncodingStrategy`')
      pattern='public enum URLQueryArrayEncodingStrategy'
      target="$repo_root/Sources/InnoNetwork/URLQueryEncoder.swift"
      ;;
    '`ResponseBodyBufferingPolicy`')
      pattern='public enum ResponseBodyBufferingPolicy'
      target="$repo_root/Sources/InnoNetwork/ResponseBodyBufferingPolicy.swift"
      ;;
    '`RequestExecutionPolicy`')
      pattern='public protocol RequestExecutionPolicy'
      target="$repo_root/Sources/InnoNetwork/RequestExecutionPolicy.swift"
      ;;
    '`NetworkErrorCategory`')
      pattern='public enum NetworkErrorCategory'
      target="$repo_root/Sources/InnoNetwork/NetworkError+Classification.swift"
      ;;
    '`NetworkError.category`')
      pattern='public var category: NetworkErrorCategory'
      target="$repo_root/Sources/InnoNetwork/NetworkError+Classification.swift"
      ;;
    '`NetworkError.isRetriableHint`')
      pattern='public var isRetriableHint: Bool'
      target="$repo_root/Sources/InnoNetwork/NetworkError+Classification.swift"
      ;;
    '`NetworkError.isUserVisible`')
      pattern='public var isUserVisible: Bool'
      target="$repo_root/Sources/InnoNetwork/NetworkError+Classification.swift"
      ;;
    '`HTTPMethod`')
      pattern='public struct HTTPMethod: RawRepresentable, Sendable, Hashable'
      target="$repo_root/Sources/InnoNetwork/HTTPMethod.swift"
      ;;
    '`SessionAuthentication`')
      pattern='public enum SessionAuthentication'
      target="$repo_root/Sources/InnoNetwork/Endpoint.swift"
      ;;
    '`EventDeliveryPolicy`')
      pattern='public struct EventDeliveryPolicy'
      target="$repo_root/Sources/InnoNetwork/EventPipeline.swift"
      ;;
    '`WebSocketCloseCode`')
      pattern='public enum WebSocketCloseCode'
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketCloseCode.swift"
      ;;
    '`EndpointBuilder`, `EndpointPathEncoding` (promoted from Provisionally Stable in 4.x.x; the path-encoding shape and decoding helpers are SemVer-protected)')
      pattern='public struct EndpointBuilder<Response: Decodable & Sendable>: APIDefinition'
      target="$repo_root/Sources/InnoNetwork/Endpoint.swift"
      ;;
    '`DecodingInterceptor` (promoted from Provisionally Stable in 4.x.x)')
      pattern='public protocol DecodingInterceptor'
      target="$repo_root/Sources/InnoNetwork/DecodingInterceptor.swift"
      ;;
    '`WebSocketCloseDisposition` (promoted from Provisionally Stable in 4.x.x)')
      pattern='public enum WebSocketCloseDisposition: Sendable, Equatable'
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketCloseDisposition.swift"
      ;;
    *)
      fail "unknown stable symbol mapping: $symbol"
      ;;
  esac

  case "$symbol" in
    '`NetworkClient.request(_:)`' | '`NetworkClient.request(_:tag:)`')
      validate_protocol_symbol "NetworkClient" "$target" "$pattern"
      ;;
    '`UploadNetworkClient.upload(_:)`' | '`UploadNetworkClient.upload(_:tag:)`')
      validate_protocol_symbol "UploadNetworkClient" "$target" "$pattern"
      ;;
    *)
      if has_rg; then
        rg -Fq "$pattern" "$target" || fail "stable symbol $symbol is not present in production sources"
      else
        grep -Fq "$pattern" "$target" || fail "stable symbol $symbol is not present in production sources"
      fi
      ;;
  esac
done

for symbol in "${expected_provisionally[@]}"; do
  case "$symbol" in
    'benchmark runner CLI flags and JSON summary presentation details')
      validate_benchmark_docs
      continue
      ;;
    'troubleshooting guidance and examples in README/DocC')
      validate_troubleshooting_and_examples_docs
      validate_doc_smoke_coverage
      continue
      ;;
    '`InnoNetworkTestSupport` library product and its `public` symbols')
      validate_test_support_product
      continue
      ;;
    '`AnyEncodable`, `NetworkContext`, and `CorrelationIDInterceptor`')
      validate_oss_readiness_public_api
      continue
      ;;
    '`RefreshTokenPolicy`, `RequestCoalescingPolicy`, retry, response cache, redirect, encoding utility, and circuit breaker policy surfaces')
      validate_resilience_public_api
      continue
      ;;
    '`MultipartResponseDecoder` buffered multipart response parsing surface')
      validate_multipart_response_api
      continue
      ;;
    '`MultipartStreamingResponseDecoder` streaming multipart response parsing surface')
      validate_multipart_streaming_api
      continue
      ;;
    '`InnoNetworkOpenAPI` companion product')
      validate_openapi_companion_product
      continue
      ;;
    '`InnoNetworkUpload` companion product and its public file-upload, progress, restoration, bounded response, event, and error symbols')
      require_contains 'name: "InnoNetworkUpload"' "$repo_root/Package.swift"
      require_contains 'targets: ["InnoNetworkUpload"]' "$repo_root/Package.swift"
      require_contains 'public actor UploadManager' \
        "$repo_root/Sources/InnoNetworkUpload/UploadManager.swift"
      require_contains 'public struct UploadReceipt: Sendable' \
        "$repo_root/Sources/InnoNetworkUpload/UploadModels.swift"
      require_contains 'Background requests containing `Authorization`' \
        "$repo_root/Sources/InnoNetworkUpload/UploadConfiguration.swift"
      continue
      ;;
    'operation-first `NetworkClientConfiguration`, `OperationNetworkClient`,')
      require_contains 'public struct OperationNetworkClient' \
        "$repo_root/Sources/InnoNetwork/V6/OperationNetworkClient.swift"
      require_contains 'public struct NetworkFailure: Error, Sendable, Equatable' \
        "$repo_root/Sources/InnoNetwork/V6/NetworkFailure.swift"
      require_contains 'public struct NetworkOperation' \
        "$repo_root/Sources/InnoNetwork/V6/NetworkOperation.swift"
      require_contains 'import InnoNetwork' \
        "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/MigrationTo6.md"
      continue
      ;;
    'bounded companion transport contracts: `BoundedNetworkTransfer`,')
      require_contains 'public struct BoundedNetworkTransfer: Sendable' \
        "$repo_root/Sources/InnoNetwork/BoundedNetworkTransfer.swift"
      require_contains 'public struct NetworkRetryExecutor: Sendable' \
        "$repo_root/Sources/InnoNetwork/NetworkRetryExecutor.swift"
      require_contains 'public enum NetworkURLPolicy: Sendable, Equatable' \
        "$repo_root/Sources/InnoNetwork/NetworkURLValidator.swift"
      require_contains 'public enum NetworkURLValidator' \
        "$repo_root/Sources/InnoNetwork/NetworkURLValidator.swift"
      continue
      ;;
    '`PersistentResponseCache` statistics and telemetry surfaces')
      validate_persistent_cache_operations_api
      continue
      ;;
    '`WebSocketError.unsupportedProtocolFeature`')
      require_contains 'case unsupportedProtocolFeature(WebSocketProtocolFeature)' \
        "$repo_root/Sources/InnoNetworkWebSocket/WebSocketState.swift"
      continue
      ;;
    '`WebSocketProtocolFeature`')
      require_contains 'public enum WebSocketProtocolFeature' \
        "$repo_root/Sources/InnoNetworkWebSocket/WebSocketState.swift"
      continue
      ;;
    '`RequestSigner` and `RequestBody` late body-aware signing contract')
      require_contains 'public protocol RequestSigner: Sendable' \
        "$repo_root/Sources/InnoNetwork/RequestSigner.swift"
      require_contains 'public enum RequestBody: Sendable' \
        "$repo_root/Sources/InnoNetwork/RequestSigner.swift"
      continue
      ;;
    '`JWTBearerInterceptor` reference signer for request-minted JWT bearer tokens')
      require_contains 'public struct JWTBearerInterceptor: RequestSigner' \
        "$repo_root/Sources/InnoNetwork/Auth/JWTBearerInterceptor.swift"
      continue
      ;;
    '`InnoNetworkAuthAWS` companion product and `AWSSigV4Interceptor` reference signer for single-shot AWS SigV4 signing')
      require_contains 'name: "InnoNetworkAuthAWS"' "$repo_root/Package.swift"
      require_contains 'targets: ["InnoNetworkAuthAWS"]' "$repo_root/Package.swift"
      require_contains 'public struct AWSSigV4Interceptor: RequestSigner' \
        "$repo_root/Sources/InnoNetworkAuthAWS/AWSSigV4Interceptor.swift"
      continue
      ;;
    '`DecodingInterceptor`')
      require_contains 'public protocol DecodingInterceptor' \
        "$repo_root/Sources/InnoNetwork/DecodingInterceptor.swift"
      continue
      ;;
    '`StreamingBufferingPolicy`, `StreamingOutputSequence`, `TraceContextInterceptor`, `W3CTraceContext`, `CurlCommandOptions`, `IdempotencyKeyPolicy`, and `RequestPriority`')
      validate_operational_dx_public_api
      continue
      ;;
    '`HTTPHeaderName<Variant>` phantom-typed header key surface and its predefined `SingleValueHeader` / `RepeatableHeader` markers (also referenced as `HTTPHeaderName` / `HTTPHeaderVariant` for contract-sync purposes)')
      require_contains 'public struct HTTPHeaderName<Variant: HTTPHeaderVariant>' \
        "$repo_root/Sources/InnoNetwork/HTTPHeaders.swift"
      require_contains 'public enum SingleValueHeader: HTTPHeaderVariant' \
        "$repo_root/Sources/InnoNetwork/HTTPHeaders.swift"
      require_contains 'public enum RepeatableHeader: HTTPHeaderVariant' \
        "$repo_root/Sources/InnoNetwork/HTTPHeaders.swift"
      continue
      ;;
    '`MultipartUploadStrategy.threshold(bytes:)`')
      require_contains 'public static func threshold(bytes: Int64)' \
        "$repo_root/Sources/InnoNetwork/APIDefinition.swift"
      continue
      ;;
    '`PersistentResponseCacheStatistics.hitCount` / `missCount` / `evictionCount`')
      require_contains 'public let hitCount: Int' \
        "$repo_root/Sources/InnoNetworkPersistentCache/PersistentResponseCacheTelemetry.swift"
      require_contains 'public let missCount: Int' \
        "$repo_root/Sources/InnoNetworkPersistentCache/PersistentResponseCacheTelemetry.swift"
      require_contains 'public let evictionCount: Int' \
        "$repo_root/Sources/InnoNetworkPersistentCache/PersistentResponseCacheTelemetry.swift"
      continue
      ;;
    '`DownloadTask.generation` / `attempt` observation accessors')
      require_contains 'public var generation: Int' \
        "$repo_root/Sources/InnoNetworkDownload/DownloadTask.swift"
      require_contains 'public var attempt: Int' \
        "$repo_root/Sources/InnoNetworkDownload/DownloadTask.swift"
      continue
      ;;
    '`NetworkErrorCode` SSOT enum (4.0.0 baseline) — owns every `NetworkError.errorCode` raw value; new cases may be added in 5.x minors when `NetworkError` itself adds a case')
      require_contains 'public enum NetworkErrorCode' \
        "$repo_root/Sources/InnoNetwork/NetworkErrorCode.swift"
      require_contains 'return NetworkErrorCode.reachability.rawValue' \
        "$repo_root/Sources/InnoNetwork/NetworkError.swift"
      require_contains 'case cancelled = 4004' \
        "$repo_root/Sources/InnoNetwork/NetworkErrorCode.swift"
      require_contains 'case timeout = 4005' \
        "$repo_root/Sources/InnoNetwork/NetworkErrorCode.swift"
      require_contains 'return NetworkErrorCode.cancelled.rawValue' \
        "$repo_root/Sources/InnoNetwork/NetworkError.swift"
      require_contains 'return NetworkErrorCode.timeout.rawValue' \
        "$repo_root/Sources/InnoNetwork/NetworkError.swift"
      require_not_contains 'NSURLErrorCancelled' \
        "$repo_root/Sources/InnoNetwork/NetworkError.swift"
      require_not_contains 'NSURLErrorTimedOut' \
        "$repo_root/Sources/InnoNetwork/NetworkError.swift"
      continue
      ;;
    '`NetworkError.reachability(_:_:_:)` and `ReachabilityReason` (4.0.0 baseline)')
      require_contains 'public enum ReachabilityReason' \
        "$repo_root/Sources/InnoNetwork/NetworkError.swift"
      require_contains 'case reachability(ReachabilityReason, SendableUnderlyingError, Response?)' \
        "$repo_root/Sources/InnoNetwork/NetworkError.swift"
      require_contains 'return .reachability(.notConnectedToInternet' \
        "$repo_root/Sources/InnoNetwork/NetworkError.swift"
      continue
      ;;
    '`MultipartUploadStrategy.inMemory(maxBytes:)` (4.0.0 baseline) — the explicit cap and encoder accumulator guard are part of the contract')
      require_contains 'case inMemory(maxBytes: Int)' \
        "$repo_root/Sources/InnoNetwork/APIDefinition.swift"
      require_contains 'maxInMemoryBytes' \
        "$repo_root/Sources/InnoNetwork/Model/MultipartFormData.swift"
      continue
      ;;
    '`DownloadTransferPack.init(...taskInactivityTimeout:...)` and `DownloadTask.lastProgressAt` (4.0.0 behavior carried into the 5.0 pack contract)')
      require_contains 'taskInactivityTimeout: Duration? = nil' \
        "$repo_root/Sources/InnoNetworkDownload/DownloadConfigurationPacks.swift"
      require_contains 'public var lastProgressAt: ContinuousClock.Instant?' \
        "$repo_root/Sources/InnoNetworkDownload/DownloadTask.swift"
      continue
      ;;
    '`ResponseCachePolicy.rfc9111Compliant(wrapping:)` directive-aware adapter (4.0.0 baseline)')
      require_contains 'indirect case rfc9111Compliant(wrapping: ResponseCachePolicy)' \
        "$repo_root/Sources/InnoNetwork/Cache/ResponseCachePolicy.swift"
      require_contains 'func prepareWithRFC9111' \
        "$repo_root/Sources/InnoNetwork/Cache/RFC9111CompliantCachePolicy.swift"
      require_contains 'HTTPDateParser.parse(expiresValue, requiresGMTZone: true)' \
        "$repo_root/Sources/InnoNetwork/Cache/RFC9111CompliantCachePolicy.swift"
      require_contains '`Expires` — when no valid `max-age` is present' \
        "$repo_root/Sources/InnoNetwork/Cache/ResponseCachePolicy.swift"
      require_contains '`Last-Modified` — when neither valid `max-age` nor `Expires`' \
        "$repo_root/Sources/InnoNetwork/Cache/ResponseCachePolicy.swift"
      require_contains 'age * 0.1' \
        "$repo_root/Sources/InnoNetwork/Cache/RFC9111CompliantCachePolicy.swift"
      continue
      ;;
    '`DownloadPersistencePack.init(...sharedContainerIdentifier:...)` (4.0.0 behavior carried into the 5.0 pack contract)')
      require_contains 'sharedContainerIdentifier: String? = nil' \
        "$repo_root/Sources/InnoNetworkDownload/DownloadConfigurationPacks.swift"
      require_contains 'config.sharedContainerIdentifier = sharedContainerIdentifier' \
        "$repo_root/Sources/InnoNetworkDownload/DownloadConfiguration.swift"
      continue
      ;;
    '`ResponseCache.invalidateTargetURI(_:)` and RFC 9111 unsafe-method target URI invalidation (4.0.0 baseline)')
      require_contains 'func invalidateTargetURI(_ targetURI: String) async' \
        "$repo_root/Sources/InnoNetwork/Cache/ResponseCachePolicy.swift"
      require_contains 'public func invalidateTargetURI(_ targetURI: String) async' \
        "$repo_root/Sources/InnoNetwork/Cache/ResponseCachePolicy.swift"
      require_contains 'public func invalidateTargetURI(_ targetURI: String) async' \
        "$repo_root/Sources/InnoNetworkPersistentCache/PersistentResponseCache.swift"
      require_contains 'invalidateUnsafeTargetURIIfNeeded' \
        "$repo_root/Sources/InnoNetwork/RequestExecutor+Cache.swift"
      continue
      ;;
    '`TransportPack.init(...streamingLineByteLimit:...)` (4.0.0 behavior carried into the 5.0 pack contract)')
      require_contains 'package static let defaultStreamingLineByteLimit' \
        "$repo_root/Sources/InnoNetwork/NetworkConfiguration.swift"
      require_contains 'streamingLineByteLimit: Int? = nil' \
        "$repo_root/Sources/InnoNetwork/Configuration/ConfigurationPacks.swift"
      require_contains 'private let streamingLineByteLimit: Int?' \
        "$repo_root/Sources/InnoNetwork/Configuration/ConfigurationPacks.swift"
      require_contains 'configuration.streamingLineByteLimit' \
        "$repo_root/Sources/InnoNetwork/StreamingExecutor.swift"
      continue
      ;;
    *)
      fail "unknown provisionally stable symbol mapping: $symbol"
      ;;
  esac
done

validate_spi_allowlist_drift
validate_public_surface_ledger
validate_public_surface_snapshot
validate_ledger_to_allowlist_parity
validate_release_quality_gates
validate_agent_guidelines_doc

require_contains "API Stability" "$readme"
require_contains ".safeDefaults(" "$readme"
require_contains "CONTRIBUTING.md" "$readme"
require_contains "SECURITY.md" "$readme"
require_contains "SUPPORT.md" "$readme"
require_contains "docs/RELEASE_POLICY.md" "$readme"
require_contains 'Responses to requests carrying `Authorization` are stored only when the' "$readme"
require_contains '`GET`, `HEAD`, `OPTIONS`, and `TRACE` retry by default' "$readme"
require_contains '`Expires` fallback' "$readme"
require_contains '`Last-Modified` heuristic freshness' "$readme"
require_contains '`Expires` |' "$repo_root/docs/rfcs/RFC9111-Compliance.md"
require_contains '`Last-Modified` |' "$repo_root/docs/rfcs/RFC9111-Compliance.md"
require_contains 'Persistent cache disk keys now include the `Vary`' \
  "$repo_root/docs/releases/4.0.0.md"
require_contains '.noStatusReceived:' \
  "$repo_root/Sources/InnoNetworkWebSocket/WebSocketCloseDisposition.swift"
require_contains '1005`' \
  "$repo_root/docs/WebSocketLifecycle.md"
require_contains 'delegate-event queue so callback ordering stays FIFO' \
  "$repo_root/docs/TaskOwnership.md"
require_contains 'Authorization` entries also require RFC 9111 §3.5 permission' \
  "$repo_root/docs/rfcs/persistent-response-cache.md"
require_contains 'ResponseCacheStoragePolicy.responsePermitsAuthenticatedStorage' \
  "$repo_root/Sources/InnoNetwork/RequestExecutor+Cache.swift"
require_contains 'ResponseCacheStoragePolicy.responsePermitsAuthenticatedStorage' \
  "$repo_root/Sources/InnoNetworkPersistentCache/PersistentResponseCache+Policy.swift"
require_contains 'deinit {' \
  "$repo_root/Sources/InnoNetwork/Auth/RefreshTokenPolicy.swift"
require_contains 'coordinator deinit cancels any orphaned in-flight refresh' \
  "$repo_root/docs/TaskOwnership.md"
require_contains 'public func retry(_ task: WebSocketTask) async -> WebSocketRetryResult?' \
  "$repo_root/Sources/InnoNetworkWebSocket/WebSocketManager.swift"
require_contains 'public let events: AsyncStream<WebSocketEvent>' \
  "$repo_root/Sources/InnoNetworkWebSocket/WebSocketEventTypes.swift"
require_contains '`WebSocketManager.retry(_:)` is an explicit logical restart.' \
  "$api_stability"
require_contains 'WebSocket explicit retry creates a fresh task' \
  "$repo_root/docs/Migration-5.0.0.md"
require_contains 'retires the source partition; its consumers finish' \
  "$repo_root/Sources/InnoNetworkWebSocket/InnoNetworkWebSocket.docc/Articles/Reconnect.md"
require_contains 'Terminal states have no outgoing transition on the same logical task.' \
  "$repo_root/docs/WebSocketLifecycle.md"
require_contains 'publication snapshot even when `.dropNewest` queues are full' \
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/Articles/EventDeliveryGuide.md"
require_contains 'invoke snapshotted callback' \
  "$repo_root/docs/TaskOwnership.md"
require_contains '`InnoNetworkClientTransport`' \
  "$repo_root/docs/CodeGeneration.md"
require_contains 'let sessionAuthentication: SessionAuthentication = .anonymous' \
  "$repo_root/Sources/InnoNetworkOpenAPI/InnoNetworkOpenAPI.docc/InnoNetworkOpenAPI.md"
require_contains 'var sessionAuthentication: SessionAuthentication { .anonymous }' \
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/Articles/OpenAPIGeneratorAdapter.md"
require_contains 'var sessionAuthentication: SessionAuthentication { operation.sessionAuthentication }' \
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/Articles/OpenAPIGeneratorAdapter.md"
require_contains 'successful CONNECT `2xx`' \
  "$repo_root/Sources/InnoNetworkOpenAPI/InnoNetworkOpenAPI.docc/InnoNetworkOpenAPI.md"
require_contains 'WebSocket handshake redirects now repeat URL admission on every hop.' \
  "$repo_root/docs/Migration-5.0.0.md"

for doc in "${required_meta_docs[@]}"; do
  [[ -f "$doc" ]] || fail "required OSS document is missing: $doc"
done

for doc in "${required_feature_docs[@]}"; do
  [[ -f "$doc" ]] || fail "required feature documentation file is missing: $doc"
done

for doc in "${example_docs[@]}"; do
  [[ -f "$doc" ]] || fail "example documentation file is missing: $doc"
  require_contains "safeDefaults" "$doc"
done

forbidden_pattern 'configuration:\s*NetworkConfiguration\(' "$readme" "${example_docs[@]}"
forbidden_pattern 'let configuration = NetworkConfiguration\(' "$readme" "${example_docs[@]}"
forbidden_pattern 'let client = DefaultNetworkClient\(\s*configuration:\s*\.default' "$readme" "${example_docs[@]}"
forbidden_pattern 'addText|addFile' "$readme" "${example_docs[@]}"
forbidden_pattern 'from:\s*"1\.0\.0"' "$readme" "${example_docs[@]}"
if [[ "$docs_release_state" == "draft" ]]; then
  forbidden_pattern '\.package.*5\.0\.0|\.exact\("5\.0\.0"\)' \
    "$readme" \
    "$api_stability"
  forbidden_pattern '5\.0\.0 is the public baseline|5\.0\.0` is the current compatibility|`5\.x` is the actively supported public release line' \
    "$readme" \
    "$api_stability" \
    "$security_policy"
fi
forbidden_pattern 'Xcode 15|Xcode 16' "$readme" "${example_docs[@]}" "$repo_root/docs" "$repo_root/Sources"
forbidden_pattern 'does not pull|do not pull|not pull `swift-syntax`|has no external dependencies|no external dependencies;' \
  "$api_stability" \
  "$readme" \
  "$repo_root/CHANGELOG.md" \
  "$repo_root/docs/releases/4.0.0.md" \
  "$repo_root/docs/releases/5.0.0.md" \
  "$repo_root/SECURITY.md" \
  "$repo_root/docs" \
  "$repo_root/Sources"
forbidden_pattern '4\.2\.0|4\.2 line|pre-v4\.2|v4\.2|docs/releases/4\.2\.0' \
  "$api_stability" \
  "$readme" \
  "$repo_root/CHANGELOG.md" \
  "$repo_root/docs/releases/4.0.0.md" \
  "$repo_root/docs/releases/5.0.0.md" \
  "$repo_root/SECURITY.md" \
  "$repo_root/Benchmarks/README.md" \
  "$repo_root/docs" \
  "$repo_root/Sources" \
  "$repo_root/Tests"
forbidden_pattern 'public func receive\(_ task: WebSocketTask\)' \
  "$repo_root/Sources/InnoNetworkWebSocket"
forbidden_pattern 'manager\.receive\(' \
  "$repo_root/README.md" \
  "$repo_root/CHANGELOG.md" \
  "$repo_root/docs" \
  "$repo_root/Sources" \
  "$repo_root/Tests"
forbidden_pattern 'DownloadManager\.make|make\(configuration:\)|DownloadConfiguration\.default|WebSocketConfiguration\.default' \
  "$repo_root/README.md" \
  "${example_docs[@]}" \
  "$repo_root/Sources/InnoNetworkDownload" \
  "$repo_root/Sources/InnoNetworkWebSocket"
forbidden_pattern 'builder\.sessionMode|DownloadConfiguration\.SessionMode' \
  "$repo_root/README.md" \
  "$repo_root/docs" \
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc" \
  "$repo_root/Sources/InnoNetworkDownload/InnoNetworkDownload.docc"
forbidden_pattern '4\.x preview' \
  "$repo_root/docs/CodeGeneration.md"
forbidden_pattern 'introduced in 4\.1|After 5\.0' \
  "$repo_root/Tools/openapi-to-innonetwork/README.md"
forbidden_pattern 'InnoNetworkOpenAPITransport|What 5\.0 will add' \
  "$repo_root/Tools/openapi-to-innonetwork/SwiftOpenAPIGeneratorPath.md"
forbidden_pattern 'missing, stale, empty' \
  "$repo_root/CHANGELOG.md" \
  "$repo_root/docs/releases/5.0.0.md"
forbidden_pattern '^[[:space:]]*await manager\.retry\(task\)[[:space:]]*$' \
  "$repo_root/docs/Migration-5.0.0.md" \
  "$repo_root/Sources/InnoNetworkWebSocket/InnoNetworkWebSocket.docc/Articles/Reconnect.md"

require_contains 'GET responses with RFC-cacheable whole-response status codes' \
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/Articles/CachingStrategies.md"
require_contains '`Cache-Control: no-store` responses are not stored' \
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/Articles/CachingStrategies.md"
require_contains 'The response `Vary` header is processed automatically' \
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/Articles/CachingStrategies.md"
forbidden_pattern 'Only `200 OK` responses are persisted|written back on a 200 response|does not implement full HTTP `Vary`|server `Cache-Control: no-store` are not honoured|응답 `Vary` 헤더 기반 자동 key 확장은 별도 설계가 필요하다|Cache-Control expansion' \
  "$repo_root/README.md" \
  "$repo_root/docs" \
  "$repo_root/Sources/InnoNetwork" \
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc"
forbidden_pattern 'wraps everything that follows|wraps the core retry/refresh/transport pipeline|retry/refresh/transport pipeline' \
  "$repo_root/README.md" \
  "$repo_root/docs" \
  "$repo_root/Sources/InnoNetwork" \
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc"

bash "$repo_root/Scripts/check_public_api_budget.sh"
bash "$six_release_state_validator" --expect draft

echo "docs-contract-sync: OK"
