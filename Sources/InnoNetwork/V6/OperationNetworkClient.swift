import Foundation

/// Operation-first adapter over any ``NetworkClient``.
///
/// The generic base keeps test doubles and application-owned client wrappers
/// usable during migration. Use the configuration initializer when the base is
/// ``DefaultNetworkClient``.
public struct OperationNetworkClient<Base: NetworkClient>: Sendable {
    private let base: Base
    private let deadlineClock: any InnoNetworkClock

    public init(client: Base) {
        self.base = client
        self.deadlineClock = SystemClock()
    }

    package init(client: Base, deadlineClock: any InnoNetworkClock) {
        self.base = client
        self.deadlineClock = deadlineClock
    }

    /// Starts a typed request and immediately returns its operation handle.
    public func start<Request: APIDefinition>(
        _ request: Request
    ) -> NetworkOperation<Request.APIResponse> {
        start(request, replaySafety: .methodDefault, deadline: nil)
    }

    /// Starts a typed request with an explicit operation-restart policy.
    ///
    /// Use ``NetworkOperationReplaySafety/stableIdempotencyKey`` only when the
    /// application reuses the same idempotency key across newly created
    /// operation handles. InnoNetwork's per-operation automatic key is not
    /// stable across a manual restart.
    public func start<Request: APIDefinition>(
        _ request: Request,
        replaySafety: NetworkOperationReplaySafety
    ) -> NetworkOperation<Request.APIResponse> {
        start(request, replaySafety: replaySafety, deadline: nil)
    }

    /// Starts a typed request under one end-to-end monotonic deadline.
    public func start<Request: APIDefinition>(
        _ request: Request,
        deadline: NetworkOperationDeadline
    ) -> NetworkOperation<Request.APIResponse> {
        start(request, replaySafety: .methodDefault, deadline: deadline)
    }

    /// Starts a typed request with explicit restart safety and one end-to-end
    /// monotonic deadline.
    public func start<Request: APIDefinition>(
        _ request: Request,
        replaySafety: NetworkOperationReplaySafety,
        deadline: NetworkOperationDeadline
    ) -> NetworkOperation<Request.APIResponse> {
        start(request, replaySafety: replaySafety, deadline: Optional(deadline))
    }

    private func start<Request: APIDefinition>(
        _ request: Request,
        replaySafety: NetworkOperationReplaySafety,
        deadline: NetworkOperationDeadline?
    ) -> NetworkOperation<Request.APIResponse> {
        let id = UUID()
        let tag = CancellationTag(id.uuidString)
        let requestMethod = request.method
        let sessionAuthentication = request.sessionAuthentication
        let (events, continuation) = AsyncStream<NetworkOperationEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        let deadlineClock = self.deadlineClock
        let deadlineInstant = deadline.map { deadlineClock.monotonicNow() + $0.duration }
        let task = Task { [base] in
            continuation.yield(.started(id: id))
            let tracker = NetworkOperationDeadlineTracker()
            tracker.mark(.requestPreparation)
            let cancellationFailure = NetworkFailure(
                migratingV5: .cancelled,
                requestMethod: requestMethod,
                sessionAuthentication: sessionAuthentication,
                replaySafety: replaySafety
            )
            if Task.isCancelled {
                continuation.yield(.failed(id: id, failure: cancellationFailure))
                continuation.finish()
                return Result<Request.APIResponse, NetworkFailure>.failure(cancellationFailure)
            }
            if let deadlineInstant, deadlineClock.monotonicNow() >= deadlineInstant {
                let failure = Self.deadlineFailure(
                    tracker: tracker,
                    requestMethod: requestMethod,
                    replaySafety: replaySafety
                )
                continuation.yield(.failed(id: id, failure: failure))
                continuation.finish()
                return Result<Request.APIResponse, NetworkFailure>.failure(failure)
            }

            let gate = NetworkOperationResultGate<Request.APIResponse>()
            let requestTask = Task<Result<Request.APIResponse, NetworkFailure>, Never> {
                let result: Result<Request.APIResponse, NetworkFailure> = await NetworkOperationDeadlineContext.$tracker
                    .withValue(tracker) {
                        do {
                            let value = try await base.request(request, tag: tag)
                            return .success(value)
                        } catch let error as NetworkError {
                            return .failure(
                                NetworkFailure(
                                    migratingV5: error,
                                    requestMethod: requestMethod,
                                    sessionAuthentication: sessionAuthentication,
                                    replaySafety: replaySafety
                                )
                            )
                        } catch {
                            let mapped = NetworkError.mapTransportError(error)
                            return .failure(
                                NetworkFailure(
                                    migratingV5: mapped,
                                    requestMethod: requestMethod,
                                    sessionAuthentication: sessionAuthentication,
                                    replaySafety: replaySafety
                                )
                            )
                        }
                    }
                if let deadlineInstant, deadlineClock.monotonicNow() >= deadlineInstant {
                    _ = gate.resolve(
                        .failure(
                            Self.deadlineFailure(
                                tracker: tracker,
                                requestMethod: requestMethod,
                                replaySafety: replaySafety
                            )
                        )
                    )
                } else {
                    _ = gate.resolve(result)
                }
                return result
            }

            let deadlineTask: Task<Void, Never>?
            if let deadlineInstant {
                deadlineTask = Task {
                    do {
                        let remaining = max(.zero, deadlineInstant - deadlineClock.monotonicNow())
                        try await deadlineClock.sleep(for: remaining)
                    } catch {
                        return
                    }
                    if gate.resolve(
                        .failure(
                            Self.deadlineFailure(
                                tracker: tracker,
                                requestMethod: requestMethod,
                                replaySafety: replaySafety
                            )
                        )
                    ) {
                        requestTask.cancel()
                    }
                }
            } else {
                deadlineTask = nil
            }
            let result = await withTaskCancellationHandler {
                await gate.wait()
            } onCancel: {
                requestTask.cancel()
                deadlineTask?.cancel()
                _ = gate.resolve(.failure(cancellationFailure))
            }
            deadlineTask?.cancel()
            requestTask.cancel()

            switch result {
            case .success(let value):
                continuation.yield(.succeeded(id: id))
                continuation.finish()
                return Result<Request.APIResponse, NetworkFailure>.success(value)
            case .failure(let failure):
                continuation.yield(.failed(id: id, failure: failure))
                continuation.finish()
                return Result<Request.APIResponse, NetworkFailure>.failure(failure)
            }
        }
        return NetworkOperation(id: id, events: events, task: task)
    }

    private static func deadlineFailure(
        tracker: NetworkOperationDeadlineTracker,
        requestMethod: HTTPMethod,
        replaySafety: NetworkOperationReplaySafety
    ) -> NetworkFailure {
        NetworkFailure.operationDeadlineExceeded(
            stage: tracker.currentStage,
            requestMethod: requestMethod,
            replaySafety: replaySafety
        )
    }
}

public extension OperationNetworkClient where Base == DefaultNetworkClient {
    init(configuration: NetworkClientConfiguration) {
        self.init(client: DefaultNetworkClient(configuration: configuration.v5Configuration))
    }

    func shutdown() async {
        await base.shutdown()
    }
}
