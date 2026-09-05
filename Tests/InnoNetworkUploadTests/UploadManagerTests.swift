import Foundation
import InnoNetwork
import Testing
import os

@testable import InnoNetworkUpload

@Suite("Upload Manager Tests")
struct UploadManagerTests {
    @Test("Upload returns a pre-registered stream and a typed response receipt")
    func uploadCompletesWithTypedReceipt() async throws {
        let (manager, session, channel) = makeUploadHarness()
        let file = try makeTemporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var request = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        request.httpMethod = "PUT"

        let operation = try await manager.upload(request, fromFile: file)
        let systemTask = try #require(session.latestTask)
        let completion = Task { () throws -> UploadReceipt in
            for await event in operation.events {
                if case .completed(let receipt) = event { return receipt }
                if case .failed(let error) = event { throw error }
            }
            throw UploadError.invalidResponse
        }

        channel.send(
            .progress(
                taskIdentifier: systemTask.taskIdentifier,
                bytesSent: 11,
                totalBytesSent: 11,
                expected: 11
            )
        )
        channel.send(.data(taskIdentifier: systemTask.taskIdentifier, data: Data(#"{"id":"asset-1"}"#.utf8)))
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )
        channel.send(
            .completed(
                taskIdentifier: systemTask.taskIdentifier,
                taskDescription: systemTask.taskDescription,
                originalRequest: request,
                currentRequest: request,
                response: response,
                error: nil
            )
        )

        let receipt = try await completion.value
        let decoded = try receipt.decode(using: AnyResponseDecoder<UploadReply>.json(decoder: JSONDecoder()))
        #expect(decoded == UploadReply(id: "asset-1"))
        #expect(await operation.task.state == .completed)
        #expect(await operation.task.progress.fractionCompleted == 1)

        await manager.shutdown()
    }

    @Test("Background uploads reject redirect-sensitive headers")
    func backgroundRejectsSensitiveHeaders() async throws {
        let configuration = UploadConfiguration.background(sessionIdentifier: "test.background.upload")
        let (manager, session, _) = makeUploadHarness(configuration: configuration)
        let file = try makeTemporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var request = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        request.httpMethod = "POST"
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

        do {
            _ = try await manager.upload(request, fromFile: file)
            Issue.record("Expected background sensitive-header rejection")
        } catch {
            #expect(error == .sensitiveHeadersRequireForeground(["Authorization"]))
        }
        #expect(session.latestTask == nil)

        await manager.shutdown()
    }

    @Test("Background restoration reattaches the system task and progress snapshot")
    func restoresBackgroundTask() async {
        var request = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        request.httpMethod = "PATCH"
        let systemTask = StubUploadURLTask(
            taskIdentifier: 42,
            request: request,
            taskDescription: "logical-upload",
            state: .running,
            bytesSent: 25,
            expectedBytes: 100
        )
        let configuration = UploadConfiguration.background(sessionIdentifier: "test.restore.upload")
        let (manager, _, _) = makeUploadHarness(configuration: configuration, tasks: [systemTask])

        let restored = await manager.restoreTasks()

        #expect(restored.count == 1)
        #expect(restored.first?.id == "logical-upload")
        #expect(await restored.first?.state == .uploading)
        #expect(await restored.first?.progress.totalBytesSent == 25)

        await manager.shutdown()
    }

    @Test("A suspended restored upload resumes after admission succeeds")
    func resumesSuspendedRestoredTask() async throws {
        var request = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        request.httpMethod = "PUT"
        let systemTask = StubUploadURLTask(
            taskIdentifier: 43,
            request: request,
            taskDescription: "suspended-upload",
            state: .suspended,
            bytesSent: 12,
            expectedBytes: 100
        )
        let configuration = UploadConfiguration.background(sessionIdentifier: "test.suspended.upload")
        let (manager, _, _) = makeUploadHarness(configuration: configuration, tasks: [systemTask])

        let restored = await manager.restoreTasks()
        let task = try #require(restored.first)

        #expect(await task.state == .uploading)
        #expect(systemTask.state == .running)
        #expect(systemTask.resumeCount == 1)

        await manager.shutdown()
    }

    @Test("A user-paused background upload stays paused across restoration")
    func restoresDurablePausedIntent() async throws {
        var request = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        request.httpMethod = "PUT"
        let systemTask = StubUploadURLTask(
            taskIdentifier: 45,
            request: request,
            taskDescription: UploadTaskDescription.paused(id: "paused-upload"),
            state: .running,
            bytesSent: 12,
            expectedBytes: 100
        )
        let configuration = UploadConfiguration.background(sessionIdentifier: "test.paused.upload")
        let (manager, _, _) = makeUploadHarness(configuration: configuration, tasks: [systemTask])

        let restored = await manager.restoreTasks()
        let task = try #require(restored.first)

        #expect(task.id == "paused-upload")
        #expect(await task.state == .paused)
        #expect(systemTask.state == .suspended)
        #expect(systemTask.suspendCount == 1)
        #expect(systemTask.resumeCount == 0)
        #expect(UploadTaskDescription.decode(systemTask.taskDescription).intent == .paused)

        await manager.shutdown()
    }

    @Test("An invalid restored upload fails closed instead of resuming")
    func rejectsInvalidRestoredTask() async throws {
        var request = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        request.httpMethod = "POST"
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let systemTask = StubUploadURLTask(
            taskIdentifier: 44,
            request: request,
            taskDescription: "invalid-restored-upload",
            state: .suspended
        )
        let configuration = UploadConfiguration.background(sessionIdentifier: "test.invalid.restore")
        let (manager, _, _) = makeUploadHarness(configuration: configuration, tasks: [systemTask])

        let restored = await manager.restoreTasks()
        let task = try #require(restored.first)

        #expect(await task.state == .failed)
        #expect(await task.error == .sensitiveHeadersRequireForeground(["Authorization"]))
        #expect(systemTask.resumeCount == 0)
        #expect(systemTask.cancelCount == 1)

        await manager.shutdown()
    }

    @Test("A completed background callback is adopted even when getAllTasks is already empty")
    func adoptsCompletionOnlyBackgroundTask() async throws {
        let configuration = UploadConfiguration.background(sessionIdentifier: "test.completed.upload")
        let (manager, _, channel) = makeUploadHarness(configuration: configuration)
        var request = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        request.httpMethod = "POST"
        let response = try #require(
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
        )

        channel.send(.data(taskIdentifier: 77, data: Data(#"{"id":"restored"}"#.utf8)))
        channel.send(
            .completed(
                taskIdentifier: 77,
                taskDescription: "completed-upload",
                originalRequest: request,
                currentRequest: request,
                response: response,
                error: nil
            )
        )

        let restored = await waitForUploadTask(manager: manager, id: "completed-upload")
        let task = try #require(restored)
        #expect(await task.state == .completed)
        let receipt = try #require(await task.receipt)
        let decoded = try receipt.decode(using: AnyResponseDecoder<UploadReply>.json(decoder: JSONDecoder()))
        #expect(decoded == UploadReply(id: "restored"))

        await manager.shutdown()
    }

    @Test("Background completion is delivered when system events win the registration race")
    func backgroundCompletionHandshakeIsOrderIndependent() {
        let store = UploadBackgroundCompletionStore()
        let callCount = OSAllocatedUnfairLock<Int>(initialState: 0)

        #expect(store.markEventsFinished() == nil)
        let ready = store.set {
            callCount.withLock { $0 += 1 }
        }
        ready?()

        #expect(callCount.withLock { $0 } == 1)
    }

    @Test("Response buffering cancels the transport at the configured ceiling")
    func responseBufferLimitIsEnforced() async throws {
        let configuration = UploadConfiguration.advanced(maximumResponseBytes: 4)
        let (manager, session, channel) = makeUploadHarness(configuration: configuration)
        let file = try makeTemporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var request = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        request.httpMethod = "POST"
        let operation = try await manager.upload(request, fromFile: file)
        let systemTask = try #require(session.latestTask)
        let terminal = Task { () -> UploadError? in
            for await event in operation.events {
                if case .failed(let error) = event { return error }
            }
            return nil
        }

        channel.send(.data(taskIdentifier: systemTask.taskIdentifier, data: Data("12345".utf8)))
        channel.send(
            .completed(
                taskIdentifier: systemTask.taskIdentifier,
                taskDescription: systemTask.taskDescription,
                originalRequest: request,
                currentRequest: request,
                response: nil,
                error: SendableUnderlyingError(URLError(.cancelled))
            )
        )

        #expect(await terminal.value == .responseTooLarge(limit: 4))
        #expect(systemTask.state == .canceling)
        #expect(await operation.task.state == .failed)

        await manager.shutdown()
    }

    @Test("Cancelling an upload publishes one terminal failure")
    func cancelPublishesOneTerminalEvent() async throws {
        let (manager, session, _) = makeUploadHarness()
        let file = try makeTemporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var request = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        request.httpMethod = "POST"
        let operation = try await manager.upload(request, fromFile: file)
        let systemTask = try #require(session.latestTask)
        let terminalFailures = Task { () -> [UploadError] in
            var failures: [UploadError] = []
            for await event in operation.events {
                if case .failed(let error) = event {
                    failures.append(error)
                }
            }
            return failures
        }

        await manager.cancel(operation.task)
        await manager.cancel(operation.task)

        #expect(await terminalFailures.value == [.cancelled])
        #expect(await operation.task.state == .cancelled)
        #expect(systemTask.cancelCount == 1)

        await manager.shutdown()
    }

    @Test("Pause and resume are idempotent and publish observable state")
    func pauseAndResumeAreIdempotent() async throws {
        let (manager, session, _) = makeUploadHarness()
        let file = try makeTemporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var request = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        request.httpMethod = "PUT"
        let operation = try await manager.upload(request, fromFile: file)
        let systemTask = try #require(session.latestTask)
        let stateEvents = Task { () -> [UploadState] in
            var states: [UploadState] = []
            for await event in operation.events {
                switch event {
                case .stateChanged(let state): states.append(state)
                case .failed, .completed: return states
                case .progress: continue
                }
            }
            return states
        }

        await manager.pause(operation.task)
        await manager.pause(operation.task)

        #expect(await operation.task.state == .paused)
        #expect(systemTask.state == .suspended)
        #expect(systemTask.suspendCount == 1)
        #expect(UploadTaskDescription.decode(systemTask.taskDescription).intent == .paused)

        await manager.resume(operation.task)
        await manager.resume(operation.task)

        #expect(await operation.task.state == .uploading)
        #expect(systemTask.state == .running)
        #expect(systemTask.resumeCount == 2)
        #expect(UploadTaskDescription.decode(systemTask.taskDescription).intent == .active)

        await manager.cancel(operation.task)
        #expect(await stateEvents.value == [.uploading, .paused, .uploading])

        await manager.shutdown()
    }

    @Test("Retry reuses the logical task with an explicit stable idempotency key")
    func retriesFailedUploadWithExplicitInputs() async throws {
        let (manager, session, channel) = makeUploadHarness()
        let file = try makeTemporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var request = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        request.httpMethod = "POST"
        request.setValue("asset-attempt-1", forHTTPHeaderField: "Idempotency-Key")
        let operation = try await manager.upload(request, fromFile: file)
        let firstSystemTask = try #require(session.latestTask)
        let firstFailure = Task { () -> UploadError? in
            for await event in operation.events {
                if case .failed(let error) = event { return error }
            }
            return nil
        }

        channel.send(
            .completed(
                taskIdentifier: firstSystemTask.taskIdentifier,
                taskDescription: firstSystemTask.taskDescription,
                originalRequest: request,
                currentRequest: request,
                response: nil,
                error: SendableUnderlyingError(URLError(.networkConnectionLost))
            )
        )
        let failure = await firstFailure.value
        guard case .network = failure else {
            Issue.record("Expected the first attempt to fail with a network error")
            await manager.shutdown()
            return
        }

        let retry = try await manager.retry(operation.task, with: request, fromFile: file)
        let secondSystemTask = try #require(session.latestTask)
        #expect(retry.task === operation.task)
        #expect(secondSystemTask.taskIdentifier != firstSystemTask.taskIdentifier)
        #expect(session.taskCount == 2)
        #expect(await retry.task.state == .uploading)
        #expect(UploadTaskDescription.decode(secondSystemTask.taskDescription).intent == .active)

        // Foundation may deliver buffered callbacks from the retired attempt
        // after the replacement task has started. They must not be adopted as
        // a second restored task or terminate the new attempt.
        channel.send(.data(taskIdentifier: firstSystemTask.taskIdentifier, data: Data("late".utf8)))
        channel.send(
            .completed(
                taskIdentifier: firstSystemTask.taskIdentifier,
                taskDescription: firstSystemTask.taskDescription,
                originalRequest: request,
                currentRequest: request,
                response: nil,
                error: SendableUnderlyingError(URLError(.cancelled))
            )
        )
        await Task.yield()
        #expect(await retry.task.state == .uploading)
        #expect(await manager.allTasks().count == 1)

        let retryCompletion = Task { () -> UploadReceipt? in
            for await event in retry.events {
                if case .completed(let receipt) = event { return receipt }
                if case .failed = event { return nil }
            }
            return nil
        }
        let response = try #require(
            HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)
        )
        channel.send(
            .completed(
                taskIdentifier: secondSystemTask.taskIdentifier,
                taskDescription: secondSystemTask.taskDescription,
                originalRequest: request,
                currentRequest: request,
                response: response,
                error: nil
            )
        )

        #expect(await retryCompletion.value?.response.statusCode == 201)
        #expect(await retry.task.state == .completed)

        await manager.shutdown()
    }

    @Test("Retry rejects failed uploads without a stable idempotency key")
    func retryRequiresStableIdempotencyKey() async throws {
        let (manager, session, channel) = makeUploadHarness()
        let file = try makeTemporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var request = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        request.httpMethod = "POST"
        let operation = try await manager.upload(request, fromFile: file)
        let systemTask = try #require(session.latestTask)
        let terminal = Task {
            for await event in operation.events {
                if case .failed = event { return }
            }
        }
        channel.send(
            .completed(
                taskIdentifier: systemTask.taskIdentifier,
                taskDescription: systemTask.taskDescription,
                originalRequest: request,
                currentRequest: request,
                response: nil,
                error: SendableUnderlyingError(URLError(.timedOut))
            )
        )
        await terminal.value

        await #expect(throws: UploadError.self) {
            _ = try await manager.retry(operation.task, with: request, fromFile: file)
        }
        #expect(session.taskCount == 1)
        #expect(await operation.task.state == .failed)

        await manager.shutdown()
    }

    @Test("Retry rejects a different idempotency key from the original attempt")
    func retryRequiresOriginalIdempotencyKey() async throws {
        let (manager, session, channel) = makeUploadHarness()
        let file = try makeTemporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var request = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        request.httpMethod = "POST"
        request.setValue("original-key", forHTTPHeaderField: "Idempotency-Key")
        let operation = try await manager.upload(request, fromFile: file)
        let systemTask = try #require(session.latestTask)
        let terminal = Task {
            for await event in operation.events {
                if case .failed = event { return }
            }
        }
        channel.send(
            .completed(
                taskIdentifier: systemTask.taskIdentifier,
                taskDescription: systemTask.taskDescription,
                originalRequest: request,
                currentRequest: request,
                response: nil,
                error: SendableUnderlyingError(URLError(.timedOut))
            )
        )
        await terminal.value

        request.setValue("replacement-key", forHTTPHeaderField: "Idempotency-Key")
        await #expect(throws: UploadError.self) {
            _ = try await manager.retry(operation.task, with: request, fromFile: file)
        }
        #expect(session.taskCount == 1)

        await manager.shutdown()
    }

    @Test("An unacceptable status retains the bounded response receipt")
    func unacceptableStatusRetainsReceipt() async throws {
        let (manager, session, channel) = makeUploadHarness()
        let file = try makeTemporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var request = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        request.httpMethod = "POST"
        let operation = try await manager.upload(request, fromFile: file)
        let systemTask = try #require(session.latestTask)
        let terminalFailure = Task { () -> UploadError? in
            for await event in operation.events {
                if case .failed(let error) = event { return error }
            }
            return nil
        }
        let response = try #require(
            HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)
        )

        channel.send(
            .completed(
                taskIdentifier: systemTask.taskIdentifier,
                taskDescription: systemTask.taskDescription,
                originalRequest: request,
                currentRequest: request,
                response: response,
                error: nil
            )
        )

        #expect(await terminalFailure.value == .unacceptableStatusCode(503))
        #expect(await operation.task.state == .failed)
        #expect(await operation.task.receipt?.response.statusCode == 503)

        await manager.shutdown()
    }

    @Test("Insecure upload URLs fail before a system task is created")
    func rejectsInsecureURL() async throws {
        let (manager, session, _) = makeUploadHarness()
        let file = try makeTemporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var request = URLRequest(url: URL(string: "http://upload.example.test/files")!)
        request.httpMethod = "POST"

        await #expect(throws: UploadError.self) {
            _ = try await manager.upload(request, fromFile: file)
        }
        #expect(session.latestTask == nil)

        await manager.shutdown()
    }

    @Test("GET and HEAD uploads fail before transport", arguments: ["GET", "HEAD"])
    func rejectsReadOnlyUploadMethods(_ method: String) async throws {
        let (manager, session, _) = makeUploadHarness()
        let file = try makeTemporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var request = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        request.httpMethod = method

        await #expect(throws: UploadError.self) {
            _ = try await manager.upload(request, fromFile: file)
        }
        #expect(session.latestTask == nil)

        await manager.shutdown()
    }

    @Test("An unreadable source file fails before transport")
    func rejectsUnreadableFile() async {
        let (manager, session, _) = makeUploadHarness()
        var request = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        request.httpMethod = "POST"
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("missing.bin")

        await #expect(throws: UploadError.self) {
            _ = try await manager.upload(request, fromFile: missing)
        }
        #expect(session.latestTask == nil)

        await manager.shutdown()
    }

    @Test("Concurrent starts reserve the tracked-task limit before actor reentry")
    func concurrentStartsHonorTrackedTaskLimit() async throws {
        let preparationGate = UploadRestorationTestGate()
        let startBarrier = UploadStartBarrier()
        let resourcePolicy = UploadResourcePolicy(
            maximumTrackedTasks: 1,
            maximumBufferedDelegateEvents: 8,
            maximumBufferedDelegateBytes: 1_024,
            maximumPendingUnknownTasks: 1
        )
        let (manager, session, _) = makeUploadHarness(
            configuration: .advanced(resourcePolicy: resourcePolicy),
            startPreparationHook: { _ in await preparationGate.wait() }
        )
        let file = try makeTemporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var mutableRequest = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        mutableRequest.httpMethod = "POST"
        let request = mutableRequest

        await withTaskGroup(of: UploadStartOutcome.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    await startBarrier.arrive(total: 100)
                    do {
                        _ = try await manager.upload(request, fromFile: file)
                        return .started
                    } catch let error as UploadError {
                        return .failed(error)
                    } catch {
                        Issue.record("Unexpected upload start error: \(error)")
                        return .unexpected
                    }
                }
            }

            await preparationGate.waitUntilEntered()
            for _ in 0..<99 {
                let outcome = await group.next()
                #expect(
                    outcome
                        == .failed(.resourceLimitExceeded(limit: 1))
                )
            }

            await preparationGate.open()
            #expect(await group.next() == .started)
        }

        #expect(session.taskCount == 1)
        #expect(await manager.allTasks().count == 1)
        await manager.shutdown()
    }

    @Test("Shutdown remains bounded when invalidation callback is missing")
    func shutdownTimesOutAndRemainsIdempotent() async {
        let (manager, session, _) = makeUploadHarness(
            emitsInvalidationEvent: false,
            invalidationTimeout: .milliseconds(20)
        )

        await manager.shutdown()
        await manager.shutdown()

        #expect(session.invalidationCallCount == 1)
    }

    @Test("A delayed restoration cannot register tasks after shutdown")
    func restorationDoesNotOutliveShutdown() async throws {
        let gate = UploadRestorationTestGate()
        var request = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        request.httpMethod = "POST"
        let restored = StubUploadURLTask(taskIdentifier: 42, request: request, taskDescription: "restored")
        let (manager, _, _) = makeUploadHarness(
            configuration: .background(sessionIdentifier: "test.shutdown.restore"),
            tasks: [restored], beforeListingTasks: { await gate.wait() }
        )
        let restoration = Task { await manager.restoreTasks() }
        await gate.waitUntilEntered()
        await manager.shutdown()
        await gate.open()

        #expect(await restoration.value.isEmpty)
        #expect(await manager.allTasks().isEmpty)
        #expect(restored.resumeCount == 0)
    }

    @Test("Upload waiting for background restoration cannot start after shutdown")
    func uploadWaitingForRestorationHonorsShutdown() async throws {
        let gate = UploadRestorationTestGate()
        let (manager, session, _) = makeUploadHarness(
            configuration: .background(sessionIdentifier: "test.shutdown.new-upload"),
            beforeListingTasks: { await gate.wait() }
        )
        let file = try makeTemporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var request = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        request.httpMethod = "POST"
        let upload = Task { try await manager.upload(request, fromFile: file) }
        await gate.waitUntilEntered()
        await manager.shutdown()
        await gate.open()

        do {
            _ = try await upload.value
            Issue.record("Expected managerShutdown instead of creating a post-shutdown task")
        } catch {
            #expect(error as? UploadError == .managerShutdown)
        }
        #expect(session.taskCount == 0)
        #expect(await manager.allTasks().isEmpty)
    }
}

private actor UploadRestorationTestGate {
    private var entered = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { arrivalWaiters.append($0) } }
    }

    func open() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor UploadStartBarrier {
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arrive(total: Int) async {
        arrivals += 1
        if arrivals == total {
            let waiting = waiters
            waiters.removeAll()
            for waiter in waiting { waiter.resume() }
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}

private enum UploadStartOutcome: Sendable, Equatable {
    case started
    case failed(UploadError)
    case unexpected
}

private struct UploadReply: Decodable, Sendable, Equatable {
    let id: String
}

private func waitForUploadTask(
    manager: UploadManager,
    id: String,
    timeout: Duration = .seconds(1)
) async -> UploadTask? {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if let task = await manager.task(withId: id) { return task }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await manager.task(withId: id)
}
