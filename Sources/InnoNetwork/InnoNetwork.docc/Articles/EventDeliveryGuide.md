# Event delivery policy

Tune the library's event pipeline for throughput, memory headroom, and
slow-consumer isolation.

## Overview

`InnoNetwork`, `InnoNetworkDownload`, and `InnoNetworkWebSocket` all publish
task-scoped event streams through a shared, bounded
`TaskEventHub`. ``EventDeliveryPolicy`` is the single knob that governs how
that hub handles back-pressure:

- per-partition buffering — one partition per logical task
- overflow behavior when a partition fills up
- per-consumer buffering so one slow listener or `AsyncStream`
  subscriber cannot starve the others

The default configuration (``EventDeliveryPolicy/default``) targets common
client workloads — a few dozen concurrent tasks, each with a few listeners,
none of which intentionally block inside event handlers. Reach for explicit
tuning only when you observe dropped events in your metrics, or when a
memory-constrained device forces a smaller ceiling.

## Where the policy is applied

``EventDeliveryPolicy`` flows through each module's observability pack:

- WebSocket: `WebSocketObservabilityPack(eventDeliveryPolicy:)`
- Download: `DownloadObservabilityPack(eventDeliveryPolicy:)`
- network requests: `ObservabilityPack(eventDeliveryPolicy:)`

Passing a custom policy replaces the default for that manager's lifetime.

## Terminal Ordering

Normal request, download, and WebSocket notifications use the configured
partition and consumer overflow policy. Their one authoritative final outcome
has a stronger guarantee. The event is admitted to the task partition and to
every observer, listener, or `AsyncStream` consumer in the
publication snapshot even when `.dropNewest` queues are full; the same
guarantee applies under `.dropOldest`. For request observability, those outcomes are
`requestFinished` and `requestFailed`.
When a bounded partition or consumer queue is full, its oldest queued event is
displaced to make room for the final outcome. The manager waits for enqueue,
not user-handler execution.

Request, download, and WebSocket terminal outcomes atomically seal their
partition when admitted. A late progress, response, or state publisher cannot
enqueue behind the final outcome or displace it. Earlier notifications in a
multi-event terminal burst, and all other nonterminal events, retain the
configured overflow policy and may be dropped.

Consumers should treat stream completion as "no more events after the terminal
outcome", not as a separate status signal. Event handling remains asynchronous
after enqueue and may finish after a manager shutdown call returns. Request
finish waits for the partition queue to hand events to each observer chain, but
does not wait for observer handler execution.

## Buffering: `maxBufferedEventsPerPartition`

Each partition — one per active task — holds up to
`maxBufferedEventsPerPartition` events while listener fan-out drains the
queue. The default is tuned for interactive UX where every event ultimately
reaches a listener. Two common adjustments:

- **Hot partitions (many tasks, fast producers)**: raise the ceiling so
  bursts don't reach the drop threshold mid-session. Typical range
  1024–4096.
- **Memory-constrained devices**: lower to 128–256 and prefer
  ``EventPipelineOverflowPolicy/dropOldest`` so the newest state always
  reaches the UI.

`maxBufferedEventsPerConsumer` applies to listener chains and `AsyncStream`
subscribers alike, isolating a slow consumer from the rest of the partition.
The final request/download/WebSocket outcome is the sole admission exception
described above; it displaces the oldest queued event instead of being dropped.

## Overflow: `.dropOldest` vs `.dropNewest`

When a partition is full, the policy picks which event the hub discards.

### Choose `.dropOldest` when

- The UI renders the **latest** state (progress bars, heartbeat ticks,
  reconnect banners).
- Replaying history is not required — stale events hurt perceived latency.
- Consumers treat each event as a point sample; missing an earlier tick is
  recoverable from later ticks.

### Choose `.dropNewest` when

- Events carry **ordered** side-effects or audit information that must not
  be reordered (e.g. log streams, replay buffers).
- Dropping the latest is safer than corrupting ordering — the next event
  will re-establish truth.
- You prefer a visible backlog (older events still flow) to silent
  mutation of the head.

## Metrics reporter integration

Inject an ``EventPipelineMetricsReporting`` implementation to observe how
the policy behaves under real load. The hub emits four metric types:

- ``EventPipelinePartitionStateMetric`` — per-partition queue depth and
  running drop counter
- ``EventPipelineConsumerStateMetric`` — per-consumer queue depth for listener
  chains and `AsyncStream` subscribers
- ``EventPipelineConsumerDeliveryLatencyMetric`` — observed enqueue→handle
  latency (samples)
- ``EventPipelineAggregateSnapshotMetric`` — periodic rollup:
  active partition/consumer counts, max queue depth, p50/p95 latency,
  event-drop totals, and metrics-proxy health

For `AsyncStream` subscribers, ``EventPipelineConsumerStateMetric`` queue depth
is a best-effort last known buffered depth. `AsyncStream` does not expose
dequeue callbacks, so the hub refreshes stream consumer ages on snapshot
cadence while retaining the last observed depth.

A minimal reporter skeleton:

```swift
struct LoggingMetricsReporter: EventPipelineMetricsReporting {
    func report(_ metric: EventPipelineMetric) {
        switch metric {
        case .partitionState(let state) where state.droppedEventCount > 0:
            logger.warning(
                "partition \(state.partitionID) dropped \(state.droppedEventCount)"
            )
        case .aggregateSnapshot(let snapshot):
            logger.info(
                "queue-depth max=\(snapshot.maxQueueDepth) " +
                "latency p95=\(snapshot.p95DeliveryLatency ?? 0) " +
                "eventDrops=\(snapshot.overflowEventCount) " +
                "metricDrops=\(snapshot.metricsOverflowCount)"
            )
        default:
            break
        }
    }
}

let config = WebSocketConfiguration.advanced(
    observability: WebSocketObservabilityPack(
        eventDeliveryPolicy: EventDeliveryPolicy(
            maxBufferedEventsPerPartition: 1024,
            maxBufferedEventsPerConsumer: 512,
            overflowPolicy: .dropOldest
        ),
        eventMetricsReporter: LoggingMetricsReporter()
    )
)
```

## Interpreting aggregate snapshots

``EventPipelineAggregateSnapshotMetric`` fields at a glance:

| Field | What it tells you |
|---|---|
| `activePartitionCount` | Tasks currently publishing — should track your app's concurrent workload. |
| `activeConsumerCount` | Total listener and `AsyncStream` subscriber count across all partitions. Sudden drops hint at a consumer crash or early cancellation. |
| `maxQueueDepth` | Deepest partition queue at the snapshot moment. Sustained highs near `maxBufferedEventsPerPartition` indicate the ceiling is too low. |
| `totalDroppedEventCount` | Monotonically increasing drop total. Delta between snapshots is the drop rate. |
| `overflowEventCount` | Windowed count, resets per snapshot. Use this to alert instead of the running total. |
| `totalDroppedMetricCount` | Monotonically increasing drop total inside the metrics reporter proxy. Separate from event delivery loss. |
| `metricsOverflowCount` | Windowed metrics-proxy overflow count. Rising values usually mean the reporter is too slow for the current event volume. |
| `p50DeliveryLatency` / `p95DeliveryLatency` | Consumer-side latency (enqueue → handler entry). p95 > 250 ms usually means a consumer is blocking. |

## Default quick reference

- ``EventDeliveryPolicy/default``: balanced for interactive UX; safe
  starting point.
- Leave the reporter unset when metrics are not needed. Tests that need to
  exercise a reporter can define a minimal local
  ``EventPipelineMetricsReporting`` conformance.

Revisit the policy when you ship operational metrics that show overflow or
consumer latency p95 creeping up — that is the earliest signal that the
defaults no longer match your workload.
