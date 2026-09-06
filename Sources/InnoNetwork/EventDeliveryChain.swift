import Foundation
import os

package actor EventDeliveryChain<Event: Sendable> {
    package typealias Handler = @Sendable (Event, Date) async -> Void

    private final class DeliveryCompletion: Sendable {
        private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = OSAllocatedUnfairLock(initialState: continuation)
        }

        func resume() {
            let continuation = continuation.withLock { state in
                let continuation = state
                state = nil
                return continuation
            }

            continuation?.resume()
        }
    }

    private struct QueuedEvent: Sendable {
        let event: Event
        let enqueuedAt: Date
        let deliveryCompletion: DeliveryCompletion?
    }

    private let handler: Handler
    private let partitionID: String
    private let consumerID: String
    private let policy: EventDeliveryPolicy
    private let metricsReporter: (any EventPipelineMetricsReporting)?
    private let clock: any InnoNetworkClock
    private var queue = FIFOBuffer<QueuedEvent>()
    private var drainTask: Task<Void, Never>?
    private var isClosed = false
    private var droppedEventCount = 0

    package init(
        partitionID: String,
        consumerID: String,
        policy: EventDeliveryPolicy,
        metricsReporter: (any EventPipelineMetricsReporting)?,
        clock: any InnoNetworkClock = SystemClock(),
        handler: @escaping Handler
    ) {
        self.partitionID = partitionID
        self.consumerID = consumerID
        self.policy = policy
        self.metricsReporter = metricsReporter
        self.clock = clock
        self.handler = handler
    }

    package func enqueue(_ event: Event, enqueuedAt: Date? = nil) {
        enqueue(
            event,
            enqueuedAt: enqueuedAt ?? clock.now(),
            deliveryCompletion: nil,
            guaranteesAdmission: false
        )
    }

    /// Enqueues the final terminal outcome even when a `.dropNewest` consumer
    /// queue is full. The oldest queued non-delivered event is displaced so
    /// the final terminal signal remains observable.
    package func enqueueGuaranteed(_ event: Event, enqueuedAt: Date? = nil) {
        enqueue(
            event,
            enqueuedAt: enqueuedAt ?? clock.now(),
            deliveryCompletion: nil,
            guaranteesAdmission: true
        )
    }

    package func enqueueAndWaitForDelivery(
        _ event: Event,
        enqueuedAt: Date? = nil
    ) async {
        await withCheckedContinuation { continuation in
            enqueue(
                event,
                enqueuedAt: enqueuedAt ?? clock.now(),
                deliveryCompletion: DeliveryCompletion(continuation),
                guaranteesAdmission: false
            )
        }
    }

    private func enqueue(
        _ event: Event,
        enqueuedAt: Date,
        deliveryCompletion: DeliveryCompletion?,
        guaranteesAdmission: Bool
    ) {
        guard !isClosed else {
            deliveryCompletion?.resume()
            return
        }
        if queue.count >= policy.maxBufferedEventsPerConsumer {
            droppedEventCount += 1
            if guaranteesAdmission {
                if let droppedEvent = queue.popFirst() {
                    droppedEvent.deliveryCompletion?.resume()
                }
            } else {
                switch policy.overflowPolicy {
                case .dropOldest:
                    if let droppedEvent = queue.popFirst() {
                        droppedEvent.deliveryCompletion?.resume()
                    }
                case .dropNewest:
                    reportQueueState()
                    deliveryCompletion?.resume()
                    return
                }
            }
        }

        queue.append(
            QueuedEvent(
                event: event,
                enqueuedAt: enqueuedAt,
                deliveryCompletion: deliveryCompletion
            )
        )
        reportQueueState()
        startDrainIfNeeded()
    }

    package func finish(deliverQueuedEvents: Bool = false) async {
        isClosed = true
        guard !deliverQueuedEvents else {
            if !queue.isEmpty {
                startDrainIfNeeded()
            }
            return
        }

        while let queuedEvent = queue.popFirst() {
            queuedEvent.deliveryCompletion?.resume()
        }
        // `finish()` can be called by the active handler while self-removing;
        // leave the drain task alive so in-flight delivery is not cancelled.
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task.detached { [self] in
            await drainLoop()
        }
    }

    private func drainLoop() async {
        while !Task.isCancelled {
            guard let queuedEvent = queue.popFirst() else { break }
            reportQueueState()
            await handler(queuedEvent.event, queuedEvent.enqueuedAt)
            reportDeliveryLatency(clock.now().timeIntervalSince(queuedEvent.enqueuedAt))
            queuedEvent.deliveryCompletion?.resume()
        }

        drainTask = nil
        if !isClosed && !queue.isEmpty {
            startDrainIfNeeded()
        }
    }

    private func reportQueueState() {
        metricsReporter?.report(
            .consumerState(
                EventPipelineConsumerStateMetric(
                    partitionID: partitionID,
                    consumerID: consumerID,
                    queueDepth: queue.count,
                    droppedEventCount: droppedEventCount,
                    oldestQueuedEventAge: queue.first.map { clock.now().timeIntervalSince($0.enqueuedAt) }
                )
            )
        )
    }

    private func reportDeliveryLatency(_ latency: TimeInterval) {
        metricsReporter?.report(
            .consumerDeliveryLatency(
                EventPipelineConsumerDeliveryLatencyMetric(
                    partitionID: partitionID,
                    consumerID: consumerID,
                    latency: latency
                )
            )
        )
    }
}
