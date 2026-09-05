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
        let cancellations = OSAllocatedUnfairLock(initialState: 0)
        let watchdog = StreamingTimeoutWatchdog(
            policy: StreamingTimeoutPolicy(firstEvent: .seconds(5)),
            logicalStart: .zero,
            clock: clock,
            cancelTransport: { cancellations.withLock { $0 += 1 } }
        )

        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(5))
        await Task.yield()

        #expect(cancellations.withLock { $0 } == 1)
        #expect(watchdog.timeoutError != nil)
        watchdog.finish()
    }

    @Test("Byte activity extends the idle deadline without creating a task per byte")
    func activityExtendsIdleDeadline() async throws {
        let clock = TestClock()
        let cancellations = OSAllocatedUnfairLock(initialState: 0)
        let watchdog = StreamingTimeoutWatchdog(
            policy: StreamingTimeoutPolicy(idle: .seconds(5)),
            logicalStart: .zero,
            clock: clock,
            cancelTransport: { cancellations.withLock { $0 += 1 } }
        )

        #expect(await clock.waitForEnqueuedCount(atLeast: 1))
        clock.advance(by: .seconds(4))
        watchdog.recordNetworkActivity()
        clock.advance(by: .seconds(1))
        #expect(await clock.waitForEnqueuedCount(atLeast: 2))
        #expect(cancellations.withLock { $0 } == 0)

        clock.advance(by: .seconds(4))
        await Task.yield()
        #expect(cancellations.withLock { $0 } == 1)
        watchdog.finish()
    }

    @Test("Total budget is measured from the logical request start")
    func totalBudgetDoesNotResetAtAcceptance() async throws {
        let clock = TestClock()
        clock.advance(by: .seconds(3))
        let cancellations = OSAllocatedUnfairLock(initialState: 0)
        let watchdog = StreamingTimeoutWatchdog(
            policy: StreamingTimeoutPolicy(total: .seconds(5)),
            logicalStart: .zero,
            clock: clock,
            cancelTransport: { cancellations.withLock { $0 += 1 } }
        )

        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(2))
        for _ in 0..<20 where cancellations.withLock({ $0 }) == 0 {
            await Task.yield()
        }
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
}

private struct TotalDeadlineStream: StreamingAPIDefinition {
    typealias Output = String

    let method = HTTPMethod.get
    let path = "events"
    let sessionAuthentication = SessionAuthentication.anonymous
    let timeoutPolicy = StreamingTimeoutPolicy(total: .seconds(1))

    func decode(line: String) throws -> String? { line }
}
