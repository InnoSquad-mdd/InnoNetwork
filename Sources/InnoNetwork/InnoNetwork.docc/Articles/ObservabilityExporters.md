# Observability exporters

Bridge ``NetworkEventObserving`` events into vendor SDKs (Sentry,
OpenTelemetry, Pulse, Datadog) through external adapter packages
without coupling the core library to any specific telemetry vendor.

## Why adapters live outside this package

InnoNetwork's observability surface is intentionally vendor-neutral.
``NetworkEvent`` exposes structured request lifecycle events, and
`ObservabilityPack(eventObservers:)` attaches observers to the client. A
vendor SDK adapter is glue code: it forwards those events to
the vendor's tracer/span/breadcrumb API in the format the vendor
expects.

``SemanticNetworkEventAdapter`` provides the dependency-free half of that
glue. It maps lifecycle events to a compact envelope using current HTTP
semantic-convention names such as `http.request.method`, `url.full`,
`server.address`, `http.request.resend_count`,
`http.response.status_code`, and `error.type`. The application still owns the
vendor exporter. Use ``NetworkSpanObserver`` when it wants bounded request and
retry-attempt span lifecycles instead of reconstructing them itself.

```swift
let observer = SemanticNetworkEventAdapter { event in
    await telemetryPipeline.export(event)
}

let configuration = NetworkConfiguration.advanced(
    baseURL: apiBaseURL,
    observability: ObservabilityPack(eventObservers: [observer])
)
```

```swift
let spans = NetworkSpanObserver(
    exporter: MySpanExporter(),
    policy: .init(maximumBufferedSpans: 512, batchSize: 32)
)
let configuration = NetworkConfiguration.advanced(
    baseURL: apiBaseURL,
    observability: ObservabilityPack(eventObservers: [spans])
)
```

Span records intentionally omit URLs, headers, and bodies. A logical request
span owns child attempt spans; retry scheduling closes the prior attempt as
`retried`. A child begins only when the physical transport dispatches. Cache
hits, coalesced followers, and failures during preparation, quota, or admission
therefore keep their logical span without a synthetic attempt. For buffered
requests, the child ends when the response body has been collected, before
decoding interceptors and policy feedback run. Its HTTP status and transport
outcome remain attached even if the logical request later fails decoding. A
streaming child stays open after response headers and ends with the stream.
Export runs asynchronously through a bounded buffer and drops the oldest
completed span under sustained exporter backpressure.

Putting that glue inside InnoNetwork would either pull every supported
vendor into the package graph (build-time cost, transitive license
exposure) or fragment the API behind compile-time flags. The vendor
adapter pattern keeps the core surface small and lets each adapter
ship at the cadence of its underlying vendor SDK.

## Adapter shape

A typical adapter is a small product that depends on InnoNetwork plus
the vendor SDK and exposes one or more observer types:

```swift
import InnoNetwork
import Sentry

public struct SentryNetworkEventObserver: NetworkEventObserving {
    public init() {}

    public func handle(_ event: NetworkEvent) async {
        switch event {
        case .requestStart(let requestID, let method, let url, let retryIndex):
            SentrySDK.startTransaction(
                name: "\(method) \(url)",
                operation: "http.client"
            )
            _ = (requestID, retryIndex)
        case .requestFinished(let requestID, let statusCode, let byteCount):
            SentrySDK.addBreadcrumb(Breadcrumb(level: .info, category: "http.client"))
            _ = (requestID, statusCode, byteCount)
        case .requestFailed(let requestID, let errorCode, let message):
            SentrySDK.capture(message: "request_failed \(errorCode): \(message)")
            _ = requestID
        default:
            break
        }
    }
}
```

The caller plugs the observer into ``NetworkConfiguration``:

```swift
let configuration = NetworkConfiguration.advanced(
    baseURL: apiBaseURL,
    observability: ObservabilityPack(eventObservers: [SentryNetworkEventObserver()])
)
```

The adapter owns:

- Event-to-vendor type mapping (transactions, spans, breadcrumbs).
- Sampling rules - InnoNetwork emits every event; the adapter decides
  what to forward.
- Vendor-specific lifecycle (transaction commit, breadcrumb buffer
  flush) tied to request boundaries.

Use ``NetworkMetricsReporting`` alongside observers when a vendor needs
raw `URLSessionTaskMetrics`; event observers are for logical lifecycle
events, while metrics reporters receive Foundation's transport metrics.

## Privacy contract

The core redacts lifecycle metadata before it calls any
``NetworkEventObserving`` implementation:

- events never contain request/response headers or bodies;
- request URLs remove user-info and fragments, redact every query value, and
  mask JWT-like path values; and
- failure messages are stable categories such as `timeout.request` or
  `configuration.invalid_request`, never `localizedDescription` or decoder,
  trust, and response payload text.

An exporter should treat these fields as the maximum safe default and must not
reconstruct a raw URL or join an event with separately captured credentials or
bodies. If a vendor SDK performs automatic HTTP body/header capture, disable
that capture in the adapter configuration unless the application has an
independently reviewed, sampled, and consented data policy.

`DefaultNetworkLogger` follows the same boundary and redacts every header
value, not only well-known credential header names. `URLRequest.curlCommand()`
also redacts every header and query value and omits the body by default. Raw
header/query/body output is available only through explicit local-diagnostic
options and is not suitable for telemetry exporters.

## Example sketches

### OpenTelemetry

Map each `.requestStart` event to a span, decorate it with
`http.request.method` and `url.full`, then attach
`http.response.status_code` and `network.response.body.size` from the
matching `.requestFinished` or `.responseReceived` event. Retry
attempts can be represented as child spans by keying in-flight spans by
`requestID`.

### Pulse

Pulse already speaks a structured logging API. The adapter forwards
`.requestStart`, `.responseReceived`, `.requestFinished`, and
`.requestFailed` to a Pulse network logger and lets the Pulse UI render
the rest. Body capture should be gated by a sampling closure on the
adapter - InnoNetwork does not buffer bodies for observability by
default.

### Datadog

Datadog RUM and APM both have HTTP request models. An adapter
typically forwards to RUM's resource API for foreground traffic and
to the tracer for backend-style flows. Retry decisions from
`.retryScheduled` and refresh-token failures from `.requestFailed` map
cleanly to RUM's error and action surfaces.

### Sentry

Wrap each request in a transaction keyed by the observed method and URL
or by an endpoint label supplied by the adapter's caller. Surface
``NetworkError`` cases as captured errors with the canonical category
as a tag so Sentry's grouping respects InnoNetwork's classification.
Refresh-token cycles should be breadcrumbs rather than transactions -
they're frequent and not interesting on their own unless they fail.

## Versioning and compatibility

The current observability surface belongs to the planned Provisionally Stable
6.x contract. Until 6.0.0 is tagged, production adapter packages should remain
on a 5.x minor range or an exact released version. After adopting 6.x, use a
minor-bounded range when reproducibility is required. Changes remain additive;
adapters should include a `default:` case in event switches so new
``NetworkEvent`` cases do not break compilation before the adapter has mapped
them.
