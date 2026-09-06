import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

@Suite("Request Admission Policy Tests", .serialized)
struct RequestAdmissionPolicyTests {
    @Test("A built-in admission wait reports policy admission before transport")
    func admissionWaitReportsDeadlineStage() async throws {
        let clock = TestClock()
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.test")!,
            networkMonitor: nil,
            requestAdmissionPolicy: RequestAdmissionPolicy(
                maximumConcurrentRequests: 1,
                maximumPendingRequests: 1,
                maximumQueueWait: .seconds(30)
            )
        )
        let runtime = RequestExecutionRuntime(
            configuration: configuration,
            inFlight: InFlightRegistry(),
            clock: clock
        )
        let blocker = try #require(
            try await runtime.requestAdmission?.acquire(
                for: URLRequest(url: configuration.baseURL)
            )
        )
        let tracker = NetworkOperationDeadlineTracker()
        let hub = NetworkEventHub()
        let executor = RequestExecutor(session: MockURLSession(), eventHub: hub)
        let task = Task {
            try await NetworkOperationDeadlineContext.$tracker.withValue(tracker) {
                try await executor.execute(
                    APISingleRequestExecutable(base: AdmissionEndpoint()),
                    configuration: configuration,
                    requestBuilder: RequestBuilder(),
                    runtime: runtime,
                    retryIndex: 0,
                    requestID: UUID()
                )
            }
        }

        #expect(await clock.waitForWaiters(count: 1))
        #expect(await runtime.requestAdmission?.snapshot.pending == 1)
        #expect(tracker.currentStage == .policyAdmission)

        task.cancel()
        _ = await task.result
        await runtime.requestAdmission?.release(scope: blocker.scope)
        await hub.shutdown()
        await runtime.shutdown()
    }

    @Test("Queue capacity rejects excess work without leaking permits")
    func boundedQueue() async throws {
        let coordinator = RequestAdmissionCoordinator(
            policy: RequestAdmissionPolicy(
                maximumConcurrentRequests: 1,
                maximumPendingRequests: 1
            ),
            clock: TestClock()
        )
        let request = URLRequest(url: URL(string: "https://api.example.test/a")!)
        let firstScope = try await coordinator.acquire(for: request).scope
        let second = Task { try await coordinator.acquire(for: request) }
        await waitForPending(1, coordinator: coordinator)

        await #expect(throws: RequestAdmissionFailure.queueFull) {
            _ = try await coordinator.acquire(for: request)
        }

        second.cancel()
        _ = try? await second.value
        await coordinator.release(scope: firstScope)
        let snapshot = await coordinator.snapshot
        #expect(snapshot.active == 0)
        #expect(snapshot.pending == 0)
    }

    @Test("Virtual queue deadline expires exactly one waiter")
    func queueWaitDeadline() async throws {
        let clock = TestClock()
        let coordinator = RequestAdmissionCoordinator(
            policy: RequestAdmissionPolicy(
                maximumConcurrentRequests: 1,
                maximumPendingRequests: 2,
                maximumQueueWait: .seconds(5)
            ),
            clock: clock
        )
        let request = URLRequest(url: URL(string: "https://api.example.test/a")!)
        let firstScope = try await coordinator.acquire(for: request).scope
        let second = Task { try await coordinator.acquire(for: request) }
        await waitForPending(1, coordinator: coordinator)
        #expect(await clock.waitForWaiters(count: 1))

        clock.advance(by: .seconds(5))
        await #expect(throws: RequestAdmissionFailure.queueWaitExpired) {
            _ = try await second.value
        }
        await coordinator.release(scope: firstScope)

        let snapshot = await coordinator.snapshot
        #expect(snapshot.active == 0)
        #expect(snapshot.pending == 0)
    }

    @Test("An origin at its cap does not block another origin")
    func scopeFairness() async throws {
        let coordinator = RequestAdmissionCoordinator(
            policy: RequestAdmissionPolicy(
                maximumConcurrentRequests: 2,
                maximumPendingRequests: 2,
                scope: .origin,
                maximumConcurrentRequestsPerScope: 1
            ),
            clock: TestClock()
        )
        let first = URLRequest(url: URL(string: "https://a.example.test/path")!)
        let second = URLRequest(url: URL(string: "https://b.example.test/path")!)

        let firstScope = try await coordinator.acquire(for: first).scope
        let secondScope = try await coordinator.acquire(for: second).scope
        let snapshot = await coordinator.snapshot
        #expect(snapshot.active == 2)
        #expect(snapshot.scopes == 2)

        await coordinator.release(scope: firstScope)
        await coordinator.release(scope: secondScope)
    }

    @Test("Immediate admission respects the origin registry bound")
    func immediateAdmissionRespectsScopeBound() async throws {
        let coordinator = RequestAdmissionCoordinator(
            policy: RequestAdmissionPolicy(
                maximumConcurrentRequests: 2,
                maximumPendingRequests: 2,
                scope: .origin,
                maximumScopes: 1
            ),
            clock: TestClock()
        )
        let first = URLRequest(url: URL(string: "https://a.example.test/path")!)
        let second = URLRequest(url: URL(string: "https://b.example.test/path")!)
        let firstScope = try await coordinator.acquire(for: first).scope

        await #expect(throws: RequestAdmissionFailure.queueFull) {
            _ = try await coordinator.acquire(for: second)
        }
        #expect(await coordinator.snapshot.scopes == 1)
        await coordinator.release(scope: firstScope)
    }

    @Test("A blocked origin does not queue work for an origin with free capacity")
    func newOriginBypassesBlockedScope() async throws {
        let coordinator = RequestAdmissionCoordinator(
            policy: RequestAdmissionPolicy(
                maximumConcurrentRequests: 2,
                maximumPendingRequests: 3,
                scope: .origin,
                maximumConcurrentRequestsPerScope: 1
            ),
            clock: TestClock()
        )
        let first = URLRequest(url: URL(string: "https://a.example.test/path")!)
        let second = URLRequest(url: URL(string: "https://b.example.test/path")!)
        let firstScope = try await coordinator.acquire(for: first).scope
        let blocked = Task { try await coordinator.acquire(for: first) }
        await waitForPending(1, coordinator: coordinator)

        let secondGrant = try await coordinator.acquire(for: second)
        #expect(!secondGrant.wasQueued)
        #expect(await coordinator.snapshot.active == 2)

        blocked.cancel()
        _ = try? await blocked.value
        await coordinator.release(scope: firstScope)
        await coordinator.release(scope: secondGrant.scope)
    }

    @Test("Explicit default port shares the implicit origin concurrency limit")
    func defaultPortSharesOriginLimit() async throws {
        let coordinator = RequestAdmissionCoordinator(
            policy: RequestAdmissionPolicy(
                maximumConcurrentRequests: 2,
                maximumPendingRequests: 1,
                scope: .origin,
                maximumConcurrentRequestsPerScope: 1
            ),
            clock: TestClock()
        )
        let implicit = URLRequest(url: URL(string: "https://API.example.test/path")!)
        let explicit = URLRequest(url: URL(string: "https://api.example.test:443/path")!)
        let firstScope = try await coordinator.acquire(for: implicit).scope
        let blocked = Task { try await coordinator.acquire(for: explicit) }
        await waitForPending(1, coordinator: coordinator)

        let snapshot = await coordinator.snapshot
        #expect(snapshot.active == 1)
        #expect(snapshot.pending == 1)
        #expect(snapshot.scopes == 1)

        blocked.cancel()
        _ = try? await blocked.value
        await coordinator.release(scope: firstScope)
    }

    private func waitForPending(
        _ count: Int,
        coordinator: RequestAdmissionCoordinator
    ) async {
        for _ in 0..<100 {
            if await coordinator.snapshot.pending >= count { return }
            await Task.yield()
        }
        Issue.record("Admission waiter did not enqueue")
    }
}

private struct AdmissionEndpoint: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = Int

    let method = HTTPMethod.get
    let path = "/admission"
    let sessionAuthentication = SessionAuthentication.anonymous
    let parameters: EmptyParameter? = nil
}
