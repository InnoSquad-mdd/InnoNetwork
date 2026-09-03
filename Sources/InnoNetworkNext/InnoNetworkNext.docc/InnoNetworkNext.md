# ``InnoNetworkNext``

Preview the operation, failure, and configuration contracts planned for
InnoNetwork 6 without replacing the 5.x request pipeline.

## Overview

Import both `InnoNetwork` and `InnoNetworkNext`, keep existing endpoint
definitions, and wrap an existing client or create one from the new
configuration façade:

```swift
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

## Topics

### Configuration

- ``NetworkClientConfiguration``

### Execution

- ``OperationNetworkClient``
- ``NetworkOperation``
- ``NetworkOperationEvent``

### Failure Contract

- ``NetworkFailure``
- ``NetworkFailureKind``
- ``NetworkRecoveryDisposition``
