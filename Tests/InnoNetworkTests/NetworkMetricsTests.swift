import Foundation
import Testing

@testable import InnoNetwork

actor MetricsRecorder: NetworkMetricsReporting {
    private var metrics: [URLSessionTaskMetrics] = []
    private var responses: [URLResponse?] = []

    nonisolated func report(metrics: URLSessionTaskMetrics, for request: URLRequest, response: URLResponse?) {
        Task { await record(metrics: metrics, response: response) }
    }

    private func record(metrics: URLSessionTaskMetrics, response: URLResponse?) {
        self.metrics.append(metrics)
        self.responses.append(response)
    }

    var count: Int {
        metrics.count
    }

    var lastResponse: URLResponse? {
        responses.last.flatMap { $0 }
    }
}


final class TestURLProtocol: URLProtocol {
    enum ResponseSpec: Sendable {
        case success(statusCode: Int, data: Data)
        case failure(Error)
    }

    nonisolated(unsafe) private static var responses: [ResponseSpec] = []
    nonisolated(unsafe) private static var lastDequeuedResponse: ResponseSpec?
    private static let lock = NSLock()

    static func enqueue(_ response: ResponseSpec) {
        lock.lock()
        responses.append(response)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        responses.removeAll()
        lastDequeuedResponse = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let responseSpec = Self.dequeue()
        switch responseSpec {
        case .success(let statusCode, let data):
            guard let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            if let httpResponse = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)
            {
                client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            }
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .none:
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
        }
    }

    override func stopLoading() {}

    private static func dequeue() -> ResponseSpec? {
        lock.lock()
        let value: ResponseSpec?
        if responses.isEmpty {
            #if DEBUG
            assertionFailure("TestURLProtocol response queue unexpectedly empty; check request expectation counts.")
            #endif
            value = lastDequeuedResponse
        } else {
            let dequeued = responses.removeFirst()
            lastDequeuedResponse = dequeued
            value = dequeued
        }
        lock.unlock()
        return value
    }
}


actor MetricsForwardingProbe {
    private var didReceiveReporterValue = false

    func markReceivedReporter(_ received: Bool) {
        didReceiveReporterValue = received
    }

    var didReceiveReporter: Bool {
        didReceiveReporterValue
    }
}

final class MetricsAwareMockSession: URLSessionProtocol, Sendable {
    private let probe: MetricsForwardingProbe

    init(probe: MetricsForwardingProbe) {
        self.probe = probe
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        guard
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        else {
            throw URLError(.badServerResponse)
        }
        return (Data(#""fallback""#.utf8), response)
    }

    func data(
        for request: URLRequest,
        context: NetworkRequestContext
    ) async throws -> (Data, URLResponse) {
        await probe.markReceivedReporter(context.metricsReporter != nil)
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        guard
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        else {
            throw URLError(.badServerResponse)
        }
        return (Data(#""forwarded""#.utf8), response)
    }
}

struct MetricsGetRequest: APIDefinition {
    var sessionAuthentication: SessionAuthentication { .anonymous }
    typealias Parameter = EmptyParameter
    typealias APIResponse = String

    var method: HTTPMethod { .get }
    var path: String { "/metrics" }
}


struct RetryOncePolicy: RetryPolicy {
    let maxRetries: Int = 1
    let maxTotalRetries: Int = 1
    let retryDelay: TimeInterval = 0

    func retryDelay(for _: Int) -> TimeInterval {
        return retryDelay
    }

    func shouldRetry(
        error: NetworkError,
        retryIndex: Int,
        request: URLRequest?,
        response: HTTPURLResponse?
    ) -> RetryDecision {
        guard retryIndex < maxRetries else { return .noRetry }
        switch error {
        case .underlying, .timeout:
            return .retry
        default:
            return .noRetry
        }
    }
}


@Suite("Network Metrics Tests", .serialized)
struct NetworkMetricsTests {

    @Test("Metrics are reported for successful requests")
    func reportsMetricsForSuccessfulRequest() async throws {
        TestURLProtocol.reset()
        TestURLProtocol.enqueue(.success(statusCode: 200, data: Data("ok".utf8)))

        let recorder = MetricsRecorder()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        let session = URLSession(configuration: config)
        let context = NetworkRequestContext(metricsReporter: recorder)

        let request = URLRequest(url: URL(string: "https://example.com/api/metrics")!)
        _ = try await session.data(for: request, context: context)

        let reported = await waitForMetrics(recorder: recorder, count: 1)
        #expect(reported)
        let response = try #require(await recorder.lastResponse as? HTTPURLResponse)
        #expect(response.statusCode == 200)
    }

    @Test("Metrics are reported for failed requests")
    func reportsMetricsForFailedRequest() async throws {
        TestURLProtocol.reset()
        TestURLProtocol.enqueue(.failure(URLError(.timedOut)))

        let recorder = MetricsRecorder()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        let session = URLSession(configuration: config)
        let context = NetworkRequestContext(metricsReporter: recorder)

        let request = URLRequest(url: URL(string: "https://example.com/api/metrics")!)
        await #expect(throws: URLError.self) {
            _ = try await session.data(for: request, context: context)
        }

        let reported = await waitForMetrics(recorder: recorder, count: 1)
        #expect(reported)
    }

    @Test("Metrics are reported for retried requests")
    func reportsMetricsForRetriedRequest() async throws {
        TestURLProtocol.reset()
        TestURLProtocol.enqueue(.failure(URLError(.cannotConnectToHost)))
        TestURLProtocol.enqueue(.success(statusCode: 200, data: Data(#""value""#.utf8)))

        let recorder = MetricsRecorder()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        let urlSession = URLSession(configuration: config)

        let networkConfiguration = NetworkConfiguration(
            baseURL: URL(string: "https://example.com/api")!,
            retryPolicy: RetryOncePolicy(),
            networkMonitor: nil,
            metricsReporter: recorder
        )
        let client = DefaultNetworkClient(
            configuration: networkConfiguration,
            session: urlSession
        )

        let result = try await client.request(MetricsGetRequest())
        #expect(result == "value")

        let reported = await waitForMetrics(recorder: recorder, count: 2)
        #expect(reported)
    }

    @Test("Metrics reporter is forwarded to custom URLSessionProtocol implementations")
    func metricsReporterForwardingToCustomSession() async throws {
        let probe = MetricsForwardingProbe()
        let session = MetricsAwareMockSession(probe: probe)
        let recorder = MetricsRecorder()

        let networkConfiguration = NetworkConfiguration(
            baseURL: URL(string: "https://example.com/api")!,
            retryPolicy: nil,
            networkMonitor: nil,
            metricsReporter: recorder,
            responseBodyBufferingPolicy: .buffered(maxBytes: nil)
        )

        let client = DefaultNetworkClient(
            configuration: networkConfiguration,
            session: session
        )

        let result = try await client.request(MetricsGetRequest())
        #expect(result == "forwarded")
        #expect(await probe.didReceiveReporter)
    }

    private func waitForMetrics(recorder: MetricsRecorder, count: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if await recorder.count >= count {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
}

@Suite("Network Monitor Tests")
struct NetworkMonitorTests {

    @Test("NetworkSnapshot init sets path status, interfaces, and capabilities")
    func snapshotInit() {
        let snapshot = NetworkSnapshot(
            status: .unsatisfied,
            interfaceTypes: [.wifi, .cellular],
            isExpensive: true,
            isConstrained: true,
            supportsDNS: true,
            supportsIPv4: true,
            supportsIPv6: false,
            unsatisfiedReason: .wifiDenied
        )
        #expect(snapshot.status == .unsatisfied)
        #expect(snapshot.interfaceTypes == [.wifi, .cellular])
        #expect(snapshot.isExpensive)
        #expect(snapshot.isConstrained)
        #expect(snapshot.supportsDNS)
        #expect(snapshot.supportsIPv4)
        #expect(!snapshot.supportsIPv6)
        #expect(snapshot.unsatisfiedReason == .wifiDenied)
    }

    @Test("Legacy NetworkSnapshot init keeps conservative capability defaults")
    func snapshotLegacyDefaults() {
        let snapshot = NetworkSnapshot(status: .satisfied, interfaceTypes: [.wifi])

        #expect(!snapshot.isExpensive)
        #expect(!snapshot.isConstrained)
        #expect(!snapshot.supportsDNS)
        #expect(!snapshot.supportsIPv4)
        #expect(!snapshot.supportsIPv6)
        #expect(snapshot.unsatisfiedReason == nil)
    }

    @Test("NetworkMonitoring default snapshot stream replays current state and later changes")
    func defaultSnapshotStream() async {
        let initial = NetworkSnapshot(status: .requiresConnection, interfaceTypes: [.wifi])
        let connected = NetworkSnapshot(
            status: .satisfied,
            interfaceTypes: [.cellular],
            isExpensive: true,
            supportsDNS: true,
            supportsIPv4: true
        )
        let monitor = SnapshotSequenceMonitor(initial: initial, changes: [connected])
        let stream = await monitor.snapshots()

        var received: [NetworkSnapshot] = []
        for await snapshot in stream {
            received.append(snapshot)
        }

        #expect(received == [initial, connected])
    }

    @Test("waitForChange returns nil on timeout when no network change occurs")
    func waitForChangeTimesOutReturnsNil() async {
        let monitor = NetworkMonitor()
        let snapshot = await monitor.currentSnapshot()
        let timeout: TimeInterval = 0.01
        let start = Date()
        let result = await monitor.waitForChange(from: snapshot, timeout: timeout)
        let elapsed = Date().timeIntervalSince(start)
        // Real network state can change immediately on CI/local machines.
        // If a snapshot is returned, it should represent a different state.
        if let result {
            #expect(result != snapshot)
        } else {
            // When no change is observed, this path should represent an actual timeout.
            #expect(elapsed >= timeout * 0.8)
        }
    }

    @Test("waitForChange returns different snapshot when network state differs")
    func waitForChangeDetectsDifferentSnapshot() async {
        let monitor = NetworkMonitor()
        let snapshot = await monitor.currentSnapshot()
        let result = await monitor.waitForChange(from: snapshot, timeout: 0.05)
        // If a result is returned, it must be different from the original snapshot
        if let result {
            #expect(result != snapshot)
        }
    }
}

private actor SnapshotSequenceMonitor: NetworkMonitoring {
    private let initial: NetworkSnapshot?
    private var changes: [NetworkSnapshot]

    init(initial: NetworkSnapshot?, changes: [NetworkSnapshot]) {
        self.initial = initial
        self.changes = changes
    }

    func currentSnapshot() async -> NetworkSnapshot? {
        initial
    }

    func waitForChange(
        from snapshot: NetworkSnapshot?,
        timeout: TimeInterval?
    ) async -> NetworkSnapshot? {
        _ = snapshot
        _ = timeout
        guard !changes.isEmpty else { return nil }
        return changes.removeFirst()
    }
}

@Suite("Retry Policy Tests")
struct RetryPolicyTests {

    @Test("ExponentialBackoffRetryPolicy uses base delay on first attempt")
    func backoffBaseDelay() {
        let policy = ExponentialBackoffRetryPolicy(
            maxRetries: 3,
            maxTotalRetries: 3,
            retryDelay: 1.5,
            maxDelay: 10,
            jitterRatio: 0.0,
            waitsForNetworkChanges: false,
            networkChangeTimeout: nil
        )
        let delay = policy.retryDelay(for: 0)
        #expect(delay == 1.5)
    }

    @Test("ExponentialBackoffRetryPolicy grows delay with attempts")
    func backoffGrowth() {
        let policy = ExponentialBackoffRetryPolicy(
            maxRetries: 3,
            maxTotalRetries: 3,
            retryDelay: 1.0,
            maxDelay: 10,
            jitterRatio: 0.0,
            waitsForNetworkChanges: false,
            networkChangeTimeout: nil
        )
        #expect(policy.retryDelay(for: 0) == 1.0)
        #expect(policy.retryDelay(for: 1) == 2.0)
        #expect(policy.retryDelay(for: 2) == 4.0)
    }

    @Test("ExponentialBackoffRetryPolicy caps delay at maxDelay")
    func backoffCap() {
        let policy = ExponentialBackoffRetryPolicy(
            maxRetries: 5,
            maxTotalRetries: 5,
            retryDelay: 2.0,
            maxDelay: 5.0,
            jitterRatio: 0.0,
            waitsForNetworkChanges: false,
            networkChangeTimeout: nil
        )

        #expect(policy.retryDelay(for: 0) == 2.0)
        #expect(policy.retryDelay(for: 1) == 4.0)
        #expect(policy.retryDelay(for: 2) == 5.0)
        #expect(policy.retryDelay(for: 3) == 5.0)
    }

    @Test("ExponentialBackoffRetryPolicy evaluates retryable status codes")
    func statusCodeRetryable() {
        let response = Response(
            statusCode: 503,
            data: Data(),
            request: nil,
            response: HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            )!
        )
        let policy = ExponentialBackoffRetryPolicy(
            maxRetries: 1,
            maxTotalRetries: 1,
            retryDelay: 1,
            maxDelay: 10,
            jitterRatio: 0,
            waitsForNetworkChanges: false,
            networkChangeTimeout: nil,
            idempotencyPolicy: .methodAgnostic
        )
        #expect(
            policy.shouldRetry(
                error: .statusCode(response),
                retryIndex: 0,
                request: nil,
                response: response.response
            ) == .retry
        )
    }

    @Test("ExponentialBackoffRetryPolicy never retries cancellation")
    func cancellationIsNotRetried() {
        let policy = ExponentialBackoffRetryPolicy(
            maxRetries: 3,
            maxTotalRetries: 3,
            retryDelay: 1,
            maxDelay: 10,
            jitterRatio: 0,
            waitsForNetworkChanges: false,
            networkChangeTimeout: nil,
            idempotencyPolicy: .methodAgnostic
        )

        #expect(
            policy.shouldRetry(
                error: .cancelled,
                retryIndex: 0,
                request: nil,
                response: nil
            ) == .noRetry
        )
    }

    @Test("shouldResetAttempts detects snapshot changes")
    func resetAttemptsOnSnapshotChange() {
        let policy = ExponentialBackoffRetryPolicy(
            maxRetries: 1,
            maxTotalRetries: 1,
            retryDelay: 1,
            maxDelay: 10,
            jitterRatio: 0,
            waitsForNetworkChanges: true,
            networkChangeTimeout: 0.1
        )
        let oldSnapshot = NetworkSnapshot(status: .satisfied, interfaceTypes: [.wifi])
        let newSnapshot = NetworkSnapshot(status: .satisfied, interfaceTypes: [.cellular])
        #expect(policy.shouldResetAttempts(afterNetworkChangeFrom: oldSnapshot, to: newSnapshot))
    }

    @Test(
        "ExponentialBackoffRetryPolicy delay remains monotonic and capped when jitter is disabled",
        arguments: Array(0..<100)
    )
    func backoffDelayLaw(seed: Int) {
        var rng = SeededGenerator(seed: UInt64(seed + 1))
        let baseDelay = Double(rng.nextInt(upperBound: 5) + 1)
        let maxDelay = Double(rng.nextInt(upperBound: 8) + 2)
        let policy = ExponentialBackoffRetryPolicy(
            maxRetries: 8,
            maxTotalRetries: 8,
            retryDelay: baseDelay,
            maxDelay: maxDelay,
            jitterRatio: 0.0,
            waitsForNetworkChanges: false,
            networkChangeTimeout: nil
        )

        var previous = 0.0
        for retryIndex in 0..<8 {
            let current = policy.retryDelay(for: retryIndex)
            #expect(current >= previous)
            #expect(current <= maxDelay)
            previous = current
        }
    }

    @Test(
        "ExponentialBackoffRetryPolicy stops retrying once retryIndex reaches maxRetries",
        arguments: Array(0..<100)
    )
    func retryBoundLaw(seed: Int) {
        var rng = SeededGenerator(seed: UInt64(seed + 101))
        let maxRetries = rng.nextInt(upperBound: 6) + 1
        let policy = ExponentialBackoffRetryPolicy(
            maxRetries: maxRetries,
            maxTotalRetries: maxRetries + 2,
            retryDelay: 1,
            maxDelay: 10,
            jitterRatio: 0,
            waitsForNetworkChanges: false,
            networkChangeTimeout: nil,
            idempotencyPolicy: .methodAgnostic
        )
        let response = Response(
            statusCode: 503,
            data: Data(),
            request: nil,
            response: HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            )!
        )

        for retryIndex in 0..<maxRetries {
            let decision = policy.shouldRetry(
                error: .statusCode(response),
                retryIndex: retryIndex,
                request: nil,
                response: response.response
            )
            #expect(decision != .noRetry)
        }
        let stopDecision = policy.shouldRetry(
            error: .statusCode(response),
            retryIndex: maxRetries,
            request: nil,
            response: response.response
        )
        #expect(stopDecision == .noRetry)
    }
}

private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x1234_5678_9ABC_DEF0 : seed
    }

    mutating func next() -> UInt64 {
        state = 2862933555777941757 &* state &+ 3037000493
        return state
    }

    mutating func nextInt(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(next() % UInt64(upperBound))
    }
}
