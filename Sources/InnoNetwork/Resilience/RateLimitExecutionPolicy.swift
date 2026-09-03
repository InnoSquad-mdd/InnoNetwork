import Foundation

/// Experimental fixed-window request-rate limiter for transport attempts.
///
/// The policy limits admission into the remainder of the execution-policy
/// chain. Each retry is an independent transport attempt and therefore consumes
/// capacity. Copies share one limiter, so reuse a policy across clients when
/// they should share a budget.
///
/// This is a client-side pacing control, not a substitute for honoring server
/// `Retry-After` responses through ``RetryPolicy``.
public struct RateLimitExecutionPolicy: RequestExecutionPolicy {
    public let maximumRequests: Int
    public let interval: Duration
    package let limiter: FixedWindowRequestLimiter

    /// Creates a fixed-window limiter. The request count is clamped to one and
    /// non-positive intervals are clamped to one millisecond.
    public init(maximumRequests: Int, per interval: Duration) {
        let normalizedMaximum = max(1, maximumRequests)
        let normalizedInterval = interval > .zero ? interval : .milliseconds(1)
        self.maximumRequests = normalizedMaximum
        self.interval = normalizedInterval
        self.limiter = FixedWindowRequestLimiter(
            maximumRequests: normalizedMaximum,
            interval: normalizedInterval
        )
    }

    public func execute(
        input: RequestExecutionInput,
        context: RequestExecutionContext,
        next: RequestExecutionNext
    ) async throws -> Response {
        try await limiter.acquire()
        return try await next.execute()
    }
}

package actor FixedWindowRequestLimiter {
    package let maximumRequests: Int
    package let interval: Duration

    private let clock: any InnoNetworkClock
    private var windowStart: Date?
    private var admissions = 0

    package init(
        maximumRequests: Int,
        interval: Duration,
        clock: any InnoNetworkClock = SystemClock()
    ) {
        self.maximumRequests = maximumRequests
        self.interval = interval
        self.clock = clock
    }

    package func acquire() async throws {
        while true {
            try Task.checkCancellation()
            let now = clock.now()
            if let windowStart {
                let elapsed = now.timeIntervalSince(windowStart)
                if elapsed >= interval.rateLimitTimeInterval {
                    self.windowStart = now
                    admissions = 0
                }
            } else {
                windowStart = now
            }

            if admissions < maximumRequests {
                admissions += 1
                return
            }

            guard let windowStart else { continue }
            let elapsed = max(0, now.timeIntervalSince(windowStart))
            let remaining = max(0, interval.rateLimitTimeInterval - elapsed)
            try await clock.sleep(for: .seconds(remaining))
        }
    }
}

private extension Duration {
    var rateLimitTimeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
