import Foundation
import InnoNetwork
import Testing

@testable import InnoNetworkPersistentCache

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Security)
import Security
#endif

extension PersistentResponseCacheTests {
    @Test("RFC initial age persists across cache reopen")
    func rfcInitialAgePersistsAcrossReopen() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/aged")
        let storedAt = Date(timeIntervalSince1970: 10_000)
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(
            key,
            CachedResponse(
                data: Data("aged".utf8),
                headers: ["Cache-Control": "max-age=60"],
                storedAt: storedAt,
                rfc9111InitialAge: 45
            )
        )

        let reopened = try PersistentResponseCache(configuration: configuration)
        let cached = try #require(await reopened.get(key))

        #expect(cached.rfc9111InitialAge == 45)
        switch ResponseCachePolicy.rfc9111Compliant(
            wrapping: .cacheFirst(maxAge: .seconds(60))
        ).prepare(cached: cached, now: storedAt.addingTimeInterval(15)) {
        case .revalidate:
            break
        default:
            Issue.record("persistent reopen must not reset the response's current age")
        }
    }

    @Test("Persistent cache opens entries written before RFC age metadata existed")
    func legacyEntryWithoutRFCInitialAgeStillOpens() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/legacy-aged")
        let storedAt = Date(timeIntervalSince1970: 10_000)
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(
            key,
            CachedResponse(
                data: Data("legacy".utf8),
                headers: ["Cache-Control": "max-age=60", "Age": "20"],
                storedAt: storedAt
            )
        )

        var index = try indexObject(in: directory)
        var entries = try #require(index["entries"] as? [String: Any])
        let entryID = try #require(entries.keys.first)
        var entry = try #require(entries[entryID] as? [String: Any])
        entry.removeValue(forKey: "rfc9111InitialAge")
        entries[entryID] = entry
        index["entries"] = entries
        let indexURL = directory.appendingPathComponent("index.json", isDirectory: false)
        let data = try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
        try data.write(to: indexURL, options: .atomic)

        let reopened = try PersistentResponseCache(configuration: configuration)
        let cached = try #require(await reopened.get(key))
        #expect(cached.data == Data("legacy".utf8))
        #expect(cached.rfc9111InitialAge == 20)
    }

    @Test("stale-if-error metadata remains enforceable after persistent-cache reopen")
    func staleIfErrorMetadataSurvivesReopen() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/resilient")
        let storedAt = Date(timeIntervalSinceNow: -30)
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(
            key,
            CachedResponse(
                data: Data("fallback".utf8),
                headers: ["Cache-Control": "stale-if-error=60"],
                storedAt: storedAt
            )
        )

        let reopened = try PersistentResponseCache(configuration: configuration)
        let cached = try #require(await reopened.get(key))
        let policy = ResponseCachePolicy.staleIfError(
            wrapping: .cacheFirst(maxAge: .seconds(1))
        )

        #expect(
            policy.staleIfErrorFallback(cached: cached, now: storedAt.addingTimeInterval(30))
                == cached
        )
    }

    @Test("Cache persists entries across actor instances")
    func persistsAcrossInstances() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/user")
        let response = CachedResponse(data: Data("cached".utf8), headers: ["ETag": "v1"])

        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(key, response)
        let bodyFileName = try #require(existingBodyURLs(in: directory).first?.lastPathComponent)
        #expect(
            (try? PersistentResponseCache.validatedBodyURL(
                fileName: bodyFileName,
                in: directory.appendingPathComponent("bodies", isDirectory: true)
            )) != nil
        )

        let reader = try PersistentResponseCache(configuration: configuration)
        let cached = try #require(await reader.get(key))

        #expect(cached.data == response.data)
        #expect(cached.headers["ETag"] == "v1")
    }

    @Test("Target URI invalidation removes all variants and persists across reopen")
    func invalidateTargetURIRemovesVariantsAcrossReopen() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let first = ResponseCacheKey(
            method: "GET",
            url: "HTTPS://EXAMPLE.COM/items?b=2&a=1#first",
            headers: ["Accept-Language": "en-US"]
        )
        let second = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/items?b=2&a=1#second",
            headers: ["Accept-Language": "ko-KR"]
        )
        let third = ResponseCacheKey(
            method: "HEAD",
            url: "https://example.com/items?b=2&a=1",
            headers: ["X-Variant": "metadata"]
        )
        let other = ResponseCacheKey(method: "GET", url: "https://example.com/items?a=1&b=3")
        let cache = try PersistentResponseCache(configuration: configuration)

        await cache.set(first, CachedResponse(data: Data("first".utf8)))
        await cache.set(second, CachedResponse(data: Data("second".utf8)))
        await cache.set(third, CachedResponse(data: Data("third".utf8)))
        await cache.set(other, CachedResponse(data: Data("other".utf8)))

        await cache.invalidateTargetURI("https://EXAMPLE.com/items?b=2&a=1#latest")

        #expect(await cache.get(first) == nil)
        #expect(await cache.get(second) == nil)
        #expect(await cache.get(third) == nil)
        #expect(await cache.get(other)?.data == Data("other".utf8))

        let reopened = try PersistentResponseCache(configuration: configuration)
        #expect(await reopened.get(first) == nil)
        #expect(await reopened.get(second) == nil)
        #expect(await reopened.get(third) == nil)
        #expect(await reopened.get(other)?.data == Data("other".utf8))
    }

    @Test("Query order remains distinct across persistent-cache reopen")
    func queryOrderRemainsDistinctAcrossReopen() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let first = ResponseCacheKey(method: "GET", url: "https://example.com/items?a=1&b=2")
        let second = ResponseCacheKey(method: "GET", url: "https://example.com/items?b=2&a=1")

        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(first, CachedResponse(data: Data("first".utf8)))
        await writer.set(second, CachedResponse(data: Data("second".utf8)))

        let reader = try PersistentResponseCache(configuration: configuration)
        #expect(await reader.get(first)?.data == Data("first".utf8))
        #expect(await reader.get(second)?.data == Data("second".utf8))
    }

    @Test("Persistent query identity is HMAC protected on disk")
    func persistentQueryIdentityIsHMACProtectedOnDisk() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/search?token=low-entropy-secret&scope=admin"
        )
        let cache = try PersistentResponseCache(configuration: configuration)

        await cache.set(key, CachedResponse(data: Data("private-query".utf8)))

        let indexText = try String(contentsOf: indexURL(in: directory), encoding: .utf8)
        #expect(!indexText.contains("low-entropy-secret"))
        #expect(!indexText.contains("token="))
        #expect(!indexText.contains("scope="))
        #expect(indexText.contains("__innonetwork_query_hmac_sha256="))

        let reopened = try PersistentResponseCache(configuration: configuration)
        #expect(await reopened.get(key)?.data == Data("private-query".utf8))
        await reopened.invalidateTargetURI(key.url)
        #expect(await reopened.get(key) == nil)
    }

    @Test("Same key with different Vary snapshots stores distinct persistent variants")
    func sameKeyDifferentVarySnapshotsDoNotOverwrite() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/negotiated",
            headers: [
                "Accept": "application/json",
                "Accept-Language": "en-US",
            ]
        )
        let cache = try PersistentResponseCache(configuration: configuration)

        await cache.set(
            key,
            CachedResponse(
                data: Data("language".utf8),
                headers: ["Vary": "Accept-Language"],
                varyHeaders: ["accept-language": "ko-KR"]
            )
        )
        await cache.set(
            key,
            CachedResponse(
                data: Data("accept".utf8),
                headers: ["Vary": "Accept"],
                varyHeaders: ["accept": "application/json"]
            )
        )

        #expect(await cache.statistics().entryCount == 2)
        #expect(await cache.get(key)?.data == Data("accept".utf8))

        await cache.set(
            key,
            CachedResponse(
                data: Data("accept-v2".utf8),
                headers: ["Vary": "Accept"],
                varyHeaders: ["accept": "application/json"]
            )
        )
        #expect(await cache.statistics().entryCount == 2)
        #expect(await cache.get(key)?.data == Data("accept-v2".utf8))

        let reopened = try PersistentResponseCache(configuration: configuration)
        #expect(await reopened.statistics().entryCount == 2)
        #expect(await reopened.get(key)?.data == Data("accept-v2".utf8))

        await reopened.invalidate(key)
        #expect(await reopened.statistics().entryCount == 0)
    }

    @Test("Authorization Vary lookup stays scoped by the HMAC disk key")
    func authorizationVaryLookupRequiresSamePersistentDiskKey() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(
            directoryURL: directory,
            storesAuthenticatedResponses: true
        )
        let firstKey = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/me",
            headers: ["Authorization": "Bearer first"]
        )
        let secondKey = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/me",
            headers: ["Authorization": "Bearer second"]
        )
        var headers = Self.authenticatedCacheHeaders
        headers["Vary"] = "Authorization"
        let legacySHA256Fingerprint = "sha256:\(String(repeating: "0", count: 64))"
        let cache = try PersistentResponseCache(configuration: configuration)

        await cache.set(
            firstKey,
            CachedResponse(
                data: Data("first".utf8),
                headers: headers,
                varyHeaders: ["authorization": legacySHA256Fingerprint]
            )
        )

        #expect(await cache.get(firstKey)?.data == Data("first".utf8))
        #expect(await cache.get(secondKey) == nil)

        let reopened = try PersistentResponseCache(configuration: configuration)
        #expect(await reopened.get(firstKey)?.data == Data("first".utf8))
        #expect(await reopened.get(secondKey) == nil)
    }

    @Test("Persistent multi-token Vary lookup matches core token-set parity")
    func persistentMultiTokenVaryLookupMatchesCoreTokenSetParity() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/compressed",
            headers: ["Accept-Encoding": "deflate, gzip"]
        )
        let cached = CachedResponse(
            data: Data("compressed".utf8),
            headers: ["Vary": "Accept-Encoding"],
            varyHeaders: ["accept-encoding": "gzip, deflate"]
        )
        var request = URLRequest(url: URL(string: "https://example.com/compressed")!)
        request.setValue("deflate, gzip", forHTTPHeaderField: "Accept-Encoding")
        let cache = try PersistentResponseCache(configuration: configuration)

        #expect(cachedResponseMatchesVary(cached, request: request))

        await cache.set(key, cached)

        #expect(await cache.get(key)?.data == Data("compressed".utf8))

        let reopened = try PersistentResponseCache(configuration: configuration)
        #expect(await reopened.get(key)?.data == Data("compressed".utf8))
    }

    @Test("RFC 9111 compliant policy reads heuristic-fresh persistent entries end to end")
    func rfc9111CompliantPolicyReadsHeuristicFreshPersistentEntry() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/users/1",
            headers: ["Accept-Language": "en-US"]
        )
        let body = try JSONEncoder().encode(PersistentCacheUser(id: 1, name: "cached"))
        await cache.set(
            key,
            CachedResponse(
                data: body,
                headers: ["Last-Modified": "Thu, 01 Jan 1970 00:00:00 GMT"],
                storedAt: Date()
            )
        )
        let session = FailingPersistentCacheURLSession()
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: URL(string: "https://example.com")!,
                responseCachePolicy: .rfc9111Compliant(wrapping: .cacheFirst(maxAge: .seconds(48 * 60 * 60))),
                responseCache: cache,
                acceptLanguageProvider: { "en-US" }
            ),
            session: session
        )

        let user = try await client.request(
            EndpointBuilder<PersistentCacheUser>(method: .get, path: "/users/1")
        )

        #expect(user == PersistentCacheUser(id: 1, name: "cached"))
        #expect(await session.requestCount == 0)
    }

    @Test("Persistent reopen preserves Last-Modified for conditional revalidation")
    func persistentReopenPreservesLastModifiedValidator() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(directoryURL: directory)
        let key = ResponseCacheKey(method: "GET", url: "https://example.com/users/1")
        let lastModified = "Wed, 21 Oct 2015 07:28:00 GMT"
        let writer = try PersistentResponseCache(configuration: configuration)
        await writer.set(
            key,
            CachedResponse(
                data: Data("cached".utf8),
                headers: ["Last-Modified": lastModified],
                storedAt: Date(timeIntervalSince1970: 0)
            )
        )

        let reopened = try PersistentResponseCache(configuration: configuration)
        let cached = try #require(await reopened.get(key))

        #expect(cached.lastModified == lastModified)
        #expect(cached.storedAt == Date(timeIntervalSince1970: 0))
    }

    @Test("Default policy rejects authenticated and Set-Cookie responses")
    func rejectsPrivateResponsesByDefault() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        let authenticatedKey = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/me",
            headers: ["Authorization": "Bearer secret"]
        )
        let cookieKey = ResponseCacheKey(method: "GET", url: "https://example.com/cookie")

        await cache.set(authenticatedKey, CachedResponse(data: Data("private".utf8)))
        await cache.set(cookieKey, CachedResponse(data: Data("cookie".utf8), headers: ["Set-Cookie": "sid=1"]))

        #expect(await cache.get(authenticatedKey) == nil)
        #expect(await cache.get(cookieKey) == nil)
    }

    @Test("Authenticated responses require RFC 9111 storage permission even when opt-in is enabled")
    func authenticatedResponsesRequireStoragePermission() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(
                directoryURL: directory,
                storesAuthenticatedResponses: true
            )
        )
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/me",
            headers: ["Authorization": "Bearer secret"]
        )

        await cache.set(key, CachedResponse(data: Data("private".utf8)))

        #expect(await cache.get(key) == nil)
    }

    @Test(
        "Authenticated responses store with RFC 9111 permission directives",
        arguments: ["public", "must-revalidate", "s-maxage=60"])
    func authenticatedResponsesStoreWithPermissionDirective(cacheControl: String) async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(
                directoryURL: directory,
                storesAuthenticatedResponses: true
            )
        )
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/me",
            headers: ["Authorization": "Bearer secret"]
        )

        await cache.set(
            key,
            CachedResponse(data: Data("private".utf8), headers: ["Cache-Control": cacheControl])
        )

        #expect(await cache.get(key)?.data == Data("private".utf8))
    }

    @Test("Default policy rejects Cookie request keys")
    func rejectsCookieRequestKeysByDefault() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/me",
            headers: ["Cookie": "sid=secret"]
        )

        await cache.set(key, CachedResponse(data: Data("cookie-auth".utf8)))

        #expect(await cache.get(key) == nil)
    }

    @Test("Default policy rejects value-scoped sensitive request keys")
    func rejectsValueScopedSensitiveRequestKeysByDefault() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let headerName = "X-Session-\(UUID().uuidString)"
        let cache = try PersistentResponseCache(
            configuration: PersistentResponseCacheConfiguration(directoryURL: directory)
        )
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/me",
            headers: [headerName: "secret"],
            sensitiveHeaderNames: [headerName]
        )

        await cache.set(key, CachedResponse(data: Data("custom-auth".utf8)))

        #expect(await cache.get(key) == nil)
    }

    @Test("Sensitive request header detection trims field-name whitespace")
    func sensitiveRequestHeaderDetectionTrimsFieldNameWhitespace() {
        #expect(
            PersistentResponseCache.containsSensitiveRequestHeader([
                " Authorization \t: Bearer secret"
            ])
        )
    }

    @Test("Authenticated persistent keys are HMAC protected on disk")
    func authenticatedPersistentKeysAreHMACProtectedOnDisk() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = PersistentResponseCacheConfiguration(
            directoryURL: directory,
            storesAuthenticatedResponses: true
        )
        let key = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/me",
            headers: ["Authorization": "Bearer low-entropy-secret"]
        )
        let cache = try PersistentResponseCache(configuration: configuration)

        await cache.set(key, CachedResponse(data: Data("private".utf8), headers: Self.authenticatedCacheHeaders))

        let cached = try #require(await cache.get(key))
        #expect(cached.data == Data("private".utf8))
        let indexText = try String(contentsOf: indexURL(in: directory), encoding: .utf8)
        #expect(!indexText.contains("Bearer low-entropy-secret"))
        #expect(!indexText.contains("authorization:sha256:"))
        #expect(indexText.contains("hmac-sha256:"))
        #expect(FileManager.default.fileExists(atPath: hmacKeyURL(in: directory).path))
    }

    @Test("Persistent cache key normalizer trims optional header whitespace")
    func persistentCacheKeyNormalizerTrimsOptionalHeaderWhitespace() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try PersistentCacheDiskKeyNormalizer.loadOrCreate(
            directoryURL: directory,
            dataProtectionClass: .completeUnlessOpen,
            fileManager: .default
        )

        #expect(
            result.normalizer.normalizeHeaders(["Accept-Language:ko"])
                == result.normalizer.normalizeHeaders(["Accept-Language: ko"])
        )
        #expect(
            result.normalizer.normalizeHeaders(["Authorization:Bearer token"])
                == result.normalizer.normalizeHeaders(["Authorization: Bearer token"])
        )
    }

}
