import Foundation

/// Lifecycle events emitted by a ``NetworkOperation``.
public enum NetworkOperationEvent: Sendable, Equatable {
    case started(id: UUID)
    case succeeded(id: UUID)
    case failed(id: UUID, failure: NetworkFailure)
}

/// A cancellation-capable handle returned before network execution completes.
///
/// The event stream is registered before work starts and retains the bounded
/// start/terminal lifecycle for a late first consumer. Await ``value()`` for
/// the typed response or call ``cancel()`` without retaining the client.
/// Cancelling a task that is currently awaiting ``value()`` also cancels this
/// operation so structured callers do not leave detached network work behind.
public struct NetworkOperation<Value: Sendable>: Sendable {
    public let id: UUID
    public let events: AsyncStream<NetworkOperationEvent>

    private let task: Task<Result<Value, NetworkFailure>, Never>

    package init(
        id: UUID,
        events: AsyncStream<NetworkOperationEvent>,
        task: Task<Result<Value, NetworkFailure>, Never>
    ) {
        self.id = id
        self.events = events
        self.task = task
    }

    public func value() async throws(NetworkFailure) -> Value {
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        switch result {
        case .success(let value):
            return value
        case .failure(let failure):
            throw failure
        }
    }

    public func cancel() {
        task.cancel()
    }

    public var isCancelled: Bool {
        task.isCancelled
    }
}
