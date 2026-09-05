import Darwin
import Foundation
import Testing

@testable import InnoNetwork

extension EventHubTests {
    @Test("TaskEventHub preserves per-task order")
    func taskEventHubPreservesPerTaskOrder() async throws {
        let hub = TaskEventHub<Int>()
        let store = EventHubIntEventStore()

        _ = await hub.addListener(taskID: "task-a") { value in
            await store.append(value)
        }

        await hub.publish(1, for: "task-a")
        await hub.publish(2, for: "task-a")
        await hub.publish(3, for: "task-a")

        let values = try await eventHubWaitForValues(store: store, expectedCount: 3)
        #expect(values == [1, 2, 3])
    }

    @Test("TaskEventHub isolates slow listeners across tasks")
    func taskEventHubIsolatesSlowListenersAcrossTasks() async throws {
        let hub = TaskEventHub<Int>()
        let slowStore = EventHubIntEventStore()
        let fastStore = EventHubIntEventStore()

        _ = await hub.addListener(taskID: "slow") { value in
            try? await Task.sleep(for: .milliseconds(250))
            await slowStore.append(value)
        }

        _ = await hub.addListener(taskID: "fast") { value in
            await fastStore.append(value)
        }

        await hub.publish(1, for: "slow")
        await hub.publish(2, for: "fast")

        let fastValues = try await eventHubWaitForValues(store: fastStore, expectedCount: 1)
        #expect(fastValues == [2])
    }

    @Test("TaskEventHub publishAndWaitForDelivery waits for listener completion")
    func taskEventHubPublishAndWaitForDeliveryWaitsForListenerCompletion() async {
        let hub = TaskEventHub<Int>()
        let gate = EventHubDeliveryGate()

        _ = await hub.addListener(taskID: "wait") { _ in
            await gate.markStarted()
            await gate.waitForRelease()
        }

        let publishTask = Task {
            await hub.publishAndWaitForDelivery(1, for: "wait")
            await gate.markReturned()
        }

        await gate.waitUntilStarted()
        #expect(await gate.hasReturned() == false)

        await gate.release()
        _ = await publishTask.result
        #expect(await gate.hasReturned())
    }

    @Test("TaskEventHub publishAndWaitForEnqueue does not wait for listener completion")
    func taskEventHubPublishAndWaitForEnqueueDoesNotWaitForListenerCompletion() async {
        let hub = TaskEventHub<Int>()
        let gate = EventHubDeliveryGate()

        _ = await hub.addListener(taskID: "enqueue") { _ in
            await gate.markStarted()
            await gate.waitForRelease()
        }

        await hub.publishAndWaitForEnqueue(1, for: "enqueue")

        await gate.waitUntilStarted()
        #expect(await gate.hasReturned() == false)

        await gate.release()
    }

    @Test("TaskEventHub publishAndWaitForEnqueue is not blocked by older listener deliveries")
    func taskEventHubPublishAndWaitForEnqueueIgnoresOlderBlockedListenerDelivery() async throws {
        let hub = TaskEventHub<Int>()
        let gate = EventHubDeliveryGate()
        let store = EventHubIntEventStore()

        _ = await hub.addListener(taskID: "enqueue-backlog") { value in
            if value == 0 {
                await gate.markStarted()
                await gate.waitForRelease()
            }
            await store.append(value)
        }

        await hub.publish(0, for: "enqueue-backlog")
        await gate.waitUntilStarted()

        let publishTask = Task {
            await hub.publishAndWaitForEnqueue(1, for: "enqueue-backlog")
            await gate.markReturned()
        }

        let returned = await eventHubWaitForCondition(timeout: 1.0) {
            await gate.hasReturned()
        }
        #expect(returned)

        await gate.release()
        _ = await publishTask.result
        let values = try await eventHubWaitForValues(store: store, expectedCount: 2)
        #expect(values == [0, 1])
    }

    @Test("TaskEventHub snapshots listeners when an event is enqueued")
    func taskEventHubDoesNotDeliverQueuedEventsToLaterListeners() async throws {
        let hub = TaskEventHub<Int>()
        let gate = EventHubDeliveryGate()
        let firstStore = EventHubIntEventStore()
        let secondStore = EventHubIntEventStore()

        _ = await hub.addListener(taskID: "snapshot") { value in
            await firstStore.append(value)
            if value == 0 {
                await gate.markStarted()
                await gate.waitForRelease()
            }
        }

        let blockingPublish = Task {
            await hub.publishAndWaitForDelivery(0, for: "snapshot")
        }
        await gate.waitUntilStarted()

        await hub.publish(1, for: "snapshot")
        _ = await hub.addListener(taskID: "snapshot") { value in
            await secondStore.append(value)
        }

        await gate.release()
        _ = await blockingPublish.result

        let firstValues = try await eventHubWaitForValues(store: firstStore, expectedCount: 2)
        #expect(firstValues == [0, 1])
        try await Task.sleep(for: .milliseconds(50))
        #expect(await secondStore.snapshot().isEmpty)
    }

    @Test("TaskEventHub publishAndWaitForDelivery completes when finish races delivery")
    func taskEventHubPublishAndWaitForDeliveryCompletesWhenFinishRacesDelivery() async {
        let hub = TaskEventHub<Int>()
        let gate = EventHubDeliveryGate()

        _ = await hub.addListener(taskID: "finish-race") { _ in
            await gate.markStarted()
            await gate.waitForRelease()
        }

        let publishTask = Task {
            await hub.publishAndWaitForDelivery(1, for: "finish-race")
            await gate.markReturned()
        }

        await gate.waitUntilStarted()
        let finishTask = Task {
            await hub.finish(taskID: "finish-race")
        }

        await gate.release()
        _ = await publishTask.result
        _ = await finishTask.result

        #expect(await gate.hasReturned())
    }

    @Test("TaskEventHub publishAndWaitForDelivery completes when listener removes itself")
    func taskEventHubPublishAndWaitForDeliveryCompletesWhenListenerRemovesItself() async {
        let hub = TaskEventHub<Int>()
        let listenerIDBox = EventHubListenerIDBox()
        let gate = EventHubDeliveryGate()

        let listenerID = await hub.addListener(taskID: "self-remove") { _ in
            await gate.markStarted()
            if let listenerID = await listenerIDBox.value() {
                await hub.removeListener(taskID: "self-remove", listenerID: listenerID)
            }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                await gate.markCancelled()
                return
            }
            await gate.markContinuedAfterCancellationAwareAwait()
        }
        await listenerIDBox.set(listenerID)

        let publishTask = Task {
            await hub.publishAndWaitForDelivery(1, for: "self-remove")
            await gate.markReturned()
        }

        await gate.waitUntilStarted()
        let completed = await eventHubWaitForCondition(timeout: 1.0) {
            await gate.hasReturned()
        }
        #expect(completed)
        #expect(await gate.didContinueAfterCancellationAwareAwait())
        #expect(await gate.wasCancelled() == false)
        #expect(await hub.listenerCount(taskID: "self-remove") == 0)

        if completed {
            _ = await publishTask.result
        } else {
            publishTask.cancel()
        }
    }

    @Test("NetworkEventHub isolates slow observers across requests")
    func networkEventHubIsolatesSlowObserversAcrossRequests() async throws {
        let hub = NetworkEventHub()
        let fastRecorder = EventHubNetworkEventRecorder()
        let fastObserver = EventHubRecordingObserver(recorder: fastRecorder)
        let slowObserver = EventHubSlowObserver()

        let slowRequestID = UUID()
        let fastRequestID = UUID()

        await hub.publish(
            .requestStart(requestID: slowRequestID, method: "GET", url: "https://example.com/slow", retryIndex: 0),
            requestID: slowRequestID,
            observers: [slowObserver]
        )
        await hub.publish(
            .requestStart(requestID: fastRequestID, method: "GET", url: "https://example.com/fast", retryIndex: 0),
            requestID: fastRequestID,
            observers: [fastObserver]
        )

        let events = try await eventHubWaitForNetworkEvents(recorder: fastRecorder, expectedCount: 1)
        #expect(events.count == 1)
        #expect(eventHubRequestID(of: events[0]) == fastRequestID)

        await hub.finish(requestID: slowRequestID)
        await hub.finish(requestID: fastRequestID)
    }

    @Test("NetworkEventHub finish preserves events queued behind an active observer")
    func networkEventHubFinishPreservesQueuedObserverEvents() async throws {
        let hub = NetworkEventHub()
        let recorder = EventHubNetworkEventRecorder()
        let gate = EventHubDeliveryGate()
        let observer = EventHubFirstEventBlockingObserver(recorder: recorder, gate: gate)
        let requestID = UUID()

        await hub.publish(
            .requestStart(
                requestID: requestID,
                method: "GET",
                url: "https://example.com/queued-finish",
                retryIndex: 0
            ),
            requestID: requestID,
            observers: [observer]
        )
        await gate.waitUntilStarted()

        await hub.publish(
            .requestFailed(requestID: requestID, errorCode: -999, message: "cancelled"),
            requestID: requestID,
            observers: [observer]
        )

        let finishTask = Task {
            await hub.finish(requestID: requestID)
            await gate.markReturned()
        }
        let finishReturned = await eventHubWaitForCondition(timeout: 1.0) {
            await gate.hasReturned()
        }
        #expect(finishReturned)
        #expect(await recorder.snapshot().isEmpty)

        await gate.release()
        _ = await finishTask.result

        let events = try await eventHubWaitForNetworkEvents(recorder: recorder, expectedCount: 2)
        #expect(events.count == 2)
        #expect(events.map(eventHubRequestID(of:)) == [requestID, requestID])
        let isTerminalFailure: Bool
        if let lastEvent = events.last, case .requestFailed = lastEvent {
            isTerminalFailure = true
        } else {
            isTerminalFailure = false
        }
        #expect(isTerminalFailure)
    }

    @Test("NetworkEventHub admits and seals a terminal event when its partition is full")
    func networkEventHubGuaranteesTerminalPartitionAdmission() async throws {
        let gate = EventHubDeliveryGate()
        let policy = EventDeliveryPolicy(
            maxBufferedEventsPerPartition: 1,
            maxBufferedEventsPerConsumer: 1,
            overflowPolicy: .dropNewest
        )
        let hub = NetworkEventHub(
            policy: policy,
            testingDrainSuspension: { _ in
                await gate.markStarted()
                await gate.waitForRelease()
            }
        )
        let recorder = EventHubNetworkEventRecorder()
        let observer = EventHubRecordingObserver(recorder: recorder)
        let requestID = UUID()

        await hub.publish(
            .requestStart(requestID: requestID, method: "GET", url: "", retryIndex: 0),
            requestID: requestID,
            observers: [observer]
        )
        await gate.waitUntilStarted()
        await hub.publish(
            .requestFinished(requestID: requestID, statusCode: 200, byteCount: 0),
            requestID: requestID,
            observers: [observer]
        )
        await hub.publish(
            .responseReceived(requestID: requestID, statusCode: 201, byteCount: 1),
            requestID: requestID,
            observers: [observer]
        )

        let finish = Task { await hub.finish(requestID: requestID) }
        await gate.release()
        await finish.value

        let events = try await eventHubWaitForNetworkEvents(recorder: recorder, expectedCount: 1)
        #expect(events.count == 1)
        if case .requestFinished(let observedID, _, _)? = events.first {
            #expect(observedID == requestID)
        } else {
            Issue.record("Expected the saturated partition to retain its terminal event")
        }
    }

    @Test("A saturated observer queue cannot strand request span state")
    func terminalDeliveryClosesSpanUnderConsumerSaturation() async {
        let policy = EventDeliveryPolicy(
            maxBufferedEventsPerPartition: 8,
            maxBufferedEventsPerConsumer: 1,
            overflowPolicy: .dropNewest
        )
        let hub = NetworkEventHub(policy: policy)
        let collector = EventHubSpanCollector()
        let spanObserver = NetworkSpanObserver(exporter: collector)
        let gate = EventHubDeliveryGate()
        let observer = EventHubFirstEventBlockingSpanObserver(
            downstream: spanObserver,
            gate: gate
        )
        let requestID = UUID()

        await hub.publish(
            .requestStart(requestID: requestID, method: "GET", url: "", retryIndex: 0),
            requestID: requestID,
            observers: [observer]
        )
        await gate.waitUntilStarted()
        await hub.publish(
            .responseReceived(requestID: requestID, statusCode: 200, byteCount: 4),
            requestID: requestID,
            observers: [observer]
        )
        await hub.publish(
            .requestFinished(requestID: requestID, statusCode: 200, byteCount: 4),
            requestID: requestID,
            observers: [observer]
        )
        await hub.finish(requestID: requestID)
        await gate.release()

        let exported = await eventHubWaitForCondition(timeout: 1.0) {
            await collector.spans().contains {
                $0.requestID == requestID && $0.kind == .request
            }
        }
        #expect(exported)
        await spanObserver.flush()
        #expect(await collector.spans().count == 1)
    }

    @Test("NetworkEventHub keeps a closed tombstone across retirement reentrancy")
    func networkEventHubRetirementRejectsReentrantPublishAndJoinsFinish() async throws {
        let retirementGate = EventHubDeliveryGate()
        let firstFinishGate = EventHubDeliveryGate()
        let secondFinishGate = EventHubDeliveryGate()
        let recorder = EventHubNetworkEventRecorder()
        let requestID = UUID()
        let hub = NetworkEventHub { retiringRequestID in
            guard retiringRequestID == requestID else { return }
            await retirementGate.markStarted()
            await retirementGate.waitForRelease()
        }
        let observer = EventHubRecordingObserver(recorder: recorder)

        await hub.publish(
            .requestStart(
                requestID: requestID,
                method: "GET",
                url: "https://example.com/retirement-reentrancy",
                retryIndex: 0
            ),
            requestID: requestID,
            observers: [observer]
        )
        _ = try await eventHubWaitForNetworkEvents(recorder: recorder, expectedCount: 1)

        let firstFinish = Task {
            await hub.finish(requestID: requestID)
            await firstFinishGate.markReturned()
        }
        await retirementGate.waitUntilStarted()

        let retiringState = try #require(
            await hub._testingRetirementState(requestID: requestID)
        )
        #expect(retiringState.isClosed)
        #expect(retiringState.isRetiring)

        await hub.publish(
            .requestFinished(requestID: requestID, statusCode: 200, byteCount: 0),
            requestID: requestID,
            observers: [observer]
        )

        let secondFinish = Task {
            await secondFinishGate.markStarted()
            await hub.finish(requestID: requestID)
            await secondFinishGate.markReturned()
        }
        await secondFinishGate.waitUntilStarted()
        let secondFinishJoined = await eventHubWaitForCondition(timeout: 1.0) {
            await hub._testingRetirementState(requestID: requestID)?.closureWaiterCount == 1
        }
        #expect(secondFinishJoined)
        #expect(await firstFinishGate.hasReturned() == false)
        #expect(await secondFinishGate.hasReturned() == false)

        await retirementGate.release()
        _ = await firstFinish.result
        _ = await secondFinish.result

        #expect(await firstFinishGate.hasReturned())
        #expect(await secondFinishGate.hasReturned())
        #expect(await recorder.snapshot().count == 1)
        #expect(await hub._testingRetirementState(requestID: requestID) == nil)
    }

}
