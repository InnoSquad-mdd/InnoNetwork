import Foundation

// MARK: - Directive-aware preparation
//
// The public surface lives on
// ``ResponseCachePolicy/rfc9111Compliant(wrapping:)`` itself — the enum
// case doubles as the construction site. Callers write
// `.rfc9111Compliant(wrapping: .cacheFirst(maxAge: ...))` directly. See
// the case's docstring on ``ResponseCachePolicy`` for the directive
// semantics.

package extension ResponseCachePolicy {
    /// Implements ``prepare(cached:now:)`` for the
    /// ``ResponseCachePolicy/rfc9111Compliant(wrapping:)`` case.
    ///
    /// The helper applies `no-store`, `must-revalidate`, `max-age`,
    /// `Expires`, and `Last-Modified` heuristic overrides on top of the
    /// inner policy's decision rather than reimplementing freshness math, so
    /// wrapping inherits future changes to the inner policy automatically.
    func prepareWithRFC9111(
        inner: ResponseCachePolicy,
        cached: CachedResponse?,
        now: Date,
        initialAge: TimeInterval?
    ) -> CachePreparation {
        guard let cached else { return inner.prepare(cached: nil, now: now) }
        let initialAge = initialAge ?? cached.rfc9111InitialAge

        let directives = RFC9111CacheControlDirectives(headers: cached.headers)
        if directives.noStore {
            return .revalidate(nil)
        }
        if directives.noCache {
            return inner.revalidatingInsteadOfServing(
                cached: cached,
                now: now,
                rfc9111InitialAge: initialAge
            )
        }

        switch directives.freshnessLifetime(headers: cached.headers, storedAt: cached.storedAt) {
        case .invalidOrExpired:
            return inner.revalidatingInsteadOfServing(
                cached: cached,
                now: now,
                rfc9111InitialAge: initialAge
            )
        case .lifetime(let seconds):
            let adjustedInner = inner.applyingMaxAge(serverMaxAge: seconds)
            let preparation = adjustedInner.prepare(
                cached: cached,
                now: now,
                rfc9111InitialAge: initialAge
            )
            if directives.mustRevalidate, case .returnStaleAndRevalidate(let entry) = preparation {
                return .revalidate(entry)
            }
            return preparation
        case .unspecified:
            break
        }

        let adjustedInner = inner.applyingMaxAge(serverMaxAge: nil)
        let preparation = adjustedInner.prepare(
            cached: cached,
            now: now,
            rfc9111InitialAge: initialAge
        )

        if directives.mustRevalidate, case .returnStaleAndRevalidate(let entry) = preparation {
            return .revalidate(entry)
        }
        return preparation
    }

    /// Returns a copy of the policy with `maxAge` clamped to
    /// `min(self.maxAge, serverMaxAge)`. Cases that do not carry a
    /// freshness window (`.disabled`, `.networkOnly`) are returned
    /// unchanged. Nested adapter cases are unwrapped once so the override
    /// hits the freshness-bearing leaf.
    func applyingMaxAge(serverMaxAge: TimeInterval?) -> ResponseCachePolicy {
        guard let serverMaxAge, serverMaxAge >= 0 else { return self }
        let serverDuration = Duration.seconds(serverMaxAge)
        switch self {
        case .disabled, .networkOnly:
            return self
        case .cacheFirst(let maxAge):
            return .cacheFirst(maxAge: min(maxAge, serverDuration))
        case .staleWhileRevalidate(let maxAge, let staleWindow):
            return .staleWhileRevalidate(maxAge: min(maxAge, serverDuration), staleWindow: staleWindow)
        case .rfc9111Compliant(let inner):
            return .rfc9111Compliant(wrapping: inner.applyingMaxAge(serverMaxAge: serverMaxAge))
        case .staleIfError(let inner):
            return .staleIfError(wrapping: inner.applyingMaxAge(serverMaxAge: serverMaxAge))
        case .requestOnlyIfCached(let inner):
            return .requestOnlyIfCached(wrapping: inner.applyingMaxAge(serverMaxAge: serverMaxAge))
        }
    }

    private func revalidatingInsteadOfServing(
        cached: CachedResponse,
        now: Date,
        rfc9111InitialAge: TimeInterval
    ) -> CachePreparation {
        switch prepare(
            cached: cached,
            now: now,
            rfc9111InitialAge: rfc9111InitialAge
        ) {
        case .bypass:
            return .bypass
        case .revalidate(let entry):
            return .revalidate(entry)
        case .revalidateWithStaleIfError(let entry):
            return .revalidateWithStaleIfError(entry)
        case .returnCached, .returnStaleAndRevalidate:
            return .revalidate(cached)
        case .onlyIfCachedMiss:
            return .onlyIfCachedMiss
        }
    }
}

// MARK: - Current age

/// RFC 9111 section 4.2.3 response-age calculation. The value is captured at
/// storage time so cache residency can be added deterministically after an
/// in-memory lookup or a persistent-cache reopen.
package enum RFC9111ResponseAge {
    /// RFC 9111 section 1.2.2 requires unrepresentable delta-seconds to be
    /// treated as 2^31 (or the largest convenient positive integer).
    package static let maximumDeltaSeconds: TimeInterval = 2_147_483_648

    package static func clamp(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return maximumDeltaSeconds }
        return min(max(0, value), maximumDeltaSeconds)
    }

    package static func initialAge(
        headers: [String: String],
        requestTime: Date,
        responseTime: Date
    ) -> TimeInterval {
        let dateValue = headerValues(named: "Date", in: headers).first
            .flatMap { HTTPDateParser.parse($0, requiresGMTZone: true) }
        let apparentAge =
            dateValue.map {
                clamp(responseTime.timeIntervalSince($0))
            } ?? 0
        let responseDelay = clamp(responseTime.timeIntervalSince(requestTime))
        let correctedAgeValue = clamp(ageValue(in: headers) + responseDelay)
        return max(apparentAge, correctedAgeValue)
    }

    private static func ageValue(in headers: [String: String]) -> TimeInterval {
        let values = headerValues(named: "Age", in: headers)
        guard values.count <= 1 else { return maximumDeltaSeconds }
        guard let raw = values.first else { return 0 }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
            value.allSatisfy({ $0.isASCII && $0.isNumber }),
            let parsed = UInt64(value)
        else {
            return maximumDeltaSeconds
        }
        return min(TimeInterval(parsed), maximumDeltaSeconds)
    }

    private static func headerValues(
        named name: String,
        in headers: [String: String]
    ) -> [String] {
        headers.compactMap { key, value in
            key.caseInsensitiveCompare(name) == .orderedSame ? value : nil
        }
    }
}

// MARK: - Directive parsing

/// Parsed projection of the `Cache-Control` header directives that the
/// adapter cares about. Header names are matched case-insensitively;
/// directive names are normalised to lowercase per RFC 9111 §5.2.
struct RFC9111CacheControlDirectives: Sendable, Equatable {
    enum FreshnessLifetime: Sendable, Equatable {
        case unspecified
        case lifetime(TimeInterval)
        case invalidOrExpired
    }

    let noStore: Bool
    let noCache: Bool
    let mustRevalidate: Bool
    let maxAgeSeconds: TimeInterval?
    let hasInvalidMaxAge: Bool
    let staleIfErrorSeconds: TimeInterval?
    let hasInvalidStaleIfError: Bool

    init(headers: [String: String]) {
        let combined =
            headers
            .filter { $0.key.caseInsensitiveCompare("Cache-Control") == .orderedSame }
            .map { $0.value }
            .joined(separator: ",")
        guard !combined.isEmpty else {
            self.noStore = false
            self.noCache = false
            self.mustRevalidate = false
            self.maxAgeSeconds = nil
            self.hasInvalidMaxAge = false
            self.staleIfErrorSeconds = nil
            self.hasInvalidStaleIfError = false
            return
        }

        var noStore = false
        var noCache = false
        var mustRevalidate = false
        var maxAge: TimeInterval?
        var maxAgeCount = 0
        var hasInvalidMaxAge = false
        var staleIfError: TimeInterval?
        var staleIfErrorCount = 0
        var hasInvalidStaleIfError = false
        for element in HTTPListParser.split(combined) {
            let name = HTTPListParser.directiveName(of: element)
            switch name {
            case "no-store":
                noStore = true
            case "no-cache":
                noCache = true
            case "must-revalidate":
                mustRevalidate = true
            case "max-age":
                // `s-maxage` is intentionally not honoured: it targets shared
                // caches and InnoNetwork's response cache is private-by-default.
                maxAgeCount += 1
                if maxAgeCount > 1 {
                    hasInvalidMaxAge = true
                } else if let value = Self.directiveValue(of: element),
                    let seconds = Self.parseDeltaSeconds(value)
                {
                    maxAge = seconds
                } else {
                    hasInvalidMaxAge = true
                }
            case "stale-if-error":
                staleIfErrorCount += 1
                if staleIfErrorCount > 1 {
                    hasInvalidStaleIfError = true
                } else if let value = Self.directiveValue(of: element),
                    let seconds = Self.parseDeltaSeconds(value)
                {
                    staleIfError = seconds
                } else {
                    hasInvalidStaleIfError = true
                }
            default:
                continue
            }
        }
        self.noStore = noStore
        self.noCache = noCache
        self.mustRevalidate = mustRevalidate
        self.maxAgeSeconds = hasInvalidMaxAge ? nil : maxAge
        self.hasInvalidMaxAge = hasInvalidMaxAge
        self.staleIfErrorSeconds = hasInvalidStaleIfError ? nil : staleIfError
        self.hasInvalidStaleIfError = hasInvalidStaleIfError
    }

    func freshnessLifetime(headers: [String: String], storedAt: Date) -> FreshnessLifetime {
        if hasInvalidMaxAge {
            return .invalidOrExpired
        }
        if let maxAgeSeconds {
            return .lifetime(maxAgeSeconds)
        }
        let referenceDate =
            Self.headerValue("Date", in: headers)
            .flatMap { HTTPDateParser.parse($0, requiresGMTZone: true) }
            ?? storedAt

        if let expiresValue = Self.headerValue("Expires", in: headers) {
            guard let expires = HTTPDateParser.parse(expiresValue, requiresGMTZone: true) else {
                return .invalidOrExpired
            }
            let lifetime = expires.timeIntervalSince(referenceDate)
            guard lifetime > 0 else {
                return .invalidOrExpired
            }
            return .lifetime(lifetime)
        }

        guard
            let lastModifiedValue = Self.headerValue("Last-Modified", in: headers),
            let lastModified = HTTPDateParser.parse(lastModifiedValue, requiresGMTZone: true)
        else {
            return .unspecified
        }
        let age = referenceDate.timeIntervalSince(lastModified)
        guard age > 0 else { return .unspecified }
        return .lifetime(min(age * 0.1, 24 * 60 * 60))
    }

    private static func headerValue(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Returns the raw value portion of a single Cache-Control element
    /// (everything after the first `=`, with surrounding whitespace and
    /// at most one pair of surrounding quotes trimmed). Returns `nil`
    /// when the element has no `=` (presence-only directive).
    private static func directiveValue(of element: String) -> String? {
        guard let equals = element.firstIndex(of: "=") else { return nil }
        let raw = element[element.index(after: equals)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    /// Parses an RFC 9111 §1.2.2 `delta-seconds` (unsigned decimal).
    /// Negative or non-numeric values are rejected — servers occasionally
    /// emit `max-age=-1` to mean "stale immediately" but RFC 9111 leaves
    /// the behaviour undefined; the safest interpretation is to treat the
    /// cached entry as stale.
    private static func parseDeltaSeconds(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        guard let seconds = TimeInterval(trimmed) else {
            return RFC9111ResponseAge.maximumDeltaSeconds
        }
        return RFC9111ResponseAge.clamp(seconds)
    }
}
