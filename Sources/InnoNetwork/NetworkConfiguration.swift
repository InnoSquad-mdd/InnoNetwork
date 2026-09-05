import Foundation
import OSLog

/// An immutable command that configures ``DefaultNetworkClient``.
///
/// Create values with ``safeDefaults(baseURL:)`` or compose explicit policy
/// packs with
/// ``advanced(baseURL:resilience:auth:observability:cache:transport:)``.
/// Runtime fields intentionally stay package-owned: exposing the same policy
/// twice as both readable state and pack input would enlarge the compatibility
/// surface without adding a supported mutation path. Applications that need
/// to inspect their chosen settings should keep that app-owned input model
/// alongside the configuration they build.
public struct NetworkConfiguration: Sendable {
    /// The default range of HTTP status codes treated as successful responses.
    /// `2xx` per RFC 9110 §15.3.
    package static let defaultAcceptableStatusCodes: Set<Int> = Set(200..<300)
    /// Default maximum UTF-8 byte length accepted for a single line-delimited
    /// streaming frame before it is rejected with
    /// ``NetworkErrorCode/streamFrameTooLarge``.
    package static let defaultStreamingLineByteLimit: Int = 1 << 20
    /// Default maximum size for a collected response, including file-upload
    /// responses, in production-facing configuration presets.
    package static let defaultResponseBodyByteLimit: Int64 = 5 * 1024 * 1024

    package enum Presets {
        static func safeDefaults(baseURL: URL) -> NetworkConfiguration {
            NetworkConfiguration(
                internalBaseURL: baseURL,
                timeout: 30.0,
                cachePolicy: .useProtocolCachePolicy,
                requestPriority: .normal,
                allowsCellularAccess: true,
                allowsExpensiveNetworkAccess: true,
                allowsConstrainedNetworkAccess: true,
                retryPolicy: nil,
                networkMonitor: NetworkMonitor.shared,
                metricsReporter: nil,
                trustPolicy: .systemDefault,
                eventObservers: [],
                eventDeliveryPolicy: .default,
                eventMetricsReporter: nil,
                acceptableStatusCodes: NetworkConfiguration.defaultAcceptableStatusCodes,
                requestInterceptors: [],
                responseInterceptors: [],
                customExecutionPolicies: [],
                requestAdmissionPolicy: nil,
                advancedRateLimitPolicy: nil,
                idempotencyKeyPolicy: .disabled,
                responseBodyBufferingPolicy: .streaming(
                    maxBytes: NetworkConfiguration.defaultResponseBodyByteLimit
                ),
                streamingLineByteLimit: NetworkConfiguration.defaultStreamingLineByteLimit,
                redirectPolicy: DefaultRedirectPolicy()
            )
        }

        static func advancedTuning(baseURL: URL) -> NetworkConfiguration {
            NetworkConfiguration(
                internalBaseURL: baseURL,
                timeout: 60.0,
                cachePolicy: .reloadIgnoringLocalCacheData,
                requestPriority: .normal,
                allowsCellularAccess: true,
                allowsExpensiveNetworkAccess: true,
                allowsConstrainedNetworkAccess: true,
                retryPolicy: nil,
                networkMonitor: NetworkMonitor.shared,
                metricsReporter: nil,
                trustPolicy: .systemDefault,
                eventObservers: [],
                eventDeliveryPolicy: EventDeliveryPolicy(
                    maxBufferedEventsPerPartition: 512,
                    maxBufferedEventsPerConsumer: 512,
                    overflowPolicy: .dropOldest
                ),
                eventMetricsReporter: nil,
                acceptableStatusCodes: NetworkConfiguration.defaultAcceptableStatusCodes,
                requestInterceptors: [],
                responseInterceptors: [],
                customExecutionPolicies: [],
                requestAdmissionPolicy: nil,
                advancedRateLimitPolicy: nil,
                idempotencyKeyPolicy: .disabled,
                responseBodyBufferingPolicy: .streaming(
                    maxBytes: NetworkConfiguration.defaultResponseBodyByteLimit
                ),
                streamingLineByteLimit: NetworkConfiguration.defaultStreamingLineByteLimit,
                redirectPolicy: DefaultRedirectPolicy()
            )
        }
    }

    package let baseURL: URL
    package let timeout: TimeInterval
    package let cachePolicy: URLRequest.CachePolicy
    /// Default priority hint applied to requests that do not override it.
    package let requestPriority: RequestPriority
    /// Default cellular-access policy applied to built `URLRequest` values.
    package let allowsCellularAccess: Bool
    /// Default expensive-network policy applied to built `URLRequest` values.
    package let allowsExpensiveNetworkAccess: Bool
    /// Default Low Data Mode policy applied to built `URLRequest` values.
    package let allowsConstrainedNetworkAccess: Bool
    package let retryPolicy: RetryPolicy?
    package let networkMonitor: (any NetworkMonitoring)?
    package let metricsReporter: (any NetworkMetricsReporting)?
    package let trustPolicy: TrustPolicy
    package let eventObservers: [any NetworkEventObserving]
    package let eventDeliveryPolicy: EventDeliveryPolicy
    package let eventMetricsReporter: (any EventPipelineMetricsReporting)?
    /// HTTP status codes that the request executor treats as successful.
    /// Responses with a status code outside this set throw
    /// ``NetworkError/statusCode(_:)``. Defaults to ``defaultAcceptableStatusCodes``
    /// (`200..<300`); override to allow values like `304` or `205` to flow
    /// through to consumer code without error mapping.
    package let acceptableStatusCodes: Set<Int>
    /// Request interceptors applied to **every** request dispatched through
    /// this client, before any per-``APIDefinition`` interceptors. Use this
    /// slot for cross-cutting concerns (Bearer auth, distributed-tracing
    /// headers, request IDs) so each ``APIDefinition`` does not have to
    /// re-declare them.
    package let requestInterceptors: [RequestInterceptor]
    /// Header-only request signers applied after every request interceptor
    /// and after the active refresh-token policy attaches its current token.
    /// Configuration signers run before endpoint-level signers.
    package let requestSigners: [RequestSigner]
    /// Response interceptors applied to **every** response, after any
    /// per-``APIDefinition`` interceptors. The order is intentionally an
    /// onion: the request chain runs outer→inner (config first), and the
    /// response chain unwinds inner→outer (config last) so a session-level
    /// interceptor can observe the same response shape its peer would have
    /// produced under a per-endpoint setup.
    package let responseInterceptors: [ResponseInterceptor]
    /// Decoding interceptors applied around the response decode boundary
    /// for **every** request. Hooks fire after all response interceptors
    /// have settled, immediately before and after the configured decoder
    /// runs. Use them for envelope unwrapping, payload sanitization,
    /// decode metrics, or typed-value normalization. See
    /// ``DecodingInterceptor`` for ordering and failure semantics.
    package let decodingInterceptors: [DecodingInterceptor]
    /// Optional token refresh policy. When configured, the client applies the
    /// current token before transport, refreshes once on matching auth status
    /// codes, and replays the fully adapted request at most one time.
    package let refreshTokenPolicy: RefreshTokenPolicy?
    /// Optional raw-transport coalescing policy. Disabled by default.
    package let requestCoalescingPolicy: RequestCoalescingPolicy
    /// Optional response cache policy. Disabled by default.
    package let responseCachePolicy: ResponseCachePolicy
    /// Cache storage used when ``responseCachePolicy`` is enabled.
    package let responseCache: (any ResponseCache)?
    /// Additional client-scoped request header names whose values are
    /// fingerprinted before they become part of a response-cache identity.
    package let responseCacheSensitiveHeaderNames: Set<String>
    /// Optional per-host circuit breaker policy. Disabled by default.
    package let circuitBreakerPolicy: CircuitBreakerPolicy?
    /// Custom public execution policies wrapped around each raw transport
    /// attempt after request adaptation/auth application and before response
    /// interceptors, status validation, cache writes, and decoding.
    package let customExecutionPolicies: [any RequestExecutionPolicy]
    /// Optional built-in admission policy enforced only when a physical
    /// transport attempt is about to begin.
    package let requestAdmissionPolicy: RequestAdmissionPolicy?
    /// Optional process-local weighted rate limiter for physical dispatches.
    package let advancedRateLimitPolicy: AdvancedRateLimitPolicy?
    /// Optional policy that attaches one stable idempotency key to every
    /// retry attempt for the same logical request.
    package let idempotencyKeyPolicy: IdempotencyKeyPolicy

    /// Produces the default `User-Agent` value at request-build time.
    ///
    /// The provider is evaluated for each request when the endpoint still
    /// carries the library default `User-Agent`, allowing tests and apps with
    /// custom bundle metadata to avoid a process-start snapshot.
    package let userAgentProvider: @Sendable () -> String

    /// Produces the default `Accept-Language` value at request-build time.
    ///
    /// The provider is evaluated for each request when the endpoint still
    /// carries the library default `Accept-Language`, so locale changes can
    /// be reflected without rebuilding endpoint types.
    package let acceptLanguageProvider: @Sendable () -> String

    /// When `false` (default), response bodies attached to ``NetworkError``
    /// cases (`decoding`, `statusCode`, and `underlying` when present) are
    /// zeroed out before the error is logged or surfaced
    /// to consumers, so PII in failure payloads cannot accidentally leak
    /// into crash logs, analytics, or error reporting. Status code, headers,
    /// and the original `URLRequest` are preserved.
    ///
    /// Set this to `true` only in diagnostic configurations where capturing
    /// the failing response body is worth the privacy trade-off.
    package let captureFailurePayload: Bool

    /// Response body collection policy. ``safeDefaults(baseURL:)``
    /// and ``advanced(baseURL:resilience:auth:observability:cache:transport:)``
    /// use ``ResponseBodyBufferingPolicy/streaming(maxBytes:)`` with a 5 MiB
    /// ceiling for inline requests and file-backed uploads. Callers that
    /// intentionally need an unbounded response
    /// can opt out explicitly with `.streaming(maxBytes: nil)` or
    /// `.buffered(maxBytes: nil)`. InnoNetworkTestSupport's `MockURLSession`
    /// and VCR replay mode can enforce bounded streaming over their already
    /// buffered fixtures. Arbitrary custom sessions that only implement
    /// `data(for:)` must select a buffered policy explicitly; bounded streaming
    /// otherwise fails closed. Custom sessions that support file uploads but
    /// not bounded upload-response streaming also fail closed while a ceiling
    /// is active.
    package let responseBodyBufferingPolicy: ResponseBodyBufferingPolicy

    /// Maximum UTF-8 byte length accepted for one line-delimited streaming
    /// frame before decoding. Defaults to 1 MiB. Values below 1 are
    /// normalised to 1 so a misconfigured client cannot disable the guard by
    /// accident.
    package let streamingLineByteLimit: Int

    /// Decides how the client reacts to HTTP redirects (3xx + `Location`).
    /// Defaults to ``DefaultRedirectPolicy``, which rejects HTTPS downgrades
    /// and any cross-origin redirect that retains an unsafe method, and strips
    /// every caller-prepared original header plus built-in or registered
    /// sensitive session headers on other cross-origin hops.
    package let redirectPolicy: any RedirectPolicy

    /// When `false` (default), a `baseURL` with `http://` scheme is rejected
    /// at request-build time with ``NetworkError/configuration(reason:)`` and
    /// ``NetworkConfigurationFailureReason/invalidBaseURL(_:)``. App
    /// Transport Security blocks plain-HTTP traffic at the Apple platform
    /// level for App Store submissions; this flag adds a defense-in-depth
    /// guard for callers that may have ATS exemptions or run in macOS/CLI
    /// targets without ATS enforcement. Set to `true` only when the
    /// non-encrypted endpoint is intentional (loopback, private LAN, opt-in
    /// staging).
    package let allowsInsecureHTTP: Bool

    /// Build a `URLSessionConfiguration` derived from `URLSessionConfiguration.default`.
    /// Provided as a convenience for callers that construct their own
    /// `URLSession` and want a starting point that matches the session-level
    /// parts of this configuration surface.
    ///
    /// Adopters that need to swap `httpCookieStorage` for multi-account
    /// isolation, configure proxy/HTTP2/TLS settings, or otherwise mutate
    /// `URLSessionConfiguration` should call this method, mutate the
    /// returned value, and pass the resulting `URLSession` to
    /// `DefaultNetworkClient(configuration:session:)`. See
    /// `docs/Cookies.md` for the canonical cookie-isolation recipe.
    ///
    /// `trustPolicy` is evaluated by InnoNetwork's per-task delegate during
    /// request execution; it is not representable on `URLSessionConfiguration`
    /// and is therefore not copied here.
    public func makeURLSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.requestCachePolicy = cachePolicy
        config.allowsCellularAccess = allowsCellularAccess
        config.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        config.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        return config
    }

    /// Internal builder used by the pack-based `advanced(...)` factory.
    /// Adopters compose
    /// configurations through
    /// ``advanced(baseURL:resilience:auth:observability:cache:transport:)``;
    /// the builder type is not part of the public API.
    package struct AdvancedBuilder: Sendable {
        package var baseURL: URL
        package var timeout: TimeInterval
        package var cachePolicy: URLRequest.CachePolicy
        package var requestPriority: RequestPriority
        package var allowsCellularAccess: Bool
        package var allowsExpensiveNetworkAccess: Bool
        package var allowsConstrainedNetworkAccess: Bool
        package var retryPolicy: RetryPolicy?
        package var networkMonitor: (any NetworkMonitoring)?
        package var metricsReporter: (any NetworkMetricsReporting)?
        package var trustPolicy: TrustPolicy
        package var eventObservers: [any NetworkEventObserving]
        package var eventDeliveryPolicy: EventDeliveryPolicy
        package var eventMetricsReporter: (any EventPipelineMetricsReporting)?
        package var acceptableStatusCodes: Set<Int>
        package var requestInterceptors: [RequestInterceptor]
        package var requestSigners: [RequestSigner]
        package var responseInterceptors: [ResponseInterceptor]
        package var decodingInterceptors: [DecodingInterceptor]
        package var refreshTokenPolicy: RefreshTokenPolicy?
        package var requestCoalescingPolicy: RequestCoalescingPolicy
        package var responseCachePolicy: ResponseCachePolicy
        package var responseCache: (any ResponseCache)?
        package var responseCacheSensitiveHeaderNames: Set<String>
        package var circuitBreakerPolicy: CircuitBreakerPolicy?
        package var customExecutionPolicies: [any RequestExecutionPolicy]
        package var requestAdmissionPolicy: RequestAdmissionPolicy?
        package var advancedRateLimitPolicy: AdvancedRateLimitPolicy?
        package var idempotencyKeyPolicy: IdempotencyKeyPolicy
        package var userAgentProvider: @Sendable () -> String
        package var acceptLanguageProvider: @Sendable () -> String
        package var captureFailurePayload: Bool
        package var responseBodyBufferingPolicy: ResponseBodyBufferingPolicy
        package var streamingLineByteLimit: Int
        package var redirectPolicy: any RedirectPolicy
        package var allowsInsecureHTTP: Bool
        package init(preset: NetworkConfiguration) {
            self.baseURL = preset.baseURL
            self.timeout = preset.timeout
            self.cachePolicy = preset.cachePolicy
            self.requestPriority = preset.requestPriority
            self.allowsCellularAccess = preset.allowsCellularAccess
            self.allowsExpensiveNetworkAccess = preset.allowsExpensiveNetworkAccess
            self.allowsConstrainedNetworkAccess = preset.allowsConstrainedNetworkAccess
            self.retryPolicy = preset.retryPolicy
            self.networkMonitor = preset.networkMonitor
            self.metricsReporter = preset.metricsReporter
            self.trustPolicy = preset.trustPolicy
            self.eventObservers = preset.eventObservers
            self.eventDeliveryPolicy = preset.eventDeliveryPolicy
            self.eventMetricsReporter = preset.eventMetricsReporter
            self.acceptableStatusCodes = preset.acceptableStatusCodes
            self.requestInterceptors = preset.requestInterceptors
            self.requestSigners = preset.requestSigners
            self.responseInterceptors = preset.responseInterceptors
            self.decodingInterceptors = preset.decodingInterceptors
            self.refreshTokenPolicy = preset.refreshTokenPolicy
            self.requestCoalescingPolicy = preset.requestCoalescingPolicy
            self.responseCachePolicy = preset.responseCachePolicy
            self.responseCache = preset.responseCache
            self.responseCacheSensitiveHeaderNames = preset.responseCacheSensitiveHeaderNames
            self.circuitBreakerPolicy = preset.circuitBreakerPolicy
            self.customExecutionPolicies = preset.customExecutionPolicies
            self.requestAdmissionPolicy = preset.requestAdmissionPolicy
            self.advancedRateLimitPolicy = preset.advancedRateLimitPolicy
            self.idempotencyKeyPolicy = preset.idempotencyKeyPolicy
            self.userAgentProvider = preset.userAgentProvider
            self.acceptLanguageProvider = preset.acceptLanguageProvider
            self.captureFailurePayload = preset.captureFailurePayload
            self.responseBodyBufferingPolicy = preset.responseBodyBufferingPolicy
            self.streamingLineByteLimit = preset.streamingLineByteLimit
            self.redirectPolicy = preset.redirectPolicy
            self.allowsInsecureHTTP = preset.allowsInsecureHTTP
        }

        package func build() -> NetworkConfiguration {
            NetworkConfiguration(
                internalBaseURL: baseURL,
                timeout: timeout,
                cachePolicy: cachePolicy,
                requestPriority: requestPriority,
                allowsCellularAccess: allowsCellularAccess,
                allowsExpensiveNetworkAccess: allowsExpensiveNetworkAccess,
                allowsConstrainedNetworkAccess: allowsConstrainedNetworkAccess,
                retryPolicy: retryPolicy,
                networkMonitor: networkMonitor,
                metricsReporter: metricsReporter,
                trustPolicy: trustPolicy,
                eventObservers: eventObservers,
                eventDeliveryPolicy: eventDeliveryPolicy,
                eventMetricsReporter: eventMetricsReporter,
                acceptableStatusCodes: acceptableStatusCodes,
                requestInterceptors: requestInterceptors,
                requestSigners: requestSigners,
                responseInterceptors: responseInterceptors,
                decodingInterceptors: decodingInterceptors,
                refreshTokenPolicy: refreshTokenPolicy,
                requestCoalescingPolicy: requestCoalescingPolicy,
                responseCachePolicy: responseCachePolicy,
                responseCache: responseCache,
                responseCacheSensitiveHeaderNames: responseCacheSensitiveHeaderNames,
                circuitBreakerPolicy: circuitBreakerPolicy,
                customExecutionPolicies: customExecutionPolicies,
                requestAdmissionPolicy: requestAdmissionPolicy,
                advancedRateLimitPolicy: advancedRateLimitPolicy,
                idempotencyKeyPolicy: idempotencyKeyPolicy,
                userAgentProvider: userAgentProvider,
                acceptLanguageProvider: acceptLanguageProvider,
                captureFailurePayload: captureFailurePayload,
                responseBodyBufferingPolicy: responseBodyBufferingPolicy,
                streamingLineByteLimit: streamingLineByteLimit,
                redirectPolicy: redirectPolicy,
                allowsInsecureHTTP: allowsInsecureHTTP
            )
        }
    }

    public static func safeDefaults(baseURL: URL) -> NetworkConfiguration {
        Presets.safeDefaults(baseURL: baseURL)
    }

    /// Composes a configuration from the five thematic packs. Each
    /// pack is optional; omitted packs leave the underlying tuned
    /// defaults from `Presets.advancedTuning(baseURL:)` untouched.
    public static func advanced(
        baseURL: URL,
        resilience: ResiliencePack = ResiliencePack(),
        auth: AuthPack = AuthPack(),
        observability: ObservabilityPack = ObservabilityPack(),
        cache: CachePack = CachePack(),
        transport: TransportPack = TransportPack()
    ) -> NetworkConfiguration {
        var builder = AdvancedBuilder(preset: Presets.advancedTuning(baseURL: baseURL))
        resilience.apply(to: &builder)
        auth.apply(to: &builder)
        observability.apply(to: &builder)
        cache.apply(to: &builder)
        transport.apply(to: &builder)
        return builder.build()
    }

    private init(
        internalBaseURL baseURL: URL,
        timeout: TimeInterval = 30.0,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        requestPriority: RequestPriority = .normal,
        allowsCellularAccess: Bool = true,
        allowsExpensiveNetworkAccess: Bool = true,
        allowsConstrainedNetworkAccess: Bool = true,
        retryPolicy: RetryPolicy? = nil,
        networkMonitor: (any NetworkMonitoring)? = NetworkMonitor.shared,
        metricsReporter: (any NetworkMetricsReporting)? = nil,
        trustPolicy: TrustPolicy = .systemDefault,
        eventObservers: [any NetworkEventObserving] = [],
        eventDeliveryPolicy: EventDeliveryPolicy = .default,
        eventMetricsReporter: (any EventPipelineMetricsReporting)? = nil,
        acceptableStatusCodes: Set<Int> = NetworkConfiguration.defaultAcceptableStatusCodes,
        requestInterceptors: [RequestInterceptor] = [],
        requestSigners: [RequestSigner] = [],
        responseInterceptors: [ResponseInterceptor] = [],
        decodingInterceptors: [DecodingInterceptor] = [],
        refreshTokenPolicy: RefreshTokenPolicy? = nil,
        requestCoalescingPolicy: RequestCoalescingPolicy = .disabled,
        responseCachePolicy: ResponseCachePolicy = .disabled,
        responseCache: (any ResponseCache)? = nil,
        responseCacheSensitiveHeaderNames: Set<String> = [],
        circuitBreakerPolicy: CircuitBreakerPolicy? = nil,
        customExecutionPolicies: [any RequestExecutionPolicy] = [],
        requestAdmissionPolicy: RequestAdmissionPolicy? = nil,
        advancedRateLimitPolicy: AdvancedRateLimitPolicy? = nil,
        idempotencyKeyPolicy: IdempotencyKeyPolicy = .disabled,
        userAgentProvider: @escaping @Sendable () -> String = { HTTPHeader.defaultUserAgent.value },
        acceptLanguageProvider: @escaping @Sendable () -> String = { HTTPHeader.defaultAcceptLanguage.value },
        captureFailurePayload: Bool = false,
        responseBodyBufferingPolicy: ResponseBodyBufferingPolicy = .streaming(
            maxBytes: NetworkConfiguration.defaultResponseBodyByteLimit
        ),
        streamingLineByteLimit: Int = NetworkConfiguration.defaultStreamingLineByteLimit,
        redirectPolicy: any RedirectPolicy = DefaultRedirectPolicy(),
        allowsInsecureHTTP: Bool = false
    ) {
        self.baseURL = baseURL
        self.timeout = timeout
        self.cachePolicy = cachePolicy
        self.requestPriority = requestPriority
        self.allowsCellularAccess = allowsCellularAccess
        self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        self.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        self.retryPolicy = retryPolicy
        self.networkMonitor = networkMonitor
        self.metricsReporter = metricsReporter
        self.trustPolicy = trustPolicy
        self.eventObservers = eventObservers
        self.eventDeliveryPolicy = eventDeliveryPolicy
        self.eventMetricsReporter = eventMetricsReporter
        self.acceptableStatusCodes = acceptableStatusCodes
        self.requestInterceptors = requestInterceptors
        self.requestSigners = requestSigners
        self.responseInterceptors = responseInterceptors
        self.decodingInterceptors = decodingInterceptors
        self.refreshTokenPolicy = refreshTokenPolicy
        self.requestCoalescingPolicy = requestCoalescingPolicy
        self.responseCachePolicy = responseCachePolicy
        self.responseCache = responseCache
        self.responseCacheSensitiveHeaderNames = Set(
            responseCacheSensitiveHeaderNames.map { $0.lowercased() }
        )
        self.circuitBreakerPolicy = circuitBreakerPolicy
        self.customExecutionPolicies = customExecutionPolicies
        self.requestAdmissionPolicy = requestAdmissionPolicy
        self.advancedRateLimitPolicy = advancedRateLimitPolicy
        self.idempotencyKeyPolicy = idempotencyKeyPolicy
        self.userAgentProvider = userAgentProvider
        self.acceptLanguageProvider = acceptLanguageProvider
        self.captureFailurePayload = captureFailurePayload
        self.responseBodyBufferingPolicy = responseBodyBufferingPolicy
        self.streamingLineByteLimit = max(1, streamingLineByteLimit)
        self.redirectPolicy = redirectPolicy
        self.allowsInsecureHTTP = allowsInsecureHTTP
        Self.assertIdempotencyHeaderNamesMatch(
            keyPolicy: idempotencyKeyPolicy,
            retryPolicy: retryPolicy
        )
    }

    package init(
        baseURL: URL,
        timeout: TimeInterval = 30.0,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        requestPriority: RequestPriority = .normal,
        allowsCellularAccess: Bool = true,
        allowsExpensiveNetworkAccess: Bool = true,
        allowsConstrainedNetworkAccess: Bool = true,
        retryPolicy: RetryPolicy? = nil,
        networkMonitor: (any NetworkMonitoring)? = NetworkMonitor.shared,
        metricsReporter: (any NetworkMetricsReporting)? = nil,
        trustPolicy: TrustPolicy = .systemDefault,
        eventObservers: [any NetworkEventObserving] = [],
        eventDeliveryPolicy: EventDeliveryPolicy = .default,
        eventMetricsReporter: (any EventPipelineMetricsReporting)? = nil,
        acceptableStatusCodes: Set<Int> = NetworkConfiguration.defaultAcceptableStatusCodes,
        requestInterceptors: [RequestInterceptor] = [],
        requestSigners: [RequestSigner] = [],
        responseInterceptors: [ResponseInterceptor] = [],
        decodingInterceptors: [DecodingInterceptor] = [],
        refreshTokenPolicy: RefreshTokenPolicy? = nil,
        requestCoalescingPolicy: RequestCoalescingPolicy = .disabled,
        responseCachePolicy: ResponseCachePolicy = .disabled,
        responseCache: (any ResponseCache)? = nil,
        responseCacheSensitiveHeaderNames: Set<String> = [],
        circuitBreakerPolicy: CircuitBreakerPolicy? = nil,
        customExecutionPolicies: [any RequestExecutionPolicy] = [],
        requestAdmissionPolicy: RequestAdmissionPolicy? = nil,
        advancedRateLimitPolicy: AdvancedRateLimitPolicy? = nil,
        idempotencyKeyPolicy: IdempotencyKeyPolicy = .disabled,
        userAgentProvider: @escaping @Sendable () -> String = { HTTPHeader.defaultUserAgent.value },
        acceptLanguageProvider: @escaping @Sendable () -> String = { HTTPHeader.defaultAcceptLanguage.value },
        captureFailurePayload: Bool = false,
        responseBodyBufferingPolicy: ResponseBodyBufferingPolicy = .streaming(
            maxBytes: NetworkConfiguration.defaultResponseBodyByteLimit
        ),
        streamingLineByteLimit: Int = NetworkConfiguration.defaultStreamingLineByteLimit,
        redirectPolicy: any RedirectPolicy = DefaultRedirectPolicy(),
        allowsInsecureHTTP: Bool = false
    ) {
        self.init(
            internalBaseURL: baseURL,
            timeout: timeout,
            cachePolicy: cachePolicy,
            requestPriority: requestPriority,
            allowsCellularAccess: allowsCellularAccess,
            allowsExpensiveNetworkAccess: allowsExpensiveNetworkAccess,
            allowsConstrainedNetworkAccess: allowsConstrainedNetworkAccess,
            retryPolicy: retryPolicy,
            networkMonitor: networkMonitor,
            metricsReporter: metricsReporter,
            trustPolicy: trustPolicy,
            eventObservers: eventObservers,
            eventDeliveryPolicy: eventDeliveryPolicy,
            eventMetricsReporter: eventMetricsReporter,
            acceptableStatusCodes: acceptableStatusCodes,
            requestInterceptors: requestInterceptors,
            requestSigners: requestSigners,
            responseInterceptors: responseInterceptors,
            decodingInterceptors: decodingInterceptors,
            refreshTokenPolicy: refreshTokenPolicy,
            requestCoalescingPolicy: requestCoalescingPolicy,
            responseCachePolicy: responseCachePolicy,
            responseCache: responseCache,
            responseCacheSensitiveHeaderNames: responseCacheSensitiveHeaderNames,
            circuitBreakerPolicy: circuitBreakerPolicy,
            customExecutionPolicies: customExecutionPolicies,
            requestAdmissionPolicy: requestAdmissionPolicy,
            advancedRateLimitPolicy: advancedRateLimitPolicy,
            idempotencyKeyPolicy: idempotencyKeyPolicy,
            userAgentProvider: userAgentProvider,
            acceptLanguageProvider: acceptLanguageProvider,
            captureFailurePayload: captureFailurePayload,
            responseBodyBufferingPolicy: responseBodyBufferingPolicy,
            streamingLineByteLimit: streamingLineByteLimit,
            redirectPolicy: redirectPolicy,
            allowsInsecureHTTP: allowsInsecureHTTP
        )
    }

    /// Debug-only sanity check that the idempotency header attached by
    /// ``IdempotencyKeyPolicy`` matches the header consulted by
    /// ``RetryIdempotencyPolicy``.
    ///
    /// A mismatch is a silent footgun: ``IdempotencyKeyPolicy`` writes the
    /// key under one header, the retry safety net reads from another and
    /// concludes the non-idempotent request has no anchor — every
    /// `POST`/`PATCH` timeout is then declined for retry. We assert here
    /// in debug builds only; release builds keep the original behaviour
    /// so a mis-configured production app does not crash.
    private static func assertIdempotencyHeaderNamesMatch(
        keyPolicy: IdempotencyKeyPolicy,
        retryPolicy: RetryPolicy?
    ) {
        guard let retryPolicy else { return }
        guard !keyPolicy.methods.isEmpty else { return }
        let keyHeader = keyPolicy.headerName
        let retryHeader = retryPolicy.idempotencyPolicy.idempotencyHeaderName
        // HTTP header names are case-insensitive (RFC 9110 §5.1) — compare
        // normalised forms so an `idempotency-key`/`Idempotency-Key`
        // pairing is not flagged as a mismatch.
        guard keyHeader.lowercased() != retryHeader.lowercased() else { return }
        let message = """
            IdempotencyKeyPolicy.headerName (\(keyHeader)) does not match \
            RetryIdempotencyPolicy.idempotencyHeaderName (\(retryHeader)). \
            The retry safety net reads under the retry policy header and \
            will refuse to retry non-idempotent timeouts when the key is \
            written under a different name.
            """
        #if DEBUG
        assertionFailure(message)
        #else
        Logger.API.warning("\(message, privacy: .public)")
        #endif
    }
}
