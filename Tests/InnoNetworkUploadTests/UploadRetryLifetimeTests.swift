import Foundation
import InnoNetwork
import Testing

@testable import InnoNetworkUpload

private func uploadRetryFence(
    _ manager: UploadManager,
    _ channel: UploadDelegateEventChannel
) async {
    let signal = AsyncStream<Void>.makeStream()
    manager.handleBackgroundEvents { signal.continuation.yield() }
    channel.send(.backgroundEventsFinished)
    for await _ in signal.stream { break }
}

private func failUploadForRetry(
    _ operation: UploadOperation,
    _ systemTask: StubUploadURLTask,
    request: URLRequest,
    manager: UploadManager,
    channel: UploadDelegateEventChannel
) async {
    channel.send(
        .completed(
            taskIdentifier: systemTask.taskIdentifier,
            taskDescription: systemTask.taskDescription,
            originalRequest: request,
            currentRequest: request,
            response: nil,
            error: SendableUnderlyingError(URLError(.networkConnectionLost))
        )
    )
    for await event in operation.events {
        if case .failed = event { break }
    }
    await uploadRetryFence(manager, channel)
}

@Suite("Upload Retry Lifetime Tests", .serialized)
struct UploadRetryLifetimeTests {
    @Test("Retry preserves the exact case-sensitive HTTP method token")
    func retryPreservesExactMethodToken() async throws {
        let (manager, session, channel) = makeUploadHarness()
        let file = try makeTemporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var request = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        request.httpMethod = "CUSTOM"
        request.setValue("method-token", forHTTPHeaderField: "Idempotency-Key")

        let original = try await manager.upload(request, fromFile: file)
        await failUploadForRetry(
            original,
            try #require(session.latestTask),
            request: request,
            manager: manager,
            channel: channel
        )

        request.httpMethod = "custom"
        await #expect(throws: UploadError.self) {
            _ = try await manager.retry(original.task, with: request, fromFile: file)
        }
        #expect(session.taskCount == 1)
        #expect(await original.task.state == .failed)

        request.httpMethod = "CUSTOM"
        let retry = try await manager.retry(original.task, with: request, fromFile: file)
        #expect(session.taskCount == 2)
        await manager.cancel(retry.task)
        await manager.shutdown()
    }

    @Test("Terminal retention never evicts an active retry")
    func terminalRetentionPreservesActiveRetry() async throws {
        let limits = UploadResourcePolicy(
            maximumTrackedTasks: 4,
            maximumBufferedDelegateEvents: 16,
            maximumBufferedDelegateBytes: 1_024,
            maximumPendingUnknownTasks: 4,
            maximumRetainedTerminalTasks: 1
        )
        let (manager, session, channel) = makeUploadHarness(
            configuration: .advanced(resourcePolicy: limits)
        )
        let file = try makeTemporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var request = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        request.httpMethod = "POST"
        request.setValue("retry-lifetime", forHTTPHeaderField: "Idempotency-Key")

        let original = try await manager.upload(request, fromFile: file)
        await failUploadForRetry(
            original,
            try #require(session.latestTask),
            request: request,
            manager: manager,
            channel: channel
        )

        let retry = try await manager.retry(original.task, with: request, fromFile: file)
        let retrySystemTask = try #require(session.latestTask)
        let other = try await manager.upload(request, fromFile: file)
        await failUploadForRetry(
            other,
            try #require(session.latestTask),
            request: request,
            manager: manager,
            channel: channel
        )

        #expect(await manager.task(withId: retry.task.id) === retry.task)
        await manager.cancel(retry.task)
        #expect(retrySystemTask.cancelCount == 1)
        #expect(await retry.task.state == .cancelled)
        await manager.shutdown()
    }

    @Test("A pre-cancelled retry never creates another system upload")
    func preCancelledRetryDoesNotDispatch() async throws {
        let (manager, session, channel) = makeUploadHarness()
        let file = try makeTemporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var request = URLRequest(url: URL(string: "https://upload.example.test/files")!)
        request.httpMethod = "POST"
        request.setValue("retry-cancellation", forHTTPHeaderField: "Idempotency-Key")

        let original = try await manager.upload(request, fromFile: file)
        await failUploadForRetry(
            original,
            try #require(session.latestTask),
            request: request,
            manager: manager,
            channel: channel
        )

        let retryRequest = request
        let retry = Task { () -> UploadError? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await manager.retry(original.task, with: retryRequest, fromFile: file)
                return nil
            } catch {
                return error as? UploadError
            }
        }

        #expect(await retry.value == .cancelled)
        #expect(session.taskCount == 1)
        #expect(await original.task.state == .failed)
        await manager.shutdown()
    }
}
