import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork

@Suite("Streaming Timeout Policy Tests", .serialized)
struct StreamingTimeoutPolicyTests {
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

private struct TotalDeadlineStream: StreamingAPIDefinition {
    typealias Output = String

    let method = HTTPMethod.get
    let path = "events"
    let sessionAuthentication = SessionAuthentication.anonymous
    let timeoutPolicy = StreamingTimeoutPolicy(total: .seconds(1))

    func decode(line: String) throws -> String? { line }
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
