import Foundation
import InnoNetwork
import os

package enum UploadDelegateEvent: Sendable {
    case progress(taskIdentifier: Int, bytesSent: Int64, totalBytesSent: Int64, expected: Int64)
    case data(taskIdentifier: Int, data: Data)
    case completed(
        taskIdentifier: Int,
        taskDescription: String?,
        originalRequest: URLRequest?,
        currentRequest: URLRequest?,
        response: HTTPURLResponse?,
        error: SendableUnderlyingError?
    )
    case overflow(taskIdentifier: Int, byteLimit: Int)
    case backgroundEventsFinished
    case invalidated

    fileprivate var taskIdentifier: Int? {
        switch self {
        case .progress(let identifier, _, _, _),
            .data(let identifier, _),
            .completed(let identifier, _, _, _, _, _),
            .overflow(let identifier, _):
            identifier
        case .backgroundEventsFinished, .invalidated:
            nil
        }
    }

    fileprivate var bufferedByteCount: Int {
        if case .data(_, let data) = self { return data.count }
        return 0
    }
}

/// A single-consumer, bounded bridge from URLSession delegate callbacks into
/// the upload manager actor. Progress is coalesced, response data is never
/// silently dropped, and lifecycle events have a task-bounded reserve.
package final class UploadDelegateEventChannel: Sendable {
    private struct State {
        var queue: [UploadDelegateEvent] = []
        var waiter: CheckedContinuation<UploadDelegateEvent?, Never>?
        var bufferedBytes = 0
        var overflowedTaskIdentifiers: Set<Int> = []
        var isFinished = false
    }

    private enum Action {
        case none
        case resume(CheckedContinuation<UploadDelegateEvent?, Never>, UploadDelegateEvent?)
    }

    private let limits: UploadResourcePolicy
    private let state = OSAllocatedUnfairLock(initialState: State())

    package init(limits: UploadResourcePolicy = .safeDefaults) {
        self.limits = limits
    }

    package func next() async -> UploadDelegateEvent? {
        await withCheckedContinuation { continuation in
            let action = state.withLock { state -> Action in
                if !state.queue.isEmpty {
                    let event = state.queue.removeFirst()
                    state.bufferedBytes -= event.bufferedByteCount
                    return .resume(continuation, event)
                }
                if state.isFinished {
                    return .resume(continuation, nil)
                }
                precondition(state.waiter == nil, "Upload delegate channel supports one consumer")
                state.waiter = continuation
                return .none
            }
            perform(action)
        }
    }

    package func send(_ event: UploadDelegateEvent) {
        let action = state.withLock { state -> Action in
            guard !state.isFinished else { return .none }
            if let waiter = state.waiter {
                state.waiter = nil
                return .resume(waiter, event)
            }

            if case .progress(let identifier, _, _, _) = event,
                let index = state.queue.lastIndex(where: {
                    if case .progress(let queuedIdentifier, _, _, _) = $0 {
                        return queuedIdentifier == identifier
                    }
                    return false
                })
            {
                state.queue[index] = event
                return .none
            }

            if case .data(let identifier, let data) = event,
                state.queue.count >= limits.maximumBufferedDelegateEvents
                    || data.count > limits.maximumBufferedDelegateBytes - state.bufferedBytes
            {
                enqueueOverflow(for: identifier, state: &state)
                return .none
            }

            if isTransferEvent(event), state.queue.count >= limits.maximumBufferedDelegateEvents {
                if let progressIndex = state.queue.firstIndex(where: {
                    if case .progress = $0 { return true }
                    return false
                }) {
                    state.queue.remove(at: progressIndex)
                } else if let identifier = event.taskIdentifier {
                    enqueueOverflow(for: identifier, state: &state)
                    return .none
                }
            }

            state.queue.append(event)
            state.bufferedBytes += event.bufferedByteCount
            return .none
        }
        perform(action)
    }

    package func finish() {
        let action = state.withLock { state -> Action in
            guard !state.isFinished else { return .none }
            state.isFinished = true
            state.queue.removeAll(keepingCapacity: false)
            state.bufferedBytes = 0
            guard let waiter = state.waiter else { return .none }
            state.waiter = nil
            return .resume(waiter, nil)
        }
        perform(action)
    }

    private func enqueueOverflow(for identifier: Int, state: inout State) {
        guard state.overflowedTaskIdentifiers.insert(identifier).inserted else { return }
        state.queue.removeAll { event in
            guard event.taskIdentifier == identifier else { return false }
            state.bufferedBytes -= event.bufferedByteCount
            return true
        }
        state.queue.append(
            .overflow(taskIdentifier: identifier, byteLimit: limits.maximumBufferedDelegateBytes)
        )
    }

    private func isTransferEvent(_ event: UploadDelegateEvent) -> Bool {
        switch event {
        case .progress, .data:
            true
        case .completed, .overflow, .backgroundEventsFinished, .invalidated:
            false
        }
    }

    private func perform(_ action: Action) {
        if case .resume(let continuation, let event) = action {
            continuation.resume(returning: event)
        }
    }
}
