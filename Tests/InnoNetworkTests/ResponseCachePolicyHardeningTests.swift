import Foundation
import os
import Testing

@testable import InnoNetwork

@Suite("ResponseCacheKey query identity")
struct ResponseCacheKeyQueryNormalizationTests {

    @Test("Reordered query items remain distinct cache keys")
    func reorderedQueryItemsRemainDistinct() throws {
        let urlA = try #require(URL(string: "https://api.example.com/v1/items?b=2&a=1&c=3"))
        let urlB = try #require(URL(string: "https://api.example.com/v1/items?a=1&b=2&c=3"))
        let urlC = try #require(URL(string: "https://api.example.com/v1/items?c=3&a=1&b=2"))

        let keyA = try #require(ResponseCacheKey(request: URLRequest(url: urlA)))
        let keyB = try #require(ResponseCacheKey(request: URLRequest(url: urlB)))
        let keyC = try #require(ResponseCacheKey(request: URLRequest(url: urlC)))

        #expect(keyA != keyB)
        #expect(keyB != keyC)
        #expect(keyA != keyC)
    }

    @Test("Repeated query names preserve value order")
    func repeatedQueryNamesPreserveOrder() throws {
        let urlA = try #require(URL(string: "https://api.example.com/items?tag=z&tag=a"))
        let urlB = try #require(URL(string: "https://api.example.com/items?tag=a&tag=z"))

        let keyA = try #require(ResponseCacheKey(request: URLRequest(url: urlA)))
        let keyB = try #require(ResponseCacheKey(request: URLRequest(url: urlB)))

        #expect(keyA != keyB)
        #expect(keyA.url == "https://api.example.com/items?tag=z&tag=a")
        #expect(keyB.url == "https://api.example.com/items?tag=a&tag=z")
    }

    @Test("Different fragments are still treated as the same key")
    func fragmentsAreStripped() throws {
        let urlA = try #require(URL(string: "https://api.example.com/v1?a=1#section-1"))
        let urlB = try #require(URL(string: "https://api.example.com/v1?a=1#section-2"))

        let keyA = try #require(ResponseCacheKey(request: URLRequest(url: urlA)))
        let keyB = try #require(ResponseCacheKey(request: URLRequest(url: urlB)))

        #expect(keyA == keyB)
    }

    @Test("URL scheme and host casing are normalized")
    func schemeAndHostCasingNormalize() async throws {
        let urlA = try #require(URL(string: "HTTPS://API.EXAMPLE.COM/v1/items?b=2&a=1"))
        let urlB = try #require(URL(string: "https://api.example.com/v1/items?b=2&a=1"))

        let keyA = try #require(ResponseCacheKey(request: URLRequest(url: urlA)))
        let keyB = try #require(ResponseCacheKey(request: URLRequest(url: urlB)))

        #expect(keyA == keyB)
    }

    @Test("Direct cache key initializer normalizes URLs without rewriting methods")
    func directInitializerNormalizesValidURLStrings() async {
        let keyA = ResponseCacheKey(
            method: "PURGE",
            url: "HTTPS://API.EXAMPLE.COM/v1/items?b=2&a=1#section"
        )
        let keyB = ResponseCacheKey(
            method: "PURGE",
            url: "https://api.example.com/v1/items?b=2&a=1"
        )

        #expect(keyA == keyB)
        #expect(keyA.method == "PURGE")
        #expect(keyA.url == "https://api.example.com/v1/items?b=2&a=1")
    }

    @Test("Differently cased custom methods remain distinct cache keys")
    func methodTokensRemainCaseSensitive() {
        let uppercase = ResponseCacheKey(method: "PURGE", url: "https://api.example.com/cache")
        let lowercase = ResponseCacheKey(method: "purge", url: "https://api.example.com/cache")

        #expect(uppercase != lowercase)
        #expect(uppercase.method == "PURGE")
        #expect(lowercase.method == "purge")
    }

    @Test("Direct cache key initializer preserves unparsable URL strings")
    func directInitializerPreservesUnparsableURLStrings() async {
        let key = ResponseCacheKey(method: "GET", url: "://not a url")
        #expect(key.url == "://not a url")
    }
}


@Suite("ResponseCacheKey sensitive headers")
struct ResponseCacheKeySensitiveHeaderTests {

    @Test("Default sensitive headers are fingerprinted in the cache key")
    func defaultSensitiveHeadersFingerprint() throws {
        let url = try #require(URL(string: "https://api.example.com/v1/me"))
        var request = URLRequest(url: url)
        request.setValue("session-secret-1", forHTTPHeaderField: "Cookie")
        request.setValue("api-key-secret", forHTTPHeaderField: "X-API-Key")
        request.setValue("auth-secret", forHTTPHeaderField: "X-Auth-Token")
        request.setValue("Basic abcd", forHTTPHeaderField: "Proxy-Authorization")

        let key = try #require(ResponseCacheKey(request: request))
        let joined = key.headers.joined(separator: "\n")

        #expect(joined.contains("session-secret-1") == false)
        #expect(joined.contains("api-key-secret") == false)
        #expect(joined.contains("auth-secret") == false)
        #expect(joined.contains("Basic abcd") == false)
        #expect(joined.contains("sha256:"))
    }

    @Test("Different cookie values yield different cache keys")
    func cookieDistinctnessPreserved() throws {
        let url = try #require(URL(string: "https://api.example.com/v1/me"))
        var requestA = URLRequest(url: url)
        requestA.setValue("session=A", forHTTPHeaderField: "Cookie")
        var requestB = URLRequest(url: url)
        requestB.setValue("session=B", forHTTPHeaderField: "Cookie")

        let keyA = try #require(ResponseCacheKey(request: requestA))
        let keyB = try #require(ResponseCacheKey(request: requestB))

        #expect(keyA != keyB)
    }

    @Test("Value-scoped sensitive headers are also fingerprinted")
    func valueScopedHeader() throws {
        let url = try #require(URL(string: "https://api.example.com/v1/internal"))
        var request = URLRequest(url: url)
        request.setValue("super-secret-internal", forHTTPHeaderField: "X-Internal-Token")

        let key = try #require(
            ResponseCacheKey(
                request: request,
                sensitiveHeaderNames: ["X-Internal-Token"]
            )
        )
        let joined = key.headers.joined(separator: "\n")
        #expect(joined.contains("super-secret-internal") == false)
        #expect(joined.contains("sha256:"))
    }

    @Test("Custom header policy does not leak into another cache key")
    func customPolicyIsValueScoped() throws {
        let url = try #require(URL(string: "https://api.example.com/v1/internal"))
        let headers = ["X-Internal-Token": "super-secret-internal"]

        let protected = ResponseCacheKey(
            method: "GET",
            url: url.absoluteString,
            headers: headers,
            sensitiveHeaderNames: ["X-Internal-Token"]
        )
        let defaultOnly = ResponseCacheKey(
            method: "GET",
            url: url.absoluteString,
            headers: headers
        )

        #expect(protected.headers.first?.contains("super-secret-internal") == false)
        #expect(defaultOnly.headers.first?.contains("super-secret-internal") == true)
    }
}


@Suite("InMemoryResponseCache LRU semantics")
struct InMemoryResponseCacheLRUTests {

    private func makeKey(_ url: String) -> ResponseCacheKey {
        ResponseCacheKey(method: "GET", url: url, headers: [:])
    }

    private func makeResponse(byteSize: Int) -> CachedResponse {
        CachedResponse(data: Data(repeating: 0xAA, count: byteSize))
    }

    private func makeTrackedResponse(
        deallocations: OSAllocatedUnfairLock<Int>
    ) -> CachedResponse {
        let byteCount = 128
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<UInt8>.alignment
        )
        pointer.initializeMemory(as: UInt8.self, repeating: 0xAA, count: byteCount)
        let data = Data(
            bytesNoCopy: pointer,
            count: byteCount,
            deallocator: .custom { pointer, _ in
                deallocations.withLock { $0 += 1 }
                pointer.deallocate()
            }
        )
        return CachedResponse(data: data)
    }

    @Test("Cache destruction releases every stored payload", arguments: [1, 2, 8])
    func cacheDestructionReleasesPayloads(entryCount: Int) async {
        let deallocations = OSAllocatedUnfairLock(initialState: 0)

        do {
            let cache = InMemoryResponseCache(maxBytes: 10_000)
            for index in 0..<entryCount {
                await cache.set(
                    makeKey("https://example.com/lifetime/\(index)"),
                    makeTrackedResponse(deallocations: deallocations)
                )
            }
        }

        #expect(deallocations.withLock { $0 } == entryCount)
    }

    @Test("Eviction removes the least-recently-used entry")
    func evictsLRU() async {
        let cache = InMemoryResponseCache(maxBytes: 2_500)
        let keyA = makeKey("https://example.com/a")
        let keyB = makeKey("https://example.com/b")
        let keyC = makeKey("https://example.com/c")

        await cache.set(keyA, makeResponse(byteSize: 1_000))
        await cache.set(keyB, makeResponse(byteSize: 1_000))

        // Touch A so B becomes the LRU.
        _ = await cache.get(keyA)

        await cache.set(keyC, makeResponse(byteSize: 1_000))

        let a = await cache.get(keyA)
        let b = await cache.get(keyB)
        let c = await cache.get(keyC)

        #expect(a != nil)
        #expect(b == nil)
        #expect(c != nil)
    }

    @Test("Overwriting the same key updates value without leaking byte budget")
    func overwriteRecomputesBudget() async {
        let cache = InMemoryResponseCache(maxBytes: 2_500)
        let key = makeKey("https://example.com/a")

        for _ in 0..<10 {
            await cache.set(key, makeResponse(byteSize: 1_000))
        }

        let other = makeKey("https://example.com/b")
        await cache.set(other, makeResponse(byteSize: 1_000))

        // Both fit because overwrites re-account, not accumulate.
        let first = await cache.get(key)
        let second = await cache.get(other)

        #expect(first != nil)
        #expect(second != nil)
    }

    @Test("Many entries evict in O(1) without timing out")
    func manyEntriesPerformance() async {
        // Pure correctness check: 1k inserts must complete well under the
        // 5s test timeout. The DLL+dict implementation makes each
        // insert/touch/eviction O(1).
        let cache = InMemoryResponseCache(maxBytes: 200_000)
        for i in 0..<1_000 {
            let key = makeKey("https://example.com/path/\(i)")
            await cache.set(key, makeResponse(byteSize: 256))
        }
        // Touch the head a thousand times — would be O(n^2) = 10^6 in the
        // legacy array impl, trivial here.
        let head = makeKey("https://example.com/path/999")
        for _ in 0..<1_000 {
            _ = await cache.get(head)
        }
    }

    @Test("Invalidate removes the entry from both storage and order")
    func invalidate() async {
        let cache = InMemoryResponseCache(maxBytes: 5_000)
        let keyA = makeKey("https://example.com/a")
        let keyB = makeKey("https://example.com/b")

        await cache.set(keyA, makeResponse(byteSize: 1_000))
        await cache.set(keyB, makeResponse(byteSize: 1_000))

        await cache.invalidate(keyA)

        let a = await cache.get(keyA)
        let b = await cache.get(keyB)
        #expect(a == nil)
        #expect(b != nil)
    }

    @Test("Target URI invalidation removes every method and header variant")
    func invalidateTargetURIRemovesVariants() async {
        let cache = InMemoryResponseCache(maxBytes: 5_000)
        let first = ResponseCacheKey(
            method: "GET",
            url: "HTTPS://EXAMPLE.COM/items?b=2&a=1#one",
            headers: ["Accept-Language": "en-US"]
        )
        let second = ResponseCacheKey(
            method: "GET",
            url: "https://example.com/items?b=2&a=1#two",
            headers: ["Accept-Language": "ko-KR"]
        )
        let third = ResponseCacheKey(
            method: "HEAD",
            url: "https://example.com/items?b=2&a=1",
            headers: ["X-Variant": "metadata"]
        )
        let other = makeKey("https://example.com/items?a=1&b=3")

        await cache.set(first, makeResponse(byteSize: 128))
        await cache.set(second, makeResponse(byteSize: 128))
        await cache.set(third, makeResponse(byteSize: 128))
        await cache.set(other, makeResponse(byteSize: 128))

        await cache.invalidateTargetURI("https://EXAMPLE.com/items?b=2&a=1#latest")

        #expect(await cache.get(first) == nil)
        #expect(await cache.get(second) == nil)
        #expect(await cache.get(third) == nil)
        #expect(await cache.get(other) != nil)
    }
}


@Suite("Vary header matching")
struct VaryHeaderMatchingTests {

    @Test("Multi-token Accept-Encoding compares as a token set")
    func acceptEncodingTokenSet() throws {
        let stored = CachedResponse(
            data: Data(),
            varyHeaders: ["accept-encoding": "gzip, deflate"]
        )
        let url = try #require(URL(string: "https://example.com/x"))
        var request = URLRequest(url: url)
        request.setValue("deflate, gzip", forHTTPHeaderField: "Accept-Encoding")

        #expect(cachedResponseMatchesVary(stored, request: request) == true)
    }

    @Test("OWS differences in single-value vary header still match")
    func owsTrim() throws {
        let stored = CachedResponse(
            data: Data(),
            varyHeaders: ["x-region": "  us-east-1 "]
        )
        let url = try #require(URL(string: "https://example.com/x"))
        var request = URLRequest(url: url)
        request.setValue("us-east-1", forHTTPHeaderField: "X-Region")

        #expect(cachedResponseMatchesVary(stored, request: request) == true)
    }

    @Test("Different multi-token vary values do not match")
    func multiTokenMismatch() throws {
        let stored = CachedResponse(
            data: Data(),
            varyHeaders: ["accept-language": "en-US, en"]
        )
        let url = try #require(URL(string: "https://example.com/x"))
        var request = URLRequest(url: url)
        request.setValue("ko-KR, ko", forHTTPHeaderField: "Accept-Language")

        #expect(cachedResponseMatchesVary(stored, request: request) == false)
    }
}
