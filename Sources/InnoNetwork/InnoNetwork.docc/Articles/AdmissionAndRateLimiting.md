# Admission and rate limiting

Bound physical transport work without changing cache or coalescing semantics.

Configure both policies through ``ResiliencePack``:

```swift
let configuration = NetworkConfiguration.advanced(
    baseURL: apiBaseURL,
    resilience: ResiliencePack(
        admission: RequestAdmissionPolicy(
            maximumConcurrentRequests: 8,
            maximumPendingRequests: 32,
            maximumQueueWait: .seconds(5),
            maximumConcurrentStreams: 2,
            maximumPendingStreams: 4
        ),
        advancedRateLimit: AdvancedRateLimitPolicy(
            algorithm: .tokenBucket(capacity: 20, refillPerSecond: 5)
        )
    )
)
```

Admission runs at the physical transport boundary, so cache hits and coalesced
followers do not consume request permits. Long-lived stream bodies use separate
slots and cannot exhaust the ordinary request pool. Every queue and origin
registry is bounded; cancellation and pre-dispatch failures release capacity.

Choose a token bucket for bursts with a steady refill, or an exact sliding
window when the server contract is expressed as requests per interval. The
optional IETF draft-11 response adapter is explicitly versioned because the
RateLimit field is still a draft contract. `Retry-After` remains independently
supported. Server hints only reduce local availability within configured bounds;
they never increase the caller's local quota.

``NetworkEvent/decision(_:)`` exposes allowed, delayed, and denied policy
outcomes without request payloads.
