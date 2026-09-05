import Foundation

// MARK: - Configuration packs
//
// `NetworkConfiguration.advanced(baseURL:resilience:auth:observability:cache:transport:)`
// composes the five thematic packs below. Each pack is a Sendable
// struct whose initializer arguments are all optional (or empty-array) with
// `nil`/`[]` defaults. The stored inputs stay private: packs are immutable
// configuration commands rather than a second readable/mutable mirror of
// `NetworkConfiguration`.
//
// Usage:
//
// ```swift
// let configuration = NetworkConfiguration.advanced(
//     baseURL: baseURL,
//     resilience: ResiliencePack(retry: retry, circuitBreaker: breaker),
//     auth: AuthPack(refreshToken: refresh, additionalSigners: [signer]),
//     transport: TransportPack(timeout: 30, trustPolicy: .custom(pinning))
// )
// ```

/// Groups retry, request coalescing, circuit breaker, idempotency,
/// response-body buffering, and custom execution policies.
public struct ResiliencePack: Sendable {
    private let retry: RetryPolicy?
    private let coalescing: RequestCoalescingPolicy?
    private let circuitBreaker: CircuitBreakerPolicy?
    private let idempotency: IdempotencyKeyPolicy?
    private let bodyBuffering: ResponseBodyBufferingPolicy?
    /// Custom ``RequestExecutionPolicy`` instances inserted around the
    /// single transport attempt. Replaces the builder slot wholesale;
    /// pass `nil` (the default) to leave the underlying value alone.
    private let customExecutionPolicies: [any RequestExecutionPolicy]?
    private let admission: RequestAdmissionPolicy?
    private let advancedRateLimit: AdvancedRateLimitPolicy?

    public init(
        retry: RetryPolicy? = nil,
        coalescing: RequestCoalescingPolicy? = nil,
        circuitBreaker: CircuitBreakerPolicy? = nil,
        idempotency: IdempotencyKeyPolicy? = nil,
        bodyBuffering: ResponseBodyBufferingPolicy? = nil,
        customExecutionPolicies: [any RequestExecutionPolicy]? = nil,
        admission: RequestAdmissionPolicy? = nil,
        advancedRateLimit: AdvancedRateLimitPolicy? = nil
    ) {
        self.retry = retry
        self.coalescing = coalescing
        self.circuitBreaker = circuitBreaker
        self.idempotency = idempotency
        self.bodyBuffering = bodyBuffering
        self.customExecutionPolicies = customExecutionPolicies
        self.admission = admission
        self.advancedRateLimit = advancedRateLimit
    }

    package func apply(to builder: inout NetworkConfiguration.AdvancedBuilder) {
        if let retry { builder.retryPolicy = retry }
        if let coalescing { builder.requestCoalescingPolicy = coalescing }
        if let circuitBreaker { builder.circuitBreakerPolicy = circuitBreaker }
        if let idempotency { builder.idempotencyKeyPolicy = idempotency }
        if let bodyBuffering {
            builder.responseBodyBufferingPolicy = bodyBuffering
        }
        if let customExecutionPolicies { builder.customExecutionPolicies = customExecutionPolicies }
        if let admission { builder.requestAdmissionPolicy = admission }
        if let advancedRateLimit { builder.advancedRateLimitPolicy = advancedRateLimit }
    }
}

/// Groups refresh-token policy and the interceptor chains.
///
/// `additionalRequestInterceptors`, `additionalSigners`,
/// `additionalResponseInterceptors`, and
/// `additionalDecodingInterceptors` are **appended** to the builder's
/// existing chains rather than replacing them, so the pack composes cleanly
/// with any preset that already populates these slots.
public struct AuthPack: Sendable {
    private let refreshToken: RefreshTokenPolicy?
    private let additionalRequestInterceptors: [RequestInterceptor]
    private let additionalSigners: [RequestSigner]
    private let additionalResponseInterceptors: [ResponseInterceptor]
    private let additionalDecodingInterceptors: [DecodingInterceptor]

    public init(
        refreshToken: RefreshTokenPolicy? = nil,
        additionalRequestInterceptors: [RequestInterceptor] = [],
        additionalSigners: [RequestSigner] = [],
        additionalResponseInterceptors: [ResponseInterceptor] = [],
        additionalDecodingInterceptors: [DecodingInterceptor] = []
    ) {
        self.refreshToken = refreshToken
        self.additionalRequestInterceptors = additionalRequestInterceptors
        self.additionalSigners = additionalSigners
        self.additionalResponseInterceptors = additionalResponseInterceptors
        self.additionalDecodingInterceptors = additionalDecodingInterceptors
    }

    package func apply(to builder: inout NetworkConfiguration.AdvancedBuilder) {
        if let refreshToken { builder.refreshTokenPolicy = refreshToken }
        if !additionalRequestInterceptors.isEmpty {
            builder.requestInterceptors.append(contentsOf: additionalRequestInterceptors)
        }
        if !additionalSigners.isEmpty {
            builder.requestSigners.append(contentsOf: additionalSigners)
        }
        if !additionalResponseInterceptors.isEmpty {
            builder.responseInterceptors.append(contentsOf: additionalResponseInterceptors)
        }
        if !additionalDecodingInterceptors.isEmpty {
            builder.decodingInterceptors.append(contentsOf: additionalDecodingInterceptors)
        }
    }
}

/// Groups event observers, event delivery policy, and metrics
/// reporters (network and event-pipeline).
public struct ObservabilityPack: Sendable {
    private let eventObservers: [any NetworkEventObserving]
    private let eventDeliveryPolicy: EventDeliveryPolicy?
    private let eventMetricsReporter: (any EventPipelineMetricsReporting)?
    private let networkMonitor: (any NetworkMonitoring)?
    private let metricsReporter: (any NetworkMetricsReporting)?

    public init(
        eventObservers: [any NetworkEventObserving] = [],
        eventDeliveryPolicy: EventDeliveryPolicy? = nil,
        eventMetricsReporter: (any EventPipelineMetricsReporting)? = nil,
        networkMonitor: (any NetworkMonitoring)? = nil,
        metricsReporter: (any NetworkMetricsReporting)? = nil
    ) {
        self.eventObservers = eventObservers
        self.eventDeliveryPolicy = eventDeliveryPolicy
        self.eventMetricsReporter = eventMetricsReporter
        self.networkMonitor = networkMonitor
        self.metricsReporter = metricsReporter
    }

    package func apply(to builder: inout NetworkConfiguration.AdvancedBuilder) {
        if !eventObservers.isEmpty {
            builder.eventObservers.append(contentsOf: eventObservers)
        }
        if let eventDeliveryPolicy { builder.eventDeliveryPolicy = eventDeliveryPolicy }
        if let eventMetricsReporter { builder.eventMetricsReporter = eventMetricsReporter }
        if let networkMonitor { builder.networkMonitor = networkMonitor }
        if let metricsReporter { builder.metricsReporter = metricsReporter }
    }
}

/// Groups response cache policy, the cache backend, and the
/// failure-payload capture toggle.
public struct CachePack: Sendable {
    private let responseCachePolicy: ResponseCachePolicy?
    private let responseCache: (any ResponseCache)?
    private let sensitiveHeaderNames: Set<String>?
    private let captureFailurePayload: Bool?

    public init(
        responseCachePolicy: ResponseCachePolicy? = nil,
        responseCache: (any ResponseCache)? = nil,
        sensitiveHeaderNames: Set<String>? = nil,
        captureFailurePayload: Bool? = nil
    ) {
        self.responseCachePolicy = responseCachePolicy
        self.responseCache = responseCache
        self.sensitiveHeaderNames = sensitiveHeaderNames
        self.captureFailurePayload = captureFailurePayload
    }

    package func apply(to builder: inout NetworkConfiguration.AdvancedBuilder) {
        if let responseCachePolicy { builder.responseCachePolicy = responseCachePolicy }
        if let responseCache { builder.responseCache = responseCache }
        if let sensitiveHeaderNames {
            builder.responseCacheSensitiveHeaderNames = Set(
                sensitiveHeaderNames.map { $0.lowercased() }
            )
        }
        if let captureFailurePayload { builder.captureFailurePayload = captureFailurePayload }
    }
}

/// Groups timeout, cache policy, network access toggles, redirect
/// policy, streaming line byte limits, the insecure-HTTP escape, trust
/// policy, acceptable status codes, and the default `User-Agent` /
/// `Accept-Language` providers.
public struct TransportPack: Sendable {
    private let timeout: TimeInterval?
    private let cachePolicy: URLRequest.CachePolicy?
    private let requestPriority: RequestPriority?
    private let allowsCellularAccess: Bool?
    private let allowsExpensiveNetworkAccess: Bool?
    private let allowsConstrainedNetworkAccess: Bool?
    private let redirectPolicy: (any RedirectPolicy)?
    private let streamingLineByteLimit: Int?
    private let allowsInsecureHTTP: Bool?
    private let trustPolicy: TrustPolicy?
    private let acceptableStatusCodes: Set<Int>?
    private let userAgentProvider: (@Sendable () -> String)?
    private let acceptLanguageProvider: (@Sendable () -> String)?

    public init(
        timeout: TimeInterval? = nil,
        cachePolicy: URLRequest.CachePolicy? = nil,
        requestPriority: RequestPriority? = nil,
        allowsCellularAccess: Bool? = nil,
        allowsExpensiveNetworkAccess: Bool? = nil,
        allowsConstrainedNetworkAccess: Bool? = nil,
        redirectPolicy: (any RedirectPolicy)? = nil,
        streamingLineByteLimit: Int? = nil,
        allowsInsecureHTTP: Bool? = nil,
        trustPolicy: TrustPolicy? = nil,
        acceptableStatusCodes: Set<Int>? = nil,
        userAgentProvider: (@Sendable () -> String)? = nil,
        acceptLanguageProvider: (@Sendable () -> String)? = nil
    ) {
        self.timeout = timeout
        self.cachePolicy = cachePolicy
        self.requestPriority = requestPriority
        self.allowsCellularAccess = allowsCellularAccess
        self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        self.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        self.redirectPolicy = redirectPolicy
        self.streamingLineByteLimit = streamingLineByteLimit
        self.allowsInsecureHTTP = allowsInsecureHTTP
        self.trustPolicy = trustPolicy
        self.acceptableStatusCodes = acceptableStatusCodes
        self.userAgentProvider = userAgentProvider
        self.acceptLanguageProvider = acceptLanguageProvider
    }

    package func apply(to builder: inout NetworkConfiguration.AdvancedBuilder) {
        if let timeout { builder.timeout = timeout }
        if let cachePolicy { builder.cachePolicy = cachePolicy }
        if let requestPriority { builder.requestPriority = requestPriority }
        if let allowsCellularAccess { builder.allowsCellularAccess = allowsCellularAccess }
        if let allowsExpensiveNetworkAccess {
            builder.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        }
        if let allowsConstrainedNetworkAccess {
            builder.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        }
        if let redirectPolicy { builder.redirectPolicy = redirectPolicy }
        if let streamingLineByteLimit { builder.streamingLineByteLimit = streamingLineByteLimit }
        if let allowsInsecureHTTP { builder.allowsInsecureHTTP = allowsInsecureHTTP }
        if let trustPolicy { builder.trustPolicy = trustPolicy }
        if let acceptableStatusCodes { builder.acceptableStatusCodes = acceptableStatusCodes }
        if let userAgentProvider { builder.userAgentProvider = userAgentProvider }
        if let acceptLanguageProvider { builder.acceptLanguageProvider = acceptLanguageProvider }
    }
}
