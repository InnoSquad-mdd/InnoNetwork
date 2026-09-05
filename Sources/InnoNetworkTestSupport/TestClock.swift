import Foundation
import InnoNetwork
import os

/// Virtual-time clock used by deterministic timing tests across all three
/// test targets. Production code receives an `any InnoNetworkClock`;
/// production paths use `SystemClock`, and tests inject this implementation
/// to drive timing deterministically via `advance(by:)` instead of
/// wall-clock sleeps.
///
/// Implementation notes:
/// - State is held behind an `OSAllocatedUnfairLock` so that enqueue,
///   cancellation, and `advance` all serialise synchronously. This avoids the
///   race where `withTaskCancellationHandler.onCancel` schedules async cleanup
///   that has not yet landed when the test calls `advance` — that race would
///   let a cancelled waiter wake up with success and let the `try await
///   clock.sleep(for:)` call return normally after its enclosing task was
///   cancelled.
/// - `sleep(for:)` also performs `Task.checkCancellation()` after resuming so
///   a waiter that was fired in a tight race with cancellation still surfaces
///   as `CancellationError` to the caller.
package final class TestClock: InnoNetworkClock, @unchecked Sendable {

    private struct Waiter {
        let id: UUID
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private enum Condition {
        case enqueuedCount(Int)
        case waiterCount(Int)

        func isSatisfied(by state: State) -> Bool {
            switch self {
            case .enqueuedCount(let target):
                return state.enqueuedCount >= target
            case .waiterCount(let target):
                return state.waiters.count >= target
            }
        }
    }

    private struct ConditionWaiter {
        let id: UUID
        let condition: Condition
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct State {
        var virtualNow: Duration = .zero
        var waiters: [Waiter] = []
        var conditionWaiters: [ConditionWaiter] = []
        /// Monotone counter of every `sleep(for:)` call that actually enqueued
        /// a waiter (i.e. duration > 0 and task not yet cancelled). Tests use
        /// snapshots of this counter to detect when the coordinator has
        /// registered a fresh sleep after a cycle completes — more reliable
        /// than `waiterCount`, which transiently dips to zero between waiters.
        var enqueuedCount: Int = 0

        mutating func removeSatisfiedConditionWaiters() -> [CheckedContinuation<Bool, Never>] {
            var ready: [CheckedContinuation<Bool, Never>] = []
            var remaining: [ConditionWaiter] = []
            for waiter in conditionWaiters {
                if waiter.condition.isSatisfied(by: self) {
                    ready.append(waiter.continuation)
                } else {
                    remaining.append(waiter)
                }
            }
            conditionWaiters = remaining
            return ready
        }
    }

    private let stateLock = OSAllocatedUnfairLock<State>(initialState: State())
    private let epoch: Date

    package init(epoch: Date = Date(timeIntervalSince1970: 0)) {
        self.epoch = epoch
    }

    /// Returns the clock's virtual `Date`, equal to `epoch + virtualNow`.
    package func now() -> Date {
        let virtualSeconds = stateLock.withLock { $0.virtualNow.timeInterval }
        return epoch.addingTimeInterval(virtualSeconds)
    }

    package func monotonicNow() -> Duration {
        stateLock.withLock { $0.virtualNow }
    }

    package func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enum Action { case resume, cancel, wait }
                let result: (Action, [CheckedContinuation<Bool, Never>]) = stateLock.withLock { state in
                    if Task.isCancelled { return (.cancel, []) }
                    if duration <= .zero { return (.resume, []) }
                    let deadline = state.virtualNow + duration
                    state.waiters.append(Waiter(id: id, deadline: deadline, continuation: continuation))
                    state.enqueuedCount += 1
                    return (.wait, state.removeSatisfiedConditionWaiters())
                }
                let action = result.0
                let readyConditions = result.1
                switch action {
                case .resume:
                    continuation.resume()
                case .cancel:
                    continuation.resume(throwing: CancellationError())
                case .wait:
                    break
                }
                for condition in readyConditions {
                    condition.resume(returning: true)
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            let waiter: Waiter? = stateLock.withLock { state in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else {
                    return nil
                }
                return state.waiters.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Advances virtual time and resumes every waiter whose deadline has now
    /// elapsed, in deadline order.
    package func advance(by duration: Duration) {
        let result: ([Waiter], [CheckedContinuation<Bool, Never>]) = stateLock.withLock { state in
            state.virtualNow += duration
            let fired = state.waiters.filter { $0.deadline <= state.virtualNow }
            state.waiters.removeAll { $0.deadline <= state.virtualNow }
            return (
                fired.sorted(by: { $0.deadline < $1.deadline }),
                state.removeSatisfiedConditionWaiters()
            )
        }
        for waiter in result.0 {
            waiter.continuation.resume()
        }
        for condition in result.1 {
            condition.resume(returning: true)
        }
    }

    /// Advances monotonic time without resuming elapsed sleepers. Tests use
    /// this to exercise actor reentrancy while a time-based operation remains
    /// suspended, then call `advance(by: .zero)` to release elapsed sleepers.
    package func advanceWithoutResuming(by duration: Duration) {
        let readyConditions = stateLock.withLock { state in
            state.virtualNow += duration
            return state.removeSatisfiedConditionWaiters()
        }
        for condition in readyConditions {
            condition.resume(returning: true)
        }
    }

    /// Outstanding waiter count. Useful for gating `advance` on the coordinator
    /// having actually registered its sleep.
    package var waiterCount: Int {
        stateLock.withLock { $0.waiters.count }
    }

    /// Monotone counter of total sleeps enqueued since the clock was created.
    /// Strictly increases; tests snapshot it before advancing a cycle and wait
    /// for it to reach a target before proceeding.
    package var enqueuedCount: Int {
        stateLock.withLock { $0.enqueuedCount }
    }

    /// Awaits until `enqueuedCount` reaches at least `target` or the timeout
    /// elapses. Returns `true` if the target was reached.
    package func waitForEnqueuedCount(atLeast target: Int, timeout: TimeInterval = 1.0) async -> Bool {
        await waitForCondition(.enqueuedCount(target), timeout: timeout)
    }

    /// Awaits until at least `count` waiters are registered or `timeout`
    /// elapses. Returns `true` if the target was reached.
    package func waitForWaiters(count: Int, timeout: TimeInterval = 1.0) async -> Bool {
        await waitForCondition(.waiterCount(count), timeout: timeout)
    }

    private func waitForCondition(_ condition: Condition, timeout: TimeInterval) async -> Bool {
        if stateLock.withLock({ condition.isSatisfied(by: $0) }) {
            return true
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let shouldWait: Bool = stateLock.withLock { state in
                    guard !condition.isSatisfied(by: state) else { return false }
                    state.conditionWaiters.append(
                        ConditionWaiter(id: id, condition: condition, continuation: continuation)
                    )
                    return true
                }

                guard shouldWait else {
                    continuation.resume(returning: true)
                    return
                }

                scheduleConditionTimeout(id: id, timeout: timeout)
            }
        } onCancel: {
            finishConditionWaiter(id: id, result: false)
        }
    }

    private func scheduleConditionTimeout(id: UUID, timeout: TimeInterval) {
        let duration = max(timeout, 0)
        Task { [self] in
            let clock = ContinuousClock()
            do {
                try await clock.sleep(for: .seconds(duration))
            } catch {
                finishConditionWaiter(id: id, result: false)
                return
            }
            finishConditionWaiter(id: id, result: false)
        }
    }

    private func finishConditionWaiter(id: UUID, result: Bool) {
        let continuation: CheckedContinuation<Bool, Never>? = stateLock.withLock { state in
            guard let index = state.conditionWaiters.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return state.conditionWaiters.remove(at: index).continuation
        }
        continuation?.resume(returning: result)
    }
}
