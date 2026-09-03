import Foundation
import os

package protocol UploadURLTask: AnyObject, Sendable {
    var taskIdentifier: Int { get }
    var taskDescription: String? { get set }
    var originalRequest: URLRequest? { get }
    var currentRequest: URLRequest? { get }
    var response: URLResponse? { get }
    var state: URLSessionTask.State { get }
    var countOfBytesSent: Int64 { get }
    var countOfBytesExpectedToSend: Int64 { get }

    func resume()
    func cancel()
}

package protocol UploadURLSession: AnyObject, Sendable {
    func makeUploadTask(with request: URLRequest, fromFile fileURL: URL) -> any UploadURLTask
    func allUploadTasks() async -> [any UploadURLTask]
    func invalidateAndCancel()
}

extension URLSessionUploadTask: UploadURLTask {}

extension URLSession: UploadURLSession {
    package func makeUploadTask(with request: URLRequest, fromFile fileURL: URL) -> any UploadURLTask {
        uploadTask(with: request, fromFile: fileURL)
    }

    package func allUploadTasks() async -> [any UploadURLTask] {
        let gate = UploadTaskQueryGate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                getAllTasks { tasks in
                    gate.complete(tasks.compactMap { $0 as? URLSessionUploadTask })
                }
            }
        } onCancel: {
            gate.complete([])
        }
    }
}

private final class UploadTaskQueryGate: Sendable {
    private struct State {
        var continuation: CheckedContinuation<[any UploadURLTask], Never>?
        var result: [any UploadURLTask]?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(_ continuation: CheckedContinuation<[any UploadURLTask], Never>) {
        let result = state.withLock { state -> [any UploadURLTask]? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let result {
            continuation.resume(returning: result)
        }
    }

    func complete(_ result: [any UploadURLTask]) {
        let continuation = state.withLock { state -> CheckedContinuation<[any UploadURLTask], Never>? in
            guard state.result == nil else { return nil }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }
}
