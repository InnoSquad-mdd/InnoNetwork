import Foundation

package actor NetworkEventHub {
    private struct EventOccurrence: Sendable {
        let event: NetworkEvent
        let occurredAt: Date
        let completesPhysicalTransport: Bool
        let isInternalPhysicalTransportCompletion: Bool
    }

    private struct PendingEvent: Sendable {
        let event: NetworkEvent
        let observers: [any NetworkEventObserving]
        let enqueuedAt: Date
        let occurredAt: Date
        let completesPhysicalTransport: Bool
        let isInternalPhysicalTransportCompletion: Bool
        let guaranteesAdmission: Bool
    }

    private struct PartitionState {
        var queue = FIFOBuffer<PendingEvent>()
        var observerChains: [Int: EventDeliveryChain<EventOccurrence>] = [:]
        var isDraining = false
        var isClosed = false
        var isRetiring = false
        var droppedEventCount = 0
    }

    private var partitions: [UUID: PartitionState] = [:]
    /// Waiters that close a request lifecycle only after its partition queue
    /// has been handed off to the per-observer delivery chains. Observer
    /// handlers remain asynchronous after that handoff.
    private var partitionClosureWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private let policy: EventDeliveryPolicy
    private let clock: any InnoNetworkClock
    private let metricsProxy: EventPipelineMetricsReporterProxy?
    private let drainSuspension: (@Sendable (UUID) async -> Void)?
    private let retirementSuspension: (@Sendable (UUID) async -> Void)?
    private var metricsReporter: (any EventPipelineMetricsReporting)? { metricsProxy }

    package init(
        policy: EventDeliveryPolicy = .default,
        metricsReporter: (any EventPipelineMetricsReporting)? = nil,
        hubKind: EventPipelineHubKind = .networkRequest,
        metricsSnapshotInterval: Duration = .seconds(30),
        clock: any InnoNetworkClock = SystemClock(),
        retirementSuspension: (@Sendable (UUID) async -> Void)? = nil
    ) {
        self.policy = policy
        self.clock = clock
        self.drainSuspension = nil
        self.retirementSuspension = retirementSuspension
        self.metricsProxy = metricsReporter.map {
            EventPipelineMetricsReporterProxy(
                hubKind: hubKind,
                reporter: $0,
                snapshotInterval: metricsSnapshotInterval,
                clock: clock
            )
        }
    }

    package init(
        policy: EventDeliveryPolicy,
        testingDrainSuspension: @escaping @Sendable (UUID) async -> Void
    ) {
        self.policy = policy
        self.clock = SystemClock()
        self.drainSuspension = testingDrainSuspension
        self.retirementSuspension = nil
        self.metricsProxy = nil
    }

    deinit {
        metricsProxy?.cancelImmediately()
    }

    /// Drains metrics accepted before this actor-isolated lifecycle boundary.
    package func shutdown() async {
        await metricsProxy?.shutdown()
    }

    /// Enqueues `event` for delivery to `observers` partitioned by `requestID`.
    ///
    /// Observers are bound at publish time, so this hub does not retain
    /// historical events for late subscribers. ``finish(requestID:)`` closes
    /// the active partition, so publishes serialized while it retires are
    /// dropped. Request IDs are one-use lifecycle identifiers and must not be
    /// reused after finish; the hub discards closed partition tombstones once
    /// observer-queue handoff completes.
    package func publish(
        _ event: NetworkEvent,
        requestID: UUID,
        observers: [any NetworkEventObserving],
        occurredAt: Date? = nil,
        completesPhysicalTransport: Bool = false
    ) {
        enqueue(
            event,
            requestID: requestID,
            observers: observers,
            guaranteesAdmission: false,
            occurredAt: occurredAt,
            completesPhysicalTransport: completesPhysicalTransport,
            isInternalPhysicalTransportCompletion: false
        )
    }

    /// Closes an already accepted streaming body attempt without emitting a
    /// second public `responseReceived` event. Timestamped internal observers
    /// use this boundary to exclude reconnect delay from physical spans.
    package func publishPhysicalTransportCompletion(
        requestID: UUID,
        statusCode: Int,
        observers: [any NetworkEventObserving],
        occurredAt: Date
    ) {
        enqueue(
            .responseReceived(
                requestID: requestID,
                statusCode: statusCode,
                byteCount: 0
            ),
            requestID: requestID,
            observers: observers,
            guaranteesAdmission: false,
            occurredAt: occurredAt,
            completesPhysicalTransport: true,
            isInternalPhysicalTransportCompletion: true
        )
    }

    /// Guarantees admission of the authoritative terminal request outcome and
    /// atomically seals its partition before a late publisher can displace it.
    package func publishTerminal(
        _ event: NetworkEvent,
        requestID: UUID,
        observers: [any NetworkEventObserving]
    ) {
        guard event.isTerminalRequestOutcome else {
            enqueue(
                event,
                requestID: requestID,
                observers: observers,
                guaranteesAdmission: false,
                occurredAt: nil,
                completesPhysicalTransport: false,
                isInternalPhysicalTransportCompletion: false
            )
            return
        }
        enqueue(
            event,
            requestID: requestID,
            observers: observers,
            guaranteesAdmission: true,
            occurredAt: nil,
            completesPhysicalTransport: false,
            isInternalPhysicalTransportCompletion: false
        )
    }

    private func enqueue(
        _ event: NetworkEvent,
        requestID: UUID,
        observers: [any NetworkEventObserving],
        guaranteesAdmission: Bool,
        occurredAt: Date?,
        completesPhysicalTransport: Bool,
        isInternalPhysicalTransportCompletion: Bool
    ) {
        guard !observers.isEmpty else { return }
        let enqueuedAt = clock.now()
        var partition = partitions[requestID] ?? PartitionState()
        guard !partition.isClosed else { return }
        if partition.queue.count >= policy.maxBufferedEventsPerPartition {
            partition.droppedEventCount += 1
            if guaranteesAdmission {
                _ = partition.queue.popFirst()
            } else {
                switch policy.overflowPolicy {
                case .dropOldest:
                    _ = partition.queue.popFirst()
                case .dropNewest:
                    partitions[requestID] = partition
                    reportPartitionMetric(for: requestID, partition: partition)
                    return
                }
            }
        }
        partition.queue.append(
            PendingEvent(
                event: event,
                observers: observers,
                enqueuedAt: enqueuedAt,
                occurredAt: occurredAt ?? enqueuedAt,
                completesPhysicalTransport: completesPhysicalTransport,
                isInternalPhysicalTransportCompletion: isInternalPhysicalTransportCompletion,
                guaranteesAdmission: guaranteesAdmission
            )
        )
        if guaranteesAdmission {
            partition.isClosed = true
        }
        partitions[requestID] = partition
        reportPartitionMetric(for: requestID, partition: partition)
        startDrainIfNeeded(requestID: requestID)
    }

    /// Closes a request partition and waits until its queued events have been
    /// handed to each observer chain. Observer handler execution remains
    /// asynchronous so slow instrumentation cannot delay request completion.
    package func finish(requestID: UUID) async {
        guard var partition = partitions[requestID] else { return }
        partition.isClosed = true
        partitions[requestID] = partition

        if partition.isRetiring || partition.isDraining || !partition.queue.isEmpty {
            await withCheckedContinuation { continuation in
                partitionClosureWaiters[requestID, default: []].append(continuation)
            }
        } else {
            await cleanupPartitionIfPossible(requestID: requestID)
        }
    }

    private func startDrainIfNeeded(requestID: UUID) {
        guard var partition = partitions[requestID], !partition.isDraining else { return }
        partition.isDraining = true
        partitions[requestID] = partition
        Task {
            await drain(requestID: requestID)
        }
    }

    private func drain(requestID: UUID) async {
        if let drainSuspension {
            await drainSuspension(requestID)
        }
        while let pending = popNextEvent(requestID: requestID) {
            for (index, observer) in pending.observers.enumerated() {
                let chain = observerChain(for: requestID, index: index, observer: observer)
                let occurrence = EventOccurrence(
                    event: pending.event,
                    occurredAt: pending.occurredAt,
                    completesPhysicalTransport: pending.completesPhysicalTransport,
                    isInternalPhysicalTransportCompletion:
                        pending.isInternalPhysicalTransportCompletion
                )
                if pending.guaranteesAdmission {
                    await chain.enqueueGuaranteed(
                        occurrence,
                        enqueuedAt: pending.enqueuedAt
                    )
                } else {
                    await chain.enqueue(
                        occurrence,
                        enqueuedAt: pending.enqueuedAt
                    )
                }
            }
        }

        guard var partition = partitions[requestID] else { return }
        partition.isDraining = false
        partitions[requestID] = partition

        if !partition.queue.isEmpty {
            startDrainIfNeeded(requestID: requestID)
            return
        }

        await cleanupPartitionIfPossible(requestID: requestID)
    }

    private func popNextEvent(requestID: UUID) -> PendingEvent? {
        guard var partition = partitions[requestID] else { return nil }
        let pending = partition.queue.popFirst()
        partitions[requestID] = partition
        reportPartitionMetric(for: requestID, partition: partition)
        return pending
    }

    private func observerChain(
        for requestID: UUID,
        index: Int,
        observer: any NetworkEventObserving
    ) -> EventDeliveryChain<EventOccurrence> {
        var partition = partitions[requestID] ?? PartitionState()
        if let existing = partition.observerChains[index] {
            partitions[requestID] = partition
            return existing
        }

        let partitionID = requestID.uuidString
        let consumerID = "observer-\(index)"
        let chain = EventDeliveryChain<EventOccurrence>(
            partitionID: partitionID,
            consumerID: consumerID,
            policy: policy,
            metricsReporter: metricsReporter,
            clock: clock
        ) { occurrence, _ in
            if let timestamped = observer as? any TimestampedNetworkEventObserving {
                if occurrence.isInternalPhysicalTransportCompletion,
                    case .responseReceived(let requestID, let statusCode, _) = occurrence.event
                {
                    await timestamped.physicalTransportCompleted(
                        requestID: requestID,
                        statusCode: statusCode,
                        occurredAt: occurrence.occurredAt
                    )
                    return
                }
                await timestamped.handle(
                    occurrence.event,
                    occurredAt: occurrence.occurredAt,
                    completesPhysicalTransport: occurrence.completesPhysicalTransport
                )
            } else {
                await observer.handle(occurrence.event)
            }
        }
        partition.observerChains[index] = chain
        partitions[requestID] = partition
        return chain
    }

    private func cleanupPartitionIfPossible(requestID: UUID) async {
        guard var partition = partitions[requestID] else { return }
        guard
            partition.isClosed,
            !partition.isRetiring,
            !partition.isDraining,
            partition.queue.isEmpty
        else { return }

        // Keep the closed partition installed across the actor reentrancy
        // points below. Otherwise a publish serialized while an observer
        // chain is closing could recreate this request lifecycle, and a
        // concurrent finish could observe the wrong partition.
        partition.isRetiring = true
        partitions[requestID] = partition
        if let retirementSuspension {
            await retirementSuspension(requestID)
        }

        for chain in partition.observerChains.values {
            await chain.finish(deliverQueuedEvents: true)
        }

        partitions.removeValue(forKey: requestID)
        let closureWaiters = partitionClosureWaiters.removeValue(forKey: requestID) ?? []
        for waiter in closureWaiters {
            waiter.resume()
        }
    }

    package func _testingRetirementState(
        requestID: UUID
    ) -> (isClosed: Bool, isRetiring: Bool, closureWaiterCount: Int)? {
        guard let partition = partitions[requestID] else { return nil }
        return (
            isClosed: partition.isClosed,
            isRetiring: partition.isRetiring,
            closureWaiterCount: partitionClosureWaiters[requestID]?.count ?? 0
        )
    }

    private func reportPartitionMetric(for requestID: UUID, partition: PartitionState) {
        metricsReporter?.report(
            .partitionState(
                EventPipelinePartitionStateMetric(
                    partitionID: requestID.uuidString,
                    queueDepth: partition.queue.count,
                    droppedEventCount: partition.droppedEventCount,
                    oldestQueuedEventAge: partition.queue.first.map { clock.now().timeIntervalSince($0.enqueuedAt) }
                )
            )
        )
    }
}
