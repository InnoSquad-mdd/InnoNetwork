import Foundation
import Testing
import os

@testable import InnoNetwork

@Suite("Rate limit execution policy")
struct RateLimitExecutionPolicyTests {
    @Test("Public initializer clamps unsafe values")
    func clampsUnsafeValues() {
        let policy = RateLimitExecutionPolicy(maximumRequests: 0, per: .zero)

        #expect(policy.maximumRequests == 1)
        #expect(policy.interval == .milliseconds(1))
    }

    @Test("Copied policy values share one request budget")
    func copiedValuesShareLimiter() {
        let policy = RateLimitExecutionPolicy(maximumRequests: 2, per: .seconds(1))
        let copy = policy

        #expect(policy.limiter === copy.limiter)
    }

    @Test("Policy forwards the executor-owned request through the chain")
    func forwardsThroughPolicyChain() async throws {
        let policy = RateLimitExecutionPolicy(maximumRequests: 2, per: .seconds(1))
        let requestID = UUID()
        let url = URL(string: "https://api.example.test/rate-limited")!
        let response = try await policy.execute(
            input: RequestExecutionInput(
                request: URLRequest(url: url),
                requestID: requestID,
                retryIndex: 1
            ),
            context: RequestExecutionContext(
                requestID: requestID,
                retryIndex: 1,
                metricsReporter: nil,
                trustPolicy: .systemDefault,
                eventObservers: []
            ),
            next: RequestExecutionNext {
                Response(
                    statusCode: 202,
                    data: Data(),
                    request: URLRequest(url: url),
                    response: HTTPURLResponse(
                        url: url,
                        statusCode: 202,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )

        #expect(response.statusCode == 202)
    }

    @Test("Limiter admits only the configured count before the next window")
    func enforcesFixedWindow() async throws {
        let clock = RateLimitTestClock()
        let limiter = FixedWindowRequestLimiter(
            maximumRequests: 2,
            interval: .seconds(10),
            clock: clock
        )

        try await limiter.acquire()
        try await limiter.acquire()
        try await limiter.acquire()

        #expect(clock.sleepCount == 1)
        #expect(clock.now() == Date(timeIntervalSince1970: 10))
    }

    @Test("A waiting admission observes cancellation")
    func waitingAdmissionIsCancellationAware() async throws {
        let clock = BlockingRateLimitTestClock()
        let limiter = FixedWindowRequestLimiter(
            maximumRequests: 1,
            interval: .seconds(10),
            clock: clock
        )
        try await limiter.acquire()

        let waiting = Task { try await limiter.acquire() }
        while !clock.didBeginSleeping {
            await Task.yield()
        }
        waiting.cancel()

        await #expect(throws: CancellationError.self) {
            try await waiting.value
        }
    }
}

private final class RateLimitTestClock: InnoNetworkClock, Sendable {
    private struct State: Sendable {
        var instant = Date(timeIntervalSince1970: 0)
        var sleepCount = 0
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    var sleepCount: Int { state.withLock { $0.sleepCount } }

    func now() -> Date {
        state.withLock { $0.instant }
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        state.withLock { state in
            state.sleepCount += 1
            state.instant = state.instant.addingTimeInterval(duration.testTimeInterval)
        }
        await Task.yield()
        try Task.checkCancellation()
    }
}

private final class BlockingRateLimitTestClock: InnoNetworkClock, Sendable {
    private let sleeping = OSAllocatedUnfairLock<Bool>(initialState: false)

    var didBeginSleeping: Bool { sleeping.withLock { $0 } }

    func now() -> Date { Date(timeIntervalSince1970: 0) }

    func sleep(for duration: Duration) async throws {
        sleeping.withLock { $0 = true }
        try await Task.sleep(for: .seconds(60))
    }
}

private extension Duration {
    var testTimeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
