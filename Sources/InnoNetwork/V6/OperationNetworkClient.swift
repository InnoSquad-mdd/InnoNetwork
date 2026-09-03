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
        let id = UUID()
        let tag = CancellationTag(id.uuidString)
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
                let failure = NetworkFailure(migratingV5: error)
                continuation.yield(.failed(id: id, failure: failure))
                continuation.finish()
                return Result<Request.APIResponse, NetworkFailure>.failure(failure)
            } catch {
                let mapped = NetworkError.mapTransportError(error)
                let failure = NetworkFailure(migratingV5: mapped)
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
