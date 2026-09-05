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
}
