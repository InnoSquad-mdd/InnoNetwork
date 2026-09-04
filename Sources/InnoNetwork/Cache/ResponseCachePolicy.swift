import CryptoKit
import Foundation

/// Opt-in response caching policy for request/response APIs.
public enum ResponseCachePolicy: Sendable, Equatable {
    /// No cache reads or writes; identical to having no cache configured.
    case disabled
    /// Always hit the network. Cache reads and writes are both skipped, so
    /// the cache stays untouched—useful when callers want fresh data without
    /// polluting an existing cache.
    case networkOnly
    /// Serve from cache while entries are within `maxAge`. Stale entries fall
    /// through to the network and RFC-cacheable GET responses may be written back.
    /// Entries flagged as `requiresRevalidation` (e.g. responses carrying
    /// `Cache-Control: no-cache`) are revalidated even while inside `maxAge`.
    case cacheFirst(maxAge: Duration)
    /// Serve fresh entries directly. Within the `staleWindow` past `maxAge`,
    /// return the cached entry immediately and revalidate in the background.
    /// Entries flagged as `requiresRevalidation` skip the fast path and force
    /// revalidation on every request even within `maxAge`.
    case staleWhileRevalidate(maxAge: Duration, staleWindow: Duration)
    /// RFC 9111 directive-aware adapter that wraps another policy. The
    /// adapter inspects cache freshness directives on the cached response
    /// and overrides the inner policy's read-side decision when they apply:
    ///
    /// - `no-store` — the entry is treated as absent; reads fall through
    ///   to a network revalidation even though the default writer already
    ///   refuses to persist `no-store` responses.
    /// - `must-revalidate` — entries past the effective `maxAge` cannot
    ///   be served from the stale window; a forced conditional
    ///   revalidation runs instead.
    /// - `max-age=N` — the effective freshness window becomes
    ///   `min(server.maxAge, inner.maxAge)`. The server can shorten the
    ///   caller's freshness ceiling but never extend it.
    /// - `Expires` — when no valid `max-age` is present, the effective
    ///   freshness window is derived from `Expires - Date`, or
    ///   `Expires - storedAt` when the response has no valid `Date` header.
    ///   Invalid freshness information is treated as stale.
    /// - `Last-Modified` — when neither valid `max-age` nor `Expires`
    ///   exists, the adapter applies the RFC 9111 §4.2.2 heuristic
    ///   freshness calculation (10% of apparent age, capped at 24 hours).
    ///
    /// Wrapping is the only way to opt into directive enforcement; the
    /// other cases remain RFC-agnostic by design so the default
    /// `Cache-Control: max-age=...` behaviour stays predictable across
    /// origins that emit conflicting directives.
    ///
    /// Nesting (`.rfc9111Compliant(wrapping: .rfc9111Compliant(...))`) is
    /// behaviourally idempotent — each layer reads the same directives
    /// from the response and recurses into its inner policy — but is
    /// preserved in the value. Pattern matches over the policy will see
    /// each layer, so consumers should not assume the case nests at most
    /// once.
    indirect case rfc9111Compliant(wrapping: ResponseCachePolicy)
    /// Allows a stale cached response to recover a transient transport or
    /// server failure when the stored response explicitly advertises a valid
    /// `Cache-Control: stale-if-error=N` window. Recovery is considered only
    /// after the active retry policy declines another retry. Cancellation,
    /// trust, configuration, decoding, and response-body-limit failures never
    /// fall back to stale data.
    ///
    /// This wrapper is opt-in and does not weaken the inner policy's cache
    /// admission, identity partitioning, or freshness ceiling.
    indirect case staleIfError(wrapping: ResponseCachePolicy)
    /// Honors a request's `Cache-Control: only-if-cached` directive. When the
    /// directive is present, an immediately reusable entry is returned without
    /// transport; a miss or an entry that requires network revalidation fails
    /// locally with ``NetworkError/configuration(reason:)``.
    ///
    /// The wrapper is opt-in so existing clients continue forwarding the
    /// directive to their origin without InnoNetwork changing request flow.
    indirect case requestOnlyIfCached(wrapping: ResponseCachePolicy)
}


/// Stable cache key for response bodies stored by ``ResponseCache``.
public struct ResponseCacheKey: Hashable, Sendable {
    public let method: String
    public let url: String
    public let headers: [String]

    /// Creates a cache identity while fingerprinting credential-bearing
    /// header values. `sensitiveHeaderNames` extends the built-in set for
    /// proprietary identity headers and is scoped to this value; it never
    /// mutates process-wide state.
    public init(
        method: String,
        url: String,
        headers: [String: String] = [:],
        sensitiveHeaderNames: Set<String> = []
    ) {
        // Method tokens are case-sensitive on the wire. Keep the exact token
        // so custom methods cannot collide with differently cased methods.
        self.method = method
        self.url = Self.normalizedTargetURI(url)
        self.headers = Self.normalizedHeaders(
            headers,
            sensitiveHeaderNames: sensitiveHeaderNames
        )
    }

    // `Authorization` is intentionally part of the cache key so that
    // user-scoped responses are not shared across identities. Token
    // rotations therefore produce new keys and the cache acts per-identity.
    // `Accept-Language` intentionally remains part of the key: many APIs
    // localize representations without changing the URL.
    private static let excludedHeaderNames: Set<String> = [
        "accept-encoding",
        "cache-control",
        "content-type",
        "date",
        "if-modified-since",
        "if-none-match",
        "user-agent",
    ]

    package init?(request: URLRequest, sensitiveHeaderNames: Set<String> = []) {
        guard let url = Self.normalizedTargetURI(request.url) else { return nil }
        let headers =
            (request.allHTTPHeaderFields ?? [:])
            .filter { !Self.excludedHeaderNames.contains($0.key.lowercased()) }
        self.init(
            method: request.httpMethod ?? "GET",
            url: url,
            headers: headers,
            sensitiveHeaderNames: sensitiveHeaderNames
        )
    }

    private static func normalizedHeaders(
        _ headers: [String: String],
        sensitiveHeaderNames: Set<String>
    ) -> [String] {
        let normalizedSensitiveHeaderNames =
            HeaderValueNormalizer.defaultSensitiveHeaderNames.union(
                sensitiveHeaderNames.map { $0.lowercased() }
            )
        return
            headers
            .map { header in
                let name = header.key.lowercased()
                let value = HeaderValueNormalizer.normalizedValue(
                    name: name,
                    value: header.value,
                    sensitiveHeaderNames: normalizedSensitiveHeaderNames
                )
                return "\(name):\(value)"
            }
            .sorted()
    }

    package static func normalizedTargetURI(_ targetURI: String) -> String {
        normalizedURLString(URL(string: targetURI)) ?? targetURI
    }

    package static func normalizedTargetURI(_ url: URL?) -> String? {
        normalizedURLString(url)
    }

    private static func normalizedURLString(_ url: URL?) -> String? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        // Query order is intentionally preserved. Although many origins treat
        // reordered query items as equivalent, signatures, duplicate-key
        // semantics, and order-sensitive application routers may not. A cache
        // must never collapse two wire-distinct targets without an explicit
        // origin contract that proves they are equivalent.
        return components.url?.absoluteString
    }

    /// Returns whether a normalized cache-key header represents sensitive
    /// identity material. Persistent cache products use this package-only
    /// boundary so custom client-scoped names do not need a second global
    /// registry.
    package static func isSensitiveNormalizedHeader(_ header: String) -> Bool {
        guard let separator = header.firstIndex(of: ":") else { return false }
        let name = String(header[..<separator])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let value = String(header[header.index(after: separator)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return HeaderValueNormalizer.defaultSensitiveHeaderNames.contains(name)
            || value.hasPrefix("sha256:")
            || value.hasPrefix("hmac-sha256:")
    }
}


enum HeaderValueNormalizer {
    static let defaultSensitiveHeaderNames: Set<String> = [
        "authorization",
        "cookie",
        "proxy-authorization",
        "x-api-key",
        "x-auth-token",
    ]

    static func normalizedValue(
        name: String,
        value: String,
        sensitiveHeaderNames: Set<String>
    ) -> String {
        sensitiveHeaderNames.contains(name.lowercased()) ? fingerprint(value) : value
    }

    /// Threat model: SHA-256 of the raw header value is collision-resistant
    /// but **not** keyed. An attacker who can read on-disk cache keys (e.g.
    /// shared keychain, lost-device exfiltration) can confirm whether a
    /// guessed credential matches the value that produced the cache entry,
    /// because the fingerprint is reproducible. This is acceptable for the
    /// in-process cache — the raw value lives in memory anyway — but for
    /// the persistent cache the fingerprint is HMAC-keyed with a per-cache
    /// installation key before it is written to disk.
    private static func fingerprint(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }
}


/// Cached HTTP response payload and metadata.
public struct CachedResponse: Sendable, Equatable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]
    public let storedAt: Date
    /// Whether a cached entry must be revalidated before reuse even while it
    /// is still inside the caller-provided freshness window.
    public let requiresRevalidation: Bool
    /// Snapshot of the request headers that were present when this response
    /// was stored, restricted to the names listed in the response `Vary`
    /// header. `nil` means the response did not carry a `Vary` header (so
    /// vary matching is skipped on lookup); an empty dictionary is reserved
    /// for `Vary` headers that resolve to no concrete names. The values are
    /// optional so a vary header that was absent on the original request
    /// stays distinguishable from one that was present and empty.
    public let varyHeaders: [String: String?]?

    public init(
        data: Data,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        storedAt: Date = Date(),
        requiresRevalidation: Bool = false,
        varyHeaders: [String: String?]? = nil
    ) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
        self.storedAt = storedAt
        self.requiresRevalidation = requiresRevalidation
        self.varyHeaders = varyHeaders
    }

    public var etag: String? {
        headers.first { $0.key.caseInsensitiveCompare("ETag") == .orderedSame }?.value
    }

    /// Origin-supplied `Last-Modified` timestamp from the cached response,
    /// suitable for the `If-Modified-Since` conditional-request header when
    /// no `ETag` is available.
    public var lastModified: String? {
        headers.first { $0.key.caseInsensitiveCompare("Last-Modified") == .orderedSame }?.value
    }

    package func response(for request: URLRequest) -> HTTPURLResponse? {
        guard let url = request.url else { return nil }
        return HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )
    }

    /// Approximate in-memory size of the cached payload in bytes. Includes the
    /// body, response headers, the vary-snapshot, and a fixed allowance for
    /// the stored timestamp and other Swift overhead. The `InMemoryResponseCache`
    /// adds key-side bytes (URL/method/key headers) on top before comparing
    /// against `maxBytes`.
    package var byteCost: Int {
        let headersCost = headers.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        let varyCost =
            varyHeaders?.reduce(0) { partial, entry in
                partial + entry.key.utf8.count + (entry.value?.utf8.count ?? 0)
            } ?? 0
        // Date stride covers `storedAt`; constant overhead covers the boxed
        // optional `varyHeaders` and the `requiresRevalidation` flag.
        return data.count + headersCost + varyCost + MemoryLayout<Date>.stride + 16
    }
}


package extension ResponseCacheKey {
    /// Approximate in-memory size of the key in bytes. Used by
    /// `InMemoryResponseCache` to charge key bytes against `maxBytes`.
    var byteCost: Int {
        method.utf8.count + url.utf8.count + headers.reduce(0) { $0 + $1.utf8.count }
    }
}


/// Async response cache abstraction used by the built-in cache policy.
///
/// Implementations store entries under ``ResponseCacheKey`` and should remove
/// every method/header variant for a target URI when
/// ``invalidateTargetURI(_:)`` is called. The target URI uses the same
/// normalization as ``ResponseCacheKey``: lowercase scheme/host, stripped
/// fragment, and query items preserved in wire order.
public protocol ResponseCache: Sendable {
    func get(_ key: ResponseCacheKey) async -> CachedResponse?
    func set(_ key: ResponseCacheKey, _ value: CachedResponse) async
    func invalidate(_ key: ResponseCacheKey) async
    func invalidateTargetURI(_ targetURI: String) async
}


public extension ResponseCache {
    /// Best-effort target URI invalidation for custom caches.
    ///
    /// This default removes only the canonical `GET` key with no header
    /// variants. Built-in caches override it to remove all variants whose
    /// normalized target URI matches. Custom caches that persist Vary/header
    /// dimensions should provide their own implementation.
    func invalidateTargetURI(_ targetURI: String) async {
        await invalidate(ResponseCacheKey(method: "GET", url: targetURI))
    }
}


/// In-memory `ResponseCache` implementation with a byte cap and O(1) LRU
/// bookkeeping.
///
/// Every `get`, `set`, and `invalidate` is O(1) regardless of the working set
/// size, backed by a doubly-linked list of nodes plus a dictionary for direct
/// lookup. Eviction charges against the sum of cached body bytes, response
/// headers, the vary snapshot, and the key bytes, so `maxBytes` reflects an
/// approximation of real memory usage rather than just body bytes.
public actor InMemoryResponseCache: ResponseCache {
    private final class Node {
        let key: ResponseCacheKey
        var value: CachedResponse
        var cost: Int
        var prev: Node?
        var next: Node?

        init(key: ResponseCacheKey, value: CachedResponse, cost: Int) {
            self.key = key
            self.value = value
            self.cost = cost
        }
    }

    private let maxBytes: Int
    private var nodes: [ResponseCacheKey: Node] = [:]
    private var head: Node?
    private var tail: Node?
    private var currentBytes = 0

    public init(maxBytes: Int = 5 * 1024 * 1024) {
        self.maxBytes = max(1, maxBytes)
    }

    public func get(_ key: ResponseCacheKey) async -> CachedResponse? {
        guard let node = nodes[key] else { return nil }
        moveToHead(node)
        return node.value
    }

    public func set(_ key: ResponseCacheKey, _ value: CachedResponse) async {
        let entryCost = key.byteCost + value.byteCost
        if let existing = nodes[key] {
            currentBytes -= existing.cost
            existing.value = value
            existing.cost = entryCost
            currentBytes += entryCost
            moveToHead(existing)
        } else {
            let node = Node(key: key, value: value, cost: entryCost)
            nodes[key] = node
            currentBytes += entryCost
            insertAtHead(node)
        }
        evictIfNeeded()
    }

    public func invalidate(_ key: ResponseCacheKey) async {
        remove(key)
    }

    public func invalidateTargetURI(_ targetURI: String) async {
        let normalizedTargetURI = ResponseCacheKey.normalizedTargetURI(targetURI)
        let keys = nodes.keys.filter { $0.url == normalizedTargetURI }
        for key in keys {
            remove(key)
        }
    }

    private func remove(_ key: ResponseCacheKey) {
        guard let node = nodes.removeValue(forKey: key) else { return }
        currentBytes -= node.cost
        unlink(node)
        if currentBytes < 0 { currentBytes = 0 }
    }

    private func insertAtHead(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func unlink(_ node: Node) {
        let prev = node.prev
        let next = node.next
        prev?.next = next
        next?.prev = prev
        if head === node { head = next }
        if tail === node { tail = prev }
        node.prev = nil
        node.next = nil
    }

    private func moveToHead(_ node: Node) {
        guard head !== node else { return }
        unlink(node)
        insertAtHead(node)
    }

    private func evictIfNeeded() {
        while currentBytes > maxBytes, let last = tail {
            nodes.removeValue(forKey: last.key)
            currentBytes -= last.cost
            unlink(last)
        }
        // Storage/order desync guard: if the dictionary is empty, clear the
        // list and reset the byte counter so a subsequent insert starts from a
        // known-good state even after an internal accounting error.
        if nodes.isEmpty {
            head = nil
            tail = nil
            currentBytes = 0
        }
    }
}


package enum CachePreparation: Sendable {
    case bypass
    case returnCached(CachedResponse)
    case revalidate(CachedResponse?)
    case revalidateWithStaleIfError(CachedResponse)
    case returnStaleAndRevalidate(CachedResponse)
    case onlyIfCachedMiss
}


package extension ResponseCachePolicy {
    var isEnabled: Bool {
        switch self {
        case .disabled:
            return false
        case .networkOnly, .cacheFirst, .staleWhileRevalidate:
            return true
        case .rfc9111Compliant(let inner),
            .staleIfError(let inner),
            .requestOnlyIfCached(let inner):
            return inner.isEnabled
        }
    }

    var allowsConditionalRevalidation: Bool {
        switch self {
        case .cacheFirst, .staleWhileRevalidate:
            return true
        case .disabled, .networkOnly:
            return false
        case .rfc9111Compliant(let inner),
            .staleIfError(let inner),
            .requestOnlyIfCached(let inner):
            return inner.allowsConditionalRevalidation
        }
    }

    /// Whether the policy may read an existing cached response.
    /// `networkOnly` must leave cache metadata untouched, so it skips reads.
    var allowsCacheRead: Bool {
        switch self {
        case .cacheFirst, .staleWhileRevalidate:
            return true
        case .disabled, .networkOnly:
            return false
        case .rfc9111Compliant(let inner),
            .staleIfError(let inner),
            .requestOnlyIfCached(let inner):
            return inner.allowsCacheRead
        }
    }

    /// Whether the policy may persist responses into the cache.
    /// `networkOnly` skips both reads and writes so it does not pollute the
    /// cache even though it is otherwise "enabled".
    var allowsCacheWrite: Bool {
        switch self {
        case .cacheFirst, .staleWhileRevalidate:
            return true
        case .disabled, .networkOnly:
            return false
        case .rfc9111Compliant(let inner),
            .staleIfError(let inner),
            .requestOnlyIfCached(let inner):
            return inner.allowsCacheWrite
        }
    }

    func prepare(cached: CachedResponse?, now: Date = Date()) -> CachePreparation {
        switch self {
        case .disabled:
            return .bypass
        case .networkOnly:
            return .revalidate(nil)
        case .cacheFirst(let maxAge):
            guard let cached else { return .revalidate(nil) }
            guard !cached.requiresRevalidation else { return .revalidate(cached) }
            return cached.age(since: now) <= maxAge.timeInterval ? .returnCached(cached) : .revalidate(cached)
        case .staleWhileRevalidate(let maxAge, let staleWindow):
            guard let cached else { return .revalidate(nil) }
            guard !cached.requiresRevalidation else { return .revalidate(cached) }
            let age = cached.age(since: now)
            if age <= maxAge.timeInterval {
                return .returnCached(cached)
            }
            if age <= maxAge.timeInterval + staleWindow.timeInterval {
                return .returnStaleAndRevalidate(cached)
            }
            return .revalidate(cached)
        case .rfc9111Compliant(let inner):
            return prepareWithRFC9111(inner: inner, cached: cached, now: now)
        case .staleIfError(let inner), .requestOnlyIfCached(let inner):
            return inner.prepare(cached: cached, now: now)
        }
    }

    var honorsRequestOnlyIfCached: Bool {
        switch self {
        case .requestOnlyIfCached:
            return true
        case .rfc9111Compliant(let inner), .staleIfError(let inner):
            return inner.honorsRequestOnlyIfCached
        case .disabled, .networkOnly, .cacheFirst, .staleWhileRevalidate:
            return false
        }
    }

    private var containsStaleIfErrorOptIn: Bool {
        switch self {
        case .staleIfError:
            return true
        case .rfc9111Compliant(let inner), .requestOnlyIfCached(let inner):
            return inner.containsStaleIfErrorOptIn
        case .disabled, .networkOnly, .cacheFirst, .staleWhileRevalidate:
            return false
        }
    }

    /// Returns the stale entry only when both sides of the contract agree:
    /// the caller opted in and the origin supplied a valid stale-if-error
    /// allowance that still covers the entry's current staleness.
    func staleIfErrorFallback(
        cached: CachedResponse,
        now: Date
    ) -> CachedResponse? {
        guard containsStaleIfErrorOptIn, allowsCacheRead else { return nil }
        let directives = RFC9111CacheControlDirectives(headers: cached.headers)
        guard !directives.noStore,
            !directives.mustRevalidate,
            !directives.hasInvalidStaleIfError,
            let staleWindow = directives.staleIfErrorSeconds,
            let freshnessLifetime = effectiveFreshnessLifetime(for: cached),
            case .revalidate(let candidate) = prepare(cached: cached, now: now),
            candidate != nil
        else {
            return nil
        }
        let staleness = max(0, cached.age(since: now) - freshnessLifetime)
        return staleness <= staleWindow ? cached : nil
    }

    private func effectiveFreshnessLifetime(for cached: CachedResponse) -> TimeInterval? {
        switch self {
        case .disabled, .networkOnly:
            return nil
        case .cacheFirst(let maxAge), .staleWhileRevalidate(let maxAge, _):
            return max(0, maxAge.timeInterval)
        case .staleIfError(let inner), .requestOnlyIfCached(let inner):
            return inner.effectiveFreshnessLifetime(for: cached)
        case .rfc9111Compliant(let inner):
            guard let innerLifetime = inner.effectiveFreshnessLifetime(for: cached) else {
                return nil
            }
            let directives = RFC9111CacheControlDirectives(headers: cached.headers)
            switch directives.freshnessLifetime(headers: cached.headers, storedAt: cached.storedAt) {
            case .invalidOrExpired:
                return 0
            case .lifetime(let serverLifetime):
                return min(innerLifetime, max(0, serverLifetime))
            case .unspecified:
                return innerLifetime
            }
        }
    }
}


private extension CachedResponse {
    func age(since now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(storedAt))
    }
}


// MARK: - Vary handling

package enum VaryEvaluation: Sendable, Equatable {
    /// The response carried `Vary: *`. The cache must not store this entry
    /// because no number of request-header copies can reliably distinguish
    /// future variants.
    case wildcardSkipsCache
    /// No `Vary` header on the response, or one that resolves to no concrete
    /// header names after normalization. The response can be cached without
    /// any vary snapshot.
    case noVary
    /// The response named at least one varying request header. The associated
    /// dictionary maps each lowercased header name to its current request
    /// value (nil when the request did not include the header).
    case vary([String: String?])
}

package func evaluateVary(
    responseHeaders: [String: String],
    request: URLRequest,
    sensitiveHeaderNames: Set<String> = []
) -> VaryEvaluation {
    let normalizedSensitiveHeaderNames =
        HeaderValueNormalizer.defaultSensitiveHeaderNames.union(
            sensitiveHeaderNames.map { $0.lowercased() }
        )
    let varyValue = responseHeaders.first { $0.key.caseInsensitiveCompare("Vary") == .orderedSame }?.value
    guard let varyValue, !varyValue.isEmpty else {
        return .noVary
    }
    let entries =
        varyValue
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    if entries.contains(where: { $0 == "*" }) {
        return .wildcardSkipsCache
    }
    if entries.isEmpty {
        return .noVary
    }
    var snapshot: [String: String?] = [:]
    for header in entries {
        let lowered = header.lowercased()
        let normalizedValue = request.value(forHTTPHeaderField: header).map {
            HeaderValueNormalizer.normalizedValue(
                name: lowered,
                value: $0,
                sensitiveHeaderNames: normalizedSensitiveHeaderNames
            )
        }
        snapshot.updateValue(normalizedValue, forKey: lowered)
    }
    return .vary(snapshot)
}

/// Returns `true` when the `Vary` header on a 304 Not Modified response
/// differs from the one that was active when `cached` was stored.
///
/// A 304 confirms that the stored representation is still fresh, but its
/// own `Vary` header does *not* automatically describe the stored
/// representation — it describes the variant the origin would have
/// served on a full 200. When those differ, re-keying the stored entry
/// against the new `Vary` snapshot would silently move it to a different
/// cache dimension, so the executor must keep the existing snapshot and
/// only refresh freshness instead of rewriting the entry.
///
/// Comparison is case-insensitive on header *names* only; whitespace
/// around tokens is trimmed. A 304 that does not carry a `Vary` header
/// is treated as "no revision" — the caller preserves the cached
/// snapshot.
package func notModifiedRevisesVary(
    cached: CachedResponse,
    notModifiedHeaders: [AnyHashable: Any]?
) -> Bool {
    guard let notModifiedHeaders else { return false }
    let newVaryRaw =
        notModifiedHeaders.first {
            ($0.key as? String).map { $0.caseInsensitiveCompare("Vary") == .orderedSame } ?? false
        }?.value as? String
    guard let newVaryRaw, !newVaryRaw.isEmpty else { return false }

    let oldVaryRaw =
        cached.headers.first { $0.key.caseInsensitiveCompare("Vary") == .orderedSame }?.value

    func normalizedTokens(_ raw: String?) -> Set<String> {
        guard let raw else { return [] }
        return Set(
            raw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }
    return normalizedTokens(newVaryRaw) != normalizedTokens(oldVaryRaw)
}

package func cachedResponseMatchesVary(
    _ cached: CachedResponse,
    request: URLRequest,
    sensitiveHeaderNames: Set<String> = []
) -> Bool {
    let normalizedSensitiveHeaderNames =
        HeaderValueNormalizer.defaultSensitiveHeaderNames.union(
            sensitiveHeaderNames.map { $0.lowercased() }
        )
    guard let storedVary = cached.varyHeaders else {
        return true
    }
    for (header, storedValue) in storedVary {
        let currentValue = request.value(forHTTPHeaderField: header).map {
            HeaderValueNormalizer.normalizedValue(
                name: header,
                value: $0,
                sensitiveHeaderNames: normalizedSensitiveHeaderNames
            )
        }
        if !varyValuesEqual(stored: storedValue, current: currentValue, headerName: header) {
            return false
        }
    }
    return true
}

private func varyValuesEqual(stored: String?, current: String?, headerName: String) -> Bool {
    switch (stored, current) {
    case (nil, nil):
        return true
    case (nil, _), (_, nil):
        return false
    case (let storedValue?, let currentValue?):
        if isMultiTokenVaryHeader(headerName) {
            // Wildcard tokens (`*`, optionally with a q-value) participate
            // in the comparison as ordinary tokens: a stored entry whose
            // original request advertised `*;q=0.5` only re-matches a
            // request that *also* advertises `*` with the same weight. We
            // deliberately do not treat `*` as "matches any future
            // request" — doing so would let an authenticated request with
            // narrow language coverage serve a cached body to a broader
            // wildcard request (or vice-versa) under semantically
            // different content negotiation. The conservative rule trades
            // a small hit-rate cost for guaranteed-correct vary matching.
            return varyTokenSet(storedValue) == varyTokenSet(currentValue)
        }
        // Trim RFC 7230 OWS so byte-for-byte differences in incidental
        // whitespace (e.g. `gzip` vs ` gzip`) do not break vary matching.
        return storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            == currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func isMultiTokenVaryHeader(_ name: String) -> Bool {
    switch name.lowercased() {
    case "accept", "accept-encoding", "accept-language", "accept-charset":
        return true
    default:
        return false
    }
}

private func varyTokenSet(_ raw: String) -> Set<String> {
    // RFC 9110 §12.5.1/§12.5.3/§12.5.4: `Accept`, `Accept-Encoding`,
    // `Accept-Language`, and `Accept-Charset` carry q-value weights that
    // determine server-side preference. Two requests with the same token
    // *set* but different priorities (`gzip;q=0.5, br` vs `gzip, br;q=0.5`)
    // ask the origin for different representations and must produce
    // distinct cache keys. In addition, `Accept` media-range parameters
    // appearing *before* `q=` (e.g. `application/json;charset=utf-8`) are
    // part of the media-type identity per §12.5.1 — two requests that
    // differ only in such parameters can legitimately receive different
    // representations. Preserve every non-`q=` parameter in the
    // normalized form, sorted for deterministic comparison, so cache
    // lookups distinguish them. Tokens without an explicit `q=` default
    // to `1.000` per the spec.
    var result: Set<String> = []
    for rawElement in raw.split(separator: ",") {
        let element = rawElement.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if element.isEmpty { continue }
        let parts = element.split(separator: ";", omittingEmptySubsequences: false)
        guard let token = parts.first.map(String.init)?.trimmingCharacters(in: .whitespaces),
            !token.isEmpty
        else { continue }
        var qValue: String = "1.000"
        var mediaParams: [String] = []
        for param in parts.dropFirst() {
            let trimmed = param.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("q=") {
                let value = trimmed.dropFirst(2)
                if let parsed = Double(value) {
                    let clamped = max(0.0, min(1.0, parsed))
                    qValue = String(format: "%.3f", clamped)
                }
                continue
            }
            mediaParams.append(trimmed)
        }
        let paramSuffix =
            mediaParams.isEmpty
            ? ""
            : ";" + mediaParams.sorted().joined(separator: ";")
        result.insert("\(token)\(paramSuffix);q=\(qValue)")
    }
    return result
}


package extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds)
            + TimeInterval(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
