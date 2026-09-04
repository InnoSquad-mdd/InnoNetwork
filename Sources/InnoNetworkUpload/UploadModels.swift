import Foundation
import InnoNetwork

/// Lifecycle state for a managed file upload.
public enum UploadState: String, Sendable, Equatable {
    case waiting
    case uploading
    case paused
    case completed
    case failed
    case cancelled

    /// Whether the state ends the upload lifecycle.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case .waiting, .uploading, .paused:
            false
        }
    }
}

/// Byte progress reported by the upload transport.
public struct UploadProgress: Sendable, Equatable {
    public let bytesSent: Int64
    public let totalBytesSent: Int64
    public let totalBytesExpectedToSend: Int64

    public var fractionCompleted: Double {
        guard totalBytesExpectedToSend > 0 else { return 0 }
        return min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }

    public static let zero = UploadProgress(
        bytesSent: 0,
        totalBytesSent: 0,
        totalBytesExpectedToSend: 0
    )

    package init(bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        self.bytesSent = bytesSent
        self.totalBytesSent = totalBytesSent
        self.totalBytesExpectedToSend = totalBytesExpectedToSend
    }
}

/// A bounded HTTP response captured after an upload finishes.
public struct UploadReceipt: Sendable {
    /// Core response metadata and bounded body bytes. The request is omitted
    /// so authorization headers are not retained in the receipt.
    public let response: Response

    package init(response: Response) {
        self.response = response
    }

    /// Decodes the response with a core InnoNetwork response decoder.
    public func decode<Output: Sendable>(
        using decoder: AnyResponseDecoder<Output>
    ) throws -> Output {
        try decoder.decode(data: response.data, response: response)
    }
}

/// Failures produced by the managed upload lifecycle.
public enum UploadError: Error, Sendable, Equatable {
    case invalidRequest(String)
    case unreadableFile
    case sensitiveHeadersRequireForeground([String])
    case duplicateSessionIdentifier(String)
    case responseTooLarge(limit: Int)
    case invalidResponse
    case unacceptableStatusCode(Int)
    case network(SendableUnderlyingError)
    case cancelled
    case managerShutdown
}

extension UploadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason):
            "Invalid upload request: \(reason)"
        case .unreadableFile:
            "The upload source must be a readable regular file"
        case .sensitiveHeadersRequireForeground(let headers):
            "Background upload cannot carry redirect-sensitive headers: \(headers.joined(separator: ", "))"
        case .duplicateSessionIdentifier(let identifier):
            "Another upload manager already owns background session \(identifier)"
        case .responseTooLarge(let limit):
            "Upload response exceeded the \(limit)-byte buffer limit"
        case .invalidResponse:
            "The upload did not return an HTTP response"
        case .unacceptableStatusCode(let statusCode):
            "Upload returned unacceptable HTTP status \(statusCode)"
        case .network(let error):
            "Upload failed: \(error.message)"
        case .cancelled:
            "Upload was cancelled"
        case .managerShutdown:
            "Upload manager is shut down"
        }
    }
}

/// An event emitted by a managed upload.
public enum UploadEvent: Sendable {
    case stateChanged(UploadState)
    case progress(UploadProgress)
    case completed(UploadReceipt)
    case failed(UploadError)
}

/// The task and pre-registered event stream created for an upload.
public struct UploadOperation: Sendable {
    public let task: UploadTask
    public let events: AsyncStream<UploadEvent>

    package init(task: UploadTask, events: AsyncStream<UploadEvent>) {
        self.task = task
        self.events = events
    }
}

/// Actor-isolated observable state for one logical file upload.
public actor UploadTask: Identifiable {
    public nonisolated let id: String
    public nonisolated let requestURL: URL
    public nonisolated let method: String

    private var currentState: UploadState
    private var currentProgress: UploadProgress
    private var currentReceipt: UploadReceipt?
    private var currentError: UploadError?

    package init(
        id: String = UUID().uuidString,
        requestURL: URL,
        method: String,
        state: UploadState = .waiting,
        progress: UploadProgress = .zero
    ) {
        self.id = id
        self.requestURL = requestURL
        self.method = method
        self.currentState = state
        self.currentProgress = progress
    }

    public var state: UploadState { currentState }
    public var progress: UploadProgress { currentProgress }
    public var receipt: UploadReceipt? { currentReceipt }
    public var error: UploadError? { currentError }

    package func begin() {
        guard !currentState.isTerminal else { return }
        currentState = .uploading
    }

    package func pause() {
        guard currentState == .waiting || currentState == .uploading else { return }
        currentState = .paused
    }

    package func update(progress: UploadProgress) {
        guard !currentState.isTerminal else { return }
        currentProgress = progress
        if currentState != .paused {
            currentState = .uploading
        }
    }

    package func prepareForRetry() -> Bool {
        guard currentState == .failed else { return false }
        currentState = .waiting
        currentProgress = .zero
        currentReceipt = nil
        currentError = nil
        return true
    }

    package func complete(with receipt: UploadReceipt) {
        guard !currentState.isTerminal else { return }
        currentReceipt = receipt
        currentError = nil
        currentState = .completed
    }

    package func fail(with error: UploadError, receipt: UploadReceipt? = nil) {
        guard !currentState.isTerminal else { return }
        currentReceipt = receipt
        currentError = error
        currentState = error == .cancelled ? .cancelled : .failed
    }

    package func terminalEvent() -> UploadEvent? {
        switch currentState {
        case .completed:
            currentReceipt.map(UploadEvent.completed)
        case .failed, .cancelled:
            currentError.map(UploadEvent.failed)
        case .waiting, .uploading, .paused:
            nil
        }
    }
}
