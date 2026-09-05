import Foundation

/// Package-internal clock abstraction used by coordinators that schedule
/// time-based work (heartbeat cadence, reconnect backoff). Production code
/// uses `SystemClock`; tests can substitute a virtual-time implementation so
/// timing behavior is deterministic without relying on wall-clock sleeps.
package protocol InnoNetworkClock: Sendable {
    /// Suspends for the requested duration. Conforming types should honor
    /// task cancellation so coordinators can exit promptly when their enclosing
    /// task is cancelled.
    func sleep(for duration: Duration) async throws

    /// Returns the clock's notion of "now" as a `Date`. Production clocks
    /// return the system wall clock; tests can return a virtual time so
    /// timestamp-dependent assertions stay deterministic.
    func now() -> Date

    /// Returns a process-local monotonic instant expressed as elapsed time
    /// from an arbitrary origin. Interval policies must compare this value,
    /// not wall-clock `Date`, so clock corrections cannot refill quotas or
    /// expire queues early.
    func monotonicNow() -> Duration
}

package extension InnoNetworkClock {
    func monotonicNow() -> Duration {
        .seconds(now().timeIntervalSinceReferenceDate)
    }
}


/// Production-backed clock that defers to structured-concurrency
/// `Task.sleep(for:)`.
package struct SystemClock: InnoNetworkClock {
    private static let monotonicOrigin = ContinuousClock.now
    package init() {}

    package func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }

    package func now() -> Date {
        Date()
    }

    package func monotonicNow() -> Duration {
        Self.monotonicOrigin.duration(to: ContinuousClock.now)
    }
}
