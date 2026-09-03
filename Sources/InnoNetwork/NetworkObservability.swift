import Foundation
import OSLog

/// Produces URL metadata that is useful for request bucketing without
/// exposing credentials or request parameters. Kept module-internal so the
/// observability and curl surfaces share one fail-closed policy without
/// adding another public customization point.
enum NetworkURLMetadataRedactor {
    static func string(
        from url: URL?,
        includesQueryValues: Bool = false,
        nilFallback: String = ""
    ) -> String {
        guard let url else { return nilFallback }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return fallbackString(from: url)
        }

        components.user = nil
        components.password = nil
        components.percentEncodedUser = nil
        components.percentEncodedPassword = nil
        // Avoid writing `components.path` back when no JWT was found. Doing
        // so decodes reserved percent escapes such as `%2F` and silently
        // changes the request path rendered by curl and event metadata.
        let decodedPath = components.path
        let maskedPath = DefaultNetworkLogger.maskJWTLikeTokens(in: decodedPath)
        if maskedPath != decodedPath {
            components.path = maskedPath
        }
        components.fragment = nil

        if !includesQueryValues, let queryItems = components.queryItems {
            components.queryItems = queryItems.map { item in
                URLQueryItem(
                    name: item.name,
                    value: item.value == nil ? nil : "<redacted>"
                )
            }
        }

        return components.string ?? fallbackString(from: url)
    }

    private static func fallbackString(from url: URL) -> String {
        let scheme = url.scheme ?? "http"
        let host = url.host ?? ""
        let path = DefaultNetworkLogger.maskJWTLikeTokens(in: url.path)
        return "\(scheme)://\(host)\(path)"
    }
}

extension NetworkError {
    /// Stable, payload-free classification for events. Error codes remain the
    /// machine-readable primary key; this string keeps dashboards useful
    /// without forwarding decoder messages, custom trust text, URLs, or
    /// response-derived values into observers.
    var observabilityCategory: String {
        switch self {
        case .configuration(let reason):
            switch reason {
            case .invalidBaseURL:
                return "configuration.invalid_base_url"
            case .invalidRequest:
                return "configuration.invalid_request"
            case .offline:
                return "configuration.offline"
            }
        case .decoding(let stage, _, _):
            switch stage {
            case .responseBody:
                return "decoding.response_body"
            case .streamFrame:
                return "decoding.stream_frame"
            }
        case .statusCode(let response):
            return "http.status.\(response.statusCode)"
        case .underlying(let error, _):
            return "transport.\(error.code)"
        case .reachability(let reason, _, _):
            switch reason {
            case .notConnectedToInternet:
                return "reachability.not_connected"
            case .dnsLookupFailed:
                return "reachability.dns_lookup_failed"
            case .cannotFindHost:
                return "reachability.cannot_find_host"
            case .networkConnectionLost:
                return "reachability.connection_lost"
            }
        case .trustEvaluationFailed(let reason):
            switch reason {
            case .unsupportedAuthenticationMethod:
                return "trust.unsupported_authentication_method"
            case .missingServerTrust:
                return "trust.missing_server_trust"
            case .systemTrustEvaluationFailed:
                return "trust.system_evaluation_failed"
            case .hostNotPinned:
                return "trust.host_not_pinned"
            case .publicKeyExtractionFailed:
                return "trust.public_key_extraction_failed"
            case .pinMismatch:
                return "trust.pin_mismatch"
            case .custom:
                return "trust.custom"
            }
        case .cancelled:
            return "cancelled"
        case .timeout(let reason, _):
            switch reason {
            case .requestTimeout:
                return "timeout.request"
            case .resourceTimeout:
                return "timeout.resource"
            case .connectionTimeout:
                return "timeout.connection"
            }
        }
    }
}

public enum NetworkEvent: Sendable {
    case requestStart(
        requestID: UUID,
        method: String,
        url: String,
        retryIndex: Int
    )
    case requestAdapted(
        requestID: UUID,
        method: String,
        url: String,
        retryIndex: Int
    )
    case responseReceived(
        requestID: UUID,
        statusCode: Int,
        byteCount: Int
    )
    case retryScheduled(
        requestID: UUID,
        retryIndex: Int,
        delay: TimeInterval,
        reason: String
    )
    case requestFinished(
        requestID: UUID,
        statusCode: Int,
        byteCount: Int
    )
    case requestFailed(
        requestID: UUID,
        errorCode: Int,
        message: String
    )
    /// Emitted while a stale-while-revalidate cache hit fans out a
    /// background refresh. Carries the *original* requestID so observers
    /// can correlate the revalidation with the request that returned the
    /// stale body, instead of the disposable internal UUID used to track
    /// the in-flight refresh task.
    case cacheRevalidation(
        originalID: UUID,
        state: CacheRevalidationState
    )
}

/// Lifecycle stages of a background cache revalidation. Observers receive
/// `.scheduled` when the refresh task starts and one of the terminal cases
/// when it ends. Used by ``NetworkEvent/cacheRevalidation(originalID:state:)``.
public enum CacheRevalidationState: Sendable, Equatable {
    case scheduled
    case completed(statusCode: Int)
    case notModified
    case failed(errorCode: Int, message: String)
}

/// Receives request lifecycle events emitted by the networking client.
public protocol NetworkEventObserving: Sendable {
    func handle(_ event: NetworkEvent) async
}

/// An observer that mirrors request lifecycle events to `OSLog`.
public struct OSLogNetworkEventObserver: NetworkEventObserving {
    public init() {}

    public func handle(_ event: NetworkEvent) async {
        #if DEBUG
        switch event {
        case .requestStart(let requestID, let method, let url, let retryIndex):
            Logger.API.debug(
                "request_start id=\(requestID.uuidString, privacy: .public) method=\(method, privacy: .public) url=\(url, privacy: .private) retryIndex=\(retryIndex)"
            )
        case .requestAdapted(let requestID, let method, let url, let retryIndex):
            Logger.API.debug(
                "request_adapted id=\(requestID.uuidString, privacy: .public) method=\(method, privacy: .public) url=\(url, privacy: .private) retryIndex=\(retryIndex)"
            )
        case .responseReceived(let requestID, let statusCode, let byteCount):
            Logger.API.debug(
                "response_received id=\(requestID.uuidString, privacy: .public) status=\(statusCode) bytes=\(byteCount)"
            )
        case .retryScheduled(let requestID, let retryIndex, let delay, let reason):
            Logger.API.info(
                "retry_scheduled id=\(requestID.uuidString, privacy: .public) retryIndex=\(retryIndex) delay=\(delay, privacy: .public)s reason=\(reason, privacy: .private)"
            )
        case .requestFinished(let requestID, let statusCode, let byteCount):
            Logger.API.info(
                "request_finished id=\(requestID.uuidString, privacy: .public) status=\(statusCode) bytes=\(byteCount)")
        case .requestFailed(let requestID, let errorCode, let message):
            Logger.API.error(
                "request_failed id=\(requestID.uuidString, privacy: .public) code=\(errorCode) message=\(message, privacy: .private)"
            )
        case .cacheRevalidation(let originalID, let state):
            Logger.API.debug(
                "cache_revalidation original_id=\(originalID.uuidString, privacy: .public) state=\(String(describing: state), privacy: .private)"
            )
        }
        #endif
    }
}

public struct NetworkRequestContext: Sendable {
    public let requestID: UUID
    public let retryIndex: Int
    public let metricsReporter: (any NetworkMetricsReporting)?
    public let trustPolicy: TrustPolicy
    public let eventObservers: [any NetworkEventObserving]
    public let redirectPolicy: any RedirectPolicy
    /// Redirect targets must use the same transport-scheme admission policy
    /// as the request that created this context.
    package let allowsInsecureHTTP: Bool
    /// Signed requests cannot follow a URLSession-generated redirect because
    /// the follow-up URL/method would not pass through the async signer stage.
    package let allowsAutomaticRedirects: Bool
    /// Signed requests must not enter URLSession's shared response cache until
    /// the signer contract can contribute a stable principal partition.
    package let allowsURLCacheStorage: Bool

    public init(
        requestID: UUID = UUID(),
        retryIndex: Int = 0,
        metricsReporter: (any NetworkMetricsReporting)? = nil,
        trustPolicy: TrustPolicy = .systemDefault,
        eventObservers: [any NetworkEventObserving] = [],
        redirectPolicy: any RedirectPolicy = DefaultRedirectPolicy(),
        allowsInsecureHTTP: Bool = false
    ) {
        self.requestID = requestID
        self.retryIndex = retryIndex
        self.metricsReporter = metricsReporter
        self.trustPolicy = trustPolicy
        self.eventObservers = eventObservers
        self.redirectPolicy = redirectPolicy
        self.allowsInsecureHTTP = allowsInsecureHTTP
        self.allowsAutomaticRedirects = true
        self.allowsURLCacheStorage = true
    }

    package init(
        requestID: UUID,
        retryIndex: Int,
        metricsReporter: (any NetworkMetricsReporting)?,
        trustPolicy: TrustPolicy,
        eventObservers: [any NetworkEventObserving],
        redirectPolicy: any RedirectPolicy,
        allowsInsecureHTTP: Bool,
        allowsAutomaticRedirects: Bool,
        allowsURLCacheStorage: Bool
    ) {
        self.requestID = requestID
        self.retryIndex = retryIndex
        self.metricsReporter = metricsReporter
        self.trustPolicy = trustPolicy
        self.eventObservers = eventObservers
        self.redirectPolicy = redirectPolicy
        self.allowsInsecureHTTP = allowsInsecureHTTP
        self.allowsAutomaticRedirects = allowsAutomaticRedirects
        self.allowsURLCacheStorage = allowsURLCacheStorage
    }

    package func restrictingSignedRequestSharing() -> NetworkRequestContext {
        NetworkRequestContext(
            requestID: requestID,
            retryIndex: retryIndex,
            metricsReporter: metricsReporter,
            trustPolicy: trustPolicy,
            eventObservers: eventObservers,
            redirectPolicy: redirectPolicy,
            allowsInsecureHTTP: allowsInsecureHTTP,
            allowsAutomaticRedirects: false,
            allowsURLCacheStorage: false
        )
    }
}
