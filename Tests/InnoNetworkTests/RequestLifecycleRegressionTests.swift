import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

private actor LifecycleSpanExporter: NetworkSpanExporting {
    private(set) var spans: [NetworkSpan] = []

    func export(_ values: [NetworkSpan]) {
        spans.append(contentsOf: values)
    }
}

private struct LifecycleCompositeObserver: NetworkEventObserving, TimestampedNetworkEventObserving {
    let spanObserver: NetworkSpanObserver
    let continuation: AsyncStream<NetworkEvent>.Continuation

    func handle(_ event: NetworkEvent) async {
        await spanObserver.handle(event)
        continuation.yield(event)
    }

    func handle(
        _ event: NetworkEvent,
        occurredAt: Date,
        completesPhysicalTransport: Bool
    ) async {
        await spanObserver.handle(
            event,
            occurredAt: occurredAt,
            completesPhysicalTransport: completesPhysicalTransport
        )
        continuation.yield(event)
    }
}

private struct IntegerResponseRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = Int

    let method = HTTPMethod.get
    let path = "/status"
    var sessionAuthentication = SessionAuthentication.anonymous
}

@Suite("Request Lifecycle Regression Tests", .serialized)
struct RequestLifecycleRegressionTests {
    @Test("Authentication replay exports every physical transport attempt")
    func authenticationReplayExportsTwoAttempts() async throws {
        let exporter = LifecycleSpanExporter()
        let spanObserver = NetworkSpanObserver(exporter: exporter)
        let events = AsyncStream<NetworkEvent>.makeStream()
        let observer = LifecycleCompositeObserver(
            spanObserver: spanObserver,
            continuation: events.continuation
        )
        let session = MockURLSession()
        session.setScriptedResponses([
            .http(statusCode: 401),
            .http(statusCode: 200, data: Data("1".utf8)),
        ])
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com")!,
            networkMonitor: nil,
            eventObservers: [observer],
            refreshTokenPolicy: RefreshTokenPolicy(
                currentToken: { "old" },
                refreshToken: { "new" }
            )
        )
        let client = DefaultNetworkClient(configuration: configuration, session: session)

        #expect(
            try await client.request(
                IntegerResponseRequest(sessionAuthentication: .required)
            ) == 1
        )
        for await event in events.stream {
            if case .requestFinished = event { break }
        }
        await spanObserver.flush()

        let spans = await exporter.spans
        let attempts = spans.filter { $0.kind == .attempt }.sorted {
            ($0.attemptIndex ?? -1) < ($1.attemptIndex ?? -1)
        }
        #expect(session.capturedRequestsInOrder.count == 2)
        #expect(attempts.map(\.attemptIndex) == [0, 1])
        #expect(attempts.map(\.outcome) == [.retried, .succeeded])
        #expect(attempts.map(\.statusCode) == [401, 200])
        #expect(spans.filter { $0.kind == .request }.count == 1)
        await client.shutdown()
    }

    @Test("A real retry exports one logical request span")
    func retryExportsOneLogicalSpan() async throws {
        let exporter = LifecycleSpanExporter()
        let spanObserver = NetworkSpanObserver(exporter: exporter)
        let events = AsyncStream<NetworkEvent>.makeStream()
        let observer = LifecycleCompositeObserver(
            spanObserver: spanObserver,
            continuation: events.continuation
        )
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com")!,
            retryPolicy: TrustObservabilityRetryPolicy(),
            networkMonitor: nil,
            eventObservers: [observer],
            responseBodyBufferingPolicy: .buffered(maxBytes: 5 * 1024 * 1024)
        )
        let client = DefaultNetworkClient(
            configuration: configuration,
            session: FlakyContextSession(failuresBeforeSuccess: 1)
        )

        #expect(try await client.request(TrustObservabilityRequest()) == "ok")
        for await event in events.stream {
            if case .requestFinished = event { break }
        }
        await spanObserver.flush()

        let spans = await exporter.spans
        #expect(spans.filter { $0.kind == .request }.count == 1)
        #expect(spans.filter { $0.kind == .attempt && $0.outcome == .retried }.count == 1)
    }

    @Test("A decoding failure cannot publish a successful terminal outcome")
    func decodingFailureIsNotSuccess() async throws {
        let exporter = LifecycleSpanExporter()
        let spanObserver = NetworkSpanObserver(exporter: exporter)
        let events = AsyncStream<NetworkEvent>.makeStream()
        let observer = LifecycleCompositeObserver(
            spanObserver: spanObserver,
            continuation: events.continuation
        )
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com")!,
            networkMonitor: nil,
            eventObservers: [observer],
            responseBodyBufferingPolicy: .buffered(maxBytes: 5 * 1024 * 1024)
        )
        let client = DefaultNetworkClient(
            configuration: configuration,
            session: FlakyContextSession(failuresBeforeSuccess: 0)
        )

        await #expect(throws: NetworkError.self) {
            _ = try await client.request(IntegerResponseRequest())
        }
        for await event in events.stream {
            if case .requestFailed = event { break }
            if case .requestFinished = event {
                Issue.record("Decoding failure published requestFinished")
                break
            }
        }
        await spanObserver.flush()

        let logicalSpans = await exporter.spans.filter { $0.kind == .request }
        #expect(logicalSpans.map(\.outcome) == [.failed])
    }

    @Test(
        "Physical spans stop at transport completion and retain HTTP outcome",
        arguments: [false, true]
    )
    func physicalSpanExcludesDecodeTime(rejectDecodedValue: Bool) async throws {
        let clock = TestClock()
        let exporter = LifecycleSpanExporter()
        let spanObserver = NetworkSpanObserver(exporter: exporter, now: { clock.now() })
        let events = AsyncStream<NetworkEvent>.makeStream()
        let observer = LifecycleCompositeObserver(
            spanObserver: spanObserver,
            continuation: events.continuation
        )
        let decodeGate = LifecycleDecodeGate()
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com")!,
            networkMonitor: nil,
            eventObservers: [observer],
            decodingInterceptors: [
                HeldLifecycleDecodingInterceptor(
                    gate: decodeGate,
                    rejectsDecodedValue: rejectDecodedValue
                )
            ]
        )
        let session = MockURLSession()
        session.setScriptedResponses([
            .http(statusCode: 200, data: Data("1".utf8))
        ])
        let client = DefaultNetworkClient(
            configuration: configuration,
            session: session,
            clock: clock
        )
        let request = Task { try await client.request(IntegerResponseRequest()) }

        await decodeGate.waitUntilEntered()
        let transportEndedAt = clock.now()
        clock.advance(by: .seconds(10))
        await decodeGate.release()
        let result = await request.result
        if rejectDecodedValue {
            if case .success = result { Issue.record("Expected decoding interceptor rejection") }
        } else {
            #expect(try result.get() == 1)
        }
        for await event in events.stream {
            if case .requestFinished = event { break }
            if case .requestFailed = event { break }
        }
        await spanObserver.flush()

        let spans = await exporter.spans
        let attempt = try #require(spans.first { $0.kind == .attempt })
        let logical = try #require(spans.first { $0.kind == .request })
        #expect(attempt.endedAt == transportEndedAt)
        #expect(attempt.statusCode == 200)
        #expect(attempt.outcome == .succeeded)
        #expect(logical.outcome == (rejectDecodedValue ? .failed : .succeeded))
        #expect(logical.duration == 10)
        await client.shutdown()
    }

    @Test("A terminal failure displaces nonterminal events in a saturated partition")
    func saturatedPartitionRetainsTerminalFailure() async throws {
        let exporter = LifecycleSpanExporter()
        let spanObserver = NetworkSpanObserver(exporter: exporter)
        let events = AsyncStream<NetworkEvent>.makeStream()
        let observer = LifecycleCompositeObserver(
            spanObserver: spanObserver,
            continuation: events.continuation
        )
        let gate = EventHubDeliveryGate()
        let eventHub = NetworkEventHub(
            policy: EventDeliveryPolicy(
                maxBufferedEventsPerPartition: 1,
                overflowPolicy: .dropNewest
            ),
            testingDrainSuspension: { _ in await gate.waitForRelease() }
        )
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com")!,
            networkMonitor: nil,
            eventObservers: [observer],
            responseBodyBufferingPolicy: .buffered(maxBytes: 1_024)
        )
        let executor = RequestExecutor(
            session: FlakyContextSession(failuresBeforeSuccess: 1),
            eventHub: eventHub
        )
        let runtime = RequestExecutionRuntime(
            configuration: configuration,
            inFlight: InFlightRegistry()
        )
        let coordinator = RetryCoordinator(eventHub: eventHub)
        let requestID = UUID()
        let requestTask = Task {
            do {
                _ = try await coordinator.execute(
                    retryPolicy: nil,
                    networkMonitor: nil,
                    requestID: requestID,
                    eventObservers: [observer]
                ) { retryIndex, requestID in
                    try await executor.execute(
                        APISingleRequestExecutable(base: TrustObservabilityRequest()),
                        configuration: configuration,
                        requestBuilder: RequestBuilder(),
                        runtime: runtime,
                        retryIndex: retryIndex,
                        requestID: requestID
                    )
                }
                return false
            } catch {
                return error is NetworkError
            }
        }

        let requestFinished = await eventHubWaitForCondition(timeout: 3) {
            await eventHub._testingRetirementState(requestID: requestID)?.closureWaiterCount == 1
        }
        await gate.release()

        #expect(requestFinished)
        #expect(await requestTask.value)
        for await event in events.stream {
            guard case .requestFailed = event else {
                Issue.record("Only a nonterminal event survived: \(event)")
                break
            }
            break
        }
        await runtime.shutdown()
        await eventHub.shutdown()
    }
}

private actor LifecycleDecodeGate {
    private let entered = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.continuation.yield()
        }
    }

    func waitUntilEntered() async {
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct HeldLifecycleDecodingInterceptor: DecodingInterceptor {
    let gate: LifecycleDecodeGate
    let rejectsDecodedValue: Bool

    func didDecode<Value: Sendable>(
        _ value: Value,
        response: Response
    ) async throws -> Value {
        _ = response
        await gate.wait()
        if rejectsDecodedValue {
            throw NetworkError.configuration(
                reason: .invalidRequest("Rejected after transport for span regression coverage.")
            )
        }
        return value
    }
}
