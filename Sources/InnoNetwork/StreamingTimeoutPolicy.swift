import Foundation
import os

/// Independent timeout budgets for a long-lived streaming request.
public struct StreamingTimeoutPolicy: Sendable, Equatable {
    public let firstResponse: Duration?
    public let firstEvent: Duration?
    public let idle: Duration?
    public let total: Duration?

    public static let disabled = StreamingTimeoutPolicy()

    public init(
        firstResponse: Duration? = nil,
        firstEvent: Duration? = nil,
        idle: Duration? = nil,
        total: Duration? = nil
    ) {
        self.firstResponse = Self.positive(firstResponse)
        self.firstEvent = Self.positive(firstEvent)
        self.idle = Self.positive(idle)
        self.total = Self.positive(total)
    }

    private static func positive(_ value: Duration?) -> Duration? {
        value.flatMap { $0 > .zero ? $0 : nil }
    }
}

package enum StreamingTimeoutPhase: String, Sendable {
    case firstResponse
    case firstEvent
    case idle
    case total

    var error: NetworkError {
        .timeout(
            reason: self == .firstResponse ? .requestTimeout : .resourceTimeout,
            underlying: SendableUnderlyingError(
                domain: NetworkError.errorDomain,
                code: NetworkErrorCode.streamingPhaseTimeout.rawValue,
                message: "Streaming \(rawValue) timeout expired."
            )
        )
    }
}

/// One watchdog per accepted response. Byte activity updates a lock-protected
/// instant; the sleeper re-evaluates deadlines when it wakes, avoiding a task
/// allocation for every byte or frame.
package final class StreamingTimeoutWatchdog: Sendable {
    private struct State {
        var acceptedAt: Duration
        var lastActivity: Duration
        var deliveredFirstEvent = false
        var timeout: StreamingTimeoutPhase?
        var isFinished = false
        var task: Task<Void, Never>?
    }

    private let policy: StreamingTimeoutPolicy
    private let logicalStart: Duration
    private let clock: any InnoNetworkClock
    private let cancelTransport: @Sendable () -> Void
    private let state: OSAllocatedUnfairLock<State>

    package init(
        policy: StreamingTimeoutPolicy,
        logicalStart: Duration,
        clock: any InnoNetworkClock,
        cancelTransport: @escaping @Sendable () -> Void
    ) {
        let now = clock.monotonicNow()
        self.policy = policy
        self.logicalStart = logicalStart
        self.clock = clock
        self.cancelTransport = cancelTransport
        self.state = OSAllocatedUnfairLock(
            initialState: State(acceptedAt: now, lastActivity: now)
        )
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run()
        }
        state.withLock { $0.task = task }
    }

    deinit { state.withLock { $0.task?.cancel() } }

    package func recordNetworkActivity() {
        let now = clock.monotonicNow()
        state.withLock { state in
            guard !state.isFinished else { return }
            state.lastActivity = now
        }
    }

    package func recordFirstEvent() {
        state.withLock { $0.deliveredFirstEvent = true }
    }

    package var timeoutError: NetworkError? {
        state.withLock { $0.timeout?.error }
    }

    package var timeoutPhase: StreamingTimeoutPhase? {
        state.withLock { $0.timeout }
    }

    package func finish() {
        let task = state.withLock { state -> Task<Void, Never>? in
            state.isFinished = true
            let task = state.task
            state.task = nil
            return task
        }
        task?.cancel()
    }

    private func run() async {
        while true {
            let snapshot = state.withLock {
                (
                    acceptedAt: $0.acceptedAt,
                    lastActivity: $0.lastActivity,
                    deliveredFirstEvent: $0.deliveredFirstEvent,
                    isFinished: $0.isFinished
                )
            }
            if snapshot.isFinished { return }
            let now = clock.monotonicNow()
            guard
                let deadline = nearestDeadline(
                    acceptedAt: snapshot.acceptedAt,
                    lastActivity: snapshot.lastActivity,
                    deliveredFirstEvent: snapshot.deliveredFirstEvent
                )
            else { return }

            if deadline.instant > now {
                do {
                    try await clock.sleep(for: deadline.instant - now)
                } catch {
                    return
                }
                continue
            }

            let shouldCancel = state.withLock { state -> Bool in
                guard !state.isFinished, state.timeout == nil else { return false }
                state.timeout = deadline.phase
                state.isFinished = true
                return true
            }
            if shouldCancel { cancelTransport() }
            return
        }
    }

    private func nearestDeadline(
        acceptedAt: Duration,
        lastActivity: Duration,
        deliveredFirstEvent: Bool
    ) -> (instant: Duration, phase: StreamingTimeoutPhase)? {
        var candidates: [(Duration, StreamingTimeoutPhase)] = []
        if let total = policy.total { candidates.append((logicalStart + total, .total)) }
        if !deliveredFirstEvent, let firstEvent = policy.firstEvent {
            candidates.append((acceptedAt + firstEvent, .firstEvent))
        }
        if let idle = policy.idle { candidates.append((lastActivity + idle, .idle)) }
        return candidates.min { $0.0 < $1.0 }.map { ($0.0, $0.1) }
    }
}
