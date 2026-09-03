import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

@Suite("Operation-first client")
struct OperationNetworkClientTests {
    @Test("Operation returns a typed value and a bounded lifecycle")
    func returnsTypedValueAndLifecycle() async throws {
        let endpoint = PreviewEndpoint()
        let stub = StubNetworkClient()
        stub.register(PreviewResponse(id: "42"), for: endpoint)
        let client = OperationNetworkClient(client: stub)

        let operation = client.start(endpoint)
        let value = try await operation.value()
        var events: [NetworkOperationEvent] = []
        for await event in operation.events {
            events.append(event)
        }

        #expect(value == PreviewResponse(id: "42"))
        #expect(events == [.started(id: operation.id), .succeeded(id: operation.id)])
    }

    @Test("Cancellation maps to the value-only failure contract")
    func mapsCancellation() async throws {
        let endpoint = PreviewEndpoint()
        let stub = StubNetworkClient()
        stub.register(
            PreviewResponse(id: "never"),
            for: endpoint,
            behavior: .delayed(seconds: 60)
        )
        let operation = OperationNetworkClient(client: stub).start(endpoint)
        operation.cancel()

        await #expect(throws: NetworkFailure.self) {
            _ = try await operation.value()
        }
        do {
            _ = try await operation.value()
        } catch {
            #expect(error.kind == .cancelled)
            #expect(error.recovery == .none)
            #expect(operation.isCancelled)
        }
    }

    @Test("Migration failure mapping removes response payload details")
    func mapsLegacyConfigurationFailure() {
        let failure = NetworkFailure(
            migratingV5: .configuration(reason: .invalidRequest("secret detail"))
        )

        #expect(failure.kind == .configuration)
        #expect(failure.recovery == .doNotRetry)
        #expect(failure.statusCode == nil)
        #expect(failure.errorDescription == "The request configuration is invalid.")
    }

    @Test(
        "Recovery only recommends retry when replay is safe",
        arguments: [408, 429, 503]
    )
    func requiresReplaySafetyForRetry(statusCode: Int) async throws {
        let error = makeHTTPFailure(statusCode: statusCode)
        let client = OperationNetworkClient(client: FailingNetworkClient(error: error))

        let getFailure = await failure(
            from: client.start(RecoveryEndpoint(method: .get))
        )
        let postFailure = await failure(
            from: client.start(RecoveryEndpoint(method: .post))
        )
        let idempotentPostFailure = await failure(
            from: client.start(
                RecoveryEndpoint(method: .post),
                replaySafety: .stableIdempotencyKey
            )
        )
        let neverReplayGetFailure = await failure(
            from: client.start(
                RecoveryEndpoint(method: .get),
                replaySafety: .never
            )
        )

        #expect(getFailure.recovery == .retry)
        #expect(postFailure.recovery == .doNotRetry)
        #expect(idempotentPostFailure.recovery == .retry)
        #expect(neverReplayGetFailure.recovery == .doNotRetry)
    }

    @Test("Timeout recovery also requires replay safety")
    func requiresReplaySafetyForTimeoutRecovery() async throws {
        let error = NetworkError.timeout(reason: .requestTimeout)
        let client = OperationNetworkClient(client: FailingNetworkClient(error: error))

        let getFailure = await failure(
            from: client.start(RecoveryEndpoint(method: .get))
        )
        let postFailure = await failure(
            from: client.start(RecoveryEndpoint(method: .post))
        )

        #expect(getFailure.recovery == .retry)
        #expect(postFailure.recovery == .doNotRetry)
    }

    @Test("Connectivity recovery does not bypass replay safety")
    func requiresReplaySafetyForConnectivityRecovery() async throws {
        let underlying = SendableUnderlyingError(URLError(.networkConnectionLost))
        let error = NetworkError.reachability(
            .networkConnectionLost,
            underlying,
            nil
        )
        let client = OperationNetworkClient(client: FailingNetworkClient(error: error))

        let getFailure = await failure(
            from: client.start(RecoveryEndpoint(method: .get))
        )
        let postFailure = await failure(
            from: client.start(RecoveryEndpoint(method: .post))
        )

        #expect(getFailure.recovery == .waitForConnectivity)
        #expect(postFailure.recovery == .doNotRetry)
    }

    @Test("401 reauthenticates session endpoints while 403 stays terminal")
    func distinguishesAuthenticationFromAuthorization() async throws {
        let authenticated = RecoveryEndpoint(
            method: .get,
            sessionAuthentication: .required
        )
        let anonymous = RecoveryEndpoint(method: .get)

        let authenticated401 = await failure(
            from: OperationNetworkClient(
                client: FailingNetworkClient(error: makeHTTPFailure(statusCode: 401))
            ).start(authenticated)
        )
        let anonymous401 = await failure(
            from: OperationNetworkClient(
                client: FailingNetworkClient(error: makeHTTPFailure(statusCode: 401))
            ).start(anonymous)
        )
        let authenticated403 = await failure(
            from: OperationNetworkClient(
                client: FailingNetworkClient(error: makeHTTPFailure(statusCode: 403))
            ).start(authenticated)
        )

        #expect(authenticated401.recovery == .reauthenticate)
        #expect(anonymous401.recovery == .doNotRetry)
        #expect(authenticated403.recovery == .doNotRetry)
    }

    @Test("Context-free migration keeps local limit failures terminal")
    func keepsResponseBodyLimitTerminal() {
        let underlying = SendableUnderlyingError(
            domain: NetworkError.errorDomain,
            code: NetworkErrorCode.responseBodyLimitExceeded.rawValue,
            message: "sensitive size detail"
        )
        let failure = NetworkFailure(
            migratingV5: .underlying(underlying, nil)
        )

        #expect(failure.kind == .transport)
        #expect(failure.code == NetworkErrorCode.responseBodyLimitExceeded.rawValue)
        #expect(failure.recovery == .doNotRetry)

        let contextFreeServerFailure = NetworkFailure(
            migratingV5: makeHTTPFailure(statusCode: 503)
        )
        #expect(contextFreeServerFailure.recovery == .doNotRetry)
    }

    @Test("Configuration facade preserves an incremental migration bridge")
    func preservesConfigurationBridge() {
        let legacy = NetworkConfiguration.safeDefaults(
            baseURL: URL(string: "https://api.example.test")!
        )
        let preview = NetworkClientConfiguration(migratingV5: legacy)

        _ = preview.legacyConfiguration
    }
}

private func failure<Value: Sendable>(
    from operation: NetworkOperation<Value>
) async -> NetworkFailure {
    do {
        _ = try await operation.value()
        Issue.record("Expected the operation to fail")
        return NetworkFailure(
            kind: .configuration,
            code: NetworkErrorCode.configurationInvalidRequest.rawValue,
            recovery: .doNotRetry
        )
    } catch {
        return error
    }
}

private func makeHTTPFailure(statusCode: Int) -> NetworkError {
    let url = URL(string: "https://api.example.test/recovery")!
    let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
    return .statusCode(
        Response(
            statusCode: statusCode,
            data: Data(),
            response: response
        )
    )
}

private struct FailingNetworkClient: NetworkClient {
    let error: NetworkError

    func request<Request: APIDefinition>(
        _: Request,
        tag _: CancellationTag?
    ) async throws(NetworkError) -> Request.APIResponse {
        throw error
    }
}

private struct RecoveryEndpoint: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = PreviewResponse

    let method: HTTPMethod
    let path = "/recovery"
    let sessionAuthentication: SessionAuthentication
    let parameters: EmptyParameter? = nil

    init(
        method: HTTPMethod,
        sessionAuthentication: SessionAuthentication = .anonymous
    ) {
        self.method = method
        self.sessionAuthentication = sessionAuthentication
    }
}

private struct PreviewEndpoint: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = PreviewResponse

    let method: HTTPMethod = .get
    let path = "/preview"
    let sessionAuthentication: SessionAuthentication = .anonymous
    let parameters: EmptyParameter? = nil
}

private struct PreviewResponse: Codable, Sendable, Equatable {
    let id: String
}
