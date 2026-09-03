import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Response metadata and bounded body chunks for one HTTP transfer.
///
/// The transport cancels itself and finishes `chunks` with a
/// ``NetworkErrorCode/responseBodyLimitExceeded`` error as soon as the body
/// crosses the configured limit. Call ``cancel()`` when abandoning the stream
/// before it reaches a terminal state.
public struct BoundedNetworkTransfer: Sendable {
    public let response: URLResponse
    public let finalRequest: URLRequest?
    public let chunks: AsyncThrowingStream<Data, Error>

    private let cancellation: @Sendable () -> Void

    package init(
        response: URLResponse,
        finalRequest: URLRequest?,
        chunks: AsyncThrowingStream<Data, Error>,
        cancellation: @escaping @Sendable () -> Void
    ) {
        self.response = response
        self.finalRequest = finalRequest
        self.chunks = chunks
        self.cancellation = cancellation
    }

    public func cancel() {
        cancellation()
    }
}

public extension URLSession {
    /// Starts an HTTP transfer whose response body is bounded while bytes are
    /// received.
    ///
    /// This is the transport boundary for first-party companion packages that
    /// need streaming bytes without importing InnoNetwork implementation
    /// details. URL admission, redirect policy, trust policy, metrics, and
    /// observer delivery are inherited from `context`.
    func boundedTransfer(
        for request: URLRequest,
        context: NetworkRequestContext = NetworkRequestContext(),
        maximumResponseBytes: Int64,
        requestID: UUID = UUID(),
        retryIndex: Int = 0
    ) async throws -> BoundedNetworkTransfer {
        guard maximumResponseBytes > 0 else {
            throw NetworkError.configuration(
                reason: .invalidRequest(
                    "A bounded transfer requires a positive response-body limit."
                )
            )
        }
        let admittedRequest = try NetworkURLAdmission.validate(
            request,
            policy: .http(allowsInsecure: context.allowsInsecureHTTP)
        )
        let attemptContext = NetworkRequestContext(
            requestID: requestID,
            retryIndex: retryIndex,
            metricsReporter: context.metricsReporter,
            trustPolicy: context.trustPolicy,
            eventObservers: context.eventObservers,
            redirectPolicy: context.redirectPolicy,
            allowsInsecureHTTP: context.allowsInsecureHTTP,
            allowsAutomaticRedirects: context.allowsAutomaticRedirects,
            allowsURLCacheStorage: context.allowsURLCacheStorage
        )
        let transfer = try await chunkedTransfer(
            for: admittedRequest,
            context: attemptContext,
            maxBytes: maximumResponseBytes
        )
        return BoundedNetworkTransfer(
            response: transfer.response,
            finalRequest: transfer.finalRequest,
            chunks: transfer.chunks,
            cancellation: transfer.cancel
        )
    }
}
