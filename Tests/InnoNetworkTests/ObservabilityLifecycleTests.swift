import Foundation
import InnoNetworkTrust
import Testing

@testable import InnoNetwork

@Suite("Observability Lifecycle Tests", .serialized)
struct ObservabilityLifecycleTests {

    private struct SensitiveQueryRequest: APIDefinition {
        struct Parameter: Encodable, Sendable {
            let token: String
            let page: Int
        }

        typealias APIResponse = String
        var sessionAuthentication: SessionAuthentication { .anonymous }
        var method: HTTPMethod { .get }
        var path: String { "/status" }
        let parameters: Parameter?
    }

    @Test("Request events retain URL shape while redacting credentials and query values")
    func requestEventsRedactSensitiveURLMetadata() async throws {
        let session = FlakyContextSession(failuresBeforeSuccess: 0)
        let store = NetworkEventStore()
        let observer = RecordingNetworkEventObserver(store: store)
        let networkConfiguration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com/v2")!,
            retryPolicy: nil,
            networkMonitor: nil,
            metricsReporter: nil,
            trustPolicy: .systemDefault,
            eventObservers: [observer],
            responseBodyBufferingPolicy: .buffered(maxBytes: 5 * 1024 * 1024)
        )
        let client = DefaultNetworkClient(configuration: networkConfiguration, session: session)

        _ = try await client.request(
            SensitiveQueryRequest(parameters: .init(token: "secret", page: 2))
        )

        let events = await waitForTrustObservabilityEvents(store: store, minimumCount: 4)
        let requestURLs = events.compactMap { event -> String? in
            switch event {
            case .requestStart(_, _, let url, _), .requestAdapted(_, _, let url, _):
                return url
            default:
                return nil
            }
        }
        #expect(requestURLs.isEmpty == false)
        for url in requestURLs {
            #expect(url.contains("api.example.com/v2"))
            #expect(url.contains("token=%3Credacted%3E"))
            #expect(url.contains("page=%3Credacted%3E"))
            #expect(!url.contains("secret"))
        }

        let sanitized = NetworkURLMetadataRedactor.string(
            from: URL(string: "https://user:password@api.example.com/path?token=secret#fragment")
        )
        #expect(!sanitized.contains("user"))
        #expect(!sanitized.contains("password"))
        #expect(!sanitized.contains("secret"))
        #expect(!sanitized.contains("fragment"))
    }

    @Test("Event error categories never include response or custom error payloads")
    func eventErrorCategoriesArePayloadFree() throws {
        let secret = "alice@example.com"
        let url = try #require(URL(string: "https://api.example.com/users"))
        let request = URLRequest(url: url)
        let httpResponse = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        )
        let response = Response(
            statusCode: 200,
            data: Data(secret.utf8),
            request: request,
            response: httpResponse
        )
        let decodingError = NetworkError.decoding(
            stage: .responseBody,
            underlying: SendableUnderlyingError(domain: "decoder", code: 1, message: secret),
            response: response
        )
        let customTrustError = NetworkError.trustEvaluationFailed(.custom(secret))
        let configurationError = NetworkError.configuration(reason: .invalidRequest(secret))

        #expect(decodingError.observabilityCategory == "decoding.response_body")
        #expect(customTrustError.observabilityCategory == "trust.custom")
        #expect(configurationError.observabilityCategory == "configuration.invalid_request")
        #expect(!decodingError.observabilityCategory.contains(secret))
        #expect(!customTrustError.observabilityCategory.contains(secret))
        #expect(!configurationError.observabilityCategory.contains(secret))
    }

    @Test("Network lifecycle events include retry chain with same correlation id")
    func lifecycleEventsWithRetry() async throws {
        let session = FlakyContextSession(failuresBeforeSuccess: 1)
        let store = NetworkEventStore()
        let observer = RecordingNetworkEventObserver(store: store)
        let networkConfiguration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com/v2")!,
            retryPolicy: TrustObservabilityRetryPolicy(),
            networkMonitor: nil,
            metricsReporter: nil,
            trustPolicy: .systemDefault,
            eventObservers: [observer],
            responseBodyBufferingPolicy: .buffered(maxBytes: 5 * 1024 * 1024)
        )
        let client = DefaultNetworkClient(
            configuration: networkConfiguration,
            session: session
        )

        let value = try await client.request(TrustObservabilityRequest())
        #expect(value == "ok")

        let events = await waitForTrustObservabilityEvents(store: store, minimumCount: 8)
        #expect(events.count >= 8)

        let requestIDs = Set(events.map(trustObservabilityRequestID(of:)))
        #expect(requestIDs.count == 1)

        let startRetryIndexes = events.compactMap { event -> Int? in
            guard case .requestStart(_, _, _, let retryIndex) = event else { return nil }
            return retryIndex
        }
        #expect(startRetryIndexes == [0, 1])

        let adaptedRetryIndexes = events.compactMap { event -> Int? in
            guard case .requestAdapted(_, _, _, let retryIndex) = event else { return nil }
            return retryIndex
        }
        #expect(adaptedRetryIndexes == [0, 1])

        let retryScheduledIndexes = events.compactMap { event -> Int? in
            guard case .retryScheduled(_, let retryIndex, _, _) = event else { return nil }
            return retryIndex
        }
        #expect(retryScheduledIndexes == [0])

        let responseCount = events.filter { event in
            if case .responseReceived = event { return true }
            return false
        }.count
        #expect(responseCount == 1)

        let failedCount = events.filter { event in
            if case .requestFailed = event { return true }
            return false
        }.count
        #expect(failedCount == 0)
        let failureMessages = events.compactMap { event -> String? in
            guard case .requestFailed(_, _, let message) = event else { return nil }
            return message
        }
        #expect(failureMessages.isEmpty)

        let finishedCount = events.filter { event in
            if case .requestFinished = event { return true }
            return false
        }.count
        #expect(finishedCount == 1)
    }

    @Test("Network request context forwards trust policy and retry index")
    func requestContextForwarding() async throws {
        let session = FlakyContextSession(failuresBeforeSuccess: 0)
        let pinningEvaluator = PublicKeyPinningEvaluator(
            policy: PublicKeyPinningPolicy(
                pinsByHost: ["api.example.com": ["sha256/primary-pin", "sha256/backup-pin"]],
                includesSubdomains: false,
                allowDefaultEvaluationForUnpinnedHosts: false
            )
        )
        let trustPolicy = TrustPolicy.custom(pinningEvaluator)
        let networkConfiguration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com/v2")!,
            retryPolicy: nil,
            networkMonitor: nil,
            metricsReporter: nil,
            trustPolicy: trustPolicy,
            eventObservers: [],
            responseBodyBufferingPolicy: .buffered(maxBytes: 5 * 1024 * 1024)
        )
        let client = DefaultNetworkClient(
            configuration: networkConfiguration,
            session: session
        )

        let value = try await client.request(TrustObservabilityRequest())
        #expect(value == "ok")

        let contexts = await session.allCapturedContexts()
        let forwardedContext = try #require(contexts.first)
        #expect(forwardedContext.retryIndex == 0)

        switch forwardedContext.trustPolicy {
        case .custom(let evaluator):
            let pinning = try #require(evaluator as? PublicKeyPinningEvaluator)
            #expect(pinning.policy.pinsByHost["api.example.com"] == Set(["sha256/primary-pin", "sha256/backup-pin"]))
            #expect(pinning.policy.includesSubdomains == false)
            #expect(pinning.policy.allowDefaultEvaluationForUnpinnedHosts == false)
        default:
            Issue.record("Expected forwarded trust policy to be public key pinning.")
        }
    }

    @Test("Slow observers do not block request completion path")
    func slowObserverNonBlocking() async throws {
        let session = FlakyContextSession(failuresBeforeSuccess: 0)
        let slowObserver = SlowNetworkEventObserver(delay: 0.2)
        let networkConfiguration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com/v2")!,
            retryPolicy: nil,
            networkMonitor: nil,
            metricsReporter: nil,
            trustPolicy: .systemDefault,
            eventObservers: [slowObserver],
            responseBodyBufferingPolicy: .buffered(maxBytes: 5 * 1024 * 1024)
        )
        let client = DefaultNetworkClient(
            configuration: networkConfiguration,
            session: session
        )

        let start = Date()
        let value = try await client.request(TrustObservabilityRequest())
        let elapsed = Date().timeIntervalSince(start)

        #expect(value == "ok")
        #expect(elapsed < 0.75)
    }
}
