import Foundation

/// A vendor-neutral value suitable for semantic telemetry attributes.
public enum SemanticAttributeValue: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case double(Double)
}

/// A normalized network lifecycle event for tracing and metrics adapters.
///
/// Attribute names follow the OpenTelemetry HTTP semantic-convention
/// vocabulary where the source ``NetworkEvent`` carries the required value.
/// URLs remain redacted by InnoNetwork before they reach this type.
public struct SemanticNetworkEvent: Sendable, Equatable {
    public let name: String
    public let requestID: UUID
    public let attributes: [String: SemanticAttributeValue]

    public init(
        name: String,
        requestID: UUID,
        attributes: [String: SemanticAttributeValue]
    ) {
        self.name = name
        self.requestID = requestID
        self.attributes = attributes
    }
}

/// Converts ``NetworkEvent`` values into a small semantic telemetry envelope.
///
/// The adapter has no dependency on an exporter SDK. Pass an async closure
/// that forwards each envelope to OpenTelemetry, Datadog, Sentry, or an
/// application-owned metrics pipeline.
public struct SemanticNetworkEventAdapter: NetworkEventObserving {
    private let export: @Sendable (SemanticNetworkEvent) async -> Void

    public init(
        export: @escaping @Sendable (SemanticNetworkEvent) async -> Void
    ) {
        self.export = export
    }

    public func handle(_ event: NetworkEvent) async {
        await export(Self.map(event))
    }

    public static func map(_ event: NetworkEvent) -> SemanticNetworkEvent {
        switch event {
        case .requestStart(let requestID, let method, let url, let retryIndex):
            return SemanticNetworkEvent(
                name: "http.client.request.start",
                requestID: requestID,
                attributes: requestAttributes(method: method, url: url, retryIndex: retryIndex)
            )
        case .requestAdapted(let requestID, let method, let url, let retryIndex):
            return SemanticNetworkEvent(
                name: "http.client.request.adapted",
                requestID: requestID,
                attributes: requestAttributes(method: method, url: url, retryIndex: retryIndex)
            )
        case .responseReceived(let requestID, let statusCode, let byteCount):
            return SemanticNetworkEvent(
                name: "http.client.response.received",
                requestID: requestID,
                attributes: responseAttributes(statusCode: statusCode, byteCount: byteCount)
            )
        case .retryScheduled(let requestID, let retryIndex, let delay, let reason):
            return SemanticNetworkEvent(
                name: "http.client.request.retry_scheduled",
                requestID: requestID,
                attributes: [
                    "http.request.resend_count": .integer(retryIndex),
                    "innonetwork.retry.delay": .double(delay),
                    "innonetwork.retry.reason": .string(reason),
                ]
            )
        case .requestFinished(let requestID, let statusCode, let byteCount):
            return SemanticNetworkEvent(
                name: "http.client.request.finished",
                requestID: requestID,
                attributes: responseAttributes(statusCode: statusCode, byteCount: byteCount)
            )
        case .requestFailed(let requestID, let errorCode, let message):
            return SemanticNetworkEvent(
                name: "http.client.request.failed",
                requestID: requestID,
                attributes: [
                    "error.type": .string(message),
                    "innonetwork.error.code": .integer(errorCode),
                ]
            )
        case .cacheRevalidation(let originalID, let state):
            return SemanticNetworkEvent(
                name: "http.client.cache.revalidation",
                requestID: originalID,
                attributes: cacheAttributes(state)
            )
        }
    }

    private static func requestAttributes(
        method: String,
        url: String,
        retryIndex: Int
    ) -> [String: SemanticAttributeValue] {
        var attributes: [String: SemanticAttributeValue] = [
            "http.request.method": .string(method),
            "url.full": .string(url),
        ]
        if retryIndex > 0 {
            attributes["http.request.resend_count"] = .integer(retryIndex)
        }
        if let host = URL(string: url)?.host {
            attributes["server.address"] = .string(host)
        }
        return attributes
    }

    private static func responseAttributes(
        statusCode: Int,
        byteCount: Int
    ) -> [String: SemanticAttributeValue] {
        [
            "http.response.status_code": .integer(statusCode),
            "http.response.body.size": .integer(byteCount),
        ]
    }

    private static func cacheAttributes(
        _ state: CacheRevalidationState
    ) -> [String: SemanticAttributeValue] {
        switch state {
        case .scheduled:
            return ["innonetwork.cache.revalidation.state": .string("scheduled")]
        case .completed(let statusCode):
            return [
                "innonetwork.cache.revalidation.state": .string("completed"),
                "http.response.status_code": .integer(statusCode),
            ]
        case .notModified:
            return [
                "innonetwork.cache.revalidation.state": .string("not_modified"),
                "http.response.status_code": .integer(304),
            ]
        case .failed(let errorCode, let message):
            return [
                "innonetwork.cache.revalidation.state": .string("failed"),
                "error.type": .string(message),
                "innonetwork.error.code": .integer(errorCode),
            ]
        }
    }
}
