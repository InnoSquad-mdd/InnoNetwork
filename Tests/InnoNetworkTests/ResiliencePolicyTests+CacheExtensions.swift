import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

extension ResiliencePolicyTests {
    @Test("only-if-cached returns a reusable entry without transport")
    func onlyIfCachedHitSkipsTransport() async throws {
        let cache = InMemoryResponseCache()
        let cached = ResilienceUser(id: 1, name: "cached-only")
        await cache.set(
            resilienceUserCacheKey(),
            CachedResponse(data: try JSONEncoder().encode(cached))
        )
        let session = ResilienceSequenceURLSession(queue: [])
        let client = DefaultNetworkClient(
            configuration: resilienceCacheExtensionConfiguration(
                policy: .requestOnlyIfCached(
                    wrapping: .cacheFirst(maxAge: .seconds(60))
                ),
                cache: cache,
                cacheControl: "max-age=0, only-if-cached"
            ),
            session: session
        )

        let response = try await client.request(ResilienceGetRequest())

        #expect(response == cached)
        #expect(await session.requestCount == 0)
    }

    @Test("only-if-cached misses fail locally without transport")
    func onlyIfCachedMissFailsLocally() async throws {
        let session = ResilienceSequenceURLSession(queue: [])
        let client = DefaultNetworkClient(
            configuration: resilienceCacheExtensionConfiguration(
                policy: .requestOnlyIfCached(
                    wrapping: .cacheFirst(maxAge: .seconds(60))
                ),
                cache: InMemoryResponseCache(),
                cacheControl: "only-if-cached"
            ),
            session: session
        )

        do {
            _ = try await client.request(ResilienceGetRequest())
            Issue.record("Expected only-if-cached miss")
        } catch NetworkError.configuration(reason: .invalidRequest(let message)) {
            #expect(message.contains("only-if-cached"))
        } catch {
            Issue.record("Expected typed invalidRequest failure, got \(error)")
        }
        #expect(await session.requestCount == 0)
    }

    @Test("only-if-cached refuses entries that require revalidation")
    func onlyIfCachedDoesNotRevalidate() async throws {
        let cache = InMemoryResponseCache()
        await cache.set(
            resilienceUserCacheKey(),
            CachedResponse(
                data: try JSONEncoder().encode(ResilienceUser(id: 1, name: "stale")),
                headers: ["ETag": "v1"],
                storedAt: Date(timeIntervalSinceNow: -60)
            )
        )
        let session = ResilienceSequenceURLSession(queue: [])
        let client = DefaultNetworkClient(
            configuration: resilienceCacheExtensionConfiguration(
                policy: .requestOnlyIfCached(
                    wrapping: .cacheFirst(maxAge: .seconds(1))
                ),
                cache: cache,
                cacheControl: "only-if-cached"
            ),
            session: session
        )

        await #expect(throws: NetworkError.self) {
            _ = try await client.request(ResilienceGetRequest())
        }
        #expect(await session.requestCount == 0)
    }

    @Test("only-if-cached suppresses stale-while-revalidate background transport")
    func onlyIfCachedUsesSWRWithoutBackgroundTransport() async throws {
        let cache = InMemoryResponseCache()
        let cached = ResilienceUser(id: 1, name: "stale-window")
        await cache.set(
            resilienceUserCacheKey(),
            CachedResponse(
                data: try JSONEncoder().encode(cached),
                storedAt: Date(timeIntervalSinceNow: -10)
            )
        )
        let session = ResilienceSequenceURLSession(queue: [])
        let client = DefaultNetworkClient(
            configuration: resilienceCacheExtensionConfiguration(
                policy: .requestOnlyIfCached(
                    wrapping: .staleWhileRevalidate(
                        maxAge: .seconds(1),
                        staleWindow: .seconds(60)
                    )
                ),
                cache: cache,
                cacheControl: "only-if-cached"
            ),
            session: session
        )

        let response = try await client.request(ResilienceGetRequest())
        try await Task.sleep(for: .milliseconds(50))

        #expect(response == cached)
        #expect(await session.requestCount == 0)
    }

    @Test("only-if-cached remains origin-controlled without the opt-in wrapper")
    func onlyIfCachedIsIgnoredWithoutOptIn() async throws {
        let fresh = ResilienceUser(id: 2, name: "network")
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 200, body: fresh)
        ])
        let client = DefaultNetworkClient(
            configuration: resilienceCacheExtensionConfiguration(
                policy: .cacheFirst(maxAge: .seconds(60)),
                cache: InMemoryResponseCache(),
                cacheControl: "only-if-cached"
            ),
            session: session
        )

        let response = try await client.request(ResilienceGetRequest())

        #expect(response == fresh)
        #expect(await session.requestCount == 1)
        #expect(
            await session.capturedRequests.first?.value(forHTTPHeaderField: "Cache-Control")
                == "only-if-cached"
        )
    }

    @Test("stale-if-error waits until status retries are exhausted")
    func staleIfErrorRunsAfterRetryExhaustion() async throws {
        let cache = try await resilienceStaleIfErrorCache(name: "fallback")
        let recorder = ResilienceResponseRecorder()
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 503),
            resilienceQueuedResponse(statusCode: 503),
        ])
        let client = DefaultNetworkClient(
            configuration: resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .staleIfError(
                    wrapping: .cacheFirst(maxAge: .seconds(1))
                ),
                responseCache: cache,
                retryPolicy: ExponentialBackoffRetryPolicy(
                    maxRetries: 1,
                    retryDelay: 0,
                    jitterRatio: 0
                ),
                responseInterceptors: [
                    ResilienceRecordingResponseInterceptor(recorder: recorder)
                ]
            ),
            session: session
        )

        let response = try await client.request(ResilienceGetRequest())

        #expect(response == ResilienceUser(id: 1, name: "fallback"))
        #expect(await session.requestCount == 2)
        #expect(await recorder.response(at: 0)?.statusCode == 200)
        #expect(await recorder.response(at: 1) == nil)
    }

    @Test("stale-if-error does not replace a successful retry")
    func staleIfErrorLetsRetrySucceed() async throws {
        let cache = try await resilienceStaleIfErrorCache(name: "fallback")
        let fresh = ResilienceUser(id: 2, name: "fresh")
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 503),
            resilienceQueuedResponse(statusCode: 200, body: fresh),
        ])
        let client = DefaultNetworkClient(
            configuration: resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .staleIfError(
                    wrapping: .cacheFirst(maxAge: .seconds(1))
                ),
                responseCache: cache,
                retryPolicy: ExponentialBackoffRetryPolicy(
                    maxRetries: 1,
                    retryDelay: 0,
                    jitterRatio: 0
                )
            ),
            session: session
        )

        let response = try await client.request(ResilienceGetRequest())

        #expect(response == fresh)
        #expect(await session.requestCount == 2)
    }

    @Test("stale-if-error recovers a terminal timeout")
    func staleIfErrorRecoversTimeout() async throws {
        let cache = try await resilienceStaleIfErrorCache(name: "offline")
        let session = ResilienceOutcomeURLSession(outcomes: [
            .failure(.timeout(reason: .requestTimeout))
        ])
        let client = DefaultNetworkClient(
            configuration: resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .staleIfError(
                    wrapping: .cacheFirst(maxAge: .seconds(1))
                ),
                responseCache: cache
            ),
            session: session
        )

        let response = try await client.request(ResilienceGetRequest())

        #expect(response == ResilienceUser(id: 1, name: "offline"))
        #expect(await session.requestCount == 1)
    }

    @Test("stale-if-error never reuses a no-cache response after failed validation")
    func staleIfErrorDoesNotRecoverNoCache() async throws {
        let cache = InMemoryResponseCache()
        await cache.set(
            resilienceUserCacheKey(),
            CachedResponse(
                data: try JSONEncoder().encode(ResilienceUser(id: 1, name: "must-validate")),
                headers: ["Cache-Control": "no-cache, max-age=10, stale-if-error=60"],
                storedAt: Date(timeIntervalSinceNow: -11),
                requiresRevalidation: false
            )
        )
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 503)
        ])
        let client = DefaultNetworkClient(
            configuration: resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .staleIfError(
                    wrapping: .rfc9111Compliant(
                        wrapping: .cacheFirst(maxAge: .seconds(10))
                    )
                ),
                responseCache: cache
            ),
            session: session
        )

        do {
            _ = try await client.request(ResilienceGetRequest())
            Issue.record("Expected the failed mandatory validation to surface")
        } catch NetworkError.statusCode(let response) {
            #expect(response.statusCode == 503)
        } catch {
            Issue.record("Expected the original 503 failure, got \(error)")
        }
        #expect(await session.requestCount == 1)
    }

    @Test("stale-if-error rechecks its window after the network attempt")
    func staleIfErrorRechecksWindowAfterNetworkAttempt() async throws {
        let clock = TestClock(epoch: Date(timeIntervalSince1970: 10_000))
        let cache = InMemoryResponseCache()
        await cache.set(
            resilienceUserCacheKey(),
            CachedResponse(
                data: try JSONEncoder().encode(ResilienceUser(id: 1, name: "expired")),
                headers: ["Cache-Control": "max-age=10, stale-if-error=5"],
                storedAt: Date(timeIntervalSince1970: 9_989)
            )
        )
        let session = ClockAdvancingResilienceURLSession(
            queued: try resilienceQueuedResponse(statusCode: 503),
            clock: clock,
            delay: .seconds(10)
        )
        let client = DefaultNetworkClient(
            configuration: resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .staleIfError(
                    wrapping: .rfc9111Compliant(
                        wrapping: .cacheFirst(maxAge: .seconds(10))
                    )
                ),
                responseCache: cache
            ),
            session: session,
            clock: clock
        )

        do {
            _ = try await client.request(ResilienceGetRequest())
            Issue.record("Expected stale-if-error to expire during transport")
        } catch NetworkError.statusCode(let response) {
            #expect(response.statusCode == 503)
        } catch {
            Issue.record("Expected the original 503 failure, got \(error)")
        }
    }

    @Test("stale-if-error never converts cancellation into success")
    func staleIfErrorDoesNotRecoverCancellation() async throws {
        let cache = try await resilienceStaleIfErrorCache(name: "must-not-return")
        let session = CancellationFirstURLSession(queue: [])
        let client = DefaultNetworkClient(
            configuration: resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .staleIfError(
                    wrapping: .cacheFirst(maxAge: .seconds(1))
                ),
                responseCache: cache
            ),
            session: session
        )
        let task = Task { try await client.request(ResilienceGetRequest()) }
        await session.waitUntilStarted()

        task.cancel()

        await expectCancelled(task)
    }

    @Test("An explicitly acceptable 503 is not replaced by stale-if-error")
    func staleIfErrorRespectsAcceptableStatusOverride() async throws {
        let cache = try await resilienceStaleIfErrorCache(name: "fallback")
        let accepted = ResilienceUser(id: 503, name: "accepted")
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 503, body: accepted)
        ])
        let client = DefaultNetworkClient(
            configuration: resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .staleIfError(
                    wrapping: .cacheFirst(maxAge: .seconds(1))
                ),
                responseCache: cache,
                acceptableStatusCodes: [503]
            ),
            session: session
        )

        let response = try await client.request(ResilienceGetRequest())

        #expect(response == accepted)
        #expect(await session.requestCount == 1)
    }
}

private func resilienceCacheExtensionConfiguration(
    policy: ResponseCachePolicy,
    cache: any ResponseCache,
    cacheControl: String
) -> NetworkConfiguration {
    resilienceMakeLocalizedCacheConfiguration(
        responseCachePolicy: policy,
        responseCache: cache,
        requestInterceptors: [
            ResilienceHeaderSettingInterceptor(
                field: "Cache-Control",
                value: cacheControl
            )
        ]
    )
}

private func resilienceStaleIfErrorCache(
    name: String,
    cacheControl: String = "stale-if-error=120"
) async throws -> InMemoryResponseCache {
    let cache = InMemoryResponseCache()
    await cache.set(
        resilienceUserCacheKey(),
        CachedResponse(
            data: try JSONEncoder().encode(ResilienceUser(id: 1, name: name)),
            headers: ["Cache-Control": cacheControl],
            storedAt: Date(timeIntervalSinceNow: -30)
        )
    )
    return cache
}

private actor ResilienceOutcomeURLSessionState {
    private var outcomes: [Result<ResilienceQueuedHTTPResponse, NetworkError>]
    private var requests: [URLRequest] = []

    init(outcomes: [Result<ResilienceQueuedHTTPResponse, NetworkError>]) {
        self.outcomes = outcomes
    }

    func next(for request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        guard !outcomes.isEmpty else {
            throw NetworkError.configuration(
                reason: .invalidRequest("No queued outcome.")
            )
        }
        let outcome = outcomes.removeFirst()
        switch outcome {
        case .success(let queued):
            return (queued.data, queued.response)
        case .failure(let error):
            throw error
        }
    }

    var requestCount: Int { requests.count }
}

private final class ResilienceOutcomeURLSession: URLSessionProtocol, Sendable {
    private let state: ResilienceOutcomeURLSessionState

    init(outcomes: [Result<ResilienceQueuedHTTPResponse, NetworkError>]) {
        self.state = ResilienceOutcomeURLSessionState(outcomes: outcomes)
    }

    var requestCount: Int { get async { await state.requestCount } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await state.next(for: request)
    }
}
