import Foundation
import Security
import Testing

@testable import InnoNetwork

// Shared helpers split out of the original TrustAndObservabilityTests so the
// trust-evaluation and observability suites can live in separate files
// without duplicating fixtures.

struct TrustObservabilityRequest: APIDefinition {
    var sessionAuthentication: SessionAuthentication { .anonymous }
    typealias Parameter = EmptyParameter
    typealias APIResponse = String

    var method: HTTPMethod { .get }
    var path: String { "/status" }
}


struct TrustObservabilityRetryPolicy: RetryPolicy {
    let maxRetries: Int = 1
    let maxTotalRetries: Int = 1
    let retryDelay: TimeInterval = 0

    func retryDelay(for retryIndex: Int) -> TimeInterval {
        _ = retryIndex
        return retryDelay
    }

    func shouldRetry(
        error: NetworkError,
        retryIndex: Int,
        request: URLRequest?,
        response: HTTPURLResponse?
    ) -> RetryDecision {
        guard retryIndex < maxRetries else { return .noRetry }
        switch error {
        case .underlying, .timeout:
            return .retry
        default:
            return .noRetry
        }
    }
}


actor FlakyContextSession: URLSessionProtocol {
    private var failuresBeforeSuccess: Int
    private var capturedContexts: [NetworkRequestContext] = []

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        return try await data(for: request, context: NetworkRequestContext())
    }

    func data(for request: URLRequest, context: NetworkRequestContext) async throws -> (Data, URLResponse) {
        capturedContexts.append(context)
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw URLError(.timedOut)
        }

        let url = request.url ?? URL(string: "https://api.example.com/v2/status")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(#""ok""#.utf8), response)
    }

    func allCapturedContexts() -> [NetworkRequestContext] {
        capturedContexts
    }
}


actor NetworkEventStore {
    private var events: [NetworkEvent] = []

    func append(_ event: NetworkEvent) {
        events.append(event)
    }

    func snapshot() -> [NetworkEvent] {
        events
    }
}


struct RecordingNetworkEventObserver: NetworkEventObserving {
    let store: NetworkEventStore

    func handle(_ event: NetworkEvent) async {
        await store.append(event)
    }
}


final class SlowNetworkEventObserver: NetworkEventObserving, Sendable {
    private let delay: TimeInterval

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func handle(_ event: NetworkEvent) async {
        _ = event
        try? await Task.sleep(for: .seconds(delay))
    }
}


struct AcceptingTrustEvaluator: TrustEvaluating {
    func evaluate(challenge: URLAuthenticationChallenge) -> TrustChallengeOutcome {
        _ = challenge
        return .useCredential
    }
}


struct RejectingTrustEvaluator: TrustEvaluating {
    func evaluate(challenge: URLAuthenticationChallenge) -> TrustChallengeOutcome {
        _ = challenge
        return .cancel(.custom("Custom trust evaluator rejected the challenge."))
    }
}


final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}


func makeTrustObservabilityChallenge(
    host: String,
    authenticationMethod: String
) -> URLAuthenticationChallenge {
    let sender = ChallengeSender()
    let protectionSpace = URLProtectionSpace(
        host: host,
        port: 443,
        protocol: "https",
        realm: nil,
        authenticationMethod: authenticationMethod
    )
    return URLAuthenticationChallenge(
        protectionSpace: protectionSpace,
        proposedCredential: nil,
        previousFailureCount: 0,
        failureResponse: nil,
        error: nil,
        sender: sender
    )
}


func waitForTrustObservabilityEvents(
    store: NetworkEventStore,
    minimumCount: Int,
    timeout: TimeInterval = 1.0
) async -> [NetworkEvent] {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let events = await store.snapshot()
        if events.count >= minimumCount {
            return events
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await store.snapshot()
}


func trustObservabilityRequestID(of event: NetworkEvent) -> UUID {
    switch event {
    case .requestStart(let requestID, _, _, _):
        return requestID
    case .requestAdapted(let requestID, _, _, _):
        return requestID
    case .responseReceived(let requestID, _, _):
        return requestID
    case .retryScheduled(let requestID, _, _, _):
        return requestID
    case .requestFinished(let requestID, _, _):
        return requestID
    case .requestFailed(let requestID, _, _):
        return requestID
    case .cacheRevalidation(let originalID, _):
        return originalID
    case .decision(let decision):
        return decision.requestID
    }
}
