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
    default: showFailure()
    }
}
```

``NetworkFailure`` is a value-only boundary: it does not retain response
bodies, headers, URLs, or arbitrary underlying error descriptions. Use
``NetworkOperation/events`` for a bounded operation-local start/terminal
lifecycle, and retain the existing `NetworkEventObserving` integration for
attempt-level production telemetry.

The 5.x `InnoNetworkNext` product no longer exists. Remove that product from
the package dependency and replace `import InnoNetworkNext` with
`import InnoNetwork`. The source names of its preview types are unchanged.
