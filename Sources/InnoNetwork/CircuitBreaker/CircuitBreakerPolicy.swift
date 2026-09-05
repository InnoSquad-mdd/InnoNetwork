import Foundation

/// Per-host circuit breaker policy for short-circuiting repeated failures.
///
/// The breaker tracks the most recent `windowSize` countable attempts per
/// host and trips into the open state once the number of failures within the
/// window meets `failureThreshold`. While open, requests fail immediately
/// with ``CircuitBreakerOpenError``. After `resetAfter` elapses the breaker
/// transitions to half-open and admits a single probe; `numberOfProbesRequiredToClose`
/// consecutive successful probes are needed before the circuit fully closes
/// (default `1`, i.e. no hysteresis). HTTP `4xx` responses are excluded from
/// the closed-state rolling window, but count as transport-health successes
/// while half-open and therefore follow the same probe hysteresis as `2xx` and
/// `3xx` responses.
public struct CircuitBreakerPolicy: Sendable, Equatable {
    public let failureThreshold: Int
    public let windowSize: Int
    public let resetAfter: Duration
    public let maxResetAfter: Duration
    public let numberOfProbesRequiredToClose: Int
    public let countsTransportSecurityFailures: Bool

    /// Errors thrown by the validating initializer.
    public enum ConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {
        case nonPositive(field: String, value: Int)
        case thresholdExceedsWindow(threshold: Int, window: Int)
        case negativeDuration(field: String)
        case maxResetSmallerThanReset

        public var description: String {
            switch self {
            case .nonPositive(let field, let value):
                return "CircuitBreakerPolicy.\(field) must be > 0 (got \(value))."
            case .thresholdExceedsWindow(let threshold, let window):
                return "CircuitBreakerPolicy.failureThreshold (\(threshold)) cannot exceed windowSize (\(window))."
            case .negativeDuration(let field):
                return "CircuitBreakerPolicy.\(field) cannot be negative."
            case .maxResetSmallerThanReset:
                return "CircuitBreakerPolicy.maxResetAfter cannot be smaller than resetAfter."
            }
        }
    }

    /// Validating initializer. Throws ``ConfigurationError`` if any argument
    /// is out of range. Prefer this over the silent-clamp
    /// `init(failureThreshold:windowSize:resetAfter:maxResetAfter:)`.
    public init(
        validatedFailureThreshold failureThreshold: Int,
        windowSize: Int,
        resetAfter: Duration,
        maxResetAfter: Duration,
        numberOfProbesRequiredToClose: Int = 1,
        countsTransportSecurityFailures: Bool = false
    ) throws {
        guard windowSize > 0 else {
            throw ConfigurationError.nonPositive(field: "windowSize", value: windowSize)
        }
        guard failureThreshold > 0 else {
            throw ConfigurationError.nonPositive(field: "failureThreshold", value: failureThreshold)
        }
        guard failureThreshold <= windowSize else {
            throw ConfigurationError.thresholdExceedsWindow(threshold: failureThreshold, window: windowSize)
        }
        guard numberOfProbesRequiredToClose > 0 else {
            throw ConfigurationError.nonPositive(
                field: "numberOfProbesRequiredToClose",
                value: numberOfProbesRequiredToClose
            )
        }
        guard resetAfter >= .zero else {
            throw ConfigurationError.negativeDuration(field: "resetAfter")
        }
        guard maxResetAfter >= .zero else {
            throw ConfigurationError.negativeDuration(field: "maxResetAfter")
        }
        guard maxResetAfter >= resetAfter else {
            throw ConfigurationError.maxResetSmallerThanReset
        }

        self.failureThreshold = failureThreshold
        self.windowSize = windowSize
        self.resetAfter = resetAfter
        self.maxResetAfter = maxResetAfter
        self.numberOfProbesRequiredToClose = numberOfProbesRequiredToClose
        self.countsTransportSecurityFailures = countsTransportSecurityFailures
    }

    /// Backwards-compatible silent-clamp initializer. Out-of-range values are
    /// coerced to safe defaults so callers cannot construct an unusable
    /// policy. New code should prefer ``init(validatedFailureThreshold:windowSize:resetAfter:maxResetAfter:numberOfProbesRequiredToClose:countsTransportSecurityFailures:)``
    /// which surfaces invalid inputs as `ConfigurationError`.
    public init(
        failureThreshold: Int = 5,
        windowSize: Int = 10,
        resetAfter: Duration = .seconds(30),
        maxResetAfter: Duration = .seconds(300),
        numberOfProbesRequiredToClose: Int = 1,
        countsTransportSecurityFailures: Bool = false
    ) {
        let normalizedWindowSize = max(1, windowSize)
        let normalizedResetAfter = max(.zero, resetAfter)

        self.windowSize = normalizedWindowSize
        self.failureThreshold = min(max(1, failureThreshold), normalizedWindowSize)
        self.resetAfter = normalizedResetAfter
        self.maxResetAfter = max(normalizedResetAfter, maxResetAfter)
        self.numberOfProbesRequiredToClose = max(1, numberOfProbesRequiredToClose)
        self.countsTransportSecurityFailures = countsTransportSecurityFailures
    }
}


/// Error wrapped by ``NetworkError/underlying(_:_:)`` when a circuit is open.
public struct CircuitBreakerOpenError: Error, Sendable, Equatable, LocalizedError, CustomNSError {
    public static let errorDomain = "com.innosquad.innonetwork.circuit-breaker"

    public let host: String
    public let retryAfter: TimeInterval

    package init(host: String, retryAfter: TimeInterval) {
        self.host = host
        self.retryAfter = max(0, retryAfter)
    }

    public var errorDescription: String? {
        "Circuit breaker is open for \(host). Retry after \(retryAfter) seconds."
    }

    public var errorCode: Int { 1 }
}


package struct CircuitBreakerProbe: Sendable, Equatable {
    fileprivate let key: String
    fileprivate let id: UUID
}

package actor CircuitBreakerRegistry {
    /// Idle state TTL: hosts that have not been touched for this duration are
    /// garbage-collected on the next access. Long-running clients with bursty
    /// traffic across many hosts otherwise leak per-host state forever.
    private static let stateIdleTTL: TimeInterval = 5 * 60

    private struct ClosedState: Equatable {
        /// Rolling window of attempts. `true` = countable failure, `false` = success.
        var window: [Bool]
    }

    private enum Mode: Equatable {
        case closed(ClosedState)
        case open(openedAt: Date, until: Date, resetAfter: Duration)
        case halfOpen(probeID: UUID?, successCount: Int, resetAfter: Duration)
    }

    private struct Entry {
        var mode: Mode
        var lastAccessAt: Date
    }

    private var states: [String: Entry] = [:]
    private let clock: any InnoNetworkClock

    package init(clock: any InnoNetworkClock = SystemClock()) {
        self.clock = clock
    }

    @discardableResult
    package func prepare(
        request: URLRequest,
        policy: CircuitBreakerPolicy?
    ) throws -> CircuitBreakerProbe? {
        guard policy != nil, let key = Self.hostKey(for: request) else { return nil }
        let now = clock.now()
        garbageCollect(now: now)
        let entry = states[key] ?? Entry(mode: .closed(ClosedState(window: [])), lastAccessAt: now)
        switch entry.mode {
        case .closed:
            return nil
        case .open(let openedAt, let until, let resetAfter):
            // Defend against system-clock regression (NTP corrections, manual
            // timezone changes, leap-second walks). `until` was computed at
            // open time as `openedAt + resetAfter`; if the clock has since
            // moved backward past `openedAt`, `now >= until` would never
            // fire and the breaker would stay open for the full skew window.
            // Trip the half-open transition either when the elapsed time
            // since open has covered `resetAfter`, or when `now` is now
            // earlier than `openedAt` — both indicate the open window has
            // outlived its monotone deadline.
            let elapsed = now.timeIntervalSince(openedAt)
            if elapsed < 0 || elapsed >= resetAfter.timeInterval || now >= until {
                let probe = CircuitBreakerProbe(key: key, id: UUID())
                states[key] = Entry(
                    mode: .halfOpen(probeID: probe.id, successCount: 0, resetAfter: resetAfter),
                    lastAccessAt: now
                )
                return probe
            }
            throw NetworkError.underlying(
                SendableUnderlyingError(CircuitBreakerOpenError(host: key, retryAfter: until.timeIntervalSince(now))),
                nil
            )
        case .halfOpen(let probeID, let successCount, let resetAfter):
            guard probeID == nil else {
                throw NetworkError.underlying(
                    SendableUnderlyingError(CircuitBreakerOpenError(host: key, retryAfter: resetAfter.timeInterval)),
                    nil
                )
            }
            let probe = CircuitBreakerProbe(key: key, id: UUID())
            states[key] = Entry(
                mode: .halfOpen(probeID: probe.id, successCount: successCount, resetAfter: resetAfter),
                lastAccessAt: now
            )
            return probe
        }
    }

    package func recordSuccess(
        request: URLRequest,
        policy: CircuitBreakerPolicy?,
        probe: CircuitBreakerProbe? = nil
    ) {
        guard let policy, let key = Self.hostKey(for: request) else { return }
        recordOutcome(key: key, isFailure: false, policy: policy, probe: probe)
    }

    package func recordFailure(
        request: URLRequest,
        policy: CircuitBreakerPolicy?,
        error: Error,
        probe: CircuitBreakerProbe? = nil
    ) {
        guard let policy, let key = Self.hostKey(for: request) else { return }
        guard isCountable(error: error, policy: policy) else {
            abandon(probe)
            return
        }
        recordOutcome(key: key, isFailure: true, policy: policy, probe: probe)
    }

    package func recordStatus(
        request: URLRequest,
        policy: CircuitBreakerPolicy?,
        statusCode: Int,
        probe: CircuitBreakerProbe? = nil
    ) {
        guard let policy, let key = Self.hostKey(for: request) else { return }
        if (500...599).contains(statusCode) {
            recordOutcome(key: key, isFailure: true, policy: policy, probe: probe)
        } else if (400...499).contains(statusCode) {
            // 4xx responses indicate a working transport with a client-side
            // semantic problem. They do not advance the rolling window in
            // either direction. In half-open they count as transport-health
            // successes and follow the same configured hysteresis as 2xx/3xx
            // probes before fully closing the circuit.
            if case .halfOpen = states[key]?.mode {
                recordOutcome(key: key, isFailure: false, policy: policy, probe: probe)
            }
        } else {
            // 2xx/3xx and other non-error status families confirm the host is
            // healthy.
            recordOutcome(key: key, isFailure: false, policy: policy, probe: probe)
        }
    }

    /// Releases only the half-open slot owned by `probe`. A stale completion
    /// cannot release a newer request's probe.
    package func abandon(_ probe: CircuitBreakerProbe?) {
        guard let probe, let entry = states[probe.key] else { return }
        switch entry.mode {
        case .halfOpen(let probeID, let successCount, let resetAfter):
            guard probeID == probe.id else { return }
            states[probe.key] = Entry(
                mode: .halfOpen(probeID: nil, successCount: successCount, resetAfter: resetAfter),
                lastAccessAt: clock.now()
            )
        case .closed, .open:
            // Cancellation in closed/open: preserve state. The cancellation
            // was not a transport outcome and should not influence the
            // rolling window.
            return
        }
    }

    private func recordOutcome(
        key: String,
        isFailure: Bool,
        policy: CircuitBreakerPolicy,
        probe: CircuitBreakerProbe?
    ) {
        let now = clock.now()
        let mode = states[key]?.mode ?? .closed(ClosedState(window: []))
        switch mode {
        case .closed(var state):
            guard probe == nil else { return }
            state.window.append(isFailure)
            if state.window.count > policy.windowSize {
                state.window.removeFirst(state.window.count - policy.windowSize)
            }
            let failureCount = state.window.lazy.filter { $0 }.count
            if isFailure, failureCount >= policy.failureThreshold {
                states[key] = Entry(
                    mode: .open(
                        openedAt: now,
                        until: now.addingTimeInterval(policy.resetAfter.timeInterval),
                        resetAfter: policy.resetAfter
                    ),
                    lastAccessAt: now
                )
            } else {
                states[key] = Entry(mode: .closed(state), lastAccessAt: now)
            }
        case .open:
            // Defensive invariant guard: normal execution cannot record an
            // outcome while still open because `prepare` either short-circuits
            // before transport or transitions to half-open for a probe. Keep
            // this branch as a no-op so stale async completions cannot mutate
            // the open window.
            return
        case .halfOpen(let probeID, let successCount, let resetAfter):
            guard probe?.key == key, probe?.id == probeID else { return }
            if isFailure {
                let doubled = min(resetAfter.timeInterval * 2, policy.maxResetAfter.timeInterval)
                let next = Duration.milliseconds(Int64((doubled * 1000).rounded()))
                states[key] = Entry(
                    mode: .open(
                        openedAt: now,
                        until: now.addingTimeInterval(next.timeInterval),
                        resetAfter: next
                    ),
                    lastAccessAt: now
                )
            } else {
                let updatedSuccess = successCount + 1
                if updatedSuccess >= policy.numberOfProbesRequiredToClose {
                    states[key] = Entry(
                        mode: .closed(ClosedState(window: [])),
                        lastAccessAt: now
                    )
                } else {
                    // Hysteresis: keep half-open and require additional probes
                    // before fully closing. Release the in-flight slot so the
                    // next probe can be admitted.
                    states[key] = Entry(
                        mode: .halfOpen(
                            probeID: nil,
                            successCount: updatedSuccess,
                            resetAfter: resetAfter
                        ),
                        lastAccessAt: now
                    )
                }
            }
        }
    }

    private func garbageCollect(now: Date) {
        states = states.filter { _, entry in
            switch entry.mode {
            case .closed:
                now.timeIntervalSince(entry.lastAccessAt) <= Self.stateIdleTTL
            case .open, .halfOpen:
                // These modes carry a safety decision that must be advanced by
                // `prepare` or a probe outcome. Dropping either one would turn
                // the next request into an unrestricted closed-state attempt.
                true
            }
        }
    }

    /// Visible for tests. Returns the canonical breaker key for a request.
    static func hostKey(for request: URLRequest) -> String? {
        NetworkOriginNormalizer.key(for: request.url, unknownSchemeDefaultPort: 0)
    }

    private func isCountable(error: Error, policy: CircuitBreakerPolicy) -> Bool {
        if NetworkError.isCancellation(error) { return false }
        if isTransportSecurityError(error) {
            return policy.countsTransportSecurityFailures
        }
        if let networkError = error as? NetworkError {
            switch networkError {
            case .timeout:
                return true
            case .trustEvaluationFailed:
                return policy.countsTransportSecurityFailures
            case .underlying(let underlying, _):
                if NetworkError.isCancellation(underlying) { return false }
                if isTransportSecurityUnderlying(underlying) {
                    return policy.countsTransportSecurityFailures
                }
                return true
            case .reachability:
                // Connectivity-class URLErrors (`notConnectedToInternet`,
                // `dnsLookupFailed`, `cannotFindHost`, `networkConnectionLost`)
                // were `.underlying` before round 1 and counted toward the
                // breaker via the `.underlying` arm. Preserve that contract
                // after the typed-throws refactor — a host that drops
                // reachability should still trip the circuit. `RetryPolicy`
                // got the same explicit arm in round 3; this is the symmetric
                // fix for the breaker side.
                return true
            default:
                return false
            }
        }
        return true
    }

    private func isTransportSecurityError(_ error: Error) -> Bool {
        if let urlError = error as? URLError, isTransportSecurityURLErrorCode(urlError.code) {
            return true
        }
        if let networkError = error as? NetworkError, case .trustEvaluationFailed = networkError {
            return true
        }
        return false
    }

    private func isTransportSecurityUnderlying(_ underlying: SendableUnderlyingError) -> Bool {
        guard underlying.domain == NSURLErrorDomain else { return false }
        return isTransportSecurityURLErrorCode(URLError.Code(rawValue: underlying.code))
    }

    private func isTransportSecurityURLErrorCode(_ code: URLError.Code) -> Bool {
        switch code {
        case .serverCertificateUntrusted,
            .serverCertificateHasBadDate,
            .serverCertificateNotYetValid,
            .serverCertificateHasUnknownRoot,
            .clientCertificateRejected,
            .clientCertificateRequired,
            .secureConnectionFailed:
            return true
        default:
            return false
        }
    }
}
