import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

@Suite("CircuitBreakerPolicy validation")
struct CircuitBreakerPolicyValidationTests {

    @Test("Validating initializer rejects non-positive windowSize")
    func rejectsNonPositiveWindow() async {
        #expect(throws: CircuitBreakerPolicy.ConfigurationError.self) {
            _ = try CircuitBreakerPolicy(
                validatedFailureThreshold: 1,
                windowSize: 0,
                resetAfter: .seconds(1),
                maxResetAfter: .seconds(60)
            )
        }
    }

    @Test("Validating initializer rejects threshold > windowSize")
    func rejectsThresholdAboveWindow() async {
        #expect(throws: CircuitBreakerPolicy.ConfigurationError.self) {
            _ = try CircuitBreakerPolicy(
                validatedFailureThreshold: 5,
                windowSize: 3,
                resetAfter: .seconds(1),
                maxResetAfter: .seconds(60)
            )
        }
    }

    @Test("Validating initializer rejects maxReset < reset")
    func rejectsMaxBelowReset() async {
        #expect(throws: CircuitBreakerPolicy.ConfigurationError.self) {
            _ = try CircuitBreakerPolicy(
                validatedFailureThreshold: 1,
                windowSize: 1,
                resetAfter: .seconds(60),
                maxResetAfter: .seconds(30)
            )
        }
    }

    @Test("Silent-clamp initializer still applies normalization")
    func silentClampStillWorks() async {
        let policy = CircuitBreakerPolicy(
            failureThreshold: 100,
            windowSize: 3,
            resetAfter: .seconds(-1),
            maxResetAfter: .seconds(-2)
        )
        #expect(policy.windowSize == 3)
        #expect(policy.failureThreshold == 3)
        #expect(policy.resetAfter == .zero)
        #expect(policy.maxResetAfter == .zero)
    }
}


@Suite("CircuitBreakerRegistry hardening")
struct CircuitBreakerRegistryHardeningTests {

    @Test("Same host on different ports tracks independent state")
    func portIsolatesState() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(failureThreshold: 1, windowSize: 1)
        let request80 = URLRequest(url: URL(string: "http://api.example.com:8080/users")!)
        let request443 = URLRequest(url: URL(string: "https://api.example.com/users")!)

        await registry.recordStatus(request: request80, policy: policy, statusCode: 500)

        // 8080 is open, 443 still closed
        await #expect(throws: NetworkError.self) {
            try await registry.prepare(request: request80, policy: policy)
        }
        try await registry.prepare(request: request443, policy: policy)
    }

    @Test("Different schemes on the same host:port still isolate state")
    func schemeIsolatesState() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(failureThreshold: 1, windowSize: 1)
        let httpRequest = URLRequest(url: URL(string: "http://api.example.com:443/x")!)
        let httpsRequest = URLRequest(url: URL(string: "https://api.example.com:443/x")!)

        await registry.recordStatus(request: httpRequest, policy: policy, statusCode: 500)
        try await registry.prepare(request: httpsRequest, policy: policy)
    }

    @Test("Host casing maps to the same circuit state")
    func hostCasingSharesState() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(failureThreshold: 1, windowSize: 1)
        let uppercaseHost = URLRequest(url: URL(string: "https://API.EXAMPLE.COM/x")!)
        let lowercaseHost = URLRequest(url: URL(string: "https://api.example.com/x")!)

        await registry.recordStatus(request: uppercaseHost, policy: policy, statusCode: 500)

        await #expect(throws: NetworkError.self) {
            try await registry.prepare(request: lowercaseHost, policy: policy)
        }
    }

    @Test("Hysteresis requires multiple successful probes before closing")
    func hysteresisRequiresMultipleProbes() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(
            failureThreshold: 1,
            windowSize: 1,
            resetAfter: .zero,
            maxResetAfter: .seconds(60),
            numberOfProbesRequiredToClose: 2
        )
        let request = URLRequest(url: URL(string: "https://api.example.com/x")!)

        await registry.recordStatus(request: request, policy: policy, statusCode: 500)

        // First probe — admitted because resetAfter is .zero.
        let firstProbe = try await registry.prepare(request: request, policy: policy)
        await registry.recordStatus(request: request, policy: policy, statusCode: 200, probe: firstProbe)
        // Still half-open after a single success: a second probe must be admitted.
        let secondProbe = try await registry.prepare(request: request, policy: policy)
        await registry.recordStatus(request: request, policy: policy, statusCode: 200, probe: secondProbe)

        // After two successes the breaker is closed; further requests proceed.
        try await registry.prepare(request: request, policy: policy)
    }

    @Test("Half-open admits only one probe under concurrent herd")
    func halfOpenAdmitsOnlyOneConcurrentProbe() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(
            failureThreshold: 1,
            windowSize: 1,
            resetAfter: .zero,
            maxResetAfter: .seconds(60)
        )
        let request = URLRequest(url: URL(string: "https://api.example.com/herd")!)
        await registry.recordStatus(request: request, policy: policy, statusCode: 500)

        let results = await withTaskGroup(of: CircuitBreakerProbe?.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    do {
                        return try await registry.prepare(request: request, policy: policy)
                    } catch let error as NetworkError {
                        guard case .underlying(let underlying, _) = error,
                            underlying.domain == CircuitBreakerOpenError.errorDomain
                        else {
                            Issue.record("Expected CircuitBreakerOpenError, got \(error)")
                            return nil
                        }
                        return nil
                    } catch {
                        Issue.record("Expected NetworkError, got \(error)")
                        return nil
                    }
                }
            }

            var admitted = 0
            var rejected = 0
            var admittedProbe: CircuitBreakerProbe?
            for await result in group {
                if let result {
                    admitted += 1
                    admittedProbe = result
                } else {
                    rejected += 1
                }
            }
            return (admitted, rejected, admittedProbe)
        }

        #expect(results.0 == 1)
        #expect(results.1 == 31)
        await registry.recordStatus(request: request, policy: policy, statusCode: 200, probe: results.2)
        try await registry.prepare(request: request, policy: policy)
    }

    @Test("A live half-open probe survives idle-state pruning")
    func liveProbeSurvivesIdlePruning() async throws {
        let clock = TestClock()
        let registry = CircuitBreakerRegistry(clock: clock)
        let policy = CircuitBreakerPolicy(
            failureThreshold: 1,
            windowSize: 1,
            resetAfter: .seconds(1)
        )
        let request = URLRequest(url: URL(string: "https://api.example.com/probe")!)

        await registry.recordFailure(
            request: request,
            policy: policy,
            error: URLError(.timedOut)
        )
        clock.advance(by: .seconds(1))
        let probe = try #require(try await registry.prepare(request: request, policy: policy))
        clock.advance(by: .seconds(301))

        await #expect(throws: NetworkError.self) {
            _ = try await registry.prepare(request: request, policy: policy)
        }

        await registry.abandon(probe)
    }

    @Test("Multiple 4xx probes honor half-open hysteresis before closing")
    func clientErrorsHonorHalfOpenHysteresis() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(
            failureThreshold: 1,
            windowSize: 1,
            resetAfter: .zero,
            maxResetAfter: .seconds(60),
            numberOfProbesRequiredToClose: 3
        )
        let request = URLRequest(url: URL(string: "https://api.example.com/x")!)

        await registry.recordStatus(request: request, policy: policy, statusCode: 500)
        var probe = try await registry.prepare(request: request, policy: policy)
        for statusCode in [404, 401] {
            await registry.recordStatus(request: request, policy: policy, statusCode: statusCode, probe: probe)

            // The healthy probe releases its slot, but the circuit stays
            // half-open until the configured success threshold is reached.
            probe = try await registry.prepare(request: request, policy: policy)
            await #expect(throws: NetworkError.self) {
                try await registry.prepare(request: request, policy: policy)
            }
        }
        await registry.recordStatus(request: request, policy: policy, statusCode: 422, probe: probe)

        // The third transport-health success closes the circuit, so prepares
        // no longer reserve a single half-open probe slot.
        try await registry.prepare(request: request, policy: policy)
        try await registry.prepare(request: request, policy: policy)
    }

    @Test("Mixed 4xx and 2xx probes share the half-open success count")
    func mixedHealthyStatusesShareHalfOpenHysteresis() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(
            failureThreshold: 1,
            windowSize: 1,
            resetAfter: .zero,
            maxResetAfter: .seconds(60),
            numberOfProbesRequiredToClose: 3
        )
        let request = URLRequest(url: URL(string: "https://api.example.com/x")!)

        await registry.recordStatus(request: request, policy: policy, statusCode: 500)
        let firstProbe = try await registry.prepare(request: request, policy: policy)

        await registry.recordStatus(request: request, policy: policy, statusCode: 404, probe: firstProbe)
        let secondProbe = try await registry.prepare(request: request, policy: policy)
        await registry.recordStatus(request: request, policy: policy, statusCode: 204, probe: secondProbe)
        let thirdProbe = try await registry.prepare(request: request, policy: policy)

        // The two status families contribute to the same healthy-probe count;
        // the third success closes the circuit.
        await registry.recordStatus(request: request, policy: policy, statusCode: 304, probe: thirdProbe)
        try await registry.prepare(request: request, policy: policy)
        try await registry.prepare(request: request, policy: policy)
    }

    @Test("4xx responses preserve the closed-state rolling window")
    func clientErrorsPreserveClosedWindow() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(failureThreshold: 2, windowSize: 2)
        let request = URLRequest(url: URL(string: "https://api.example.com/x")!)

        await registry.recordStatus(request: request, policy: policy, statusCode: 500)
        await registry.recordStatus(request: request, policy: policy, statusCode: 404)
        await registry.recordStatus(request: request, policy: policy, statusCode: 401)
        await registry.recordStatus(request: request, policy: policy, statusCode: 500)

        // Closed-state 4xx responses neither erase nor evict the first
        // transport failure, so the second 500 still opens the circuit.
        await #expect(throws: NetworkError.self) {
            try await registry.prepare(request: request, policy: policy)
        }
    }

    @Test("Cancellation in closed state preserves the rolling window")
    func cancellationPreservesClosedWindow() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(failureThreshold: 2, windowSize: 2)
        let request = URLRequest(url: URL(string: "https://api.example.com/x")!)

        await registry.recordStatus(request: request, policy: policy, statusCode: 500)
        await registry.abandon(nil)
        // The window must still hold the prior failure; one more 500 trips.
        await registry.recordStatus(request: request, policy: policy, statusCode: 500)

        await #expect(throws: NetworkError.self) {
            try await registry.prepare(request: request, policy: policy)
        }
    }

    @Test("A stale probe cannot release a newer half-open probe")
    func staleProbeCannotReleaseCurrentOwner() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(failureThreshold: 1, windowSize: 1, resetAfter: .zero)
        let request = URLRequest(url: URL(string: "https://api.example.com/x")!)
        await registry.recordStatus(request: request, policy: policy, statusCode: 500)

        let staleProbe = try #require(try await registry.prepare(request: request, policy: policy))
        await registry.abandon(staleProbe)
        let currentProbe = try #require(try await registry.prepare(request: request, policy: policy))

        await registry.abandon(staleProbe)
        await #expect(throws: NetworkError.self) {
            _ = try await registry.prepare(request: request, policy: policy)
        }

        await registry.recordStatus(
            request: request,
            policy: policy,
            statusCode: 200,
            probe: currentProbe
        )
        _ = try await registry.prepare(request: request, policy: policy)
    }

    @Test("A local admission rejection releases its half-open probe")
    func localAdmissionRejectionReleasesProbe() async throws {
        let policy = CircuitBreakerPolicy(failureThreshold: 1, windowSize: 1, resetAfter: .zero)
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com")!,
            networkMonitor: nil,
            circuitBreakerPolicy: policy,
            requestAdmissionPolicy: RequestAdmissionPolicy(
                maximumConcurrentRequests: 1,
                maximumPendingRequests: 0
            )
        )
        let runtime = RequestExecutionRuntime(configuration: configuration, inFlight: InFlightRegistry())
        let eventHub = NetworkEventHub()
        let executor = RequestExecutor(session: MockURLSession(), eventHub: eventHub)
        let request = URLRequest(url: URL(string: "https://api.example.com/x")!)
        let admission = try #require(runtime.requestAdmission)
        let heldGrant = try await admission.acquire(for: request)
        await runtime.circuitBreakers.recordStatus(request: request, policy: policy, statusCode: 500)

        await #expect(throws: NetworkError.self) {
            _ = try await executor.performTransportResult(
                request: request,
                identityRequest: request,
                bodySource: .inline,
                configuration: configuration,
                context: NetworkRequestContext(),
                runtime: runtime,
                allowsRequestCoalescing: false
            )
        }
        await admission.release(scope: heldGrant.scope)

        let recoveredProbe = try await runtime.circuitBreakers.prepare(request: request, policy: policy)
        #expect(recoveredProbe != nil)
        await runtime.circuitBreakers.abandon(recoveredProbe)
        await eventHub.shutdown()
        await runtime.shutdown()
    }

    @Test("DNS lookup failure remains a countable underlying transport failure")
    func dnsFailureCountableAsUnderlyingTransportFailure() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(failureThreshold: 1, windowSize: 1)
        let request = URLRequest(url: URL(string: "https://api.example.com/x")!)

        let dns = URLError(.dnsLookupFailed)
        await registry.recordFailure(request: request, policy: policy, error: dns)

        await #expect(throws: NetworkError.self) {
            try await registry.prepare(request: request, policy: policy)
        }
    }

    @Test(
        "NetworkError.reachability(reason:) counts toward the breaker for every reason",
        arguments: [
            ReachabilityReason.notConnectedToInternet,
            ReachabilityReason.dnsLookupFailed,
            ReachabilityReason.cannotFindHost,
            ReachabilityReason.networkConnectionLost,
        ]
    )
    func reachabilityIsCountable(_ reason: ReachabilityReason) async throws {
        // Round 1 reclassified four URLErrors from `.underlying` into the
        // typed `.reachability` case. Without an explicit arm in
        // `isCountable(...)`, those failures stopped tripping the breaker —
        // the regression the RetryPolicy parallel test covers on the retry
        // side. Lock the breaker side too.
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(failureThreshold: 1, windowSize: 1)
        let request = URLRequest(url: URL(string: "https://api.example.com/x")!)

        let underlying = SendableUnderlyingError(
            domain: NSURLErrorDomain,
            code: -1,
            message: "reachability fixture"
        )
        let error = NetworkError.reachability(reason, underlying, nil)
        await registry.recordFailure(request: request, policy: policy, error: error)

        await #expect(throws: NetworkError.self) {
            try await registry.prepare(request: request, policy: policy)
        }
    }

    @Test("Transport security URL failures count when countsTransportSecurityFailures is true")
    func transportSecurityURLFailureCountableWhenOptedIn() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(
            failureThreshold: 1,
            windowSize: 1,
            countsTransportSecurityFailures: true
        )
        let request = URLRequest(url: URL(string: "https://api.example.com/x")!)

        let securityError = URLError(.secureConnectionFailed)
        await registry.recordFailure(request: request, policy: policy, error: securityError)

        await #expect(throws: NetworkError.self) {
            try await registry.prepare(request: request, policy: policy)
        }
    }

    @Test("Trust evaluation failure does not count by default")
    func trustEvaluationNotCountable() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(failureThreshold: 1, windowSize: 1)
        let request = URLRequest(url: URL(string: "https://api.example.com/x")!)
        let trustError = NetworkError.trustEvaluationFailed(.systemTrustEvaluationFailed(reason: "bad"))

        await registry.recordFailure(request: request, policy: policy, error: trustError)

        try await registry.prepare(request: request, policy: policy)
    }

    @Test("Transport security URL failures do not count by default")
    func transportSecurityURLFailureNotCountableByDefault() async throws {
        let registry = CircuitBreakerRegistry()
        let policy = CircuitBreakerPolicy(failureThreshold: 1, windowSize: 1)
        let request = URLRequest(url: URL(string: "https://api.example.com/x")!)
        let securityError = URLError(.secureConnectionFailed)

        await registry.recordFailure(request: request, policy: policy, error: securityError)

        try await registry.prepare(request: request, policy: policy)
    }
}
