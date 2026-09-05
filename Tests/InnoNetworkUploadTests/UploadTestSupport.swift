import Foundation
import InnoNetwork
import os

@testable import InnoNetworkUpload

final class StubUploadURLTask: UploadURLTask, @unchecked Sendable {
    private struct Storage {
        var taskDescription: String?
        var response: URLResponse?
        var state: URLSessionTask.State
        var bytesSent: Int64
        var expectedBytes: Int64
        var resumeCount: Int
        var suspendCount: Int
        var cancelCount: Int
    }

    let taskIdentifier: Int
    let originalRequest: URLRequest?
    let currentRequest: URLRequest?
    private let storage: OSAllocatedUnfairLock<Storage>

    init(
        taskIdentifier: Int,
        request: URLRequest,
        taskDescription: String? = nil,
        state: URLSessionTask.State = .suspended,
        bytesSent: Int64 = 0,
        expectedBytes: Int64 = NSURLSessionTransferSizeUnknown,
        response: URLResponse? = nil
    ) {
        self.taskIdentifier = taskIdentifier
        self.originalRequest = request
        self.currentRequest = request
        self.storage = OSAllocatedUnfairLock(
            initialState: Storage(
                taskDescription: taskDescription,
                response: response,
                state: state,
                bytesSent: bytesSent,
                expectedBytes: expectedBytes,
                resumeCount: 0,
                suspendCount: 0,
                cancelCount: 0
            )
        )
    }

    var taskDescription: String? {
        get { storage.withLock { $0.taskDescription } }
        set { storage.withLock { $0.taskDescription = newValue } }
    }

    var response: URLResponse? { storage.withLock { $0.response } }
    var state: URLSessionTask.State { storage.withLock { $0.state } }
    var countOfBytesSent: Int64 { storage.withLock { $0.bytesSent } }
    var countOfBytesExpectedToSend: Int64 { storage.withLock { $0.expectedBytes } }
    var resumeCount: Int { storage.withLock { $0.resumeCount } }
    var suspendCount: Int { storage.withLock { $0.suspendCount } }
    var cancelCount: Int { storage.withLock { $0.cancelCount } }

    func resume() {
        storage.withLock {
            $0.resumeCount += 1
            $0.state = .running
        }
    }

    func suspend() {
        storage.withLock {
            $0.suspendCount += 1
            $0.state = .suspended
        }
    }

    func cancel() {
        storage.withLock {
            $0.cancelCount += 1
            $0.state = .canceling
        }
    }
}

final class StubUploadURLSession: UploadURLSession, @unchecked Sendable {
    private struct Storage {
        var tasks: [StubUploadURLTask]
        var nextIdentifier: Int
        var invalidationCallCount: Int
    }

    private let storage: OSAllocatedUnfairLock<Storage>
    private let channel: UploadDelegateEventChannel
    private let emitsInvalidationEvent: Bool
    private let beforeListingTasks: (@Sendable () async -> Void)?

    init(
        channel: UploadDelegateEventChannel,
        tasks: [StubUploadURLTask] = [],
        emitsInvalidationEvent: Bool = true,
        beforeListingTasks: (@Sendable () async -> Void)? = nil
    ) {
        self.channel = channel
        self.emitsInvalidationEvent = emitsInvalidationEvent
        self.beforeListingTasks = beforeListingTasks
        self.storage = OSAllocatedUnfairLock(
            initialState: Storage(
                tasks: tasks,
                nextIdentifier: (tasks.map(\.taskIdentifier).max() ?? 0) + 1,
                invalidationCallCount: 0
            )
        )
    }

    var latestTask: StubUploadURLTask? {
        storage.withLock { $0.tasks.last }
    }

    var taskCount: Int {
        storage.withLock { $0.tasks.count }
    }

    var invalidationCallCount: Int {
        storage.withLock { $0.invalidationCallCount }
    }

    func makeUploadTask(with request: URLRequest, fromFile fileURL: URL) -> any UploadURLTask {
        storage.withLock { storage in
            let task = StubUploadURLTask(taskIdentifier: storage.nextIdentifier, request: request)
            storage.nextIdentifier += 1
            storage.tasks.append(task)
            return task
        }
    }

    func allUploadTasks() async -> [any UploadURLTask] {
        await beforeListingTasks?()
        return storage.withLock { $0.tasks.map { $0 as any UploadURLTask } }
    }

    func invalidateAndCancel() {
        let tasks = storage.withLock { storage in
            storage.invalidationCallCount += 1
            return storage.tasks
        }
        tasks.forEach { $0.cancel() }
        if emitsInvalidationEvent {
            channel.send(.invalidated)
        }
    }
}

func makeUploadHarness(
    configuration: UploadConfiguration = .safeDefaults(),
    tasks: [StubUploadURLTask] = [],
    emitsInvalidationEvent: Bool = true,
    invalidationTimeout: Duration = .seconds(5),
    beforeListingTasks: (@Sendable () async -> Void)? = nil,
    startPreparationHook: (@Sendable (String) async -> Void)? = nil
) -> (UploadManager, StubUploadURLSession, UploadDelegateEventChannel) {
    let channel = UploadDelegateEventChannel()
    let session = StubUploadURLSession(
        channel: channel,
        tasks: tasks,
        emitsInvalidationEvent: emitsInvalidationEvent,
        beforeListingTasks: beforeListingTasks
    )
    let manager = UploadManager(
        configuration: configuration,
        session: session,
        channel: channel,
        invalidationTimeout: invalidationTimeout,
        startPreparationHook: startPreparationHook
    )
    return (manager, session, channel)
}

func makeTemporaryUploadFile() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("payload.bin")
    try Data("upload-body".utf8).write(to: file, options: .atomic)
    return file
}
