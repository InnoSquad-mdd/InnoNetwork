# Offline-Aware Request Handling

Decide whether a request should fail fast, queue, or proceed
optimistically when the device cannot reach the network. Covers
the existing ``NetworkMonitoring`` protocol, the
`NetworkSnapshot` shape, and recipes for building offline-aware
``RequestInterceptor`` and ``RetryPolicy`` integrations.

## Overview

Mobile networks are flaky by design — cellular handover, captive
portals, transient TLS handshake stalls, train tunnels — and
issuing every request optimistically wastes battery and surfaces
slow timeouts to the user instead of immediate, actionable
errors. InnoNetwork ships ``NetworkMonitor`` (an `NWPathMonitor`
wrapper) and the ``NetworkMonitoring`` protocol so consumers can
inspect or wait on the path state, but the *policy* — fail fast,
queue, retry-on-recovery — stays in the consumer's hands.

This article documents the three patterns most apps need.

## Pattern A — Inspect-and-skip

For one-off background work where a missing network is a
business-acceptable outcome (telemetry flush, prefetch warm-up):

```swift
guard
    let snapshot = await monitor.currentSnapshot(),
    snapshot.status == .satisfied
else { return }

try await client.request(prefetchEndpoint)
```

This avoids issuing a request that will time out 30 seconds later
on a known-unsatisfied path. It does not retry on recovery; the
caller is expected to schedule the next attempt.

## Pattern B — Fail-fast `RequestInterceptor`

For interactive flows where queuing is wrong (the user is staring
at a spinner) but optimistic dispatch is wasteful, wrap the check
in a ``RequestInterceptor``:

```swift
struct RequireOnlineInterceptor: RequestInterceptor {
    let monitor: any NetworkMonitoring

    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        let snapshot = await monitor.currentSnapshot()
        if let snapshot, snapshot.status == .unsatisfied {
            throw NetworkError.configuration(
                reason: .offline("Network is not reachable; refusing to dispatch.")
            )
        }
        // .requiresConnection (VPN/proxy needed) and nil (no
        // path observed yet) fall through — those are not
        // definitively offline.
        return urlRequest
    }
}

let configuration = NetworkConfiguration.advanced(
    baseURL: baseURL,
    auth: AuthPack(
        additionalRequestInterceptors: [RequireOnlineInterceptor(monitor: networkMonitor)]
    )
)
```

The interceptor runs on every retry attempt by ``RequestInterceptor``
contract, so a request issued during a brief outage will retry once
the path recovers (assuming the configured ``RetryPolicy`` accepts
the thrown ``NetworkError``).

The reason this is a `RequestInterceptor` rather than a
``RetryPolicy`` modifier is that **rejecting the request before it
hits the wire** is the point: a `RetryPolicy.shouldRetry` callback
runs only after a transport error, which means the OS already
spent the timeout budget waiting for an unsatisfied path.

## Pattern C — Wait-for-recovery on retry

For non-interactive flows (background uploads, telemetry batching)
where the request *should* succeed eventually, combine
``NetworkMonitoring/waitForChange(from:timeout:)`` with a custom retry policy:

```swift
struct WaitForRecoveryRetryPolicy: RetryPolicy {
    let inner: any RetryPolicy
    let monitor: any NetworkMonitoring

    var maxRetries: Int { inner.maxRetries }
    var maxTotalRetries: Int { inner.maxTotalRetries }
    var retryDelay: TimeInterval { inner.retryDelay }
    var maxRetryAfterDelay: TimeInterval { inner.maxRetryAfterDelay }

    func retryDelay(for retryIndex: Int) -> TimeInterval {
        inner.retryDelay(for: retryIndex)
    }

    func shouldRetry(
        error: Error,
        retryIndex: Int,
        request: URLRequest,
        response: HTTPURLResponse?
    ) async -> RetryDecision {
        let snapshot = await monitor.currentSnapshot()
        if snapshot?.status == .unsatisfied {
            // Wait up to 30 s for the path to recover before
            // letting the inner policy decide.
            _ = await monitor.waitForChange(from: snapshot, timeout: 30)
        }
        return await inner.shouldRetry(
            error: error,
            retryIndex: retryIndex,
            request: request,
            response: response
        )
    }
}
```

This decouples the retry budget from the offline-wait time:
``RetryPolicy/maxRetries`` still bounds attempts, but transient
offline windows do not burn through the budget on a tight loop.

## Why no built-in `OfflineQueuePolicy`?

A persistent offline queue (write-through to disk, replay on
recovery) is a backend-shaped decision: idempotency, cookie
scoping, quota, and TTL semantics depend on the API contract, not
on the transport layer. Shipping a one-size-fits-all queue would
either be too restrictive (locked to a single persistence engine)
or too configurable (every consumer ends up wiring their own
shape anyway). The patterns above let consumers compose what they
need on top of ``NetworkMonitoring`` and the existing retry
machinery without taking a dependency on a full queue
implementation that may not match their semantics.

## Cellular access vs reachability

`NetworkSnapshot.interfaceTypes` reports the active path interface
mix (`.wifi`, `.cellular`, `.wiredEthernet`, `.loopback`,
`.other`) so consumers can implement Wi-Fi-only or
cellular-allowed policies on top of reachability:

```swift
guard let snapshot = await monitor.currentSnapshot() else { return }
guard snapshot.status == .satisfied else { return }
guard snapshot.interfaceTypes.contains(.wifi) else {
    // skip large download on cellular
    return
}
try await downloader.startLargeMediaDownload()
```

For an ongoing policy, observe ``NetworkMonitoring/snapshots()``. New
subscribers receive the current snapshot when one is available, followed by
later changes. The stream keeps only the newest pending state for slow
consumers:

```swift
let snapshots = await monitor.snapshots()
for await snapshot in snapshots {
    let shouldDeferLargeTransfer = snapshot.isConstrained || snapshot.isExpensive
    updateTransferPolicy(shouldDeferLargeTransfer)
}
```

Snapshots produced by ``NetworkMonitor`` also report DNS, IPv4, and IPv6
capabilities plus a typed ``NetworkUnsatisfiedReason`` for unsatisfied paths.
Capability values on manually constructed snapshots use conservative defaults
unless supplied explicitly.

This pairs naturally with the `allowsCellularAccess` inputs on
``TransportPack`` and the optional `DownloadTransferPack` type from
`InnoNetworkDownload`.

## See also

- ``NetworkMonitoring``
- ``NetworkSnapshot``
- ``NetworkReachabilityStatus``
- ``NetworkUnsatisfiedReason``
- ``NetworkInterfaceType``
- <doc:RetryDecisions>
- [HTTP/3 opt-in](../../../../docs/HTTP3.md) for transport tuning
  that often pairs with offline-aware policies.
