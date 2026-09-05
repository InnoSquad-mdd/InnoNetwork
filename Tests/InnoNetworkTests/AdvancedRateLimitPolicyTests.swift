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
        _ = await limiter.commit(try await limiter.reserve(for: request))
        _ = await limiter.commit(try await limiter.reserve(for: request))

        let third = Task { try await limiter.reserve(for: request) }
        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(1))
        let reservation = try await third.value
        #expect(reservation.wasDelayed)
        _ = await limiter.commit(reservation)
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
        _ = await limiter.commit(try await limiter.reserve(for: request))
        _ = await limiter.commit(try await limiter.reserve(for: request))

        let third = Task { try await limiter.reserve(for: request) }
        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(5))
        let reservation = try await third.value
        #expect(reservation.wasDelayed)
        _ = await limiter.commit(reservation)
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
        _ = await limiter.commit(second)
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
        _ = await limiter.commit(first)
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
        _ = await limiter.commit(reservation)
    }

    @Test("Reservations delayed behind admission are rechecked at dispatch")
    func dispatchBoundaryRechecksQuota() async throws {
        let clock = TestClock()
        let limiter = AdvancedRateLimitCoordinator(
            policy: AdvancedRateLimitPolicy(
                algorithm: .tokenBucket(capacity: 1, refillPerSecond: 1)
            ),
            clock: clock
        )
        let request = request(host: "api.example.test")
        let initial = try await limiter.reserve(for: request)
        #expect(await limiter.commit(initial) == nil)

        clock.advance(by: .seconds(1))
        let firstQueued = try await limiter.reserve(for: request)
        clock.advance(by: .seconds(1))
        let secondQueued = try await limiter.reserve(for: request)
        clock.advance(by: .seconds(8))

        #expect(await limiter.commit(firstQueued) == nil)
        #expect(await limiter.commit(secondQueued) == .seconds(1))
        clock.advance(by: .seconds(1))
        #expect(await limiter.commit(secondQueued) == nil)
    }

    @Test("Invalid numeric policies fail without sleeping or trapping")
    func invalidNumericConfiguration() async throws {
        let request = request(host: "api.example.test")
        let invalidPolicies = [
            AdvancedRateLimitPolicy(
                algorithm: .tokenBucket(capacity: 1, refillPerSecond: 0)
            ),
            AdvancedRateLimitPolicy(
                algorithm: .tokenBucket(capacity: .infinity, refillPerSecond: 1)
            ),
            AdvancedRateLimitPolicy(
                algorithm: .slidingWindow(limit: 1, interval: .zero)
            ),
            AdvancedRateLimitPolicy(
                algorithm: .tokenBucket(capacity: 1, refillPerSecond: 1),
                defaultRequestCost: .nan
            ),
        ]

        for policy in invalidPolicies {
            let limiter = AdvancedRateLimitCoordinator(policy: policy, clock: TestClock())
            await #expect(throws: RateLimitAdmissionFailure.self) {
                _ = try await limiter.reserve(for: request)
            }
        }
    }

    @Test("A request cost larger than capacity is rejected")
    func oversizedRequestCost() async throws {
        let limiter = AdvancedRateLimitCoordinator(
            policy: AdvancedRateLimitPolicy(
                algorithm: .tokenBucket(capacity: 1, refillPerSecond: 1)
            ),
            clock: TestClock()
        )

        await #expect(throws: RateLimitAdmissionFailure.self) {
            _ = try await limiter.reserve(for: request(host: "api.example.test"), cost: 2)
        }
    }

    @Test("A fully replenished inactive origin releases its scope slot")
    func dormantScopeIsReclaimed() async throws {
        let clock = TestClock()
        let limiter = AdvancedRateLimitCoordinator(
            policy: AdvancedRateLimitPolicy(
                algorithm: .tokenBucket(capacity: 1, refillPerSecond: 1),
                maximumScopes: 1
            ),
            clock: clock
        )
        let first = try await limiter.reserve(for: request(host: "a.example.test"))
        #expect(await limiter.commit(first) == nil)

        clock.advance(by: .seconds(1))
        let second = try await limiter.reserve(for: request(host: "b.example.test"))
        #expect(await limiter.commit(second) == nil)
        #expect(await limiter.snapshot.scopes == 1)
    }

    @Test("Explicit default port shares the implicit origin quota")
    func defaultPortSharesOriginQuota() async throws {
        let clock = TestClock()
        let limiter = AdvancedRateLimitCoordinator(
            policy: AdvancedRateLimitPolicy(
                algorithm: .tokenBucket(capacity: 1, refillPerSecond: 1)
            ),
            clock: clock
        )
        let implicit = URLRequest(url: URL(string: "https://API.example.test/resource")!)
        let explicit = URLRequest(url: URL(string: "https://api.example.test:443/resource")!)
        #expect(await limiter.commit(try await limiter.reserve(for: implicit)) == nil)

        let delayed = Task { try await limiter.reserve(for: explicit) }
        #expect(await clock.waitForWaiters(count: 1))
        #expect(await limiter.snapshot.scopes == 1)
        clock.advance(by: .seconds(1))
        _ = await limiter.commit(try await delayed.value)
    }

    private func request(host: String) -> URLRequest {
        URLRequest(url: URL(string: "https://\(host)/resource")!)
    }
}
