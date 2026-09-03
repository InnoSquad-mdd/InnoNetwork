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
                expectedBytes: expectedBytes
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

    func resume() {
        storage.withLock { $0.state = .running }
    }

    func cancel() {
        storage.withLock { $0.state = .canceling }
    }
}

final class StubUploadURLSession: UploadURLSession, @unchecked Sendable {
    private struct Storage {
        var tasks: [StubUploadURLTask]
        var nextIdentifier: Int
    }

    private let storage: OSAllocatedUnfairLock<Storage>
    private let channel: UploadDelegateEventChannel

    init(channel: UploadDelegateEventChannel, tasks: [StubUploadURLTask] = []) {
        self.channel = channel
        self.storage = OSAllocatedUnfairLock(
            initialState: Storage(tasks: tasks, nextIdentifier: (tasks.map(\.taskIdentifier).max() ?? 0) + 1)
        )
    }

    var latestTask: StubUploadURLTask? {
        storage.withLock { $0.tasks.last }
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
        storage.withLock { $0.tasks.map { $0 as any UploadURLTask } }
    }

    func invalidateAndCancel() {
        let tasks = storage.withLock { $0.tasks }
        tasks.forEach { $0.cancel() }
        channel.send(.invalidated)
    }
}

func makeUploadHarness(
    configuration: UploadConfiguration = .safeDefaults(),
    tasks: [StubUploadURLTask] = []
) -> (UploadManager, StubUploadURLSession, UploadDelegateEventChannel) {
    let channel = UploadDelegateEventChannel()
    let session = StubUploadURLSession(channel: channel, tasks: tasks)
    let manager = UploadManager(configuration: configuration, session: session, channel: channel)
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
