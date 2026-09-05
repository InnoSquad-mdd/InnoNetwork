import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

@Suite("Advanced Rate Limit Policy Tests", .serialized)
struct AdvancedRateLimitPolicyTests {
    @Test("Token bucket never exceeds capacity plus monotonic refill")
    func tokenBucketEnvelope() async throws {
        let clock = TestClock()
        let limiter = AdvancedRateLimitCoordinator(
            policy: AdvancedRateLimitPolicy(
                algorithm: .tokenBucket(capacity: 2, refillPerSecond: 1)
            ),
            clock: clock
        )
        let request = request(host: "api.example.test")
        await limiter.commit(try await limiter.reserve(for: request))
        await limiter.commit(try await limiter.reserve(for: request))

        let third = Task { try await limiter.reserve(for: request) }
        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(1))
        let reservation = try await third.value
        #expect(reservation.wasDelayed)
        await limiter.commit(reservation)
    }

    @Test("Sliding window admits no more than its weighted limit")
    func slidingWindowInvariant() async throws {
        let clock = TestClock()
        let limiter = AdvancedRateLimitCoordinator(
            policy: AdvancedRateLimitPolicy(
                algorithm: .slidingWindow(limit: 2, interval: .seconds(5))
            ),
            clock: clock
        )
        let request = request(host: "api.example.test")
        await limiter.commit(try await limiter.reserve(for: request))
        await limiter.commit(try await limiter.reserve(for: request))

        let third = Task { try await limiter.reserve(for: request) }
        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(5))
        let reservation = try await third.value
        #expect(reservation.wasDelayed)
        await limiter.commit(reservation)
    }

    @Test("A pre-dispatch refund restores capacity")
    func refundBeforeDispatch() async throws {
        let limiter = AdvancedRateLimitCoordinator(
            policy: AdvancedRateLimitPolicy(
                algorithm: .tokenBucket(capacity: 1, refillPerSecond: 0.01)
            ),
            clock: TestClock()
        )
        let request = request(host: "api.example.test")
        let first = try await limiter.reserve(for: request)
        await limiter.refund(first)

        let second = try await limiter.reserve(for: request)
        #expect(!second.wasDelayed)
        await limiter.commit(second)
    }

    @Test("Draft-11 zero remaining feedback applies a bounded cooldown")
    func draftFeedbackCooldown() async throws {
        let clock = TestClock()
        let limiter = AdvancedRateLimitCoordinator(
            policy: AdvancedRateLimitPolicy(
                algorithm: .tokenBucket(capacity: 10, refillPerSecond: 10),
                serverFeedback: .ietfDraft11(maximumDelay: 3)
            ),
            clock: clock
        )
        let request = request(host: "api.example.test")
        let first = try await limiter.reserve(for: request)
        await limiter.commit(first)
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["RateLimit": "\"default\";r=0;t=30"]
            )
        )
        await limiter.observe(response: response, for: request)

        let next = Task { try await limiter.reserve(for: request) }
        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(3))
        let reservation = try await next.value
        #expect(reservation.wasDelayed)
        await limiter.commit(reservation)
    }

    private func request(host: String) -> URLRequest {
        URLRequest(url: URL(string: "https://\(host)/resource")!)
    }
}
