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
        await limiter.observe(response: response, for: request, reservation: first)

        let next = Task { try await limiter.reserve(for: request) }
        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(3))
        let reservation = try await next.value
        #expect(reservation.wasDelayed)
        _ = await limiter.commit(reservation)
    }

    @Test("Draft-11 uses the first policy in a multi-policy field")
    func draftFeedbackUsesFirstPolicy() throws {
        let response = try #require(
            HTTPURLResponse(
                url: URL(string: "https://api.example.test")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["RateLimit": "\"primary\";r=0;t=60, \"secondary\";r=0;t=1"]
            )
        )

        #expect(RateLimitHeaderAdapterV11.cooldown(response: response, maximumDelay: 120) == 60)
    }

    @Test("Draft-11 does not parse parameters embedded in the policy name")
    func draftFeedbackIgnoresQuotedParameterLookalikes() throws {
        let response = try #require(
            HTTPURLResponse(
                url: URL(string: "https://api.example.test")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["RateLimit": "\"primary;r=0;t=60;garbage\""]
            )
        )

        #expect(RateLimitHeaderAdapterV11.cooldown(response: response, maximumDelay: 120) == nil)
    }

    @Test("Draft-11 ignores a field containing a malformed list member")
    func draftFeedbackRejectsMalformedList() throws {
        let response = try #require(
            HTTPURLResponse(
                url: URL(string: "https://api.example.test")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["RateLimit": "\"primary\";r=0;t=60, malformed"]
            )
        )

        #expect(RateLimitHeaderAdapterV11.cooldown(response: response, maximumDelay: 120) == nil)
    }

    @Test("Draft-11 rejects invalid Structured Field boundaries")
    func draftFeedbackRejectsInvalidStructuredFields() throws {
        let invalidFields = [
            "\"primary\";r =0;t=60",
            "\"primary\" ;r=0;t=60",
            "\"primary\";r=0;t=60;vendor=1000000000000000",
            "\"primary\";r=0;t=60;vendor-date=@1000000000000000",
            "\"primary\";r=0;t=60;vendor=é",
            "\"primary\";r=0;t=60;pk=:a:",
            "\"primary\";r=0;t=60,\"secondary\";t=1",
        ]

        for field in invalidFields {
            let response = try #require(
                HTTPURLResponse(
                    url: URL(string: "https://api.example.test")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["RateLimit": field]
                )
            )
            #expect(
                RateLimitHeaderAdapterV11.cooldown(response: response, maximumDelay: 120) == nil,
                "Expected the complete field to be ignored: \(field)"
            )
        }
    }

    @Test("Draft-11 accepts valid extension item types and last duplicate values")
    func draftFeedbackAcceptsStructuredFieldExtensions() throws {
        let fields = [
            "\"primary\";r=0;t=60;vendor-date=@999999999999999;vendor-past=@-999999999999999;vendor-label=%\"ready%20soon\"",
            "\"primary\";r=0;t=60;vendor-label=%\"path\\\\\"",
            "\"primary\";r=5;r=0;t=60;pk=:dHJpYWw=:",
            "\"primary\";  r=0; t=60",
        ]

        for field in fields {
            let response = try #require(
                HTTPURLResponse(
                    url: URL(string: "https://api.example.test")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["RateLimit": field]
                )
            )
            #expect(
                RateLimitHeaderAdapterV11.cooldown(response: response, maximumDelay: 120) == 60,
                "Expected valid extension parameters to be ignored: \(field)"
            )
        }
    }

    @Test("Retry-After takes precedence over draft-11 feedback")
    func retryAfterTakesPrecedenceOverDraftFeedback() async throws {
        let clock = TestClock()
        let limiter = AdvancedRateLimitCoordinator(
            policy: AdvancedRateLimitPolicy(
                algorithm: .tokenBucket(capacity: 10, refillPerSecond: 10),
                serverFeedback: .ietfDraft11(maximumDelay: 120)
            ),
            clock: clock
        )
        let request = request(host: "api.example.test")
        let first = try await limiter.reserve(for: request)
        #expect(await limiter.commit(first) == nil)
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: [
                    "RateLimit": "\"default\";r=0;t=1",
                    "Retry-After": "60",
                ]
            )
        )
        await limiter.observe(response: response, for: request, reservation: first)

        let next = Task { try await limiter.reserve(for: request) }
        #expect(await clock.waitForWaiters(count: 1))
        clock.advance(by: .seconds(1))
        #expect(await limiter.snapshot.pending == 1)

        clock.advance(by: .seconds(59))
        let reservation = try await next.value
        #expect(reservation.wasDelayed)
        #expect(await limiter.commit(reservation) == nil)
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
        await limiter.finish(first)

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

    @Test("A dormant-scope prune cannot evict a suspended token-bucket waiter")
    func tokenBucketWaiterRetainsScope() async throws {
        try await verifySuspendedWaiterRetainsScope(
            algorithm: .tokenBucket(capacity: 1, refillPerSecond: 1),
            elapsed: .seconds(1)
        )
    }

    @Test("A dormant-scope prune cannot evict a suspended sliding-window waiter")
    func slidingWindowWaiterRetainsScope() async throws {
        try await verifySuspendedWaiterRetainsScope(
            algorithm: .slidingWindow(limit: 1, interval: .seconds(1)),
            elapsed: .seconds(1)
        )
    }

    @Test("Cancelling a suspended reservation releases its scope lifetime")
    func cancellationReleasesScopeLifetime() async throws {
        let clock = TestClock()
        let limiter = AdvancedRateLimitCoordinator(
            policy: AdvancedRateLimitPolicy(
                algorithm: .tokenBucket(capacity: 1, refillPerSecond: 1),
                maximumScopes: 1
            ),
            clock: clock
        )
        let firstRequest = request(host: "a.example.test")
        let first = try await limiter.reserve(for: firstRequest)
        #expect(await limiter.commit(first) == nil)
        await limiter.finish(first)
        let suspended = Task { try await limiter.reserve(for: firstRequest) }
        #expect(await clock.waitForWaiters(count: 1))

        suspended.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await suspended.value
        }
        clock.advanceWithoutResuming(by: .seconds(1))

        let replacement = try await limiter.reserve(for: request(host: "b.example.test"))
        #expect(await limiter.commit(replacement) == nil)
        #expect(await limiter.snapshot.scopes == 1)
    }

    private func verifySuspendedWaiterRetainsScope(
        algorithm: AdvancedRateLimitAlgorithm,
        elapsed: Duration
    ) async throws {
        let clock = TestClock()
        let limiter = AdvancedRateLimitCoordinator(
            policy: AdvancedRateLimitPolicy(
                algorithm: algorithm,
                maximumScopes: 1
            ),
            clock: clock
        )
        let firstRequest = request(host: "a.example.test")
        let first = try await limiter.reserve(for: firstRequest)
        #expect(await limiter.commit(first) == nil)
        await limiter.finish(first)
        let suspended = Task { try await limiter.reserve(for: firstRequest) }
        #expect(await clock.waitForWaiters(count: 1))

        clock.advanceWithoutResuming(by: elapsed)
        await #expect(throws: RateLimitAdmissionFailure.scopeLimitReached) {
            _ = try await limiter.reserve(for: request(host: "b.example.test"))
        }
        #expect(await limiter.snapshot.scopes == 1)

        clock.advance(by: .zero)
        let delayed = try await suspended.value
        #expect(delayed.wasDelayed)
        #expect(await limiter.commit(delayed) == nil)
    }

    @Test("An in-flight response retains its origin and server cooldown")
    func inFlightResponseRetainsServerFeedback() async throws {
        let clock = TestClock()
        let limiter = AdvancedRateLimitCoordinator(
            policy: AdvancedRateLimitPolicy(
                algorithm: .tokenBucket(capacity: 1, refillPerSecond: 1),
                maximumPendingRequests: 0,
                maximumScopes: 1,
                serverFeedback: .retryAfter(maximumDelay: 60)
            ),
            clock: clock
        )
        let firstRequest = request(host: "a.example.test")
        let first = try await limiter.reserve(for: firstRequest)
        #expect(await limiter.commit(first) == nil)
        clock.advance(by: .seconds(1))

        await #expect(throws: RateLimitAdmissionFailure.scopeLimitReached) {
            _ = try await limiter.reserve(for: request(host: "b.example.test"))
        }

        let response = try #require(
            HTTPURLResponse(
                url: firstRequest.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "60"]
            )
        )
        await limiter.observe(response: response, for: firstRequest, reservation: first)

        await #expect(throws: RateLimitAdmissionFailure.queueFull) {
            _ = try await limiter.reserve(for: firstRequest)
        }
    }

    private func request(host: String) -> URLRequest {
        URLRequest(url: URL(string: "https://\(host)/resource")!)
    }
}
