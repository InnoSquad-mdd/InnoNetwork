import Foundation
import InnoNetwork
import os

package final class UploadBackgroundCompletionStore: Sendable {
    private struct State {
        var callback: (@Sendable () -> Void)?
        var eventsFinished = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    package func set(_ value: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)? {
        state.withLock { state in
            guard state.eventsFinished else {
                state.callback = value
                return nil
            }
            state.eventsFinished = false
            state.callback = nil
            return value
        }
    }

    package func markEventsFinished() -> (@Sendable () -> Void)? {
        state.withLock { state in
            guard let callback = state.callback else {
                state.eventsFinished = true
                return nil
            }
            state.callback = nil
            state.eventsFinished = false
            return callback
        }
    }
}

package final class UploadSessionDelegate: NSObject, URLSessionDataDelegate {
    private let channel: UploadDelegateEventChannel
    private let rejectedRedirects = OSAllocatedUnfairLock<Set<Int>>(initialState: [])

    package init(channel: UploadDelegateEventChannel) {
        self.channel = channel
        super.init()
    }

    package func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        channel.send(
            .progress(
                taskIdentifier: task.taskIdentifier,
                bytesSent: bytesSent,
                totalBytesSent: totalBytesSent,
                expected: totalBytesExpectedToSend
            )
        )
    }

    package func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        channel.send(.data(taskIdentifier: dataTask.taskIdentifier, data: data))
    }

    package func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let original = task.originalRequest ?? task.currentRequest
        guard let original,
            let admitted = DefaultRedirectPolicy().redirect(
                request: newRequest,
                response: response,
                originalRequest: original
            )
        else {
            rejectRedirect(task: task, target: newRequest, completionHandler: completionHandler)
            return
        }

        do {
            try NetworkURLAdmission.validate(admitted, policy: .http(allowsInsecure: false))
            completionHandler(admitted)
        } catch {
            rejectRedirect(task: task, target: admitted, completionHandler: completionHandler)
        }
    }

    package func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if rejectedRedirects.withLock({ $0.remove(task.taskIdentifier) != nil }) {
            return
        }
        channel.send(
            .completed(
                taskIdentifier: task.taskIdentifier,
                taskDescription: task.taskDescription,
                originalRequest: task.originalRequest,
                currentRequest: task.currentRequest,
                response: task.response as? HTTPURLResponse,
                error: error.map(SendableUnderlyingError.init)
            )
        )
    }

    package func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        channel.send(.backgroundEventsFinished)
    }

    package func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        channel.send(.invalidated)
    }

    private func rejectRedirect(
        task: URLSessionTask,
        target: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let firstRejection = rejectedRedirects.withLock { $0.insert(task.taskIdentifier).inserted }
        if firstRejection {
            channel.send(
                .completed(
                    taskIdentifier: task.taskIdentifier,
                    taskDescription: task.taskDescription,
                    originalRequest: task.originalRequest,
                    currentRequest: target,
                    response: nil,
                    error: SendableUnderlyingError(
                        domain: "InnoNetworkUpload.RedirectAdmission",
                        code: 1,
                        message: "Upload redirect was rejected by the HTTPS and origin policy"
                    )
                )
            )
        }
        completionHandler(nil)
        task.cancel()
    }
}
