# Retry decisions

Tune ``RetryPolicy`` so transient failures recover automatically without amplifying load on
unhealthy servers.

## Overview

A retry policy decides three things:

1. **Whether to retry** at all (``RetryDecision/retry`` vs ``RetryDecision/noRetry``).
2. **How long to wait** before retrying (delay, with optional jitter).
3. **When to stop retrying entirely** (per-request cap and absolute total cap).

InnoNetwork ships ``ExponentialBackoffRetryPolicy`` as the default. It honours the server's
`Retry-After` header (RFC 9110, both delta-seconds and HTTP-date forms) and clamps the
result to the policy's `maxDelay`.

## Choose a budget per session, not per request

`maxRetries` caps attempts for a single request. `maxTotalRetries` caps attempts across the
client's lifetime — and is **not** reset when the network monitor flips back to satisfied.
This is intentional: a flaky network should not turn a single user action into hundreds of
retries.

```swift
let policy = ExponentialBackoffRetryPolicy(
    maxRetries: 3,
    retryDelay: 0.5,
    maxDelay: 30,
    maxTotalRetries: 12
)
```

Pick `maxTotalRetries` based on the user-visible cost of a "slow but eventually-succeeds"
session, not on raw success probability. Ten retries of 30 seconds each is a five-minute
freeze.

## Honour Retry-After

When the server returns `429` or `503` with a `Retry-After` header, the policy uses the
header value instead of the computed backoff. The header is clamped to `maxDelay` so a
hostile or buggy server cannot pin the client for an hour.

```http
HTTP/1.1 429 Too Many Requests
Retry-After: 5
```

The next attempt fires after 5 seconds even if the exponential backoff for that attempt
number would have been larger.

## Client-side Request Pacing

``RateLimitExecutionPolicy`` is an experimental fixed-window admission policy
for APIs with a known client budget:

```swift
let pacing = RateLimitExecutionPolicy(maximumRequests: 10, per: .seconds(1))
let configuration = NetworkConfiguration.advanced(
    baseURL: apiBaseURL,
    resilience: ResiliencePack(customExecutionPolicies: [pacing])
)
```

The policy applies to transport attempts, so a retry consumes another slot.
It is cancellation-aware while waiting, but does not replace server-driven
`Retry-After` handling or distributed rate limiting.

## Idempotency defaults

The built-in ``ExponentialBackoffRetryPolicy`` is conservative by default:

- `GET`, `HEAD`, `OPTIONS`, and `TRACE` can retry automatically
- `POST`, upload, multipart, `PUT`, `PATCH`, and `DELETE` retry only when the
  originating request carries an `Idempotency-Key` header
- transport failures are still evaluated against the request method and headers
  before retrying

Use an idempotency key for any unsafe method where the server can deduplicate
duplicate submissions:

```swift
@APIDefinition(method: .post, path: "/orders", auth: .anonymous)
struct CreateOrder {
    typealias Parameter = CreateOrderInput
    typealias APIResponse = CreateOrderOutput

    let parameters: CreateOrderInput?
    var headers: HTTPHeaders {
        var headers = HTTPHeaders.default
        headers.add(name: "Idempotency-Key", value: "order-\(parameters?.clientID ?? "unknown")")
        return headers
    }
}
```

If a consumer already owns duplicate-write protection outside InnoNetwork and
needs the previous method-agnostic behaviour, opt in explicitly:

```swift
let configuration = NetworkConfiguration.advanced(
    baseURL: URL(string: "https://api.example.com")!,
    resilience: ResiliencePack(
        retry: ExponentialBackoffRetryPolicy(
            idempotencyPolicy: .methodAgnostic
        )
    )
)
```

## Streaming requests do not retry

`DefaultNetworkClient.stream(_:)` does not apply the retry policy — re-establishing a
streaming connection is a higher-level concern that depends on whether the protocol has
a notion of position or sequence number (Last-Event-ID for SSE, sequence cursor for
NDJSON, etc.). For SSE specifically, see the streaming resume policy on
``StreamingAPIDefinition``.

## Custom decisions

For policies that need access to the request, response, or attempt count, implement
``RetryPolicy`` directly:

```swift
struct CircuitBreakerRetryPolicy: RetryPolicy {
    let maxRetries = 3
    let retryDelay: TimeInterval = 0.5
    let breaker: CircuitBreaker

    func shouldRetry(
        error: NetworkError,
        retryIndex: Int,
        request: URLRequest?,
        response: HTTPURLResponse?
    ) -> RetryDecision {
        guard breaker.allowsRequest(to: request?.url) else {
            return .noRetry
        }
        guard retryIndex < maxRetries, isTransient(response, error) else {
            return .noRetry
        }
        return .retryAfter(retryDelay * Double(1 << retryIndex))
    }
}
```

The decision-returning overload is preferred over the legacy `Bool` overload — it lets the
policy carry the delay alongside the retry decision in a single result.

## Related

- ``RetryPolicy``
- ``RetryDecision``
- ``RetryIdempotencyPolicy``
- ``ExponentialBackoffRetryPolicy``
