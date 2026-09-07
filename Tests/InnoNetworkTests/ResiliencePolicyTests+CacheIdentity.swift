import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork

extension ResiliencePolicyTests {
    @Test("Fresh cache returns without transport")
    func freshCacheShortCircuitsTransport() async throws {
        let cache = InMemoryResponseCache()
        let key = resilienceUserCacheKey()
        let body = try JSONEncoder().encode(ResilienceUser(id: 1, name: "cached"))
        await cache.set(key, CachedResponse(data: body, headers: ["ETag": "v1"]))
        let session = ResilienceSequenceURLSession(queue: [])
        let client = DefaultNetworkClient(
            configuration: resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
                responseCache: cache
            ),
            session: session
        )

        let user = try await client.request(ResilienceGetRequest())

        #expect(user == ResilienceUser(id: 1, name: "cached"))
        #expect(await session.requestCount == 0)
    }

    @Test("Stale cache lookup is shared with conditional revalidation")
    func staleCacheUsesOnePreTransportLookup() async throws {
        let cachedBody = try JSONEncoder().encode(ResilienceUser(id: 1, name: "cached"))
        let cache = ResilienceCountingResponseCache(
            cached: CachedResponse(
                data: cachedBody,
                headers: ["ETag": "v1"],
                storedAt: Date(timeIntervalSince1970: 0)
            )
        )
        let freshBody = ResilienceUser(id: 2, name: "fresh")
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 200, body: freshBody)
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                responseCachePolicy: .cacheFirst(maxAge: .seconds(1)),
                responseCache: cache
            ),
            session: session
        )

        let user = try await client.request(ResilienceGetRequest())

        #expect(user == freshBody)
        #expect(await cache.getCount == 1)
        #expect(await session.capturedRequests.first?.value(forHTTPHeaderField: "If-None-Match") == "v1")
    }

    @Test("Vary mismatch performs one lookup and skips conditional headers")
    func varyMismatchUsesOnePreTransportLookup() async throws {
        let cachedBody = try JSONEncoder().encode(ResilienceUser(id: 1, name: "cached"))
        let cache = ResilienceCountingResponseCache(
            cached: CachedResponse(
                data: cachedBody,
                headers: ["ETag": "v1", "Vary": "Accept-Language"],
                storedAt: Date(timeIntervalSince1970: 0),
                varyHeaders: ["accept-language": "definitely-not-the-request-language"]
            )
        )
        let freshBody = ResilienceUser(id: 2, name: "fresh")
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 200, body: freshBody)
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                responseCachePolicy: .cacheFirst(maxAge: .seconds(1)),
                responseCache: cache
            ),
            session: session
        )

        let user = try await client.request(ResilienceGetRequest())

        #expect(user == freshBody)
        #expect(await cache.getCount == 1)
        #expect(await session.capturedRequests.first?.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test("ETag 304 response uses cached body")
    func etagNotModifiedUsesCachedBody() async throws {
        let cache = InMemoryResponseCache()
        let recorder = ResilienceResponseRecorder()
        let key = resilienceUserCacheKey()
        let body = try JSONEncoder().encode(ResilienceUser(id: 1, name: "cached"))
        let storedAt = Date(timeIntervalSinceNow: -60)
        await cache.set(
            key,
            CachedResponse(
                data: body,
                headers: ["ETag": "v1"],
                storedAt: storedAt
            )
        )
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 304, headers: ["ETag": "v2", "Cache-Control": "max-age=60"])
        ])
        let client = DefaultNetworkClient(
            configuration: resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .cacheFirst(maxAge: .seconds(1)),
                responseCache: cache,
                responseInterceptors: [ResilienceRecordingResponseInterceptor(recorder: recorder)]
            ),
            session: session
        )

        let user = try await client.request(ResilienceGetRequest())

        #expect(user == ResilienceUser(id: 1, name: "cached"))
        #expect(await session.capturedRequests.first?.value(forHTTPHeaderField: "If-None-Match") == "v1")
        let observedResponse = try #require(await recorder.response())
        #expect(observedResponse.statusCode == 200)
        #expect(resilienceResponseHeader(observedResponse, named: "ETag") == "v2")
        #expect(resilienceResponseHeader(observedResponse, named: "Cache-Control") == "max-age=60")
        let refreshed = try #require(await cache.get(key))
        #expect(refreshed.etag == "v2")
        #expect(
            refreshed.headers.first { $0.key.caseInsensitiveCompare("Cache-Control") == .orderedSame }?.value
                == "max-age=60")
        #expect(refreshed.storedAt > storedAt)
    }

    @Test("Last-Modified 304 response uses cached body")
    func lastModifiedNotModifiedUsesCachedBody() async throws {
        let cache = InMemoryResponseCache()
        let key = resilienceUserCacheKey()
        let body = try JSONEncoder().encode(ResilienceUser(id: 1, name: "cached"))
        let lastModified = "Wed, 21 Oct 2015 07:28:00 GMT"
        await cache.set(
            key,
            CachedResponse(
                data: body,
                headers: ["Last-Modified": lastModified],
                storedAt: Date(timeIntervalSinceNow: -60)
            )
        )
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 304, headers: ["Cache-Control": "max-age=60"])
        ])
        let client = DefaultNetworkClient(
            configuration: resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .cacheFirst(maxAge: .seconds(1)),
                responseCache: cache
            ),
            session: session
        )

        let user = try await client.request(ResilienceGetRequest())

        #expect(user == ResilienceUser(id: 1, name: "cached"))
        #expect(
            await session.capturedRequests.first?.value(forHTTPHeaderField: "If-Modified-Since")
                == lastModified
        )
        #expect(await session.capturedRequests.first?.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test("Conditional revalidation sends both valid validators")
    func conditionalRevalidationSendsBothValidators() async throws {
        let cache = InMemoryResponseCache()
        let key = resilienceUserCacheKey()
        let lastModified = "Wed, 21 Oct 2015 07:28:00 GMT"
        await cache.set(
            key,
            CachedResponse(
                data: try JSONEncoder().encode(ResilienceUser(id: 1, name: "cached")),
                headers: ["ETag": "v1", "Last-Modified": lastModified],
                storedAt: Date(timeIntervalSinceNow: -60)
            )
        )
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 304)
        ])
        let client = DefaultNetworkClient(
            configuration: resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .cacheFirst(maxAge: .seconds(1)),
                responseCache: cache
            ),
            session: session
        )

        _ = try await client.request(ResilienceGetRequest())

        let request = try #require(await session.capturedRequests.first)
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == "v1")
        #expect(request.value(forHTTPHeaderField: "If-Modified-Since") == lastModified)
    }

    @Test("Malformed Last-Modified is not emitted as a conditional header")
    func malformedLastModifiedIsNotEmitted() async throws {
        let cache = InMemoryResponseCache()
        let key = resilienceUserCacheKey()
        let fresh = ResilienceUser(id: 2, name: "fresh")
        await cache.set(
            key,
            CachedResponse(
                data: try JSONEncoder().encode(ResilienceUser(id: 1, name: "cached")),
                headers: ["Last-Modified": "tomorrow-ish"],
                storedAt: Date(timeIntervalSinceNow: -60)
            )
        )
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 200, body: fresh)
        ])
        let client = DefaultNetworkClient(
            configuration: resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .cacheFirst(maxAge: .seconds(1)),
                responseCache: cache
            ),
            session: session
        )

        let user = try await client.request(ResilienceGetRequest())

        #expect(user == fresh)
        #expect(
            await session.capturedRequests.first?.value(forHTTPHeaderField: "If-Modified-Since") == nil
        )
    }

    @Test("Background stale revalidation uses Last-Modified")
    func staleWhileRevalidateUsesLastModified() async throws {
        let cache = InMemoryResponseCache()
        let key = resilienceUserCacheKey()
        let lastModified = "Wed, 21 Oct 2015 07:28:00 GMT"
        let storedAt = Date(timeIntervalSinceNow: -5)
        let cachedUser = ResilienceUser(id: 1, name: "cached")
        await cache.set(
            key,
            CachedResponse(
                data: try JSONEncoder().encode(cachedUser),
                headers: ["Last-Modified": lastModified],
                storedAt: storedAt
            )
        )
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 304, headers: ["Cache-Control": "max-age=60"])
        ])
        let client = DefaultNetworkClient(
            configuration: resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .staleWhileRevalidate(
                    maxAge: .seconds(1),
                    staleWindow: .seconds(10)
                ),
                responseCache: cache
            ),
            session: session
        )

        let user = try await client.request(ResilienceGetRequest())
        try await waitUntil {
            await cache.get(key)?.storedAt ?? storedAt > storedAt
        }

        #expect(user == cachedUser)
        #expect(
            await session.capturedRequests.first?.value(forHTTPHeaderField: "If-Modified-Since")
                == lastModified
        )
        #expect(await cache.get(key)?.storedAt ?? storedAt > storedAt)
    }

    @Test("304 after cached entry disappears throws cacheRevalidationFailed")
    func etagNotModifiedThrowsWhenCachedEntryDisappears() async throws {
        let cache = InMemoryResponseCache()
        let key = resilienceUserCacheKey()
        let body = try JSONEncoder().encode(ResilienceUser(id: 1, name: "cached"))
        await cache.set(
            key,
            CachedResponse(
                data: body,
                headers: ["ETag": "v1"],
                storedAt: Date(timeIntervalSinceNow: -60)
            )
        )
        let session = ResilienceCacheInvalidatingURLSession(
            cache: cache,
            cacheKey: key,
            resilienceQueuedResponse: try resilienceQueuedResponse(statusCode: 304, headers: ["ETag": "v2"])
        )
        let client = DefaultNetworkClient(
            configuration: resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .cacheFirst(maxAge: .seconds(1)),
                responseCache: cache
            ),
            session: session
        )

        do {
            _ = try await client.request(ResilienceGetRequest())
            Issue.record("Expected cache-revalidation-failed underlying error, got success")
        } catch {
            guard case .underlying(let underlying, let cached?) = error,
                underlying.domain == "InnoNetwork.ResponseCache"
            else {
                Issue.record("Expected .underlying with InnoNetwork.ResponseCache domain, got \(error)")
                return
            }
            #expect(cached.statusCode == 200)
        }
    }

    @Test("304 carrying a different Vary header invalidates the stored vary snapshot")
    func etagNotModifiedWithChangedVaryInvalidatesSnapshot() async throws {
        let cache = InMemoryResponseCache()
        let recorder = ResilienceResponseRecorder()
        let key = resilienceUserCacheKey()
        let body = try JSONEncoder().encode(ResilienceUser(id: 1, name: "cached"))
        let storedAt = Date(timeIntervalSinceNow: -60)
        await cache.set(
            key,
            CachedResponse(
                data: body,
                headers: ["ETag": "v1", "Vary": "Accept-Language"],
                storedAt: storedAt,
                varyHeaders: ["accept-language": cacheFixtureAcceptLanguage]
            )
        )
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(
                statusCode: 304,
                headers: ["ETag": "v2", "Vary": "Accept"]
            )
        ])
        let client = DefaultNetworkClient(
            configuration: resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .cacheFirst(maxAge: .seconds(1)),
                responseCache: cache,
                responseInterceptors: [ResilienceRecordingResponseInterceptor(recorder: recorder)]
            ),
            session: session
        )

        let user = try await client.request(ResilienceGetRequest())

        #expect(user == ResilienceUser(id: 1, name: "cached"))
        let observedResponse = try #require(await recorder.response())
        #expect(observedResponse.statusCode == 200)
        #expect(resilienceResponseHeader(observedResponse, named: "Vary") == "Accept-Language")
        #expect(resilienceResponseHeader(observedResponse, named: "ETag") == "v1")
        #expect(await cache.get(key) == nil)
    }

    @Test("SWR returns stale data and revalidates in the background")
    func staleWhileRevalidateUpdatesCache() async throws {
        let cache = InMemoryResponseCache()
        let key = resilienceUserCacheKey()
        let staleBody = try JSONEncoder().encode(ResilienceUser(id: 1, name: "stale"))
        await cache.set(
            key,
            CachedResponse(
                data: staleBody,
                headers: ["ETag": "v1"],
                storedAt: Date(timeIntervalSinceNow: -5)
            )
        )
        let fresh = ResilienceUser(id: 1, name: "fresh")
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 200, body: fresh, headers: ["ETag": "v2"])
        ])
        let client = DefaultNetworkClient(
            configuration: resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .staleWhileRevalidate(maxAge: .seconds(1), staleWindow: .seconds(10)),
                responseCache: cache
            ),
            session: session
        )

        let returned = try await client.request(ResilienceGetRequest())

        #expect(returned == ResilienceUser(id: 1, name: "stale"))
        try await waitUntil {
            guard let cached = await cache.get(key),
                let decoded = try? JSONDecoder().decode(ResilienceUser.self, from: cached.data)
            else {
                return false
            }
            return await session.requestCount == 1 && decoded == fresh
        }
        #expect(await session.capturedRequests.first?.value(forHTTPHeaderField: "If-None-Match") == "v1")
    }

    @Test("SWR revalidation events carry original request ID")
    func staleWhileRevalidateRevalidationEventsUseOriginalRequestID() async throws {
        let cache = InMemoryResponseCache()
        let key = resilienceUserCacheKey()
        let stale = ResilienceUser(id: 1, name: "stale")
        let staleBody = try JSONEncoder().encode(stale)
        await cache.set(
            key,
            CachedResponse(
                data: staleBody,
                headers: ["ETag": "v1"],
                storedAt: Date(timeIntervalSinceNow: -5)
            )
        )
        let store = NetworkEventStore()
        let observer = RecordingNetworkEventObserver(store: store)
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(
                statusCode: 200, body: ResilienceUser(id: 1, name: "fresh"), headers: ["ETag": "v2"])
        ])
        let client = DefaultNetworkClient(
            configuration: resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .staleWhileRevalidate(maxAge: .seconds(1), staleWindow: .seconds(10)),
                responseCache: cache,
                eventObservers: [observer]
            ),
            session: session
        )

        let returned = try await client.request(ResilienceGetRequest())

        #expect(returned == stale)
        try await waitUntil {
            let states = await resilienceRecordedRevalidationEvents(in: store).map { $0.state }
            return states == [
                CacheRevalidationState.scheduled,
                CacheRevalidationState.completed(statusCode: 200),
            ]
        }

        let events = await store.snapshot()
        let resilienceOriginalRequestID = try #require(events.compactMap(resilienceOriginalRequestID(from:)).first)
        let observedRevalidationEvents = await resilienceRecordedRevalidationEvents(in: store)
        #expect(!observedRevalidationEvents.isEmpty)
        #expect(observedRevalidationEvents.allSatisfy { $0.originalID == resilienceOriginalRequestID })
    }

    @Test("SWR background revalidation uses request coalescing")
    func staleWhileRevalidateBackgroundRevalidationCoalesces() async throws {
        let cache = InMemoryResponseCache()
        let key = resilienceUserCacheKey()
        let stale = ResilienceUser(id: 1, name: "stale")
        let staleBody = try JSONEncoder().encode(stale)
        await cache.set(
            key,
            CachedResponse(
                data: staleBody,
                headers: ["ETag": "v1"],
                storedAt: Date(timeIntervalSinceNow: -5)
            )
        )
        let fresh = ResilienceUser(id: 1, name: "fresh")
        let session = try ResilienceSequenceURLSession(
            queue: [
                resilienceQueuedResponse(statusCode: 200, body: fresh, headers: ["ETag": "v2"])
            ],
            delay: .milliseconds(80)
        )
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: URL(string: "https://api.example.com")!,
                requestInterceptors: [
                    ResilienceHeaderSettingInterceptor(field: "Accept-Language", value: cacheFixtureAcceptLanguage)
                ],
                requestCoalescingPolicy: .getOnly,
                responseCachePolicy: .staleWhileRevalidate(maxAge: .seconds(1), staleWindow: .seconds(10)),
                responseCache: cache,
                responseBodyBufferingPolicy: .buffered(maxBytes: nil)
            ),
            session: session
        )

        async let first = client.request(ResilienceGetRequest())
        async let second = client.request(ResilienceGetRequest())
        let returned = try await [first, second]

        #expect(returned == [stale, stale])
        try await waitUntil {
            guard let cached = await cache.get(key),
                let decoded = try? JSONDecoder().decode(ResilienceUser.self, from: cached.data)
            else {
                return false
            }
            return await session.requestCount == 1 && decoded == fresh
        }
        #expect(await session.requestCount == 1)
    }

    @Test("SWR background revalidation is cancelled by cancelAll")
    func staleWhileRevalidateBackgroundTaskIsCancelledByCancelAll() async throws {
        let cache = InMemoryResponseCache()
        let key = resilienceUserCacheKey()
        let stale = ResilienceUser(id: 1, name: "stale")
        let staleBody = try JSONEncoder().encode(stale)
        await cache.set(
            key,
            CachedResponse(
                data: staleBody,
                headers: ["ETag": "v1"],
                storedAt: Date(timeIntervalSinceNow: -5)
            )
        )
        let session = try ResilienceSequenceURLSession(
            queue: [
                resilienceQueuedResponse(
                    statusCode: 200, body: ResilienceUser(id: 1, name: "fresh"), headers: ["ETag": "v2"])
            ],
            delay: .milliseconds(200)
        )
        let client = DefaultNetworkClient(
            configuration: resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .staleWhileRevalidate(maxAge: .seconds(1), staleWindow: .seconds(10)),
                responseCache: cache
            ),
            session: session
        )

        let returned = try await client.request(ResilienceGetRequest())

        #expect(returned == stale)
        try await waitUntil {
            await session.requestCount == 1
        }
        await client.cancelAll()
        try await Task.sleep(for: .milliseconds(250))
        let cached = await cache.get(key)
        let decoded = try #require(cached.flatMap { try? JSONDecoder().decode(ResilienceUser.self, from: $0.data) })
        #expect(decoded == stale)
    }

    @Test("Response cache keeps different Authorization headers separate")
    func responseCacheSeparatesAuthorizationHeaders() async throws {
        let cache = InMemoryResponseCache()
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "one")),
            resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 2, name: "two")),
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
                responseCache: cache
            ),
            session: session
        )

        let first = try await client.request(AuthorizedResilienceGetRequest(token: "one"))
        let second = try await client.request(AuthorizedResilienceGetRequest(token: "two"))

        #expect(first == ResilienceUser(id: 1, name: "one"))
        #expect(second == ResilienceUser(id: 2, name: "two"))
        #expect(await session.requestCount == 2)
    }

    @Test("Authorization responses without explicit RFC 9111 permission are not cached")
    func responseCacheRejectsAuthorizedResponseWithoutPermissionDirective() async throws {
        let cache = InMemoryResponseCache()
        let cacheKey = authorizedResilienceUserCacheKey(token: "one")
        await cache.set(
            cacheKey,
            CachedResponse(
                data: try JSONEncoder().encode(ResilienceUser(id: 1, name: "legacy")),
                headers: ["Cache-Control": "public"],
                storedAt: Date(timeIntervalSinceNow: -60)
            )
        )
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "fresh"))
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                responseCachePolicy: .cacheFirst(maxAge: .seconds(1)),
                responseCache: cache,
                acceptLanguageProvider: { cacheFixtureAcceptLanguage }
            ),
            session: session
        )

        let user = try await client.request(AuthorizedResilienceGetRequest(token: "one"))

        #expect(user == ResilienceUser(id: 1, name: "fresh"))
        #expect(await cache.get(cacheKey) == nil)
    }

    @Test(
        "Authorization responses are cached only with RFC 9111 permission directives",
        arguments: ["public", "must-revalidate", "s-maxage=60"])
    func responseCacheStoresAuthorizedResponsesWithPermissionDirective(cacheControl: String) async throws {
        let cache = InMemoryResponseCache()
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(
                statusCode: 200,
                body: ResilienceUser(id: 1, name: cacheControl),
                headers: ["Cache-Control": cacheControl]
            )
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
                responseCache: cache,
                acceptLanguageProvider: { cacheFixtureAcceptLanguage }
            ),
            session: session
        )

        _ = try await client.request(AuthorizedResilienceGetRequest(token: "one"))

        let cacheKey = authorizedResilienceUserCacheKey(token: "one")
        let cached = try #require(await cache.get(cacheKey))
        let decoded = try JSONDecoder().decode(ResilienceUser.self, from: cached.data)
        #expect(decoded == ResilienceUser(id: 1, name: cacheControl))
    }

    @Test("Response cache key fingerprints Authorization header values")
    func responseCacheKeyFingerprintsAuthorizationHeaderValues() {
        let first = ResponseCacheKey(
            method: "GET",
            url: "https://api.example.com/users/1",
            headers: ["Authorization": "Bearer secret-one"]
        )
        let second = ResponseCacheKey(
            method: "GET",
            url: "https://api.example.com/users/1",
            headers: ["Authorization": "Bearer secret-two"]
        )

        #expect(first != second)
        #expect(first.headers.contains { $0.contains("authorization:sha256:") })
        #expect(!first.headers.contains { $0.contains("secret-one") })
        #expect(!second.headers.contains { $0.contains("secret-two") })
    }

    @Test("Client-scoped sensitive headers reach executor-owned cache keys")
    func clientScopedSensitiveHeadersReachExecutorCacheKeys() async throws {
        let cache = ResilienceCountingResponseCache()
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "cached"))
        ])
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com")!,
            requestInterceptors: [
                ResilienceHeaderSettingInterceptor(field: "X-Tenant-Token", value: "tenant-secret")
            ],
            responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
            responseCache: cache,
            responseCacheSensitiveHeaderNames: ["X-Tenant-Token"],
            responseBodyBufferingPolicy: .buffered(maxBytes: nil)
        )
        let client = DefaultNetworkClient(configuration: configuration, session: session)

        _ = try await client.request(ResilienceGetRequest())

        let key = try #require(await cache.lastSetKey)
        #expect(key.headers.contains { $0.hasPrefix("x-tenant-token:sha256:") })
        #expect(key.headers.contains { $0.contains("tenant-secret") } == false)
    }

    @Test("Response cache key strips URL fragments")
    func responseCacheKeyStripsURLFragments() throws {
        var firstRequest = URLRequest(url: try #require(URL(string: "https://api.example.com/users/1#first")))
        firstRequest.httpMethod = "GET"
        var secondRequest = URLRequest(url: try #require(URL(string: "https://api.example.com/users/1#second")))
        secondRequest.httpMethod = "GET"

        let first = try #require(ResponseCacheKey(request: firstRequest))
        let second = try #require(ResponseCacheKey(request: secondRequest))

        #expect(first == second)
        #expect(first.url == "https://api.example.com/users/1")
    }

    @Test(
        "Response cache stores RFC-cacheable GET status codes",
        arguments: [203, 300, 301, 308, 404, 405, 410, 414, 501])
    func responseCacheStoresCacheableStatusCodes(statusCode: Int) async throws {
        let cache = InMemoryResponseCache()
        let body = ResilienceUser(id: statusCode, name: "cached-\(statusCode)")
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: statusCode, body: body)
        ])
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com")!,
            acceptableStatusCodes: NetworkConfiguration.defaultAcceptableStatusCodes.union([statusCode]),
            requestInterceptors: [
                ResilienceHeaderSettingInterceptor(field: "Accept-Language", value: cacheFixtureAcceptLanguage)
            ],
            responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
            responseCache: cache,
            responseBodyBufferingPolicy: .buffered(maxBytes: nil)
        )
        let client = DefaultNetworkClient(configuration: configuration, session: session)

        let user = try await client.request(ResilienceGetRequest())

        #expect(user == body)
        let stored = try #require(await cache.get(resilienceUserCacheKey()))
        #expect(stored.statusCode == statusCode)

        let cachedOnlySession = ResilienceSequenceURLSession(queue: [])
        let cachedOnlyClient = DefaultNetworkClient(configuration: configuration, session: cachedOnlySession)
        let cachedUser = try await cachedOnlyClient.request(ResilienceGetRequest())

        #expect(cachedUser == body)
        #expect(await cachedOnlySession.requestCount == 0)
    }

}
