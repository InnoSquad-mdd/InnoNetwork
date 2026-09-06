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

    @Test("An expired operation deadline fails before a delayed request completes")
    func expiresOperationDeadline() async throws {
        let endpoint = PreviewEndpoint()
        let stub = StubNetworkClient()
        stub.register(
            PreviewResponse(id: "late"),
            for: endpoint,
            behavior: .delayed(seconds: 60)
        )
        let operation = OperationNetworkClient(client: stub).start(
            endpoint,
            deadline: NetworkOperationDeadline(after: .zero)
        )

        let failure = await failure(from: operation)

        #expect(failure.kind == .timeout)
        #expect(failure.code == NetworkErrorCode.timeout.rawValue)
        #expect(failure.deadlineStage == .requestPreparation)
        #expect(failure.recovery == .retry)
    }

    @Test("Unsafe operations keep deadline recovery terminal")
    func deadlineRecoveryRespectsReplaySafety() async throws {
        let endpoint = RecoveryEndpoint(method: .post)
        let stub = StubNetworkClient()
        stub.register(
            PreviewResponse(id: "late"),
            for: endpoint,
            behavior: .delayed(seconds: 60)
        )
        let operation = OperationNetworkClient(client: stub).start(
            endpoint,
            deadline: NetworkOperationDeadline(after: .zero)
        )

        let failure = await failure(from: operation)

        #expect(failure.kind == .timeout)
        #expect(failure.recovery == .doNotRetry)
    }

    @Test("A zero deadline never dispatches the base client")
    func zeroDeadlineDoesNotDispatch() async {
        let base = DeadlineHeldNetworkClient()
        let clock = TestClock()
        let operation = OperationNetworkClient(client: base, deadlineClock: clock).start(
            PreviewEndpoint(),
            deadline: NetworkOperationDeadline(after: .zero)
        )

        let result = await failure(from: operation)

        #expect(result.kind == .timeout)
        #expect(await base.requestCount == 0)
        #expect(clock.waiterCount == 0)
    }

    @Test("An elapsed deadline cannot lose to a late successful response")
    func elapsedDeadlineWinsLateSuccess() async throws {
        let base = DeadlineHeldNetworkClient()
        let clock = TestClock()
        let operation = OperationNetworkClient(client: base, deadlineClock: clock).start(
            PreviewEndpoint(),
            deadline: NetworkOperationDeadline(after: .seconds(1))
        )

        await base.waitUntilStarted()
        #expect(await clock.waitForWaiters(count: 1))
        clock.advanceWithoutResuming(by: .seconds(2))
        await base.release()
        let result = await failure(from: operation)

        #expect(result.kind == .timeout)
        #expect(result.deadlineStage == .requestPreparation)
        #expect(await base.requestCount == 1)
        clock.advance(by: .zero)
        #expect(clock.waiterCount == 0)
    }

    @Test("A successful operation cancels its pending deadline wait")
    func successCancelsDeadlineWait() async throws {
        let endpoint = PreviewEndpoint()
        let stub = StubNetworkClient()
        stub.register(PreviewResponse(id: "42"), for: endpoint)
        let clock = TestClock()
        let client = OperationNetworkClient(client: stub, deadlineClock: clock)

        let value = try await client.start(
            endpoint,
            deadline: NetworkOperationDeadline(after: .seconds(60))
        ).value()

        #expect(value == PreviewResponse(id: "42"))
        #expect(clock.waiterCount == 0)
    }

    @Test("Deadline reports retry-delay exhaustion")
    func reportsRetryDelayStage() async throws {
        let clock = TestClock()
        let session = DeadlineFailingURLSession()
        let base = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.test",
                retryPolicy: ExponentialBackoffRetryPolicy(
                    maxRetries: 1,
                    retryDelay: 5,
                    jitterRatio: 0
                )
            ),
            session: session,
            clock: clock
        )
        let client = OperationNetworkClient(client: base, deadlineClock: clock)
        let operation = client.start(
            PreviewEndpoint(),
            deadline: NetworkOperationDeadline(after: .seconds(2))
        )

        #expect(await clock.waitForWaiters(count: 2))
        clock.advance(by: .seconds(2))
        let failure = await failure(from: operation)

        #expect(failure.kind == .timeout)
        #expect(failure.deadlineStage == .retryDelay)
        #expect(await session.requestCount == 1)
    }

    @Test("Caller cancellation wins over a pending operation deadline")
    func cancellationWinsPendingDeadline() async throws {
        let endpoint = PreviewEndpoint()
        let stub = StubNetworkClient()
        stub.register(
            PreviewResponse(id: "late"),
            for: endpoint,
            behavior: .delayed(seconds: 60)
        )
        let clock = TestClock()
        let operation = OperationNetworkClient(client: stub, deadlineClock: clock).start(
            endpoint,
            deadline: NetworkOperationDeadline(after: .seconds(60))
        )

        operation.cancel()
        let failure = await failure(from: operation)

        #expect(failure.kind == .cancelled)
        #expect(failure.deadlineStage == nil)
        #expect(clock.waiterCount == 0)
    }

    @Test("Coalesced callers keep independent operation deadlines", .timeLimit(.minutes(1)))
    func coalescedCallersKeepIndependentDeadlines() async throws {
        let clock = TestClock()
        let session = DeadlineBlockingURLSession()
        let base = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.test",
                requestCoalescingPolicy: .getOnly
            ),
            session: session,
            clock: clock
        )
        let client = OperationNetworkClient(client: base, deadlineClock: clock)
        let long = client.start(
            PreviewEndpoint(),
            deadline: NetworkOperationDeadline(after: .seconds(10))
        )
        await session.waitUntilStarted()
        let short = client.start(
            PreviewEndpoint(),
            deadline: NetworkOperationDeadline(after: .seconds(1))
        )

        await base.waitForCoalescedCallerCount(atLeast: 2)
        #expect(await clock.waitForWaiters(count: 2))
        clock.advance(by: .seconds(1))
        let shortFailure = await failure(from: short)

        #expect(shortFailure.deadlineStage == .transport)
        #expect(await session.requestCount == 1)

        try await session.succeed(with: PreviewResponse(id: "shared"))
        let longValue = try await long.value()

        #expect(longValue == PreviewResponse(id: "shared"))
        #expect(await session.requestCount == 1)
        #expect(clock.waiterCount == 0)
        await base.shutdown()
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

private actor DeadlineFailingURLSession: URLSessionProtocol {
    private(set) var requestCount = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        _ = request
        requestCount += 1
        throw URLError(.timedOut)
    }
}

private actor DeadlineBlockingURLSession: URLSessionProtocol {
    private var continuations: [CheckedContinuation<(Data, URLResponse), Error>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestCount = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        _ = request
        requestCount += 1
        let pendingStarts = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in pendingStarts { waiter.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard requestCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func succeed(with response: PreviewResponse) throws {
        let data = try JSONEncoder().encode(response)
        let urlResponse = HTTPURLResponse(
            url: URL(string: "https://api.example.test/preview")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let pending = continuations
        continuations.removeAll(keepingCapacity: false)
        for continuation in pending {
            continuation.resume(returning: (data, urlResponse))
        }
    }
}

private actor DeadlineHeldNetworkClient: NetworkClient {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestCount = 0

    func request<Request: APIDefinition>(
        _: Request,
        tag _: CancellationTag?
    ) async throws(NetworkError) -> Request.APIResponse {
        requestCount += 1
        let pendingStarts = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in pendingStarts { waiter.resume() }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        do {
            return try JSONDecoder().decode(
                Request.APIResponse.self,
                from: JSONEncoder().encode(PreviewResponse(id: "late"))
            )
        } catch {
            throw .configuration(reason: .invalidRequest("Unable to create the deadline test response."))
        }
    }

    func waitUntilStarted() async {
        guard requestCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
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
