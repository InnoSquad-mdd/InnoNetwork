import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork

extension ResiliencePolicyTests {
    @Test("Circuit breaker opens after countable failure")
    func circuitBreakerOpens() async throws {
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 500),
            resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "unused")),
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                circuitBreakerPolicy: CircuitBreakerPolicy(failureThreshold: 1, windowSize: 1)
            ),
            session: session
        )

        await #expect(throws: NetworkError.self) {
            try await client.request(ResilienceGetRequest())
        }
        await #expect(throws: NetworkError.self) {
            try await client.request(ResilienceGetRequest())
        }

        #expect(await session.requestCount == 1)
    }

    @Test("Circuit breaker policy normalizes invalid thresholds and durations")
    func circuitBreakerPolicyNormalizesInputs() {
        let capped = CircuitBreakerPolicy(
            failureThreshold: 10,
            windowSize: 2,
            resetAfter: .seconds(-1),
            maxResetAfter: .seconds(-2)
        )
        #expect(capped.windowSize == 2)
        #expect(capped.failureThreshold == 2)
        #expect(capped.resetAfter == .zero)
        #expect(capped.maxResetAfter == .zero)

        let minimum = CircuitBreakerPolicy(
            failureThreshold: 0,
            windowSize: 0,
            resetAfter: .seconds(5),
            maxResetAfter: .seconds(1)
        )
        #expect(minimum.windowSize == 1)
        #expect(minimum.failureThreshold == 1)
        #expect(minimum.resetAfter == .seconds(5))
        #expect(minimum.maxResetAfter == .seconds(5))
    }

    @Test("Refresh replay clears prior Authorization header before reapplying")
    func refreshTokenReplayClearsPreviousAuthorizationHeader() async throws {
        let coordinator = RefreshTokenCoordinator(
            policy: RefreshTokenPolicy(
                currentToken: { "old" },
                refreshToken: { "new" },
                applyToken: { token, request in
                    var request = request
                    request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    return request
                }
            )
        )
        var request = URLRequest(url: URL(string: "https://api.example.com/users/1")!)
        request.setValue("Bearer old", forHTTPHeaderField: "Authorization")

        let applied = try await coordinator.refreshAndApply(to: request)

        #expect(applied.value(forHTTPHeaderField: "Authorization") == "Bearer new")
    }

    @Test("Current token application clears prior Authorization header before reapplying")
    func currentTokenApplicationClearsPreviousAuthorizationHeader() async throws {
        let coordinator = RefreshTokenCoordinator(
            policy: RefreshTokenPolicy(
                currentToken: { "current" },
                refreshToken: { "unused" },
                applyToken: { token, request in
                    var request = request
                    request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    return request
                }
            )
        )
        var request = URLRequest(url: URL(string: "https://api.example.com/users/1")!)
        request.setValue("Bearer endpoint", forHTTPHeaderField: "authorization")

        let applied = try await coordinator.applyCurrentToken(to: request)
        let headers = applied.allHTTPHeaderFields ?? [:]
        let authHeaders = headers.filter { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }

        #expect(authHeaders.count == 1)
        #expect(authHeaders.first?.value == "Bearer current")
    }

    @Test("Failed refresh does not replay stale failure to subsequent callers when cooldown is disabled")
    func refreshTokenFailedRefreshDoesNotReplayStaleFailure() async throws {
        actor RefreshScript {
            var calls = 0
            func next() async throws -> String {
                calls += 1
                if calls == 1 {
                    throw NetworkError.configuration(reason: .invalidRequest("first refresh fails"))
                }
                return "fresh"
            }
        }
        let script = RefreshScript()
        let coordinator = RefreshTokenCoordinator(
            policy: RefreshTokenPolicy(
                failureCooldown: .disabled,
                currentToken: { "old" },
                refreshToken: { try await script.next() }
            )
        )
        let request = URLRequest(url: URL(string: "https://api.example.com/users/1")!)

        await #expect(throws: NetworkError.self) {
            _ = try await coordinator.refreshAndApply(to: request)
        }
        let applied = try await coordinator.refreshAndApply(to: request)

        #expect(await script.calls == 2)
        #expect(applied.value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
    }

    @Test("Refresh failure cooldown throttles subsequent callers within the cooldown window")
    func refreshTokenFailureCooldownThrottlesCallers() async throws {
        actor RefreshScript {
            var calls = 0
            func next() async throws -> String {
                calls += 1
                throw NetworkError.configuration(reason: .invalidRequest("refresh keeps failing"))
            }
        }
        let script = RefreshScript()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let nowBox = OSAllocatedUnfairLock<Date>(initialState: now)
        let coordinator = RefreshTokenCoordinator(
            policy: RefreshTokenPolicy(
                failureCooldown: .exponentialBackoff(base: 5, max: 60),
                currentToken: { "old" },
                refreshToken: { try await script.next() }
            ),
            now: { nowBox.withLock { $0 } }
        )
        let request = URLRequest(url: URL(string: "https://api.example.com/users/1")!)

        // First call performs refresh and fails — opens cooldown for 5s.
        await #expect(throws: NetworkError.self) {
            _ = try await coordinator.refreshAndApply(to: request)
        }
        // Second call within cooldown window must throw cached error WITHOUT
        // invoking the refresh provider again.
        await #expect(throws: NetworkError.self) {
            _ = try await coordinator.refreshAndApply(to: request)
        }
        #expect(await script.calls == 1)

        // Advancing past the cooldown window allows another attempt.
        nowBox.withLock { $0 = now.addingTimeInterval(6) }
        await #expect(throws: NetworkError.self) {
            _ = try await coordinator.refreshAndApply(to: request)
        }
        #expect(await script.calls == 2)
    }

    @Test("Request runtime injects its virtual clock into refresh cooldown")
    func runtimeClockDrivesRefreshCooldown() async throws {
        actor RefreshScript {
            var calls = 0
            func next() async throws -> String {
                calls += 1
                throw NetworkError.configuration(reason: .invalidRequest("refresh keeps failing"))
            }
        }

        let script = RefreshScript()
        let clock = TestClock(epoch: Date(timeIntervalSince1970: 1_700_000_000))
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com")!,
            refreshTokenPolicy: RefreshTokenPolicy(
                failureCooldown: .exponentialBackoff(base: 5, max: 60),
                currentToken: { "old" },
                refreshToken: { try await script.next() }
            )
        )
        let runtime = RequestExecutionRuntime(
            configuration: configuration,
            inFlight: InFlightRegistry(),
            clock: clock
        )
        let coordinator = try #require(runtime.refreshCoordinator)
        let request = URLRequest(url: URL(string: "https://api.example.com/users/1")!)

        await #expect(throws: NetworkError.self) {
            _ = try await coordinator.refreshAndApply(to: request)
        }
        await #expect(throws: NetworkError.self) {
            _ = try await coordinator.refreshAndApply(to: request)
        }
        #expect(await script.calls == 1)

        clock.advance(by: .seconds(6))
        await #expect(throws: NetworkError.self) {
            _ = try await coordinator.refreshAndApply(to: request)
        }
        #expect(await script.calls == 2)
    }

    @Test("Refresh failure cooldown normalizes invalid bounds")
    func refreshFailureCooldownNormalizesInvalidBounds() async {
        let disabledByNegativeInput = RefreshFailureCooldown.exponentialBackoff(base: -1, max: -5)
        #expect(disabledByNegativeInput.cooldown(afterConsecutiveFailures: 1) == 0)

        let capRaisedToBase = RefreshFailureCooldown.exponentialBackoff(base: 2, max: 1)
        #expect(capRaisedToBase.cooldown(afterConsecutiveFailures: 1) == 2)
        #expect(capRaisedToBase.cooldown(afterConsecutiveFailures: 2) == 2)
    }

    @Test("RefreshAndApply strips lowercase Authorization header before reapplying the new token")
    func refreshTokenStripsCaseInsensitiveAuthorization() async throws {
        let coordinator = RefreshTokenCoordinator(
            policy: RefreshTokenPolicy(
                currentToken: { "old" },
                refreshToken: { "fresh" }
            )
        )
        var request = URLRequest(url: URL(string: "https://api.example.com/users/1")!)
        // Manually planted lowercase header — without a case-insensitive strip
        // this would coexist with the new "Authorization" entry on the replay.
        request.setValue("Bearer stale", forHTTPHeaderField: "authorization")

        let applied = try await coordinator.refreshAndApply(to: request)
        let headers = applied.allHTTPHeaderFields ?? [:]
        let authHeaders = headers.filter { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }
        #expect(authHeaders.count == 1)
        #expect(authHeaders.first?.value == "Bearer fresh")
    }

    @Test("Half-open probe cancellation releases the host")
    func circuitBreakerHalfOpenProbeCancellationDoesNotTrap() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(failureThreshold: 1, windowSize: 1, resetAfter: .zero)
        let request = URLRequest(url: URL(string: "https://api.example.com/users/1")!)

        await registry.recordStatus(request: request, policy: policy, statusCode: 500)
        let probe = try await registry.prepare(request: request, policy: policy)
        await registry.abandon(probe)

        _ = try await registry.prepare(request: request, policy: policy)
    }

    @Test("401 does not open circuit breaker")
    func authFailureDoesNotOpenCircuitBreaker() async throws {
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 401),
            resilienceQueuedResponse(statusCode: 401),
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                circuitBreakerPolicy: CircuitBreakerPolicy(failureThreshold: 1, windowSize: 1)
            ),
            session: session
        )

        await #expect(throws: NetworkError.self) {
            try await client.request(ResilienceGetRequest())
        }
        await #expect(throws: NetworkError.self) {
            try await client.request(ResilienceGetRequest())
        }

        #expect(await session.requestCount == 2)
    }

    @Test("Half-open probe receiving 4xx releases the probe slot")
    func circuitBreakerHalfOpenProbe4xxReleasesSlot() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(failureThreshold: 1, windowSize: 1, resetAfter: .zero)
        let request = URLRequest(url: URL(string: "https://api.example.com/users/1")!)

        await registry.recordStatus(request: request, policy: policy, statusCode: 500)
        // prepare(...) transitions open to half-open and returns its probe.
        // resetAfter (here .zero) elapses.
        let probe = try await registry.prepare(request: request, policy: policy)
        // The probe came back with 404 — semantic failure, but the transport
        // worked. The slot must be released so subsequent traffic is admitted.
        await registry.recordStatus(request: request, policy: policy, statusCode: 404, probe: probe)

        try await registry.prepare(request: request, policy: policy)
    }

    @Test("4xx response does not reset accumulated transport failures")
    func circuitBreakerWindowSurvivesInterleaved4xx() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(failureThreshold: 3, windowSize: 3)
        let request = URLRequest(url: URL(string: "https://api.example.com/users/1")!)

        await registry.recordStatus(request: request, policy: policy, statusCode: 500)
        await registry.recordStatus(request: request, policy: policy, statusCode: 500)
        // A 4xx between transport failures must not reset the rolling window.
        await registry.recordStatus(request: request, policy: policy, statusCode: 404)
        await registry.recordStatus(request: request, policy: policy, statusCode: 500)

        await #expect(throws: NetworkError.self) {
            try await registry.prepare(request: request, policy: policy)
        }
    }

    @Test("2xx response closes the circuit and clears failures")
    func circuitBreakerSuccessClosesCircuit() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(failureThreshold: 3, windowSize: 3)
        let request = URLRequest(url: URL(string: "https://api.example.com/users/1")!)

        await registry.recordStatus(request: request, policy: policy, statusCode: 500)
        await registry.recordStatus(request: request, policy: policy, statusCode: 500)
        await registry.recordStatus(request: request, policy: policy, statusCode: 200)
        await registry.recordStatus(request: request, policy: policy, statusCode: 500)
        await registry.recordStatus(request: request, policy: policy, statusCode: 500)

        try await registry.prepare(request: request, policy: policy)
    }

    @Test("Coalesced transport failure counts once for circuit breaker")
    func coalescedFailureCountsOnceForCircuitBreaker() async throws {
        let session = try ResilienceSequenceURLSession(
            queue: [
                resilienceQueuedResponse(statusCode: 500),
                resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "recovered")),
            ],
            delay: .milliseconds(50)
        )
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                requestCoalescingPolicy: .getOnly,
                circuitBreakerPolicy: CircuitBreakerPolicy(failureThreshold: 2, windowSize: 2)
            ),
            session: session
        )

        await #expect(throws: NetworkError.self) {
            try await withThrowingTaskGroup(of: ResilienceUser.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        try await client.request(ResilienceGetRequest())
                    }
                }
                for try await _ in group {}
            }
        }

        let recovered = try await client.request(ResilienceGetRequest())

        #expect(recovered == ResilienceUser(id: 1, name: "recovered"))
        #expect(await session.requestCount == 2)
    }
}
