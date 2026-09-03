import Foundation

/// Executes a transport attempt under InnoNetwork's retry policy.
///
/// Companion packages use this value to share retry classification,
/// idempotency safeguards, connectivity waits, and request-event delivery
/// without depending on the core coordinator implementation.
public struct NetworkRetryExecutor: Sendable {
    private let coordinator: RetryCoordinator

    /// Creates an executor backed by the system clock.
    public init() {
        self.coordinator = RetryCoordinator(eventHub: NetworkEventHub())
    }

    /// Creates an executor with caller-controlled time.
    ///
    /// This initializer is intended for deterministic integrations and tests.
    public init(
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        now: @escaping @Sendable () -> Date
    ) {
        let clock = ClosureNetworkClock(sleep: sleep, now: now)
        self.coordinator = RetryCoordinator(
            eventHub: NetworkEventHub(clock: clock),
            clock: clock
        )
    }

    /// Runs `operation` until it succeeds or `retryPolicy` reaches a terminal
    /// decision.
    ///
    /// The request is attached to mapped attempt failures so method and
    /// idempotency policy remain enforceable. `retryIndex` starts at zero and
    /// increments for each admitted retry; `requestID` is stable for the full
    /// logical operation.
    public func execute<Value>(
        retryPolicy: (any RetryPolicy)?,
        networkMonitor: (any NetworkMonitoring)? = NetworkMonitor.shared,
        request: URLRequest? = nil,
        requestID: UUID = UUID(),
        eventObservers: [any NetworkEventObserving] = [],
        operation:
            @escaping @Sendable (_ retryIndex: Int, _ requestID: UUID) async throws -> Value
    ) async throws -> Value {
        try await coordinator.execute(
            retryPolicy: retryPolicy,
            networkMonitor: networkMonitor,
            requestID: requestID,
            eventObservers: eventObservers
        ) { retryIndex, requestID in
            do {
                return try await operation(retryIndex, requestID)
            } catch let error as NetworkError {
                throw RequestExecutionFailure(error: error, request: request)
            } catch {
                throw RequestExecutionFailure(
                    error: NetworkError.mapTransportError(error),
                    request: request
                )
            }
        }
    }
}

private struct ClosureNetworkClock: InnoNetworkClock {
    let sleepClosure: @Sendable (Duration) async throws -> Void
    let nowClosure: @Sendable () -> Date

    init(
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        now: @escaping @Sendable () -> Date
    ) {
        self.sleepClosure = sleep
        self.nowClosure = now
    }

    func sleep(for duration: Duration) async throws {
        try await sleepClosure(duration)
    }

    func now() -> Date {
        nowClosure()
    }
}
