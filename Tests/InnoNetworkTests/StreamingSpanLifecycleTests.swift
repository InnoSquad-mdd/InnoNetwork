import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork

private actor StreamingSpanExporter: NetworkSpanExporting {
    private(set) var spans: [NetworkSpan] = []

    func export(_ spans: [NetworkSpan]) {
        self.spans.append(contentsOf: spans)
    }
}

private actor StreamingSpanObserverHarness: TimestampedNetworkEventObserving {
    let spanObserver: NetworkSpanObserver
    private let terminal = AsyncStream<Void>.makeStream()
    private(set) var publicResponseCount = 0

    init(spanObserver: NetworkSpanObserver) {
        self.spanObserver = spanObserver
    }

    func handle(_ event: NetworkEvent) async {
        await spanObserver.handle(event)
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
        switch event {
        case .responseReceived:
            publicResponseCount += 1
        case .requestFinished, .requestFailed:
            terminal.continuation.yield()
        default:
            break
        }
    }

    func physicalTransportCompleted(
        requestID: UUID,
        statusCode: Int,
        occurredAt: Date
    ) async {
        await spanObserver.physicalTransportCompleted(
            requestID: requestID,
            statusCode: statusCode,
            occurredAt: occurredAt
        )
    }

    func waitForTerminal() async {
        var iterator = terminal.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

private final class CompletingStreamingSpanURLProtocol: URLProtocol {
    private static let calls = OSAllocatedUnfairLock(initialState: 0)

    static var callCount: Int { calls.withLock { $0 } }

    static func reset() {
        calls.withLock { $0 = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.calls.withLock { $0 += 1 }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("event\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct ReconnectingStreamingSpanEndpoint: StreamingAPIDefinition {
    typealias Output = String

    let method = HTTPMethod.get
    let path = "events"
    let sessionAuthentication = SessionAuthentication.anonymous
    let resumePolicy = StreamingResumePolicy.serverSentEvents(
        maxAttempts: 1,
        retryDelay: 10
    )

    func decode(line: String) throws -> String? { line }
}

@Suite("Streaming Span Lifecycle", .serialized)
struct StreamingSpanLifecycleTests {
    @Test("Physical spans exclude reconnect delay without duplicating public response events")
    func physicalSpansEndBeforeReconnectDelay() async throws {
        CompletingStreamingSpanURLProtocol.reset()
        let clock = TestClock()
        let exporter = StreamingSpanExporter()
        let spanObserver = NetworkSpanObserver(exporter: exporter, now: { clock.now() })
        let observer = StreamingSpanObserverHarness(spanObserver: spanObserver)
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://stream-span.example.com")!,
            networkMonitor: nil,
            eventObservers: [observer]
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [CompletingStreamingSpanURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let runtime = RequestExecutionRuntime(
            configuration: configuration,
            inFlight: InFlightRegistry(),
            clock: clock
        )
        let eventHub = NetworkEventHub(clock: clock)
        let (sequence, sink) = StreamingOutputSequence<String>.make(buffering: .backpressured)
        let execution = Task {
            await StreamingExecutor(session: session, eventHub: eventHub).run(
                request: ReconnectingStreamingSpanEndpoint(),
                requestID: UUID(),
                configuration: configuration,
                executionRuntime: runtime,
                sink: sink
            )
        }
        let collection = Task {
            var values: [String] = []
            for try await value in sequence { values.append(value) }
            return values
        }

        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(10))
        #expect(try await collection.value == ["event", "event"])
        await execution.value
        await observer.waitForTerminal()
        await spanObserver.flush()

        let spans = await exporter.spans
        let attempts = spans.filter { $0.kind == .attempt }.sorted {
            ($0.attemptIndex ?? -1) < ($1.attemptIndex ?? -1)
        }
        let logical = try #require(spans.first { $0.kind == .request })
        #expect(CompletingStreamingSpanURLProtocol.callCount == 2)
        #expect(await observer.publicResponseCount == 2)
        #expect(attempts.map(\.outcome) == [.retried, .succeeded])
        #expect(attempts.map(\.statusCode) == [200, 200])
        #expect(attempts.map(\.duration) == [0, 0])
        #expect(logical.duration == 10)

        await eventHub.shutdown()
        await runtime.shutdown()
    }
}
