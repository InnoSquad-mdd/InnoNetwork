import Foundation
import Testing

@testable import InnoNetwork

/// Property-based fuzz coverage over `ResponseCachePolicy.prepare`.
///
/// Drives the policy with deterministic random walks across the full
/// `(policy, cached?, now)` space and asserts the invariants the
/// production cache executor relies on:
///
/// 1. `.disabled` always yields `.bypass`, regardless of cache state
///    or freshness.
/// 2. `.networkOnly` always yields `.revalidate(nil)` — it never
///    surfaces a cached payload to the caller.
/// 3. `.returnCached` is only emitted for entries whose age is within
///    `maxAge` AND that do not require revalidation.
/// 4. `.returnStaleAndRevalidate` only fires for `staleWhileRevalidate`
///    inside the post-`maxAge` stale window AND for non-revalidating
///    entries.
/// 5. `requiresRevalidation == true` always escapes the fast path:
///    `prepare` returns `.revalidate(_)` for any enabled cache-aware
///    policy.
@Suite("ResponseCachePolicy fuzz")
struct ResponseCachePolicyFuzzTests {
    private static let seeds: [UInt64] = [
        0x1234_5678_ABCD_EF01,
        0xDEAD_BEEF_CAFE_BABE,
        0x0F0F_0F0F_0F0F_0F0F,
        0xFEDC_BA98_7654_3210,
        0xA5A5_5A5A_3C3C_C3C3,
    ]

    @Test(".disabled is always bypass", arguments: seeds)
    func disabledAlwaysBypasses(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        for _ in 0..<1000 {
            let cached = randomCached(rng: &rng)
            let now = Date(timeIntervalSinceReferenceDate: Double(rng.next() % 1_000_000))
            let result = ResponseCachePolicy.disabled.prepare(cached: cached, now: now)
            guard case .bypass = result else {
                Issue.record("disabled produced \(result) for cached=\(String(describing: cached))")
                continue
            }
        }
    }

    @Test(".networkOnly never surfaces a cached payload", arguments: seeds)
    func networkOnlyNeverSurfacesCached(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        for _ in 0..<1000 {
            let cached = randomCached(rng: &rng)
            let now = Date(timeIntervalSinceReferenceDate: Double(rng.next() % 1_000_000))
            let result = ResponseCachePolicy.networkOnly.prepare(cached: cached, now: now)
            switch result {
            case .revalidate(let payload):
                #expect(payload == nil, "networkOnly leaked cached payload \(String(describing: payload))")
            default:
                Issue.record("networkOnly produced unexpected \(result)")
            }
        }
    }

    @Test("cacheFirst returnCached only inside maxAge and not requiring revalidation", arguments: seeds)
    func cacheFirstFastPathRespectsAgeAndRequiresRevalidation(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        for _ in 0..<1000 {
            let storedAt = Date(timeIntervalSinceReferenceDate: 1_000_000)
            let ageSeconds = Double(rng.next() % 600)
            let now = storedAt.addingTimeInterval(ageSeconds)
            let requiresRevalidation = (rng.next() & 1) == 1
            let cached = makeCached(storedAt: storedAt, requiresRevalidation: requiresRevalidation)
            let maxAgeSeconds = Double(rng.next() % 600)
            let policy = ResponseCachePolicy.cacheFirst(maxAge: .seconds(Int(maxAgeSeconds)))

            let result = policy.prepare(cached: cached, now: now)
            switch result {
            case .returnCached:
                #expect(!requiresRevalidation, "returnCached emitted for entry that requires revalidation")
                #expect(
                    ageSeconds <= maxAgeSeconds,
                    "returnCached emitted past maxAge: age=\(ageSeconds) maxAge=\(maxAgeSeconds)")
            case .revalidate(let payload):
                #expect(payload != nil, "cacheFirst dropped cached payload during revalidate")
                if !requiresRevalidation {
                    #expect(ageSeconds > maxAgeSeconds, "cacheFirst revalidated within freshness window unexpectedly")
                }
            case .returnStaleAndRevalidate, .bypass, .revalidateWithStaleIfError, .onlyIfCachedMiss:
                Issue.record("cacheFirst produced unexpected \(result)")
            }
        }
    }

    @Test("staleWhileRevalidate respects the (maxAge, staleWindow) partition", arguments: seeds)
    func swrPartitionsAgeIntoFreshStaleAndExpired(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        for _ in 0..<1000 {
            let storedAt = Date(timeIntervalSinceReferenceDate: 1_000_000)
            let ageSeconds = Double(rng.next() % 600)
            let now = storedAt.addingTimeInterval(ageSeconds)
            let requiresRevalidation = (rng.next() & 1) == 1
            let cached = makeCached(storedAt: storedAt, requiresRevalidation: requiresRevalidation)
            let maxAgeSeconds = Double(rng.next() % 300)
            let staleWindowSeconds = Double(rng.next() % 300)
            let policy = ResponseCachePolicy.staleWhileRevalidate(
                maxAge: .seconds(Int(maxAgeSeconds)),
                staleWindow: .seconds(Int(staleWindowSeconds))
            )

            let result = policy.prepare(cached: cached, now: now)
            switch result {
            case .returnCached:
                #expect(!requiresRevalidation, "swr returnCached for entry that requires revalidation")
                #expect(
                    ageSeconds <= maxAgeSeconds,
                    "swr returnCached past maxAge: age=\(ageSeconds) maxAge=\(maxAgeSeconds)")
            case .returnStaleAndRevalidate:
                #expect(!requiresRevalidation, "swr stale-and-revalidate for entry that requires revalidation")
                #expect(
                    ageSeconds > maxAgeSeconds && ageSeconds <= maxAgeSeconds + staleWindowSeconds,
                    "swr stale-and-revalidate emitted outside [maxAge, maxAge+staleWindow]"
                )
            case .revalidate(let payload):
                #expect(payload != nil, "swr dropped cached payload during revalidate")
                if !requiresRevalidation {
                    #expect(
                        ageSeconds > maxAgeSeconds + staleWindowSeconds,
                        "swr revalidated inside stale window without cause"
                    )
                }
            case .bypass, .revalidateWithStaleIfError, .onlyIfCachedMiss:
                Issue.record("swr produced unexpected \(result)")
            }
        }
    }

    @Test("requiresRevalidation always forces revalidate on enabled cache-aware policies", arguments: seeds)
    func requiresRevalidationAlwaysEscapesFastPath(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        for _ in 0..<500 {
            let storedAt = Date(timeIntervalSinceReferenceDate: 1_000_000)
            let ageSeconds = Double(rng.next() % 600)
            let now = storedAt.addingTimeInterval(ageSeconds)
            let cached = makeCached(storedAt: storedAt, requiresRevalidation: true)
            let maxAgeSeconds = Int(rng.next() % 600)
            let staleWindowSeconds = Int(rng.next() % 600)

            let cacheFirst = ResponseCachePolicy.cacheFirst(maxAge: .seconds(maxAgeSeconds))
                .prepare(cached: cached, now: now)
            let swr = ResponseCachePolicy.staleWhileRevalidate(
                maxAge: .seconds(maxAgeSeconds),
                staleWindow: .seconds(staleWindowSeconds)
            ).prepare(cached: cached, now: now)

            for result in [cacheFirst, swr] {
                switch result {
                case .revalidate(let payload):
                    #expect(payload != nil, "requiresRevalidation dropped cached payload")
                default:
                    Issue.record("requiresRevalidation entry took fast path: \(result)")
                }
            }
        }
    }

    @Test("nil cached entry never resolves to a cached payload", arguments: seeds)
    func nilCachedNeverResolvesToCachedPayload(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        for _ in 0..<500 {
            let now = Date(timeIntervalSinceReferenceDate: Double(rng.next() % 1_000_000))
            let maxAgeSeconds = Int(rng.next() % 600)
            let staleWindowSeconds = Int(rng.next() % 600)
            let policies: [ResponseCachePolicy] = [
                .cacheFirst(maxAge: .seconds(maxAgeSeconds)),
                .staleWhileRevalidate(
                    maxAge: .seconds(maxAgeSeconds),
                    staleWindow: .seconds(staleWindowSeconds)
                ),
            ]
            for policy in policies {
                let result = policy.prepare(cached: nil, now: now)
                switch result {
                case .revalidate(let payload):
                    #expect(payload == nil, "nil cached produced revalidate(non-nil)")
                default:
                    Issue.record("nil cached produced \(result)")
                }
            }
        }
    }

    @Test("RFC no-cache header forces revalidation for externally restored entries")
    func rfcNoCacheHeaderForcesRevalidation() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let cached = CachedResponse(
            data: Data([0x01]),
            headers: ["Cache-Control": "no-cache, max-age=60"],
            storedAt: now,
            requiresRevalidation: false
        )

        let policies: [ResponseCachePolicy] = [
            .rfc9111Compliant(wrapping: .cacheFirst(maxAge: .seconds(60))),
            .rfc9111Compliant(
                wrapping: .staleWhileRevalidate(maxAge: .seconds(60), staleWindow: .seconds(60))
            ),
            .staleIfError(
                wrapping: .rfc9111Compliant(wrapping: .cacheFirst(maxAge: .seconds(60)))
            ),
        ]

        for policy in policies {
            let result = policy.prepare(cached: cached, now: now)
            guard case .revalidate(let candidate) = result else {
                Issue.record("Expected no-cache metadata to force revalidation, got \(result)")
                continue
            }
            #expect(candidate == cached)
        }
    }

    private func randomCached(rng: inout SplitMix64) -> CachedResponse? {
        if rng.next() & 1 == 0 { return nil }
        let storedAt = Date(timeIntervalSinceReferenceDate: Double(rng.next() % 1_000_000))
        return makeCached(storedAt: storedAt, requiresRevalidation: (rng.next() & 1) == 1)
    }

    private func makeCached(storedAt: Date, requiresRevalidation: Bool) -> CachedResponse {
        CachedResponse(
            data: Data([0x01, 0x02, 0x03]),
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            storedAt: storedAt,
            requiresRevalidation: requiresRevalidation,
            varyHeaders: nil
        )
    }
}

/// Deterministic 64-bit PRNG (SplitMix64) so fuzz iterations are
/// reproducible across runs and Swift versions.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
