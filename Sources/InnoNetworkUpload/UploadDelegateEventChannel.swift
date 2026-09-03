import Foundation
import InnoNetwork

package enum UploadDelegateEvent: Sendable {
    case progress(taskIdentifier: Int, bytesSent: Int64, totalBytesSent: Int64, expected: Int64)
    case data(taskIdentifier: Int, data: Data)
    case completed(
        taskIdentifier: Int,
        taskDescription: String?,
        originalRequest: URLRequest?,
        currentRequest: URLRequest?,
        response: HTTPURLResponse?,
        error: SendableUnderlyingError?
    )
    case backgroundEventsFinished
    case invalidated
}

package final class UploadDelegateEventChannel: Sendable {
    package let stream: AsyncStream<UploadDelegateEvent>
    private let continuation: AsyncStream<UploadDelegateEvent>.Continuation

    package init() {
        let pair = AsyncStream.makeStream(
            of: UploadDelegateEvent.self,
            bufferingPolicy: .unbounded
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    package func send(_ event: UploadDelegateEvent) {
        continuation.yield(event)
    }

    package func finish() {
        continuation.finish()
    }
}
