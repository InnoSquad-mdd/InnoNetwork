import Foundation
import os

package actor TaskEventHub<Event: Sendable> {
    package typealias Listener = @Sendable (Event) async -> Void
    private var partitions: [String: PartitionState] = [:]
    /// Waiters used by lifecycle owners that must not finish retirement until
    /// a closed partition has been fully detached. Listener handlers are still
    /// allowed to drain asynchronously after detachment.
    private var partitionRetirementBarriers: [PartitionKey: PartitionRetirementBarrier] = [:]
    private let policy: EventDeliveryPolicy
    private let metricsProxy: EventPipelineMetricsReporterProxy?
    private let metricsSnapshotInterval: Duration?
    private let partitionRetirementHook: (@Sendable (String, UUID) async -> Void)?
    private var streamMetricsReconciliationTask: Task<Void, Never>?
    private let clock: any InnoNetworkClock
    private var metricsReporter: (any EventPipelineMetricsReporting)? { metricsProxy }

    package init(
        policy: EventDeliveryPolicy = .default,
        metricsReporter: (any EventPipelineMetricsReporting)? = nil,
        hubKind: EventPipelineHubKind = .genericTask,
        metricsSnapshotInterval: Duration = .seconds(30),
        clock: any InnoNetworkClock = SystemClock()
    ) {
        self.policy = policy
        self.clock = clock
        self.metricsSnapshotInterval = metricsReporter == nil ? nil : metricsSnapshotInterval
        self.metricsProxy = metricsReporter.map {
            EventPipelineMetricsReporterProxy(
                hubKind: hubKind,
                reporter: $0,
                snapshotInterval: metricsSnapshotInterval,
                clock: clock
            )
        }
        self.partitionRetirementHook = nil
    }

    package init(
        policy: EventDeliveryPolicy = .default,
        metricsReporter: (any EventPipelineMetricsReporting)? = nil,
        hubKind: EventPipelineHubKind = .genericTask,
        metricsSnapshotInterval: Duration = .seconds(30),
        clock: any InnoNetworkClock = SystemClock(),
        partitionRetirementHook: @escaping @Sendable (String, UUID) async -> Void
    ) {
        self.policy = policy
        self.clock = clock
        self.metricsSnapshotInterval = metricsReporter == nil ? nil : metricsSnapshotInterval
        self.metricsProxy = metricsReporter.map {
            EventPipelineMetricsReporterProxy(
                hubKind: hubKind,
                reporter: $0,
                snapshotInterval: metricsSnapshotInterval,
                clock: clock
            )
        }
        self.partitionRetirementHook = partitionRetirementHook
    }

    deinit {
        streamMetricsReconciliationTask?.cancel()
        metricsProxy?.cancelImmediately()
    }

    /// Stops periodic reconciliation and drains metrics accepted before this
    /// actor-isolated lifecycle boundary.
    package func shutdown() async {
        let reconciliationTask = streamMetricsReconciliationTask
        streamMetricsReconciliationTask = nil
        reconciliationTask?.cancel()
        await reconciliationTask?.value
        await metricsProxy?.shutdown()
    }

    package func addListener(taskID: String, listener: @escaping Listener) async -> UUID {
        await waitForClosedPartitionRetirement(taskID: taskID)
        let listenerID = UUID()
        var partition = partition(for: taskID)
        partition.listeners[listenerID] = EventDeliveryChain(
            partitionID: taskID,
            consumerID: listenerID.uuidString,
            policy: policy,
            metricsReporter: metricsReporter,
            clock: clock,
            handler: { event, _ in await listener(event) }
        )
        partitions[taskID] = partition
        return listenerID
    }

    package func removeListener(taskID: String, listenerID: UUID) async {
        guard var partition = partitions[taskID] else { return }
        let chain = partition.listeners.removeValue(forKey: listenerID)
        partitions[taskID] = partition
        await chain?.finish()
        await cleanupPartitionIfPossible(taskID: taskID)
    }

    package func listenerCount(taskID: String) -> Int {
        partitions[taskID]?.listeners.count ?? 0
    }

    package func streamConsumerCount(taskID: String) -> Int {
        partitions[taskID]?.streamConsumers.count ?? 0
    }

    /// Deterministic observation used by concurrency tests to wait until
    /// `AsyncStream(unfolding:)` calls have actually suspended in their
    /// mailboxes. This stays package-scoped and does not affect consumer API.
    package func streamWaiterCount(taskID: String) -> Int {
        partitions[taskID]?.streamConsumers.values.reduce(into: 0) { count, consumer in
            count += consumer.mailbox.snapshot().waiterCount
        } ?? 0
    }

    package func stream(for taskID: String) async -> AsyncStream<Event> {
        await waitForClosedPartitionRetirement(taskID: taskID)
        let continuationID = UUID()
        let mailbox = StreamMailbox(clock: clock)
        let removalToken = StreamRemovalToken { [weak self, mailbox] in
            // `AsyncStream(unfolding:)` cannot forcibly unwind a producer that
            // is suspended in a checked continuation. End the mailbox first so
            // cancellation never depends on this actor still being alive or
            // available to process the bookkeeping hop below.
            mailbox.cancel()
            guard let self else { return }
            Task.detached { [self] in
                await self.removeContinuation(taskID: taskID, continuationID: continuationID)
            }
        }
        var partition = partition(for: taskID)
        partition.streamConsumers[continuationID] = StreamConsumerState(
            id: continuationID,
            mailbox: mailbox
        )
        partitions[taskID] = partition
        updateStreamMetricsReconciliationTaskState()
        return AsyncStream(
            unfolding: {
                _ = removalToken
                return await mailbox.next()
            },
            onCancel: {
                removalToken.remove()
            }
        )
    }

    /// A terminal publisher may have sealed a partition while its final
    /// event is still draining. New consumers must join the next partition,
    /// not the closed predecessor whose enqueue guard would discard replay.
    private func waitForClosedPartitionRetirement(taskID: String) async {
        while let partition = partitions[taskID], partition.isClosed {
            let barrier = retirementBarrier(taskID: taskID, partition: partition)
            await barrier.wait()
        }
    }

    package func publish(_ event: Event, for taskID: String) {
        enqueue(
            event,
            for: taskID,
            completion: nil,
            completionMode: .none,
            guaranteesAdmission: false
        )
    }

    /// Validates a producer epoch before admitting a nonterminal event.
    /// Validation suspends this actor, allowing an already-started terminal
    /// publisher to seal the partition first. Once validation succeeds, the
    /// enqueue happens in the same actor turn, so terminal ordering is total.
    @discardableResult
    package func publishIfCurrent(
        _ event: Event,
        for taskID: String,
        validate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        guard await validate() else { return false }
        guard partitions[taskID]?.isClosed != true else { return false }
        enqueue(
            event,
            for: taskID,
            completion: nil,
            completionMode: .none,
            guaranteesAdmission: false
        )
        return true
    }

    package func publishAndWaitForEnqueue(_ event: Event, for taskID: String) async {
        await withCheckedContinuation { continuation in
            enqueue(
                event,
                for: taskID,
                completion: DeliveryCompletion(continuation),
                completionMode: .listenerEnqueue,
                guaranteesAdmission: false
            )
        }
    }

    /// Admits the final terminal outcome even when `.dropNewest` queues are
    /// saturated, then waits until it has reached every currently registered
    /// consumer's queue. Delivery remains asynchronous under each consumer's
    /// policy. Earlier notifications in a multi-event terminal burst retain
    /// the configured bounded overflow behavior.
    package func publishTerminalAndWaitForEnqueue(_ event: Event, for taskID: String) async {
        await withCheckedContinuation { continuation in
            enqueue(
                event,
                for: taskID,
                completion: DeliveryCompletion(continuation),
                completionMode: .listenerEnqueue,
                guaranteesAdmission: true
            )
        }
    }

    /// Admits the final terminal outcome and atomically seals its partition.
    ///
    /// Sealing in the same actor turn prevents a late nonterminal publisher
    /// from displacing the guaranteed event in a `.dropOldest` listener queue
    /// or an `AsyncStream.bufferingNewest` buffer. Events already admitted
    /// ahead of the terminal outcome retain their configured overflow policy.
    package func publishTerminalAndFinish(_ event: Event, for taskID: String) async {
        await withCheckedContinuation { continuation in
            enqueue(
                event,
                for: taskID,
                completion: DeliveryCompletion(continuation),
                completionMode: .listenerEnqueue,
                guaranteesAdmission: true
            )
            if var partition = partitions[taskID] {
                partition.isClosed = true
                partitions[taskID] = partition
            }
        }
    }

    package func publishAndWaitForDelivery(_ event: Event, for taskID: String) async {
        await withCheckedContinuation { continuation in
            enqueue(
                event,
                for: taskID,
                completion: DeliveryCompletion(continuation),
                completionMode: .listenerDelivery,
                guaranteesAdmission: false
            )
        }
    }

    private func enqueue(
        _ event: Event,
        for taskID: String,
        completion: DeliveryCompletion?,
        completionMode: CompletionMode,
        guaranteesAdmission: Bool
    ) {
        var partition = partition(for: taskID)
        guard !partition.isClosed else {
            completion?.resume()
            return
        }
        if partition.queue.count >= policy.maxBufferedEventsPerPartition {
            partition.droppedEventCount += 1
            if guaranteesAdmission {
                partition.queue.popFirst()?.completion?.resume()
            } else {
                switch policy.overflowPolicy {
                case .dropOldest:
                    partition.queue.popFirst()?.completion?.resume()
                case .dropNewest:
                    partitions[taskID] = partition
                    reportPartitionMetric(for: taskID, partition: partition)
                    completion?.resume()
                    return
                }
            }
        }
        partition.queue.append(
            PendingEvent(
                event: event,
                enqueuedAt: clock.now(),
                listenerIDs: Array(partition.listeners.keys),
                streamConsumerIDs: Array(partition.streamConsumers.keys),
                completion: completion,
                completionMode: completionMode,
                guaranteesAdmission: guaranteesAdmission
            )
        )
        partitions[taskID] = partition
        reportPartitionMetric(for: taskID, partition: partition)
        startDrainIfNeeded(taskID: taskID)
    }

    package func finish(taskID: String) async {
        guard var partition = partitions[taskID] else { return }
        partition.isClosed = true
        partitions[taskID] = partition
        await cleanupPartitionIfPossible(taskID: taskID)
    }

    /// Closes a partition and waits until the hub has detached it.
    ///
    /// This stronger boundary is intended for task lifecycles that must retire
    /// their event partition before a successor can be registered. It waits
    /// for the partition-level queue to drain, but not for user listener
    /// handlers: their delivery chains retain the asynchronous semantics
    /// established by ``finish(taskID:)``.
    package func finishAndWaitForClosure(taskID: String) async {
        guard var partition = partitions[taskID] else { return }
        let retirementBarrier = retirementBarrier(taskID: taskID, partition: partition)
        partition.isClosed = true
        partitions[taskID] = partition
        await cleanupPartitionIfPossible(taskID: taskID)
        await retirementBarrier.wait()
    }

    private func removeContinuation(taskID: String, continuationID: UUID) async {
        guard var partition = partitions[taskID] else { return }
        let removedConsumer = removeStreamConsumer(
            continuationID: continuationID,
            from: &partition
        )
        partitions[taskID] = partition
        if let removedConsumer {
            removedConsumer.mailbox.cancel()
            await reportStreamConsumerRemoval(for: taskID, consumer: removedConsumer)
            updateStreamMetricsReconciliationTaskState()
        }
        await cleanupPartitionIfPossible(taskID: taskID)
    }

    private func startDrainIfNeeded(taskID: String) {
        guard var partition = partitions[taskID], !partition.isDraining else { return }
        partition.isDraining = true
        partitions[taskID] = partition
        Task.detached { [self] in
            await drain(taskID: taskID)
        }
    }

    private func drain(taskID: String) async {
        while let pendingEvent = popNextEvent(taskID: taskID) {
            guard var partition = partitions[taskID] else {
                pendingEvent.completion?.resume()
                break
            }
            var removedConsumers: [StreamConsumerState] = []

            for consumerID in pendingEvent.streamConsumerIDs {
                guard let streamConsumer = partition.streamConsumers[consumerID] else {
                    continue
                }
                let result = streamConsumer.mailbox.enqueue(
                    pendingEvent.event,
                    enqueuedAt: pendingEvent.enqueuedAt,
                    maxBufferedEvents: policy.maxBufferedEventsPerConsumer,
                    overflowPolicy: policy.overflowPolicy,
                    guaranteesAdmission: pendingEvent.guaranteesAdmission
                )
                switch result {
                case .terminated:
                    if let removedConsumer = removeStreamConsumer(
                        continuationID: consumerID,
                        from: &partition
                    ) {
                        removedConsumers.append(removedConsumer)
                    }
                case .accepted, .dropped:
                    reportStreamConsumerMetric(for: taskID, consumer: streamConsumer)
                }
            }

            partitions[taskID] = partition
            if !removedConsumers.isEmpty {
                for removedConsumer in removedConsumers {
                    await reportStreamConsumerRemoval(for: taskID, consumer: removedConsumer)
                }
                updateStreamMetricsReconciliationTaskState()
            }
            let listeners = pendingEvent.listenerIDs.compactMap { partition.listeners[$0] }
            switch pendingEvent.completionMode {
            case .none:
                for listener in listeners {
                    if pendingEvent.guaranteesAdmission {
                        await listener.enqueueGuaranteed(
                            pendingEvent.event,
                            enqueuedAt: pendingEvent.enqueuedAt
                        )
                    } else {
                        await listener.enqueue(pendingEvent.event, enqueuedAt: pendingEvent.enqueuedAt)
                    }
                }
            case .listenerEnqueue:
                for listener in listeners {
                    if pendingEvent.guaranteesAdmission {
                        await listener.enqueueGuaranteed(
                            pendingEvent.event,
                            enqueuedAt: pendingEvent.enqueuedAt
                        )
                    } else {
                        await listener.enqueue(pendingEvent.event, enqueuedAt: pendingEvent.enqueuedAt)
                    }
                }
                pendingEvent.completion?.resume()
            case .listenerDelivery:
                await deliverAndWait(
                    event: pendingEvent.event,
                    enqueuedAt: pendingEvent.enqueuedAt,
                    to: listeners
                )
                pendingEvent.completion?.resume()
            }
        }

        guard var partition = partitions[taskID] else { return }
        partition.isDraining = false
        partitions[taskID] = partition

        if !partition.queue.isEmpty {
            startDrainIfNeeded(taskID: taskID)
            return
        }

        await cleanupPartitionIfPossible(taskID: taskID)
    }

    private func deliverAndWait(
        event: Event,
        enqueuedAt: Date,
        to listeners: [EventDeliveryChain<Event>]
    ) async {
        guard !listeners.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for listener in listeners {
                group.addTask {
                    await listener.enqueueAndWaitForDelivery(event, enqueuedAt: enqueuedAt)
                }
            }

            await group.waitForAll()
        }
    }

    private func popNextEvent(taskID: String) -> PendingEvent? {
        guard var partition = partitions[taskID] else { return nil }
        let event = partition.queue.popFirst()
        partitions[taskID] = partition
        reportPartitionMetric(for: taskID, partition: partition)
        return event
    }

    private func cleanupPartitionIfPossible(taskID: String) async {
        guard let partition = partitions[taskID] else { return }
        guard partition.isClosed, !partition.isDraining, partition.queue.isEmpty else { return }

        let key = PartitionKey(taskID: taskID, generation: partition.generation)
        let retirementBarrier = partitionRetirementBarriers[key]
        partitions.removeValue(forKey: taskID)
        await partitionRetirementHook?(taskID, partition.generation)

        for consumer in partition.streamConsumers.values {
            await reportStreamConsumerRemoval(for: taskID, consumer: consumer)
        }
        updateStreamMetricsReconciliationTaskState()

        for consumer in partition.streamConsumers.values {
            consumer.mailbox.finish()
        }

        for listener in partition.listeners.values {
            await listener.finish(deliverQueuedEvents: true)
        }

        retirementBarrier?.complete()
        partitionRetirementBarriers.removeValue(forKey: key)
    }

    private func partition(for taskID: String) -> PartitionState {
        partitions[taskID] ?? PartitionState()
    }

    private func retirementBarrier(
        taskID: String,
        partition: PartitionState
    ) -> PartitionRetirementBarrier {
        let key = PartitionKey(taskID: taskID, generation: partition.generation)
        if let barrier = partitionRetirementBarriers[key] {
            return barrier
        }
        let barrier = PartitionRetirementBarrier()
        partitionRetirementBarriers[key] = barrier
        return barrier
    }

    private func reportPartitionMetric(for taskID: String, partition: PartitionState) {
        metricsReporter?.report(
            .partitionState(
                EventPipelinePartitionStateMetric(
                    partitionID: taskID,
                    queueDepth: partition.queue.count,
                    droppedEventCount: partition.droppedEventCount,
                    oldestQueuedEventAge: partition.queue.first.map { clock.now().timeIntervalSince($0.enqueuedAt) }
                )
            )
        )
    }

    private func reportStreamConsumerMetric(for taskID: String, consumer: StreamConsumerState) {
        metricsReporter?.report(.consumerState(consumer.makeMetric(partitionID: taskID)))
    }

    private func reportStreamConsumerRemoval(for taskID: String, consumer: StreamConsumerState) async {
        if let metricsProxy {
            await metricsProxy.reportTerminalConsumerState(
                consumer.makeTerminalMetric(partitionID: taskID)
            )
        }
    }

    private func removeStreamConsumer(
        continuationID: UUID,
        from partition: inout PartitionState
    ) -> StreamConsumerState? {
        return partition.streamConsumers.removeValue(forKey: continuationID)
    }

    private func updateStreamMetricsReconciliationTaskState() {
        guard metricsReporter != nil, let metricsSnapshotInterval else {
            streamMetricsReconciliationTask?.cancel()
            streamMetricsReconciliationTask = nil
            return
        }

        guard hasActiveStreamConsumers else {
            streamMetricsReconciliationTask?.cancel()
            streamMetricsReconciliationTask = nil
            return
        }

        guard streamMetricsReconciliationTask == nil else { return }

        let clock = self.clock
        streamMetricsReconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: metricsSnapshotInterval)
                } catch {
                    return
                }

                guard let self else { return }
                await self.reconcileStreamConsumerMetrics()
            }
        }
    }

    private var hasActiveStreamConsumers: Bool {
        partitions.values.contains { !$0.streamConsumers.isEmpty }
    }

    private func reconcileStreamConsumerMetrics() {
        guard metricsReporter != nil, hasActiveStreamConsumers else {
            updateStreamMetricsReconciliationTaskState()
            return
        }

        for (taskID, partition) in partitions {
            for consumer in partition.streamConsumers.values {
                reportStreamConsumerMetric(for: taskID, consumer: consumer)
            }
        }
    }
}
