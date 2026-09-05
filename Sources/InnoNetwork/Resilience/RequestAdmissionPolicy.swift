import Foundation
import os

/// Determines how built-in request admission partitions concurrency.
public enum RequestAdmissionScope: Sendable, Equatable {
    case global
    case origin
}

/// Bounded concurrency and queue policy enforced at the actual transport
/// boundary after cache lookup and request coalescing.
public struct RequestAdmissionPolicy: Sendable, Equatable {
    public let maximumConcurrentRequests: Int
    public let maximumPendingRequests: Int
    public let maximumQueueWait: Duration?
    public let scope: RequestAdmissionScope
    public let maximumConcurrentRequestsPerScope: Int
    public let maximumScopes: Int

    public init(
        maximumConcurrentRequests: Int,
        maximumPendingRequests: Int,
        maximumQueueWait: Duration? = nil,
        scope: RequestAdmissionScope = .origin,
        maximumConcurrentRequestsPerScope: Int? = nil,
        maximumScopes: Int = 128
    ) {
        let concurrent = max(1, maximumConcurrentRequests)
        self.maximumConcurrentRequests = concurrent
        self.maximumPendingRequests = max(0, maximumPendingRequests)
        self.maximumQueueWait = maximumQueueWait.map { max(.zero, $0) }
        self.scope = scope
        self.maximumConcurrentRequestsPerScope = max(
            1,
            min(concurrent, maximumConcurrentRequestsPerScope ?? concurrent)
        )
        self.maximumScopes = max(1, maximumScopes)
    }
}

package enum RequestAdmissionFailure: Error, Sendable, Equatable {
    case queueFull
    case queueWaitExpired
}

package struct RequestAdmissionGrant: Sendable {
    let scope: String
    let wasQueued: Bool
}

package actor RequestAdmissionCoordinator {
    private struct Waiter {
        let id: UUID
        let scope: String
        let continuation: CheckedContinuation<Void, Error>
        let timeoutTask: Task<Void, Never>?
    }

    private let policy: RequestAdmissionPolicy
    private let clock: any InnoNetworkClock
    private let cancellationMarks = OSAllocatedUnfairLock<Set<UUID>>(initialState: [])
    private var active = 0
    private var activeByScope: [String: Int] = [:]
    private var waiters: [Waiter] = []

    package init(policy: RequestAdmissionPolicy, clock: any InnoNetworkClock) {
        self.policy = policy
        self.clock = clock
    }

    package func acquire(for request: URLRequest) async throws -> RequestAdmissionGrant {
        try Task.checkCancellation()
        let scope = scopeKey(for: request)
        if waiters.isEmpty, hasCapacity(for: scope) {
            grant(scope: scope)
            return RequestAdmissionGrant(scope: scope, wasQueued: false)
        }
        guard waiters.count < policy.maximumPendingRequests else {
            throw RequestAdmissionFailure.queueFull
        }
        guard knownScopes.contains(scope) || knownScopes.count < policy.maximumScopes else {
            throw RequestAdmissionFailure.queueFull
        }

        let id = UUID()
        let maximumQueueWait = policy.maximumQueueWait
        let timeoutClock = clock
        var acquired = false
        do {
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    if consumeCancellationMark(id) || Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let timeoutTask: Task<Void, Never>?
                    if let maximumQueueWait {
                        timeoutTask = Task { [weak self] in
                            do {
                                try await timeoutClock.sleep(for: maximumQueueWait)
                            } catch {
                                return
                            }
                            await self?.expire(id: id)
                        }
                    } else {
                        timeoutTask = nil
                    }
                    waiters.append(
                        Waiter(
                            id: id,
                            scope: scope,
                            continuation: continuation,
                            timeoutTask: timeoutTask
                        )
                    )
                }
            }, onCancel: { [weak self] in
                self?.cancellationMarks.withLock { _ = $0.insert(id) }
                Task { [weak self] in await self?.cancel(id: id) }
            })
            acquired = true
            try Task.checkCancellation()
            return RequestAdmissionGrant(scope: scope, wasQueued: true)
        } catch {
            if acquired { release(scope: scope) }
            throw error
        }
    }

    package func release(scope: String) {
        guard active > 0, let scoped = activeByScope[scope], scoped > 0 else { return }
        active -= 1
        if scoped == 1 { activeByScope.removeValue(forKey: scope) }
        else { activeByScope[scope] = scoped - 1 }
        pump()
    }

    package var snapshot: (active: Int, pending: Int, scopes: Int) {
        (active, waiters.count, knownScopes.count)
    }

    private var knownScopes: Set<String> {
        Set(activeByScope.keys).union(waiters.map(\.scope))
    }

    private func hasCapacity(for scope: String) -> Bool {
        active < policy.maximumConcurrentRequests
            && activeByScope[scope, default: 0] < policy.maximumConcurrentRequestsPerScope
    }

    private func grant(scope: String) {
        active += 1
        activeByScope[scope, default: 0] += 1
    }

    private func pump() {
        while active < policy.maximumConcurrentRequests,
            let index = waiters.firstIndex(where: { hasCapacity(for: $0.scope) })
        {
            let waiter = waiters.remove(at: index)
            waiter.timeoutTask?.cancel()
            if consumeCancellationMark(waiter.id) {
                waiter.continuation.resume(throwing: CancellationError())
                continue
            }
            grant(scope: waiter.scope)
            waiter.continuation.resume()
        }
    }

    private func expire(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: RequestAdmissionFailure.queueWaitExpired)
        pump()
    }

    private func cancel(id: UUID) {
        _ = consumeCancellationMark(id)
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(throwing: CancellationError())
        pump()
    }

    private func consumeCancellationMark(_ id: UUID) -> Bool {
        cancellationMarks.withLock { $0.remove(id) != nil }
    }

    private func scopeKey(for request: URLRequest) -> String {
        guard policy.scope == .origin,
            let url = request.url,
            let scheme = url.scheme?.lowercased(),
            let host = url.host?.lowercased()
        else { return "global" }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }
}
