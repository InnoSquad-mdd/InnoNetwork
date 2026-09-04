import Foundation

/// Caps the number of in-flight transport attempts with a cancellation-aware
/// FIFO admission queue.
///
/// `ConcurrencyLimitExecutionPolicy` wraps the rest of the
/// ``RequestExecutionPolicy`` chain in an acquire / awaited-release pair, so a
/// request only proceeds to the underlying transport once capacity is
/// available. Register the policy through the `customExecutionPolicies`
/// argument of ``ResiliencePack/init(retry:coalescing:circuitBreaker:idempotency:bodyBuffering:customExecutionPolicies:)``
/// and the surrounding execution machinery handles the token lifecycle
/// — including transport errors and cancellation, where the policy awaits
/// release before returning or rethrowing.
///
/// ```swift
/// let limit = ConcurrencyLimitExecutionPolicy(maxConcurrent: 4)
///
/// let configuration = NetworkConfiguration.advanced(
///     baseURL: baseURL,
///     resilience: ResiliencePack(customExecutionPolicies: [limit])
/// )
/// ```
///
/// Because `RequestExecutionPolicy` runs around each transport
/// attempt (including retries), a request that retries `N` times
/// acquires and releases the bucket `N` times — which matches the
/// "in-flight tokens cap concurrent transport pressure" semantics
/// users expect from a per-host or per-endpoint rate limit. Reuse the same
/// policy value in multiple configurations to share one cap across clients;
/// construct separate values for independent caps.
public struct ConcurrencyLimitExecutionPolicy: RequestExecutionPolicy {
    /// Maximum number of transport attempts admitted concurrently.
    public let maxConcurrent: Int
    package let bucket: ConcurrencyTokenBucket

    /// Creates a policy with a positive concurrency cap. Values below one are
    /// clamped to one so request execution always makes forward progress.
    public init(maxConcurrent: Int) {
        let normalizedLimit = max(1, maxConcurrent)
        self.maxConcurrent = normalizedLimit
        self.bucket = ConcurrencyTokenBucket(maxConcurrent: normalizedLimit)
    }

    public func execute(
        input: RequestExecutionInput,
        context: RequestExecutionContext,
        next: RequestExecutionNext
    ) async throws -> Response {
        NetworkOperationDeadlineContext.mark(.policyAdmission)
        try await bucket.acquire()
        do {
            let response = try await next.execute()
            await bucket.release()
            return response
        } catch {
            await bucket.release()
            throw error
        }
    }
}
