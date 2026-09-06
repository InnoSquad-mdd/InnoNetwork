import Foundation
import InnoNetwork
import Testing

@Suite("RFC 9111 Compliant Cache Policy Tests")
struct RFC9111ComplianceTests {
    @Test("Age received from an intermediary contributes to current age")
    func intermediaryAgeContributesToCurrentAge() {
        let storedAt = Date(timeIntervalSince1970: 10_000)
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: [
                "Cache-Control": "max-age=60, must-revalidate",
                "Age": "120",
            ],
            storedAt: storedAt
        )
        let adapter = ResponseCachePolicy.rfc9111Compliant(
            wrapping: .cacheFirst(maxAge: .seconds(3_600))
        )

        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(1)) {
        case .revalidate(let attached):
            #expect(attached == cached)
        default:
            Issue.record("an entry older than max-age at storage must be revalidated")
        }
    }

    @Test("Apparent age from Date prevents an expired response from becoming fresh on storage")
    func apparentAgeContributesToCurrentAge() {
        let storedAt = Date(timeIntervalSince1970: 10_000)
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: [
                "Date": "Thu, 01 Jan 1970 02:00:00 GMT",
                "Expires": "Thu, 01 Jan 1970 02:01:00 GMT",
            ],
            storedAt: storedAt
        )
        let adapter = ResponseCachePolicy.rfc9111Compliant(
            wrapping: .cacheFirst(maxAge: .seconds(3_600))
        )

        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(1)) {
        case .revalidate(let attached):
            #expect(attached == cached)
        default:
            Issue.record("an already-expired origin response must not become fresh when stored")
        }
    }

    @Test("RFC freshness is exclusive at the max-age boundary")
    func maxAgeBoundaryIsStale() {
        let storedAt = Date(timeIntervalSince1970: 10_000)
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Cache-Control": "max-age=60"],
            storedAt: storedAt
        )
        let adapter = ResponseCachePolicy.rfc9111Compliant(
            wrapping: .cacheFirst(maxAge: .seconds(60))
        )

        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(60)) {
        case .revalidate:
            break
        default:
            Issue.record("freshness_lifetime must be greater than current_age")
        }
    }

    @Test("Plain cache policy remains independent from RFC Age metadata")
    func plainPolicyIgnoresRFCResponseAge() {
        let storedAt = Date(timeIntervalSince1970: 10_000)
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Age": "120"],
            storedAt: storedAt
        )

        switch ResponseCachePolicy.cacheFirst(maxAge: .seconds(60)).prepare(
            cached: cached,
            now: storedAt.addingTimeInterval(1)
        ) {
        case .returnCached:
            break
        default:
            Issue.record("the RFC-agnostic policy contract must remain unchanged")
        }
    }

    @Test(
        "Invalid and overflowing Age values fail closed without overflowing",
        arguments: [
            "1, 2",
            "-1",
            "not-a-number",
            "999999999999999999999999999999999999999",
        ])
    func invalidAgeFailsClosed(age: String) {
        let storedAt = Date(timeIntervalSince1970: 10_000)
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: [
                "Cache-Control": "max-age=60",
                "Age": age,
            ],
            storedAt: storedAt
        )
        let adapter = ResponseCachePolicy.rfc9111Compliant(
            wrapping: .cacheFirst(maxAge: .seconds(60))
        )

        switch adapter.prepare(cached: cached, now: storedAt) {
        case .revalidate:
            break
        default:
            Issue.record("invalid or excessive Age must not extend cache reuse")
        }
    }

    @Test("stale-if-error uses corrected current age")
    func staleIfErrorUsesCorrectedAge() {
        let storedAt = Date(timeIntervalSince1970: 10_000)
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: [
                "Cache-Control": "max-age=5, stale-if-error=30",
                "Age": "20",
            ],
            storedAt: storedAt
        )
        let policy = ResponseCachePolicy.staleIfError(
            wrapping: .rfc9111Compliant(
                wrapping: .cacheFirst(maxAge: .seconds(60))
            )
        )

        #expect(
            policy.staleIfErrorFallback(
                cached: cached,
                now: storedAt.addingTimeInterval(20)
            ) == nil
        )
    }

    @Test("stale-if-error accepts a valid origin window through either wrapper order")
    func staleIfErrorAcceptsValidWindowAcrossWrapperOrder() {
        let storedAt = Date()
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Cache-Control": "max-age=5, stale-if-error=30"],
            storedAt: storedAt
        )
        let policies: [ResponseCachePolicy] = [
            .staleIfError(
                wrapping: .rfc9111Compliant(
                    wrapping: .cacheFirst(maxAge: .seconds(10))
                )
            ),
            .rfc9111Compliant(
                wrapping: .staleIfError(
                    wrapping: .cacheFirst(maxAge: .seconds(10))
                )
            ),
        ]

        for policy in policies {
            #expect(
                policy.staleIfErrorFallback(
                    cached: cached,
                    now: storedAt.addingTimeInterval(20)
                ) == cached
            )
        }
    }

    @Test("stale-if-error fails closed for malformed duplicate expired and must-revalidate directives")
    func staleIfErrorRejectsUnsafeDirectiveShapes() {
        let storedAt = Date()
        let policy = ResponseCachePolicy.staleIfError(
            wrapping: .cacheFirst(maxAge: .seconds(5))
        )
        let cases: [(String, TimeInterval)] = [
            ("stale-if-error", 10),
            ("stale-if-error=-1", 10),
            ("stale-if-error=20, stale-if-error=30", 10),
            ("stale-if-error=5", 11),
            ("must-revalidate, stale-if-error=30", 10),
        ]

        for (cacheControl, age) in cases {
            let cached = CachedResponse(
                data: Data("payload".utf8),
                headers: ["Cache-Control": cacheControl],
                storedAt: storedAt
            )
            #expect(
                policy.staleIfErrorFallback(
                    cached: cached,
                    now: storedAt.addingTimeInterval(age)
                ) == nil,
                "Unexpected fallback for \(cacheControl)"
            )
        }
    }


    // MARK: - no-store

    @Test("no-store on cached entry forces network revalidation through adapter")
    func noStoreSuppressesCacheReads() {
        let storedAt = Date()
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Cache-Control": "no-store"],
            storedAt: storedAt
        )
        let inner = ResponseCachePolicy.cacheFirst(maxAge: .seconds(60))
        let adapter = ResponseCachePolicy.rfc9111Compliant(wrapping: inner)

        // Inner policy would happily serve a fresh entry.
        switch inner.prepare(cached: cached, now: storedAt) {
        case .returnCached:
            break
        default:
            Issue.record("inner policy should serve a fresh entry without no-store enforcement")
        }

        // Adapter must refuse the read despite the entry being inside maxAge.
        switch adapter.prepare(cached: cached, now: storedAt) {
        case .revalidate(let attached):
            #expect(attached == nil, "no-store entry must be treated as absent")
        default:
            Issue.record("adapter should force revalidation for no-store cached entry")
        }
    }

    // MARK: - must-revalidate

    @Test("must-revalidate disables stale-while-revalidate stale window")
    func mustRevalidateBlocksStaleWindow() {
        let storedAt = Date()
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Cache-Control": "must-revalidate"],
            storedAt: storedAt
        )
        let inner = ResponseCachePolicy.staleWhileRevalidate(maxAge: .seconds(10), staleWindow: .seconds(60))
        let adapter = ResponseCachePolicy.rfc9111Compliant(wrapping: inner)

        // 30 seconds past storedAt → inside the inner stale window (10+60 = 70s).
        let now = storedAt.addingTimeInterval(30)

        switch inner.prepare(cached: cached, now: now) {
        case .returnStaleAndRevalidate:
            break
        default:
            Issue.record("inner policy should hit the stale window without must-revalidate enforcement")
        }

        switch adapter.prepare(cached: cached, now: now) {
        case .revalidate(let attached):
            #expect(attached == cached, "must-revalidate must force a conditional revalidation, not bypass")
        default:
            Issue.record("adapter should force revalidation when must-revalidate is set on a stale entry")
        }
    }

    @Test("must-revalidate does not affect fresh entries")
    func mustRevalidateLeavesFreshEntriesAlone() {
        let storedAt = Date()
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Cache-Control": "must-revalidate"],
            storedAt: storedAt
        )
        let adapter = ResponseCachePolicy.rfc9111Compliant(
            wrapping: .staleWhileRevalidate(maxAge: .seconds(60), staleWindow: .seconds(60))
        )

        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(5)) {
        case .returnCached:
            break
        default:
            Issue.record("must-revalidate should not block reads while entry is still fresh")
        }
    }

    // MARK: - max-age override

    @Test("Server max-age narrows inner freshness window")
    func serverMaxAgeNarrowsFreshness() {
        let storedAt = Date()
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Cache-Control": "max-age=5"],
            storedAt: storedAt
        )
        let adapter = ResponseCachePolicy.rfc9111Compliant(
            wrapping: .cacheFirst(maxAge: .seconds(60))
        )

        // 3 seconds in → inside server max-age (5s)  →  fresh.
        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(3)) {
        case .returnCached:
            break
        default:
            Issue.record("entry should be fresh within the server max-age window")
        }

        // 10 seconds in → past server max-age (5s) but inside inner maxAge (60s).
        // Adapter must use the narrower server value.
        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(10)) {
        case .revalidate(let attached):
            #expect(attached == cached, "expired entry must be revalidated with the cached representation attached")
        default:
            Issue.record("adapter should revalidate past the server max-age window")
        }
    }

    @Test("Server max-age cannot extend caller's freshness window")
    func serverMaxAgeCannotExtendCallerWindow() {
        let storedAt = Date()
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Cache-Control": "max-age=600"],
            storedAt: storedAt
        )
        let adapter = ResponseCachePolicy.rfc9111Compliant(
            wrapping: .cacheFirst(maxAge: .seconds(10))
        )

        // 20 seconds in → past caller's 10s ceiling, inside server's 600s.
        // The caller's ceiling must remain enforced.
        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(20)) {
        case .revalidate:
            break
        default:
            Issue.record("server cannot extend the caller's freshness ceiling")
        }
    }

    // MARK: - Expires fallback

    @Test("Expires fallback uses Date header for freshness")
    func expiresFallbackUsesDateHeader() {
        let storedAt = Date(timeIntervalSince1970: 0)
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: [
                "Date": "Thu, 01 Jan 1970 00:00:00 GMT",
                "Expires": "Thu, 01 Jan 1970 00:00:30 GMT",
            ],
            storedAt: storedAt
        )
        let adapter = ResponseCachePolicy.rfc9111Compliant(
            wrapping: .cacheFirst(maxAge: .seconds(60))
        )

        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(20)) {
        case .returnCached:
            break
        default:
            Issue.record("entry should be fresh before the Expires-derived lifetime")
        }

        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(40)) {
        case .revalidate(let attached):
            #expect(attached == cached)
        default:
            Issue.record("entry should be stale after the Expires-derived lifetime")
        }
    }

    @Test("Expires fallback uses storedAt when Date header is absent")
    func expiresFallbackUsesStoredAtWithoutDate() {
        let storedAt = Date(timeIntervalSince1970: 0)
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Expires": "Thu, 01 Jan 1970 00:00:30 GMT"],
            storedAt: storedAt
        )
        let adapter = ResponseCachePolicy.rfc9111Compliant(
            wrapping: .cacheFirst(maxAge: .seconds(60))
        )

        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(20)) {
        case .returnCached:
            break
        default:
            Issue.record("Date-less entry should fall back to storedAt for Expires freshness")
        }
    }

    @Test("Invalid Expires is treated as stale")
    func invalidExpiresIsStale() {
        let storedAt = Date()
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Expires": "0"],
            storedAt: storedAt
        )
        let adapter = ResponseCachePolicy.rfc9111Compliant(
            wrapping: .cacheFirst(maxAge: .seconds(60))
        )

        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(1)) {
        case .revalidate(let attached):
            #expect(attached == cached)
        default:
            Issue.record("invalid Expires should not fall back to serving a fresh inner-policy entry")
        }
    }

    @Test("max-age takes precedence over Expires")
    func maxAgeTakesPrecedenceOverExpires() {
        let storedAt = Date(timeIntervalSince1970: 0)
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: [
                "Cache-Control": "max-age=60",
                "Expires": "Thu, 01 Jan 1970 00:00:00 GMT",
            ],
            storedAt: storedAt
        )
        let adapter = ResponseCachePolicy.rfc9111Compliant(
            wrapping: .cacheFirst(maxAge: .seconds(60))
        )

        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(30)) {
        case .returnCached:
            break
        default:
            Issue.record("valid max-age must ignore an older Expires fallback")
        }
    }

    // MARK: - Last-Modified heuristic freshness

    @Test("Last-Modified heuristic freshness uses ten percent of apparent age")
    func lastModifiedHeuristicUsesTenPercentOfAge() {
        let storedAt = Date(timeIntervalSince1970: 1_000)
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: [
                "Date": "Thu, 01 Jan 1970 00:16:40 GMT",
                "Last-Modified": "Thu, 01 Jan 1970 00:00:00 GMT",
            ],
            storedAt: storedAt
        )
        let adapter = ResponseCachePolicy.rfc9111Compliant(
            wrapping: .cacheFirst(maxAge: .seconds(1_000))
        )

        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(90)) {
        case .returnCached:
            break
        default:
            Issue.record("entry should be fresh within the 10% Last-Modified heuristic lifetime")
        }

        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(110)) {
        case .revalidate(let attached):
            #expect(attached == cached)
        default:
            Issue.record("entry should be stale after the 10% Last-Modified heuristic lifetime")
        }
    }

    @Test("Last-Modified heuristic falls back to storedAt when Date is absent")
    func lastModifiedHeuristicUsesStoredAtWithoutDate() {
        let storedAt = Date(timeIntervalSince1970: 1_000)
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Last-Modified": "Thu, 01 Jan 1970 00:00:00 GMT"],
            storedAt: storedAt
        )
        let adapter = ResponseCachePolicy.rfc9111Compliant(
            wrapping: .cacheFirst(maxAge: .seconds(1_000))
        )

        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(90)) {
        case .returnCached:
            break
        default:
            Issue.record("Date-less entry should use storedAt for heuristic freshness")
        }
    }

    @Test("Invalid or future Last-Modified does not extend inner policy")
    func invalidOrFutureLastModifiedDoesNotExtendInnerPolicy() {
        let storedAt = Date(timeIntervalSince1970: 1_000)
        let adapter = ResponseCachePolicy.rfc9111Compliant(
            wrapping: .cacheFirst(maxAge: .seconds(1))
        )
        let invalid = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Last-Modified": "invalid"],
            storedAt: storedAt
        )
        let future = CachedResponse(
            data: Data("payload".utf8),
            headers: [
                "Date": "Thu, 01 Jan 1970 00:16:40 GMT",
                "Last-Modified": "Thu, 01 Jan 1970 00:20:00 GMT",
            ],
            storedAt: storedAt
        )

        switch adapter.prepare(cached: invalid, now: storedAt.addingTimeInterval(2)) {
        case .revalidate:
            break
        default:
            Issue.record("invalid Last-Modified should not create heuristic freshness")
        }
        switch adapter.prepare(cached: future, now: storedAt.addingTimeInterval(2)) {
        case .revalidate:
            break
        default:
            Issue.record("future Last-Modified should not create heuristic freshness")
        }
    }

    // MARK: - Pass-through

    @Test("Adapter without directives matches inner policy behaviour")
    func transparentWithoutDirectives() {
        let storedAt = Date()
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Content-Type": "application/json"],
            storedAt: storedAt
        )
        let inner = ResponseCachePolicy.cacheFirst(maxAge: .seconds(30))
        let adapter = ResponseCachePolicy.rfc9111Compliant(wrapping: inner)

        let now = storedAt.addingTimeInterval(10)
        let innerResult = inner.prepare(cached: cached, now: now)
        let adapterResult = adapter.prepare(cached: cached, now: now)

        switch (innerResult, adapterResult) {
        case (.returnCached, .returnCached):
            break
        default:
            Issue.record("adapter must behave identically when no governed directives are present")
        }
    }

    @Test("Adapter inherits inner policy capabilities")
    func adapterCapabilitiesMatchInner() {
        let inner = ResponseCachePolicy.cacheFirst(maxAge: .seconds(60))
        let adapter = ResponseCachePolicy.rfc9111Compliant(wrapping: inner)
        #expect(adapter.isEnabled == inner.isEnabled)
        #expect(adapter.allowsCacheRead == inner.allowsCacheRead)
        #expect(adapter.allowsCacheWrite == inner.allowsCacheWrite)
        #expect(adapter.allowsConditionalRevalidation == inner.allowsConditionalRevalidation)

        let disabledAdapter = ResponseCachePolicy.rfc9111Compliant(wrapping: .disabled)
        #expect(!disabledAdapter.isEnabled)
        #expect(!disabledAdapter.allowsCacheRead)
        #expect(!disabledAdapter.allowsCacheWrite)
    }

    // MARK: - Edge cases

    @Test("max-age with malformed value is treated as stale")
    func malformedMaxAgeIsStale() {
        let storedAt = Date()
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Cache-Control": "max-age=not-a-number"],
            storedAt: storedAt
        )
        let adapter = ResponseCachePolicy.rfc9111Compliant(
            wrapping: .cacheFirst(maxAge: .seconds(60))
        )

        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(30)) {
        case .revalidate(let attached):
            #expect(attached == cached)
        default:
            Issue.record("malformed max-age should be treated as stale")
        }
    }

    @Test("duplicate max-age directives are treated as stale")
    func duplicateMaxAgeIsStale() {
        let storedAt = Date()
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Cache-Control": "max-age=60, max-age=120"],
            storedAt: storedAt
        )
        let adapter = ResponseCachePolicy.rfc9111Compliant(
            wrapping: .cacheFirst(maxAge: .seconds(60))
        )

        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(10)) {
        case .revalidate(let attached):
            #expect(attached == cached)
        default:
            Issue.record("duplicate freshness directives should not serve a cached entry")
        }
    }

    @Test("Multiple Cache-Control directives are honoured together")
    func combinedDirectives() {
        let storedAt = Date()
        let cached = CachedResponse(
            data: Data("payload".utf8),
            headers: ["Cache-Control": "max-age=5, must-revalidate"],
            storedAt: storedAt
        )
        let adapter = ResponseCachePolicy.rfc9111Compliant(
            wrapping: .staleWhileRevalidate(maxAge: .seconds(60), staleWindow: .seconds(60))
        )

        // Past server max-age (5s) — must-revalidate forbids the stale window.
        switch adapter.prepare(cached: cached, now: storedAt.addingTimeInterval(10)) {
        case .revalidate:
            break
        default:
            Issue.record("max-age + must-revalidate should force revalidation past the server window")
        }
    }
}
