import Foundation

/// Rejects transport attempts when the device is known to be
/// offline, instead of letting the request burn the URLSession
/// timeout budget on an unsatisfied path.
///
/// `ReachabilityCheckExecutionPolicy` consults a
/// ``NetworkMonitoring`` source before forwarding to the rest of
/// the ``RequestExecutionPolicy`` chain. If the snapshot reports
/// `.unsatisfied`, the policy throws an early
/// ``NetworkError`` so the caller sees an immediate failure
/// instead of a 30-second timeout. If the snapshot reports
/// `.requiresConnection`, the policy waits briefly for a fresh
/// signal before either forwarding, surfacing offline, or throwing
/// ``NetworkError/underlying(_:_:)`` (with `code = 4002`). The ``Mode`` switch lets the
/// policy log-only without rejecting — useful for staged
/// rollouts where the team wants telemetry before tightening the
/// gate.
///
/// ```swift
/// let monitor = NetworkMonitor.shared
/// let reachability = ReachabilityCheckExecutionPolicy(monitor: monitor)
///
/// let configuration = NetworkConfiguration.advanced(
///     baseURL: baseURL,
///     resilience: ResiliencePack(customExecutionPolicies: [reachability])
/// )
/// ```
///
/// `nil` snapshots (no path observed yet) fall through because they
/// are not definitively offline. `.requiresConnection` is treated as
/// temporarily suspended only when it persists through
/// ``suspensionWaitTimeout``.
///
/// The policy reports
/// `NetworkError.configuration(reason: .offline(_:))` for rejected
/// requests. Switch on the `NetworkConfigurationFailureReason.offline`
/// payload to distinguish this from malformed base URLs or invalid request
/// shapes.
public struct ReachabilityCheckExecutionPolicy: RequestExecutionPolicy {
    /// Behaviour switch for offline observations.
    public enum Mode: Sendable, Equatable {
        /// Rejects requests with
        /// `NetworkError.configuration(reason: .offline(...))` when the
        /// snapshot reports `.unsatisfied`. Default.
        case requireOnline
        /// Lets the request continue regardless. Useful for early
        /// rollouts that want telemetry without altering behaviour.
        case warnOnly
    }

    public let monitor: any NetworkMonitoring
    public let mode: Mode
    /// Maximum time, in seconds, to wait while reachability remains
    /// `.requiresConnection` before surfacing
    /// ``NetworkError/underlying(_:_:)`` (with `code = 4002`).
    ///
    /// Negative values passed to the initializer are clamped to `0`.
    public let suspensionWaitTimeout: TimeInterval

    /// Creates a reachability gate for request execution.
    ///
    /// - Parameters:
    ///   - monitor: Reachability source used to read the current network path
    ///     and wait for path changes.
    ///   - mode: Whether `.unsatisfied` and persistent `.requiresConnection`
    ///     snapshots reject requests or are observed without blocking.
    ///     Defaults to `.requireOnline`.
    ///   - suspensionWaitTimeout: TimeInterval, in seconds, to wait for
    ///     `.requiresConnection` to recover before throwing
    ///     ``NetworkError/underlying(_:_:)`` (with `code = 4002`). Defaults to `1.0` and is
    ///     clamped with `max(0, suspensionWaitTimeout)`.
    public init(
        monitor: any NetworkMonitoring,
        mode: Mode = .requireOnline,
        suspensionWaitTimeout: TimeInterval = 1.0
    ) {
        self.monitor = monitor
        self.mode = mode
        self.suspensionWaitTimeout = max(0, suspensionWaitTimeout)
    }

    public func execute(
        input: RequestExecutionInput,
        context: RequestExecutionContext,
        next: RequestExecutionNext
    ) async throws -> Response {
        guard mode == .requireOnline else {
            return try await next.execute()
        }

        let snapshot = await monitor.currentSnapshot()
        switch snapshot?.status {
        case .unsatisfied:
            throw NetworkError.configuration(
                reason: .offline("device path is .unsatisfied")
            )
        case .requiresConnection:
            NetworkOperationDeadlineContext.mark(.connectivityWait)
            let updated = await monitor.waitForChange(
                from: snapshot,
                timeout: suspensionWaitTimeout
            )
            switch updated?.status {
            case .satisfied:
                break
            case .unsatisfied:
                throw NetworkError.configuration(
                    reason: .offline("device path became .unsatisfied")
                )
            case .requiresConnection, nil:
                // Surface this as the typed `.reachability` case rather than
                // `.underlying` so it shares one discriminator with the
                // URLSession-driven reachability classification — otherwise
                // two distinct enum shapes would collide on
                // `errorCode == 4002`.
                throw NetworkError.reachability(
                    .notConnectedToInternet,
                    SendableUnderlyingError(
                        domain: NetworkError.errorDomain,
                        code: NetworkErrorCode.reachability.rawValue,
                        message:
                            "The network connection is still being restored. Please wait a moment and try the request again."
                    ),
                    nil
                )
            }
        case .satisfied, nil:
            break
        }
        return try await next.execute()
    }
}
