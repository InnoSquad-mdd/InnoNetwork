import Darwin
import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

actor EventHubIntEventStore {
    private var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }

    func snapshot() -> [Int] {
        values
    }
}

actor EventHubNetworkEventRecorder {
    private var events: [NetworkEvent] = []

    func append(_ event: NetworkEvent) {
        events.append(event)
    }

    func snapshot() -> [NetworkEvent] {
        events
    }
}

struct EventHubRecordingObserver: NetworkEventObserving {
    let recorder: EventHubNetworkEventRecorder

    func handle(_ event: NetworkEvent) async {
        await recorder.append(event)
    }
}

struct EventHubFirstEventBlockingObserver: NetworkEventObserving {
    let recorder: EventHubNetworkEventRecorder
    let gate: EventHubDeliveryGate

    func handle(_ event: NetworkEvent) async {
        if case .requestStart = event {
            await gate.markStarted()
            await gate.waitForRelease()
        }
        await recorder.append(event)
    }
}

actor EventHubSpanCollector: NetworkSpanExporting {
    private var storedSpans: [NetworkSpan] = []

    func export(_ spans: [NetworkSpan]) async {
        storedSpans.append(contentsOf: spans)
    }

    func spans() -> [NetworkSpan] {
        storedSpans
    }
}

struct EventHubFirstEventBlockingSpanObserver: NetworkEventObserving {
    let downstream: NetworkSpanObserver
    let gate: EventHubDeliveryGate

    func handle(_ event: NetworkEvent) async {
        if case .requestStart = event {
            await gate.markStarted()
            await gate.waitForRelease()
        }
        await downstream.handle(event)
    }
}

final class EventHubMetricRecorder: EventPipelineMetricsReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var metrics: [EventPipelineMetric] = []

    func report(_ metric: EventPipelineMetric) {
        lock.lock()
        metrics.append(metric)
        lock.unlock()
    }

    func snapshot() -> [EventPipelineMetric] {
        lock.lock()
        let value = metrics
        lock.unlock()
        return value
    }
}

final class EventHubSlowMetricReporter: EventPipelineMetricsReporting, @unchecked Sendable {
    private let downstream: EventHubMetricRecorder
    private let delayMicroseconds: useconds_t

    init(downstream: EventHubMetricRecorder, delayMicroseconds: useconds_t = 200_000) {
        self.downstream = downstream
        self.delayMicroseconds = delayMicroseconds
    }

    func report(_ metric: EventPipelineMetric) {
        usleep(delayMicroseconds)
        downstream.report(metric)
    }
}

final class EventHubSlowObserver: NetworkEventObserving, Sendable {
    func handle(_ event: NetworkEvent) async {
        _ = event
        try? await Task.sleep(for: .milliseconds(200))
    }
}

actor EventHubDeliveryGate {
    private var started = false
    private var released = false
    private var returned = false
    private var continuedAfterCancellationAwareAwait = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }

    func markReturned() {
        returned = true
    }

    func hasReturned() -> Bool {
        returned
    }

    func markContinuedAfterCancellationAwareAwait() {
        continuedAfterCancellationAwareAwait = true
    }

    func didContinueAfterCancellationAwareAwait() -> Bool {
        continuedAfterCancellationAwareAwait
    }

    func markCancelled() {
        cancelled = true
    }

    func wasCancelled() -> Bool {
        cancelled
    }
}

actor EventHubListenerIDBox {
    private var listenerID: UUID?

    func set(_ listenerID: UUID) {
        self.listenerID = listenerID
    }

    func value() -> UUID? {
        listenerID
    }
}

actor EventHubPartitionRetirementSequencer {
    private let gates: [EventHubDeliveryGate]
    private var index = 0

    init(gates: [EventHubDeliveryGate]) {
        self.gates = gates
    }

    func handleRetirement() async {
        guard index < gates.count else { return }
        let gate = gates[index]
        index += 1
        await gate.markStarted()
        await gate.waitForRelease()
    }
}

@Suite("Event Hub Tests", .serialized)
struct EventHubTests {
}

func eventHubWaitForValues(
    store: EventHubIntEventStore,
    expectedCount: Int
) async throws -> [Int] {
    for _ in 0..<50 {
        let values = await store.snapshot()
        if values.count >= expectedCount {
            return values
        }
        try await Task.sleep(for: .milliseconds(20))
    }

    return await store.snapshot()
}

func eventHubWaitForCondition(
    timeout: TimeInterval,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }

    return await condition()
}

func eventHubWaitForNetworkEvents(
    recorder: EventHubNetworkEventRecorder,
    expectedCount: Int
) async throws -> [NetworkEvent] {
    for _ in 0..<50 {
        let events = await recorder.snapshot()
        if events.count >= expectedCount {
            return events
        }
        try await Task.sleep(for: .milliseconds(20))
    }

    return await recorder.snapshot()
}

func eventHubWaitForLatencyMetrics(
    recorder: EventHubMetricRecorder,
    partitionID: String,
    minimumCount: Int
) async throws -> [EventPipelineConsumerDeliveryLatencyMetric] {
    for _ in 0..<50 {
        let latencies = recorder.snapshot().compactMap { metric -> EventPipelineConsumerDeliveryLatencyMetric? in
            guard case .consumerDeliveryLatency(let latency) = metric else { return nil }
            return latency.partitionID == partitionID ? latency : nil
        }
        if latencies.count >= minimumCount {
            return latencies
        }
        try await Task.sleep(for: .milliseconds(20))
    }

    return recorder.snapshot().compactMap { metric -> EventPipelineConsumerDeliveryLatencyMetric? in
        guard case .consumerDeliveryLatency(let latency) = metric else { return nil }
        return latency.partitionID == partitionID ? latency : nil
    }
}

/// Bounded poll for an exact TestClock waiter count. Used to observe a loop
/// stopping (waiters dropping), which waitForWaiters(count:) — an at-least
/// condition — cannot express.
func eventHubWaitForClockWaiterCount(
    _ clock: TestClock,
    exactly target: Int,
    timeout: Duration = .seconds(2)
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if clock.waiterCount == target { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return clock.waiterCount == target
}

func eventHubWaitForConsumerMetrics(
    recorder: EventHubMetricRecorder,
    partitionID: String,
    minimumCount: Int,
    minimumDroppedEventCount: Int = 0
) async throws -> [EventPipelineConsumerStateMetric] {
    for _ in 0..<50 {
        let metrics = recorder.snapshot().compactMap { metric -> EventPipelineConsumerStateMetric? in
            guard case .consumerState(let state) = metric else { return nil }
            return state.partitionID == partitionID ? state : nil
        }
        let maxDroppedEventCount = metrics.map(\.droppedEventCount).max() ?? 0
        if metrics.count >= minimumCount, maxDroppedEventCount >= minimumDroppedEventCount {
            return metrics
        }
        try await Task.sleep(for: .milliseconds(20))
    }

    return recorder.snapshot().compactMap { metric -> EventPipelineConsumerStateMetric? in
        guard case .consumerState(let state) = metric else { return nil }
        return state.partitionID == partitionID ? state : nil
    }
}

func eventHubWaitForConsumerMetric(
    recorder: EventHubMetricRecorder,
    partitionID: String,
    consumerID: String,
    predicate: (EventPipelineConsumerStateMetric) -> Bool
) async -> EventPipelineConsumerStateMetric? {
    for _ in 0..<100 {
        let metric = recorder.snapshot().compactMap { metric -> EventPipelineConsumerStateMetric? in
            guard case .consumerState(let state) = metric else { return nil }
            return state.partitionID == partitionID && state.consumerID == consumerID ? state : nil
        }.last(where: predicate)
        if let metric {
            return metric
        }
        try? await Task.sleep(for: .milliseconds(20))
    }

    return recorder.snapshot().compactMap { metric -> EventPipelineConsumerStateMetric? in
        guard case .consumerState(let state) = metric else { return nil }
        return state.partitionID == partitionID && state.consumerID == consumerID ? state : nil
    }.last(where: predicate)
}

func eventHubWaitForAggregateSnapshots(
    recorder: EventHubMetricRecorder,
    hubKind: EventPipelineHubKind,
    minimumCount: Int
) async throws -> [EventPipelineAggregateSnapshotMetric] {
    for _ in 0..<50 {
        let snapshots = recorder.snapshot().compactMap { metric -> EventPipelineAggregateSnapshotMetric? in
            guard case .aggregateSnapshot(let snapshot) = metric else { return nil }
            return snapshot.hubKind == hubKind ? snapshot : nil
        }
        if snapshots.count >= minimumCount {
            return snapshots
        }
        try await Task.sleep(for: .milliseconds(20))
    }

    return recorder.snapshot().compactMap { metric -> EventPipelineAggregateSnapshotMetric? in
        guard case .aggregateSnapshot(let snapshot) = metric else { return nil }
        return snapshot.hubKind == hubKind ? snapshot : nil
    }
}

func eventHubWaitForAdditionalAggregateSnapshots(
    recorder: EventHubMetricRecorder,
    hubKind: EventPipelineHubKind,
    existingCount: Int,
    additionalCount: Int
) async throws -> [EventPipelineAggregateSnapshotMetric] {
    for _ in 0..<100 {
        let snapshots = recorder.snapshot().compactMap { metric -> EventPipelineAggregateSnapshotMetric? in
            guard case .aggregateSnapshot(let snapshot) = metric else { return nil }
            return snapshot.hubKind == hubKind ? snapshot : nil
        }
        if snapshots.count >= existingCount + additionalCount {
            return Array(snapshots.dropFirst(existingCount))
        }
        try await Task.sleep(for: .milliseconds(20))
    }

    let snapshots = recorder.snapshot().compactMap { metric -> EventPipelineAggregateSnapshotMetric? in
        guard case .aggregateSnapshot(let snapshot) = metric else { return nil }
        return snapshot.hubKind == hubKind ? snapshot : nil
    }
    return Array(snapshots.dropFirst(existingCount))
}

func eventHubWaitForAggregateSnapshot(
    recorder: EventHubMetricRecorder,
    hubKind: EventPipelineHubKind,
    predicate: (EventPipelineAggregateSnapshotMetric) -> Bool
) async -> EventPipelineAggregateSnapshotMetric? {
    for _ in 0..<100 {
        let snapshot = recorder.snapshot().compactMap { metric -> EventPipelineAggregateSnapshotMetric? in
            guard case .aggregateSnapshot(let snapshot) = metric else { return nil }
            return snapshot.hubKind == hubKind ? snapshot : nil
        }.last(where: predicate)
        if let snapshot {
            return snapshot
        }
        try? await Task.sleep(for: .milliseconds(20))
    }

    return recorder.snapshot().compactMap { metric -> EventPipelineAggregateSnapshotMetric? in
        guard case .aggregateSnapshot(let snapshot) = metric else { return nil }
        return snapshot.hubKind == hubKind ? snapshot : nil
    }.last(where: predicate)
}

func eventHubRequestID(of event: NetworkEvent) -> UUID {
    switch event {
    case .requestStart(let requestID, _, _, _):
        return requestID
    case .requestAdapted(let requestID, _, _, _):
        return requestID
    case .responseReceived(let requestID, _, _):
        return requestID
    case .retryScheduled(let requestID, _, _, _):
        return requestID
    case .requestFinished(let requestID, _, _):
        return requestID
    case .requestFailed(let requestID, _, _):
        return requestID
    case .cacheRevalidation(let originalID, _):
        return originalID
    case .decision(let decision):
        return decision.requestID
    }
}
