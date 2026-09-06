import Foundation
import os

/// The execution stage that was active when an operation deadline expired.
///
/// Stages are intentionally coarse and payload-free. They identify which
/// bounded part of the client lifecycle consumed the caller's latency budget
/// without retaining URLs, headers, request bodies, or response bodies.
public enum NetworkOperationDeadlineStage: String, Sendable, Equatable {
    case requestPreparation
    case authentication
    case cacheLookup
    case policyAdmission
    case connectivityWait
    case retryDelay
    case transport
    case responseDecoding
    case unknown
}

/// A caller-owned monotonic latency budget for one ``NetworkOperation``.
///
/// The duration covers request preparation, authentication, cache lookup,
/// policy admission, connectivity waits, retry delays, every transport
/// attempt, and response decoding. Non-positive durations expire immediately.
public struct NetworkOperationDeadline: Sendable, Equatable {
    public let duration: Duration

    public init(after duration: Duration) {
        self.duration = max(.zero, duration)
    }
}

package final class NetworkOperationDeadlineTracker: Sendable {
    private let stage = OSAllocatedUnfairLock<NetworkOperationDeadlineStage>(
        initialState: .unknown
    )

    package init() {}

    package func mark(_ stage: NetworkOperationDeadlineStage) {
        self.stage.withLock { $0 = stage }
    }

    package var currentStage: NetworkOperationDeadlineStage {
        stage.withLock { $0 }
    }
}

package enum NetworkOperationDeadlineContext {
    @TaskLocal package static var tracker: NetworkOperationDeadlineTracker?

    package static func mark(_ stage: NetworkOperationDeadlineStage) {
        tracker?.mark(stage)
    }
}

package final class NetworkOperationResultGate<Value: Sendable>: Sendable {
    private struct State {
        var result: Result<Value, NetworkFailure>?
        var waiters: [CheckedContinuation<Result<Value, NetworkFailure>, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    package func wait() async -> Result<Value, NetworkFailure> {
        return await withCheckedContinuation { continuation in
            let result = state.withLock { state -> Result<Value, NetworkFailure>? in
                if let result = state.result { return result }
                state.waiters.append(continuation)
                return nil
            }
            if let result {
                continuation.resume(returning: result)
            }
        }
    }

    @discardableResult
    package func resolve(_ result: Result<Value, NetworkFailure>) -> Bool {
        let pending = state.withLock { state -> [CheckedContinuation<Result<Value, NetworkFailure>, Never>]? in
            guard state.result == nil else { return nil }
            state.result = result
            let pending = state.waiters
            state.waiters.removeAll(keepingCapacity: false)
            return pending
        }
        guard let pending else { return false }
        for waiter in pending {
            waiter.resume(returning: result)
        }
        return true
    }
}
