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
