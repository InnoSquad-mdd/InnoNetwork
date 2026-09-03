# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Developer Guidelines

### Language Policy
- Developer is Korean.
- Respond in Korean unless explicitly requested otherwise.
- PR description always in Korean.

### Project Context
- This is a network library, not a UI framework.
- Focus on async/await patterns, thread safety, and type safety.
- Avoid UI-related considerations (main thread for UI updates, etc.).

### Root Cause First Approach
- Value fundamental problem solving.
- When addressing an issue, identify root cause before proposing changes.
- Consider network-specific issues: connectivity, timeouts, SSL, response parsing.

### Code Quality Standards
- **Type Safety**: Never use `as any`, `@ts-ignore`, or similar type suppression
- **Error Handling**: No empty catch blocks
- **Concurrency**: Use actors for shared state, make types Sendable where appropriate
- **Testing**: Write tests using Swift Testing framework

### Coding Style
- Swift 6.2 API Design Guidelines
- 4-space indentation
- Public APIs documented with `///`
- Actor-based thread safety for shared mutable state
- Protocol-based design for flexibility

### Git and Version Control
- Branch name in English
- Commit message in English
- PR description in Korean
- Run `swift test` before submitting PR
- DO NOT git add unstaged changes unless specified
- Keep commits focused and logically grouped

## Project Overview

InnoNetwork is a type-safe Swift network library shipped as **12 products**:

**InnoNetwork (Core):**
- Async/await + `typed throws` (`async throws(NetworkError)`)
- Type-safe request/response via generics + `APIDefinition`
- Content types: JSON, Form URL-encoded, Multipart/Form-data, custom
- Interceptors (request/response), single-flight refresh token with explicit `SessionAuthentication`
- RFC 9110 idempotency-aware retry, circuit breaker, request coalescing
- RFC 9111 cache adapter (`rfc9111Compliant(wrapping:)`)
- Phantom-typed HTTP headers, observability/metrics/logger with redaction

**InnoNetworkAuthAWS:**
- AWS Signature Version 4 request interception
- Bounded credential and service-region configuration

**InnoNetworkDownload:**
- Background `URLSession` with restoration barrier
- Pause/resume + atomic file move + inactivity watchdog
- AsyncSequence event streams + actor-based persistence

**InnoNetworkHLS:**
- Bounded HLS playlist resolution + deterministic variant selection
- Browser-free VOD segment download and TS/fMP4 assembly
- AsyncSequence progress, completion, failure, and cancellation events

**InnoNetworkHLSLive:**
- Blocking and delta live-playlist reloads with bounded snapshot delivery
- Deterministic multivariant selection, Content Steering recovery, and DVR capture

**InnoNetworkHLSAVFoundation:**
- System-managed asset downloads, playback configuration, and metrics
- Interstitial observation and application-owned FairPlay workflows

**InnoNetworkHLSAudio:**
- Xcode 27 / Swift 6.4 decoded-PCM delivery and paced sample consumption
- Optional full-mix processing tap on supported version 27 platforms

**InnoNetworkWebSocket:**
- Lifecycle reducer state machine + heartbeat + reconnect with jitter
- RFC 6455 close-code disposition + handshake error classification

**InnoNetworkPersistentCache:**
- On-disk RFC 9111-aware cache with HMAC key normalizer
- LRU + size budgets + data protection class

**InnoNetworkOpenAPI:**
- Adapter for `swift-openapi-generator` output

**InnoNetworkTrust:**
- Public Key Pinning (SPKI/DER) — opt-in product so non-pinning apps don't pay binary cost

**InnoNetworkTestSupport:**
- Public consumer helpers: `MockURLSession`, `StubNetworkClient`, `VCRURLSession`, `WebSocketEventRecorder`
- `FaultInjection` and `TestClock` are `package`-scoped: they serve this repository's own test targets and are not part of the shipped consumer surface

**Platform:**
- Swift 6.2+ (package enforces `swiftLanguageMode(.v6)`)
- iOS 16.0+ / macOS 14.0+ / tvOS 16.0+ / watchOS 9.0+ / visionOS 1.0+
- Apple-only (intentional). Full Sendable compliance, no `@unchecked Sendable` in the runtime modules (the only occurrences live in `InnoNetworkTestSupport`'s package-scoped lock-backed test fakes)

## Development Commands

```bash
# Build
swift build

# Test
swift test --parallel

# Test with coverage (the CI coverage lane is intentionally serial)
swift test --no-parallel --enable-code-coverage

# List tests
swift test --list-tests
```

## Architecture

전체 13개 product. 신규 기여 시 진입 파일과 책임만 빠르게 파악하세요.

### Sources/InnoNetwork (Core)
- `APIDefinition.swift` / `APIDefinition+Macro.swift` — endpoint 선언 프로토콜 + `@APIDefinition` 매크로
- `DefaultNetworkClient.swift` — `NetworkClient` 구현 (불변 final class + Sendable)
- `RequestExecutor.swift` + `RequestExecutor+Pipeline.swift` / `+Cache.swift` / `+Transport.swift` — 요청 실행 파이프라인
- `NetworkError.swift` / `NetworkErrorCode.swift` / `SendableUnderlyingError.swift` — 에러 모델 (typed throws 대상)
- `RetryPolicy.swift` / `RetryCoordinator.swift` / `IdempotencyKeyPolicy.swift` — RFC 9110 idempotency-aware retry
- `Auth/` — refresh token coordinator (`RefreshTokenPolicy`, `RefreshTokenCoordinator`)
- `Cache/` — response cache abstractions (RFC 9111 compliance adapter)
- `CircuitBreaker/` / `Resilience/` / `RequestCoalescing/` — failure isolation, single-flight
- `Multipart/` + `Model/MultipartFormData.swift` — RFC 7578 multipart 인/디코딩 (streaming)
- `HTTPHeader*.swift` — phantom-typed 헤더 키
- `TransportPolicy.swift` — endpoint 단위 transport shape (json/query/form/multipart/custom)
- `NetworkLogger.swift` + `Logger+.swift` — redaction (JWT, Authorization, URL user-info)
- `StreamingExecutor.swift` / `StreamingDecoders.swift` / `StreamingAPIDefinition.swift` — SSE/JSON-lines streaming
- `TrustPolicy.swift` — server trust evaluation (Trust 모듈과 연계)
- `Resources/en.lproj/Localizable.strings` — 사용자 향 에러 메시지

### Sources/InnoNetworkAuthAWS
- `AWSSigV4Interceptor.swift` — AWS Signature Version 4 요청 서명
- `AWSCredentials.swift` / `AWSServiceRegion.swift` — 자격 증명과 서비스·리전 계약

### Sources/InnoNetworkDownload
- `DownloadManager.swift` — 메인 actor (async callbacks + AsyncSequence)
- `DownloadTask.swift` — actor 기반 개별 작업
- `DownloadLifecycleReducer.swift` — 상태 머신 (illegal transition reject)
- `DownloadTaskPersistence.swift` — 디스크 영속 (flock + append-log + atomic write)
- `DownloadTransferCoordinator.swift` / `DownloadRestoreCoordinator.swift` / `DownloadFailureCoordinator.swift` — 책임 분리
- `DownloadSessionDelegate.swift` — `URLSessionDelegate` bridge
- `DownloadRuntimeRegistry.swift` — in-memory task ↔ identifier 매핑
- `DownloadConfiguration.swift` / `DownloadState.swift`

### Sources/InnoNetworkUpload
- `UploadManager.swift` — 파일 기반 foreground/background 업로드와 시스템 task 복원
- `UploadModels.swift` — 진행률, lifecycle event, bounded response receipt
- `UploadSessionDelegate.swift` — 진행률·응답·redirect delegate bridge

### Sources/InnoNetworkNext
- `OperationNetworkClient.swift` — 6.0 operation-first 실행 프리뷰와 5.x client adapter
- `NetworkOperation.swift` — 취소 가능한 typed value handle과 bounded lifecycle event
- `NetworkFailure.swift` — payload를 보존하지 않는 value-only 실패·복구 분류
- `NetworkClientConfiguration.swift` — secure/production configuration façade와 migration bridge

### Sources/InnoNetworkHLS
- `PlaylistResolver.swift` — bounded UTF-8 playlist fetch + parser
- `VariantSelector.swift` — deterministic configurable variant selection
- `HLSHTTPClient.swift` — shared bounded chunk transport + request policy bridge
- `HLSDownloader.swift` — per-resource-bounded VOD download + ordered assembly
- `HLSModels.swift` — playlist, variant, progress, event, and stable error contracts

### Sources/InnoNetworkHLSLive
- `HLSLivePlaylistClient.swift` — blocking/delta reload와 bounded snapshot stream
- `HLSLivePlaylistMerger.swift` — media-sequence 기반 delta reconstruction
- `HLSLiveDVRRecorder.swift` — bounded live-window VOD package capture

### Sources/InnoNetworkHLSAVFoundation
- `HLSAssetDownloadSession.swift` — system-managed background asset downloads
- `HLSPlaybackConfigurator.swift` / `HLSPlaybackMetrics.swift` — caller-owned playback bridge
- `HLSFairPlaySession.swift` / `HLSFairPlayPersistentKeyWorkflow.swift` — app-owned FairPlay integration

### Sources/InnoNetworkHLSAudio
- `HLSDecodedAudioOutput.swift` / `HLSDecodedAudioPacedSequence.swift` — demand-driven and paced decoded PCM
- `HLSAudioMixProcessingTap.swift` — opt-in full-mix real-time processing on supported version 27 platforms

### Sources/InnoNetworkWebSocket
- `WebSocketManager.swift` — 메인 actor
- `WebSocketLifecycleReducer.swift` — 상태 머신
- `WebSocketConnectionCoordinator.swift` / `WebSocketReceiveLoop.swift` / `WebSocketReconnectCoordinator.swift` / `WebSocketHeartbeatCoordinator.swift` — 책임 분리
- `WebSocketCloseDisposition.swift` / `WebSocketCloseCode.swift` — RFC 6455 close-code 분류
- `WebSocketSessionDelegate.swift` / `WebSocketTask.swift` / `WebSocketState.swift`
- `WebSocketInvalidationBarrier.swift` — shutdown 정합성
- `WebSocketRuntimeRegistry.swift`

### Sources/InnoNetworkPersistentCache
- `PersistentResponseCache.swift` — 메인 actor (LRU + budget + data protection)
- `PersistentResponseCacheCoding.swift` — entry serialization
- `PersistentResponseCacheKeyNormalizer.swift` — HMAC 기반 key normalization
- `PersistentResponseCacheConfiguration.swift` / `PersistentResponseCacheTelemetry.swift`

### Sources/InnoNetworkOpenAPI
- `OpenAPIAdapter.swift` — `swift-openapi-generator` transport adapter

### Sources/InnoNetworkTrust
- `PublicKeyPinning.swift` — SPKI/DER pinning (별도 product로 옵트인)

### Sources/InnoNetworkTestSupport
- `MockURLSession.swift` / `StubNetworkClient.swift` / `VCRURLSession.swift` — 1차 시민 테스트 fake
- `FaultInjection.swift` / `TestClock.swift` — deterministic timing/failure (package-scoped, not consumer API)
- `WebSocketEventRecorder.swift`

### Benchmarks / SmokeTests
- `Benchmarks/InnoNetworkBenchmarks/` — performance harness
- `SmokeTests/InnoNetworkDocSmoke/` / `InnoNetworkDownloadSmoke/` — release-time live smoke
- `Tests/InnoNetworkLiveTests/` — env-gated live (gated by env vars, off by default)

## Common Patterns

### API Definition

```swift
// Named API catalog entries keep their explicit struct while the macro derives
// repetitive conformance witnesses and validates the contract.
@APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
struct GetUser {
    typealias APIResponse = User

    let id: Int
}

@APIDefinition(method: .post, path: "/posts", auth: .required)
struct CreatePost {
    struct Params: Encodable, Sendable { let title: String; let body: String }
    typealias APIResponse = Post

    let body: Params

    init(title: String, body: String) {
        self.body = Params(title: title, body: body)
    }
}

// Multipart upload
struct UploadPhoto: MultipartAPIDefinition {
    typealias APIResponse = UploadResponse
    var sessionAuthentication: SessionAuthentication { .required }

    var multipartFormData: MultipartFormData {
        var formData = MultipartFormData()
        formData.append(title, name: "title")
        formData.append(
            imageData,
            name: "image",
            fileName: "photo.jpg",
            mimeType: "image/jpeg"
        )
        return formData
    }

    var method: HTTPMethod { .post }
    var path: String { "/upload" }
    let title: String
    let imageData: Data

    init(title: String, imageData: Data) {
        self.title = title
        self.imageData = imageData
    }
}
```

### Using the Client

```swift
let client = DefaultNetworkClient(
    baseURL: URL(string: "https://api.example.com")!
)

// Regular request
let user = try await client.request(GetUser(id: 1))

// Multipart upload
let response = try await client.upload(UploadPhoto(title: "My Photo", imageData: data))
```

### Download

```swift
// Construct one DownloadManager per feature with a unique session identifier.
// 4.0.0 removed the global `DownloadManager.shared`; manage lifetimes via DI.
let manager = try DownloadManager(
    configuration: .safeDefaults(sessionIdentifier: "com.example.app.media")
)

// Start download
let task = await manager.download(url: url, to: destination)

// AsyncSequence events
for await event in manager.events(for: task) {
    switch event {
    case .progress(let progress):
        print(progress.percentCompleted)
    case .completed(let url):
        print("Downloaded: \(url)")
    case .failed(let error):
        print("Failed: \(error)")
    default:
        break
    }
}

// Or use callbacks
await manager.setOnProgressHandler { task, progress in
    print(progress.percentCompleted)
}

// Control
await manager.pause(task)
await manager.resume(task)
await manager.cancel(task)
```

### Interceptors

```swift
struct TenantInterceptor: RequestInterceptor {
    let tenantID: String

    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        request.setValue(tenantID, forHTTPHeaderField: "X-Tenant-ID")
        return request
    }
}

@APIDefinition(method: .get, path: "/profile", auth: .required)
struct GetProfile {
    typealias APIResponse = Profile
    var requestInterceptors: [RequestInterceptor] {
        [TenantInterceptor(tenantID: "consumer-app")]
    }
}
```

## Testing Guidelines

- Use Swift Testing framework (`@Suite`, `@Test`)
- Tests are async-compatible
- Mock URLSession for network tests
- Test error cases and success cases
- Download tests verify state transitions
