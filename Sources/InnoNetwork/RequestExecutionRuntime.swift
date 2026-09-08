import Foundation

package final class RequestExecutionRuntime: Sendable {
    let refreshCoordinator: RefreshTokenCoordinator?
    let requestCoalescer: RequestCoalescer
    let circuitBreakers: CircuitBreakerRegistry
    let requestAdmission: RequestAdmissionCoordinator?
    let streamAdmission: RequestAdmissionCoordinator?
    let rateLimit: AdvancedRateLimitCoordinator?
    let cacheMutations: ResponseCacheMutationCoordinator
    let inFlight: InFlightRegistry
    let clock: any InnoNetworkClock

    init(
        configuration: NetworkConfiguration,
        inFlight: InFlightRegistry,
        clock: any InnoNetworkClock = SystemClock()
    ) {
        let now: @Sendable () -> Date = { clock.now() }
        self.refreshCoordinator = configuration.refreshTokenPolicy.map {
            RefreshTokenCoordinator(policy: $0, now: now)
        }
        self.requestCoalescer = RequestCoalescer(now: now)
        self.circuitBreakers = CircuitBreakerRegistry(clock: clock)
        self.requestAdmission = configuration.requestAdmissionPolicy.map {
            RequestAdmissionCoordinator(policy: $0, clock: clock)
        }
        self.streamAdmission = configuration.requestAdmissionPolicy.map {
            RequestAdmissionCoordinator(policy: $0.streamingPolicy, clock: clock)
        }
        self.rateLimit = configuration.advancedRateLimitPolicy.map {
            AdvancedRateLimitCoordinator(policy: $0, clock: clock)
        }
        self.cacheMutations = configuration.responseCacheMutations
        self.inFlight = inFlight
        self.clock = clock
    }

    package func shutdown() async {
        await refreshCoordinator?.shutdown()
    }
}
