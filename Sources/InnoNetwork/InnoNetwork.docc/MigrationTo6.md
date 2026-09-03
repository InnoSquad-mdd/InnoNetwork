# Migrating to InnoNetwork 6

Adopt the operation, failure, and configuration contracts promoted into the
core module in InnoNetwork 6.

## Overview

Import `InnoNetwork`, keep existing endpoint definitions, and wrap an existing
client or create one from the configuration façade:

```swift
import Foundation
import InnoNetwork

let configuration = NetworkClientConfiguration.production(
    baseURL: URL(string: "https://api.example.com")!,
    resilience: ResiliencePack(
        customExecutionPolicies: [
            RateLimitExecutionPolicy(maximumRequests: 10, per: .seconds(1))
        ]
    )
)
let client = OperationNetworkClient<DefaultNetworkClient>(
    configuration: configuration
)
let operation = client.start(GetProfile())

do {
    let profile = try await operation.value()
    _ = profile
} catch {
    switch error.recovery {
    case .retry: scheduleRetry()
    case .waitForConnectivity: showOfflineState()
    case .reauthenticate: presentSignIn()
    case .doNotRetry, .none: showFailure()
    @unknown default: showFailure()
    }
}
```

``NetworkFailure`` is a value-only boundary: it does not retain response
bodies, headers, URLs, or arbitrary underlying error descriptions. Use
``NetworkOperation/events`` for a bounded operation-local start/terminal
lifecycle, and retain the existing `NetworkEventObserving` integration for
attempt-level production telemetry.

Recovery is contextual. `OperationNetworkClient` recommends `.retry` for
GET, HEAD, OPTIONS, and TRACE by default. Unsafe methods such as POST remain
`.doNotRetry` even for transient status codes and timeouts because the server
may already have applied their side effect. Opt in only when the application
owns a stable idempotency key and reuses it across operation restarts:

```swift
let operation = client.start(
    CreateOrder(idempotencyKey: orderAttemptID),
    replaySafety: .stableIdempotencyKey
)
```

The automatic `IdempotencyKeyPolicy` uses the logical request identifier. A
new `NetworkOperation` receives a new identifier, so that policy alone does
not prove that an application-level restart is safe. A 401 maps to
`.reauthenticate` only for `.optional` or `.required` session-authenticated
endpoints; 403 is an authorization failure and stays terminal. Reauthentication
does not authorize automatic replay of the failed operation.

The 5.x `InnoNetworkNext` product no longer exists. Remove that product from
the package dependency and replace `import InnoNetworkNext` with
`import InnoNetwork`. The source names of its preview types are unchanged.
