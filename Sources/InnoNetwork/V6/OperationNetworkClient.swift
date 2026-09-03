import Foundation

/// Operation-first adapter over any ``NetworkClient``.
///
/// The generic base keeps test doubles and application-owned client wrappers
/// usable during migration. Use the configuration initializer when the base is
/// ``DefaultNetworkClient``.
public struct OperationNetworkClient<Base: NetworkClient>: Sendable {
    private let base: Base

    public init(client: Base) {
        self.base = client
    }

    /// Starts a typed request and immediately returns its operation handle.
    public func start<Request: APIDefinition>(
        _ request: Request
    ) -> NetworkOperation<Request.APIResponse> {
        start(request, replaySafety: .methodDefault)
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
        let id = UUID()
        let tag = CancellationTag(id.uuidString)
        let requestMethod = request.method
        let sessionAuthentication = request.sessionAuthentication
        let (events, continuation) = AsyncStream<NetworkOperationEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        let task = Task { [base] in
            continuation.yield(.started(id: id))
            do {
                let value = try await base.request(request, tag: tag)
                continuation.yield(.succeeded(id: id))
                continuation.finish()
                return Result<Request.APIResponse, NetworkFailure>.success(value)
            } catch let error as NetworkError {
                let failure = NetworkFailure(
                    migratingV5: error,
                    requestMethod: requestMethod,
                    sessionAuthentication: sessionAuthentication,
                    replaySafety: replaySafety
                )
                continuation.yield(.failed(id: id, failure: failure))
                continuation.finish()
                return Result<Request.APIResponse, NetworkFailure>.failure(failure)
            } catch {
                let mapped = NetworkError.mapTransportError(error)
                let failure = NetworkFailure(
                    migratingV5: mapped,
                    requestMethod: requestMethod,
                    sessionAuthentication: sessionAuthentication,
                    replaySafety: replaySafety
                )
                continuation.yield(.failed(id: id, failure: failure))
                continuation.finish()
                return Result<Request.APIResponse, NetworkFailure>.failure(failure)
            }
        }
        return NetworkOperation(id: id, events: events, task: task)
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
