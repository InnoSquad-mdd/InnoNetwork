import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork

@Suite("Streaming Timeout Policy Tests", .serialized, .timeLimit(.minutes(1)))
struct StreamingTimeoutPolicyTests {
    @Test(
        "Recoverable watchdog timeouts use the configured resume policy",
        arguments: [
            StreamingTimeoutPolicy(firstEvent: .seconds(1)),
            StreamingTimeoutPolicy(idle: .seconds(1)),
        ]
    )
    func watchdogTimeoutReconnects(policy: StreamingTimeoutPolicy) async throws {
        SilentThenSuccessfulStreamURLProtocol.reset()
        let clock = TestClock()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SilentThenSuccessfulStreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let responseSignal = StreamingResponseSignal()
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://stream-timeout.example.com")!,
            networkMonitor: nil,
            eventObservers: [responseSignal]
        )
        let runtime = RequestExecutionRuntime(
            configuration: configuration,
            inFlight: InFlightRegistry(),
            clock: clock
        )
        let eventHub = NetworkEventHub()
        let (sequence, sink) = StreamingOutputSequence<String>.make(buffering: .backpressured)
        let execution = Task {
            await StreamingExecutor(session: session, eventHub: eventHub).run(
                request: WatchdogResumeStream(timeoutPolicy: policy),
                requestID: UUID(),
                configuration: configuration,
                executionRuntime: runtime,
                sink: sink
            )
        }

        await responseSignal.waitUntilReceived()
        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(1))
        var values: [String] = []
        for try await value in sequence { values.append(value) }
        await execution.value

        #expect(values == ["resumed"])
        #expect(SilentThenSuccessfulStreamURLProtocol.callCount == 2)
        #expect(clock.waiterCount == 0)
        await eventHub.shutdown()
        await runtime.shutdown()
    }

    @Test("A total watchdog timeout never reconnects")
    func totalWatchdogTimeoutDoesNotReconnect() async throws {
        SilentThenSuccessfulStreamURLProtocol.reset()
        let clock = TestClock()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SilentThenSuccessfulStreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let responseSignal = StreamingResponseSignal()
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://stream-timeout.example.com")!,
            networkMonitor: nil,
            eventObservers: [responseSignal]
        )
        let runtime = RequestExecutionRuntime(
            configuration: configuration,
            inFlight: InFlightRegistry(),
            clock: clock
        )
        let eventHub = NetworkEventHub()
        let (sequence, sink) = StreamingOutputSequence<String>.make(buffering: .backpressured)
        let execution = Task {
            await StreamingExecutor(session: session, eventHub: eventHub).run(
                request: WatchdogResumeStream(
                    timeoutPolicy: StreamingTimeoutPolicy(total: .seconds(1))
                ),
                requestID: UUID(),
                configuration: configuration,
                executionRuntime: runtime,
                sink: sink
            )
        }

        await responseSignal.waitUntilReceived()
        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(1))
        var iterator = sequence.makeAsyncIterator()
        await #expect(throws: NetworkError.self) { _ = try await iterator.next() }
        await execution.value

        #expect(SilentThenSuccessfulStreamURLProtocol.callCount == 1)
        #expect(clock.waiterCount == 0)
        await eventHub.shutdown()
        await runtime.shutdown()
    }

    @Test("First-event budget cancels an accepted response exactly once")
    func firstEventTimeout() async throws {
        let clock = TestClock()
        let cancellationSignal = AsyncStream<Void>.makeStream()
        let cancellations = OSAllocatedUnfairLock(initialState: 0)
        let watchdog = StreamingTimeoutWatchdog(
            policy: StreamingTimeoutPolicy(firstEvent: .seconds(5)),
            logicalStart: .zero,
            clock: clock,
            cancelTransport: {
                cancellations.withLock { $0 += 1 }
                cancellationSignal.continuation.yield()
            }
        )

        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(5))
        var cancellationIterator = cancellationSignal.stream.makeAsyncIterator()
        _ = await cancellationIterator.next()

        #expect(cancellations.withLock { $0 } == 1)
        #expect(watchdog.timeoutError != nil)
        watchdog.finish()
    }

    @Test("A first event recorded after the watchdog snapshot prevents a stale timeout")
    func firstEventRevalidatesBeforeTimeoutLatch() async throws {
        let events = AsyncStream<WatchdogSnapshotRaceEvent>.makeStream()
        let clock = WatchdogSnapshotRaceClock(events: events.continuation)
        let watchdog = StreamingTimeoutWatchdog(
            policy: StreamingTimeoutPolicy(
                firstEvent: .seconds(1),
                total: .seconds(2)
            ),
            logicalStart: .zero,
            clock: clock,
            cancelTransport: { events.continuation.yield(.cancelled) }
        )

        var snapshotIterator = clock.snapshotTaken.stream.makeAsyncIterator()
        _ = await snapshotIterator.next()
        watchdog.recordFirstEvent()
        clock.releaseSnapshot()

        var eventIterator = events.stream.makeAsyncIterator()
        #expect(await eventIterator.next() == .sleepingUntilCurrentDeadline)
        #expect(watchdog.timeoutPhase == nil)
        watchdog.finish()
    }

    @Test("Byte activity recorded after the watchdog snapshot prevents a stale idle timeout")
    func activityRevalidatesBeforeTimeoutLatch() async throws {
        let events = AsyncStream<WatchdogSnapshotRaceEvent>.makeStream()
        let clock = WatchdogSnapshotRaceClock(events: events.continuation)
        let watchdog = StreamingTimeoutWatchdog(
            policy: StreamingTimeoutPolicy(
                idle: .seconds(1),
                total: .seconds(3)
            ),
            logicalStart: .zero,
            clock: clock,
            cancelTransport: { events.continuation.yield(.cancelled) }
        )

        var snapshotIterator = clock.snapshotTaken.stream.makeAsyncIterator()
        _ = await snapshotIterator.next()
        watchdog.recordNetworkActivity()
        clock.releaseSnapshot()

        var eventIterator = events.stream.makeAsyncIterator()
        #expect(await eventIterator.next() == .sleepingUntilCurrentDeadline)
        #expect(watchdog.timeoutPhase == nil)
        watchdog.finish()
    }

    @Test("Byte activity extends the idle deadline without creating a task per byte")
    func activityExtendsIdleDeadline() async throws {
        let clock = TestClock()
        let cancellationSignal = AsyncStream<Void>.makeStream()
        let cancellations = OSAllocatedUnfairLock(initialState: 0)
        let watchdog = StreamingTimeoutWatchdog(
            policy: StreamingTimeoutPolicy(idle: .seconds(5)),
            logicalStart: .zero,
            clock: clock,
            cancelTransport: {
                cancellations.withLock { $0 += 1 }
                cancellationSignal.continuation.yield()
            }
        )

        #expect(await clock.waitForEnqueuedCount(atLeast: 1))
        clock.advance(by: .seconds(4))
        watchdog.recordNetworkActivity()
        clock.advance(by: .seconds(1))
        #expect(await clock.waitForEnqueuedCount(atLeast: 2))
        #expect(cancellations.withLock { $0 } == 0)

        clock.advance(by: .seconds(4))
        var cancellationIterator = cancellationSignal.stream.makeAsyncIterator()
        _ = await cancellationIterator.next()
        #expect(cancellations.withLock { $0 } == 1)
        watchdog.finish()
    }

    @Test("A first event cannot revive an already expired deadline")
    func lateFirstEventLatchesExpiredDeadline() async throws {
        let clock = TestClock()
        let cancellationSignal = AsyncStream<Void>.makeStream()
        let watchdog = StreamingTimeoutWatchdog(
            policy: StreamingTimeoutPolicy(firstEvent: .seconds(1)),
            logicalStart: .zero,
            clock: clock,
            cancelTransport: { cancellationSignal.continuation.yield() }
        )

        #expect(await clock.waitForWaiters(count: 1))
        clock.advanceWithoutResuming(by: .seconds(2))
        watchdog.recordFirstEvent()
        var cancellationIterator = cancellationSignal.stream.makeAsyncIterator()
        _ = await cancellationIterator.next()

        #expect(watchdog.timeoutPhase == .firstEvent)
        watchdog.finish()
    }

    @Test("Late byte activity cannot extend an already expired idle deadline")
    func lateActivityLatchesExpiredIdleDeadline() async throws {
        let clock = TestClock()
        let cancellationSignal = AsyncStream<Void>.makeStream()
        let watchdog = StreamingTimeoutWatchdog(
            policy: StreamingTimeoutPolicy(idle: .seconds(1)),
            logicalStart: .zero,
            clock: clock,
            cancelTransport: { cancellationSignal.continuation.yield() }
        )

        #expect(await clock.waitForWaiters(count: 1))
        clock.advanceWithoutResuming(by: .seconds(2))
        watchdog.recordNetworkActivity()
        var cancellationIterator = cancellationSignal.stream.makeAsyncIterator()
        _ = await cancellationIterator.next()

        #expect(watchdog.timeoutPhase == .idle)
        watchdog.finish()
    }

    @Test("Total budget is measured from the logical request start")
    func totalBudgetDoesNotResetAtAcceptance() async throws {
        let clock = TestClock()
        clock.advance(by: .seconds(3))
        let cancellationSignal = AsyncStream<Void>.makeStream()
        let cancellations = OSAllocatedUnfairLock(initialState: 0)
        let watchdog = StreamingTimeoutWatchdog(
            policy: StreamingTimeoutPolicy(total: .seconds(5)),
            logicalStart: .zero,
            clock: clock,
            cancelTransport: {
                cancellations.withLock { $0 += 1 }
                cancellationSignal.continuation.yield()
            }
        )

        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(2))
        var cancellationIterator = cancellationSignal.stream.makeAsyncIterator()
        _ = await cancellationIterator.next()
        #expect(cancellations.withLock { $0 } == 1)
        watchdog.finish()
    }

    @Test("Total budget expires while a stream is waiting for local quota")
    func totalBudgetIncludesRateLimitAdmission() async throws {
        let clock = TestClock()
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://example.com")!,
            networkMonitor: nil,
            advancedRateLimitPolicy: AdvancedRateLimitPolicy(
                algorithm: .tokenBucket(capacity: 1, refillPerSecond: 0.1)
            )
        )
        let runtime = RequestExecutionRuntime(
            configuration: configuration,
            inFlight: InFlightRegistry(),
            clock: clock
        )
        let quotaRequest = URLRequest(url: URL(string: "https://example.com/events")!)
        let reservation = try #require(try await runtime.rateLimit?.reserve(for: quotaRequest))
        #expect(await runtime.rateLimit?.commit(reservation) == nil)

        let (sequence, sink) = StreamingOutputSequence<String>.make(buffering: .backpressured)
        let executor = StreamingExecutor(session: MockURLSession(), eventHub: NetworkEventHub())
        let execution = Task {
            await executor.run(
                request: TotalDeadlineStream(),
                requestID: UUID(),
                configuration: configuration,
                executionRuntime: runtime,
                sink: sink
            )
        }

        #expect(await clock.waitForWaiters(count: 2))
        clock.advance(by: .seconds(1))

        var iterator = sequence.makeAsyncIterator()
        await #expect(throws: NetworkError.self) {
            _ = try await iterator.next()
        }
        await execution.value
        #expect(clock.waiterCount == 0)
    }

    @Test("Total budget bounds the initial network snapshot")
    func totalBudgetIncludesInitialNetworkSnapshot() async throws {
        let clock = TestClock()
        let monitor = HeldStreamingNetworkMonitor(holdsInitialSnapshot: true)
        let session = FailingStreamingTimeoutSession()
        let configuration = streamingTimeoutConfiguration(monitor: monitor)
        let runtime = RequestExecutionRuntime(
            configuration: configuration,
            inFlight: InFlightRegistry(),
            clock: clock
        )
        let (sequence, sink) = StreamingOutputSequence<String>.make(buffering: .backpressured)
        let eventHub = NetworkEventHub()
        let executor = StreamingExecutor(session: session, eventHub: eventHub)
        let execution = Task {
            await executor.run(
                request: TotalDeadlineStream(),
                requestID: UUID(),
                configuration: configuration,
                executionRuntime: runtime,
                sink: sink
            )
        }

        var entries = monitor.entries.makeAsyncIterator()
        #expect(await entries.next() == .initialSnapshot)
        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(1))

        var iterator = sequence.makeAsyncIterator()
        await #expect(throws: NetworkError.self) {
            _ = try await iterator.next()
        }
        await execution.value
        #expect(session.bytesCallCount == 0)
        #expect(!monitor.hasOutstandingWait)
        #expect(clock.waiterCount == 0)
        await eventHub.shutdown()
        await runtime.shutdown()
    }

    @Test("Total budget bounds retry network-change waiting")
    func totalBudgetIncludesNetworkChangeWait() async throws {
        let clock = TestClock()
        let monitor = HeldStreamingNetworkMonitor(holdsInitialSnapshot: false)
        let session = FailingStreamingTimeoutSession()
        let configuration = streamingTimeoutConfiguration(monitor: monitor)
        let runtime = RequestExecutionRuntime(
            configuration: configuration,
            inFlight: InFlightRegistry(),
            clock: clock
        )
        let (sequence, sink) = StreamingOutputSequence<String>.make(buffering: .backpressured)
        let eventHub = NetworkEventHub()
        let executor = StreamingExecutor(session: session, eventHub: eventHub)
        let execution = Task {
            await executor.run(
                request: TotalDeadlineStream(),
                requestID: UUID(),
                configuration: configuration,
                executionRuntime: runtime,
                sink: sink
            )
        }

        var entries = monitor.entries.makeAsyncIterator()
        #expect(await entries.next() == .networkChange)
        #expect(await clock.waitForWaiters(count: 1))
        #expect(monitor.lastNetworkChangeTimeout == 1)
        clock.advance(by: .seconds(1))

        var iterator = sequence.makeAsyncIterator()
        await #expect(throws: NetworkError.self) {
            _ = try await iterator.next()
        }
        await execution.value
        #expect(session.bytesCallCount == 1)
        #expect(!monitor.hasOutstandingWait)
        #expect(clock.waiterCount == 0)
        await eventHub.shutdown()
        await runtime.shutdown()
    }

    @Test("Total timeout surfaces before a noncooperative interceptor returns")
    func totalTimeoutDoesNotWaitForInterceptorCompletion() async throws {
        let clock = TestClock()
        let gate = HeldStreamingInterceptorGate()
        let laterInterceptor = CountingStreamingRequestInterceptor()
        let session = MockURLSession()
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://example.com")!,
            networkMonitor: nil,
            requestInterceptors: [
                HeldStreamingRequestInterceptor(gate: gate),
                laterInterceptor,
            ]
        )
        let runtime = RequestExecutionRuntime(
            configuration: configuration,
            inFlight: InFlightRegistry(),
            clock: clock
        )
        let eventHub = NetworkEventHub()
        let (sequence, sink) = StreamingOutputSequence<String>.make(buffering: .backpressured)
        let executor = StreamingExecutor(session: session, eventHub: eventHub)
        let execution = Task {
            await executor.run(
                request: TotalDeadlineStream(),
                requestID: UUID(),
                configuration: configuration,
                executionRuntime: runtime,
                sink: sink
            )
        }

        await gate.waitUntilEntered()
        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(1))
        await gate.waitUntilCancelled()

        var iterator = sequence.makeAsyncIterator()
        await #expect(throws: NetworkError.self) {
            _ = try await iterator.next()
        }
        await execution.value
        #expect(session.capturedRequestsInOrder.isEmpty)

        await gate.release()
        await gate.waitUntilReturned()
        #expect(laterInterceptor.callCount == 0)
        #expect(session.capturedRequestsInOrder.isEmpty)
        await eventHub.shutdown()
        await runtime.shutdown()
    }

    @Test("A timed-out signer chain stops before its next signer")
    func totalTimeoutStopsSignerChain() async throws {
        let clock = TestClock()
        let gate = HeldStreamingInterceptorGate()
        let laterSigner = CountingStreamingRequestSigner()
        let session = MockURLSession()
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://example.com")!,
            networkMonitor: nil,
            requestSigners: [
                HeldStreamingRequestSigner(gate: gate),
                laterSigner,
            ]
        )
        let runtime = RequestExecutionRuntime(
            configuration: configuration,
            inFlight: InFlightRegistry(),
            clock: clock
        )
        let eventHub = NetworkEventHub()
        let (sequence, sink) = StreamingOutputSequence<String>.make(buffering: .backpressured)
        let execution = Task {
            await StreamingExecutor(session: session, eventHub: eventHub).run(
                request: TotalDeadlineStream(),
                requestID: UUID(),
                configuration: configuration,
                executionRuntime: runtime,
                sink: sink
            )
        }

        await gate.waitUntilEntered()
        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(1))
        var iterator = sequence.makeAsyncIterator()
        await #expect(throws: NetworkError.self) { _ = try await iterator.next() }
        await execution.value
        await gate.release()
        await gate.waitUntilReturned()

        #expect(laterSigner.callCount == 0)
        #expect(session.capturedRequestsInOrder.isEmpty)
        await eventHub.shutdown()
        await runtime.shutdown()
    }

    @Test("A timed-out token provider stops before request signing")
    func totalTimeoutStopsAfterTokenProvider() async throws {
        let clock = TestClock()
        let gate = HeldStreamingInterceptorGate()
        let signer = CountingStreamingRequestSigner()
        let session = MockURLSession()
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://example.com")!,
            networkMonitor: nil,
            requestSigners: [signer],
            refreshTokenPolicy: RefreshTokenPolicy(
                currentToken: {
                    await gate.wait()
                    return "late-token"
                },
                refreshToken: { "refreshed-token" }
            )
        )
        let runtime = RequestExecutionRuntime(
            configuration: configuration,
            inFlight: InFlightRegistry(),
            clock: clock
        )
        let eventHub = NetworkEventHub()
        let (sequence, sink) = StreamingOutputSequence<String>.make(buffering: .backpressured)
        let execution = Task {
            await StreamingExecutor(session: session, eventHub: eventHub).run(
                request: OptionalAuthTotalDeadlineStream(),
                requestID: UUID(),
                configuration: configuration,
                executionRuntime: runtime,
                sink: sink
            )
        }

        await gate.waitUntilEntered()
        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(1))
        var iterator = sequence.makeAsyncIterator()
        await #expect(throws: NetworkError.self) { _ = try await iterator.next() }
        await execution.value
        await gate.release()
        await gate.waitUntilReturned()

        #expect(signer.callCount == 0)
        #expect(session.capturedRequestsInOrder.isEmpty)
        await eventHub.shutdown()
        await runtime.shutdown()
    }

    @Test("A response completed after its absolute first-response deadline is discarded")
    func lateFirstResponseCannotWinDelayedTimer() async throws {
        let clock = TestClock()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ImmediateStreamingTimeoutURLProtocol.self]
        let urlSession = URLSession(configuration: sessionConfiguration)
        defer { urlSession.invalidateAndCancel() }
        let session = LateFirstResponseSession(session: urlSession, clock: clock)
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://stream-timeout.example.com")!,
            networkMonitor: nil
        )
        let runtime = RequestExecutionRuntime(
            configuration: configuration,
            inFlight: InFlightRegistry(),
            clock: clock
        )
        let eventHub = NetworkEventHub()
        let (sequence, sink) = StreamingOutputSequence<String>.make(buffering: .backpressured)
        let execution = Task {
            await StreamingExecutor(session: session, eventHub: eventHub).run(
                request: AbsoluteFirstResponseDeadlineStream(),
                requestID: UUID(),
                configuration: configuration,
                executionRuntime: runtime,
                sink: sink
            )
        }

        var iterator = sequence.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("Expected the response that completed at two seconds to time out")
        } catch {
            guard case .timeout(.requestTimeout, _) = error else {
                Issue.record("Expected the first-response timeout, got \(error)")
                await execution.value
                return
            }
        }
        await execution.value

        #expect(clock.monotonicNow() == .seconds(2))
        #expect(clock.waiterCount == 0)
        await eventHub.shutdown()
        await runtime.shutdown()
    }

    @Test("An explicit first-response deadline remains terminal when retry is enabled")
    func firstResponseDeadlineDoesNotEnterHandshakeRetry() async throws {
        let clock = TestClock()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ImmediateStreamingTimeoutURLProtocol.self]
        let urlSession = URLSession(configuration: sessionConfiguration)
        defer { urlSession.invalidateAndCancel() }
        let session = LateFirstResponseSession(session: urlSession, clock: clock)
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://stream-timeout.example.com")!,
            retryPolicy: ExponentialBackoffRetryPolicy(
                maxRetries: 1,
                retryDelay: 0,
                maxDelay: 0,
                jitterRatio: 0
            ),
            networkMonitor: nil
        )
        let client = DefaultNetworkClient(
            configuration: configuration,
            session: session,
            clock: clock
        )

        var iterator = client.stream(AbsoluteFirstResponseDeadlineStream()).makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("Expected the first-response deadline to remain terminal")
        } catch {
            guard case .timeout(.requestTimeout, _) = error else {
                Issue.record("Expected the first-response timeout, got \(error)")
                await client.shutdown()
                return
            }
        }

        #expect(session.bytesCallCount == 1)
        await client.shutdown()
    }

    @Test("Control-only EOF cannot complete after the absolute total deadline")
    func controlOnlyEOFCannotBypassTotalDeadline() async throws {
        let clock = TestClock()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ImmediateStreamingTimeoutURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://stream-timeout.example.com")!,
            networkMonitor: nil
        )
        let client = DefaultNetworkClient(
            configuration: configuration,
            session: session,
            clock: clock
        )

        var iterator = client.stream(
            LateControlOnlyEOFStream(clock: clock)
        ).makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("Expected control-only EOF after the total deadline to time out")
        } catch {
            guard case .timeout(.resourceTimeout, _) = error else {
                Issue.record("Expected the total timeout, got \(error)")
                await client.shutdown()
                return
            }
        }

        #expect(clock.monotonicNow() == .seconds(2))
        await client.shutdown()
    }

    private func streamingTimeoutConfiguration(
        monitor: any NetworkMonitoring
    ) -> NetworkConfiguration {
        NetworkConfiguration(
            baseURL: URL(string: "https://example.com")!,
            retryPolicy: ExponentialBackoffRetryPolicy(
                maxRetries: 1,
                maxTotalRetries: 1,
                retryDelay: 0,
                jitterRatio: 0,
                waitsForNetworkChanges: true,
                networkChangeTimeout: nil
            ),
            networkMonitor: monitor
        )
    }
}

private actor HeldStreamingInterceptorGate {
    let entered = AsyncStream<Void>.makeStream()
    let cancelled = AsyncStream<Void>.makeStream()
    let returned = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered.continuation.yield()
            }
        } onCancel: {
            cancelled.continuation.yield()
        }
        returned.continuation.yield()
    }

    func waitUntilEntered() async {
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func waitUntilCancelled() async {
        var iterator = cancelled.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func waitUntilReturned() async {
        var iterator = returned.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private enum WatchdogSnapshotRaceEvent: Sendable, Equatable {
    case sleepingUntilCurrentDeadline
    case cancelled
}

private final class WatchdogSnapshotRaceClock: InnoNetworkClock, Sendable {
    let snapshotTaken = AsyncStream<Void>.makeStream()

    private let reads = OSAllocatedUnfairLock(initialState: 0)
    private let snapshotRelease = DispatchSemaphore(value: 0)
    private let events: AsyncStream<WatchdogSnapshotRaceEvent>.Continuation

    init(events: AsyncStream<WatchdogSnapshotRaceEvent>.Continuation) {
        self.events = events
    }

    func now() -> Date { Date(timeIntervalSince1970: monotonicNow().timeInterval) }

    func monotonicNow() -> Duration {
        let read = reads.withLock { reads in
            reads += 1
            return reads
        }
        if read == 2 {
            snapshotTaken.continuation.yield()
            snapshotRelease.wait()
            return .seconds(1)
        }
        if read == 3 { return .milliseconds(500) }
        return read > 2 ? .seconds(1) : .zero
    }

    func sleep(for duration: Duration) async throws {
        _ = duration
        events.yield(.sleepingUntilCurrentDeadline)
        try await Task.sleep(for: .seconds(60))
    }

    func releaseSnapshot() {
        snapshotRelease.signal()
    }
}

private final class CountingStreamingRequestInterceptor: RequestInterceptor, Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    var callCount: Int { count.withLock { $0 } }

    func adapt(_ request: URLRequest) async throws -> URLRequest {
        count.withLock { $0 += 1 }
        return request
    }
}

private struct HeldStreamingRequestSigner: RequestSigner {
    let gate: HeldStreamingInterceptorGate

    func signatureHeaders(for request: URLRequest, body: RequestBody) async throws -> HTTPHeaders {
        _ = (request, body)
        await gate.wait()
        return HTTPHeaders()
    }
}

private final class CountingStreamingRequestSigner: RequestSigner, Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    var callCount: Int { count.withLock { $0 } }

    func signatureHeaders(for request: URLRequest, body: RequestBody) async throws -> HTTPHeaders {
        _ = (request, body)
        count.withLock { $0 += 1 }
        return HTTPHeaders()
    }
}

private struct HeldStreamingRequestInterceptor: RequestInterceptor {
    let gate: HeldStreamingInterceptorGate

    func adapt(_ request: URLRequest) async throws -> URLRequest {
        await gate.wait()
        return request
    }
}

private struct TotalDeadlineStream: StreamingAPIDefinition {
    typealias Output = String

    let method = HTTPMethod.get
    let path = "events"
    let sessionAuthentication = SessionAuthentication.anonymous
    let timeoutPolicy = StreamingTimeoutPolicy(total: .seconds(1))

    func decode(line: String) throws -> String? { line }
}

private struct OptionalAuthTotalDeadlineStream: StreamingAPIDefinition {
    typealias Output = String

    let method = HTTPMethod.get
    let path = "events"
    let sessionAuthentication = SessionAuthentication.optional
    let timeoutPolicy = StreamingTimeoutPolicy(total: .seconds(1))

    func decode(line: String) throws -> String? { line }
}

private struct WatchdogResumeStream: StreamingAPIDefinition {
    typealias Output = String

    let method = HTTPMethod.get
    let path = "events"
    let sessionAuthentication = SessionAuthentication.anonymous
    let timeoutPolicy: StreamingTimeoutPolicy
    let resumePolicy = StreamingResumePolicy.serverSentEvents(
        maxAttempts: 1,
        retryDelay: 0,
        reconnectOnEOF: false
    )

    func decode(line: String) throws -> String? { line.isEmpty ? nil : line }
}

private struct AbsoluteFirstResponseDeadlineStream: StreamingAPIDefinition {
    typealias Output = String

    let method = HTTPMethod.get
    let path = "events"
    let sessionAuthentication = SessionAuthentication.anonymous
    let timeoutPolicy = StreamingTimeoutPolicy(firstResponse: .seconds(1))

    func decode(line: String) throws -> String? { line }
}

private struct LateControlOnlyEOFStream: StreamingAPIDefinition {
    typealias Output = String

    let method = HTTPMethod.get
    let path = "events"
    let sessionAuthentication = SessionAuthentication.anonymous
    let timeoutPolicy = StreamingTimeoutPolicy(total: .seconds(1))
    let clock: TestClock

    func decode(line: String) throws -> String? {
        clock.advanceWithoutResuming(by: .seconds(2))
        return nil
    }
}

private final class LateFirstResponseSession: URLSessionProtocol, Sendable {
    let session: URLSession
    let clock: TestClock
    private let callCount = OSAllocatedUnfairLock(initialState: 0)

    var bytesCallCount: Int { callCount.withLock { $0 } }

    init(session: URLSession, clock: TestClock) {
        self.session = session
        self.clock = clock
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    func bytes(for request: URLRequest, context: NetworkRequestContext) async throws -> (
        URLSession.AsyncBytes, URLResponse
    ) {
        callCount.withLock { $0 += 1 }
        let result = try await session.bytes(for: request, context: context)
        clock.advanceWithoutResuming(by: .seconds(2))
        return result
    }
}

private final class ImmediateStreamingTimeoutURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("late\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class SilentThenSuccessfulStreamURLProtocol: URLProtocol {
    private static let calls = OSAllocatedUnfairLock(initialState: 0)

    static var callCount: Int { calls.withLock { $0 } }

    static func reset() {
        calls.withLock { $0 = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let count = Self.calls.withLock { calls in
            calls += 1
            return calls
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if count > 1 {
            client?.urlProtocol(self, didLoad: Data("resumed\n".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private actor StreamingResponseSignal: NetworkEventObserving {
    private var received = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func handle(_ event: NetworkEvent) async {
        guard case .responseReceived = event else { return }
        received = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending { waiter.resume() }
    }

    func waitUntilReceived() async {
        if received { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class FailingStreamingTimeoutSession: URLSessionProtocol, Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    var bytesCallCount: Int { count.withLock { $0 } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        _ = request
        throw URLError(.notConnectedToInternet)
    }

    func bytes(for request: URLRequest, context: NetworkRequestContext) async throws -> (
        URLSession.AsyncBytes, URLResponse
    ) {
        _ = (request, context)
        count.withLock { $0 += 1 }
        throw URLError(.notConnectedToInternet)
    }
}

private final class HeldStreamingNetworkMonitor: NetworkMonitoring, @unchecked Sendable {
    enum Entry: Sendable, Equatable {
        case initialSnapshot
        case networkChange
    }

    private struct State {
        var continuation: CheckedContinuation<NetworkSnapshot?, Never>?
        var holdsInitialSnapshot: Bool
        var lastNetworkChangeTimeout: TimeInterval?
    }

    let entries: AsyncStream<Entry>
    private let entryContinuation: AsyncStream<Entry>.Continuation
    private let state: OSAllocatedUnfairLock<State>

    init(holdsInitialSnapshot: Bool) {
        let pair = AsyncStream<Entry>.makeStream(bufferingPolicy: .unbounded)
        entries = pair.stream
        entryContinuation = pair.continuation
        state = OSAllocatedUnfairLock(
            initialState: State(
                continuation: nil,
                holdsInitialSnapshot: holdsInitialSnapshot,
                lastNetworkChangeTimeout: nil
            )
        )
    }

    var hasOutstandingWait: Bool {
        state.withLock { $0.continuation != nil }
    }

    var lastNetworkChangeTimeout: TimeInterval? {
        state.withLock { $0.lastNetworkChangeTimeout }
    }

    func currentSnapshot() async -> NetworkSnapshot? {
        let shouldHold = state.withLock { state in
            guard state.holdsInitialSnapshot else { return false }
            state.holdsInitialSnapshot = false
            return true
        }
        guard shouldHold else { return nil }
        entryContinuation.yield(.initialSnapshot)
        return await suspendUntilCancelled()
    }

    func waitForChange(
        from snapshot: NetworkSnapshot?,
        timeout: TimeInterval?
    ) async -> NetworkSnapshot? {
        _ = snapshot
        state.withLock { $0.lastNetworkChangeTimeout = timeout }
        entryContinuation.yield(.networkChange)
        return await suspendUntilCancelled()
    }

    func snapshots() async -> AsyncStream<NetworkSnapshot> {
        AsyncStream { $0.finish() }
    }

    private func suspendUntilCancelled() async -> NetworkSnapshot? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResume = state.withLock { state in
                    if Task.isCancelled { return true }
                    state.continuation = continuation
                    return false
                }
                if shouldResume { continuation.resume(returning: nil) }
            }
        } onCancel: {
            let continuation = self.state.withLock { state in
                let continuation = state.continuation
                state.continuation = nil
                return continuation
            }
            continuation?.resume(returning: nil)
        }
    }
}
