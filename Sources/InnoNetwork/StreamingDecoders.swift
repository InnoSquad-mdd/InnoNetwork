import Foundation
import OSLog
import os

/// A dispatched Server-Sent Events data event.
///
/// Fields populate from `id:`, `event:`, and `data:` lines. Multiple
/// `data:` lines within one frame are joined with `\n`. The `retry:`
/// field carries the server-suggested reconnect delay in milliseconds
/// when present in the same block; consumers are free to honor or ignore it.
/// `id` inherits the most recent accepted ID within this response, including
/// an empty string after an explicit reset. Metadata-only blocks do not emit
/// outputs. This value is not a browser EventSource implementation.
public struct ServerSentEvent: Sendable, Equatable {
    public var id: String?
    public var event: String?
    public var data: String
    public var retry: Int?

    public init(
        id: String? = nil,
        event: String? = nil,
        data: String = "",
        retry: Int? = nil
    ) {
        self.id = id
        self.event = event
        self.data = data
        self.retry = retry
    }
}


/// Stateful decoder that turns a stream of UTF-8 lines into a stream of
/// ``ServerSentEvent`` values.
///
/// Wire one of these into a ``StreamingAPIDefinition`` to consume an SSE
/// endpoint:
///
/// ```swift
/// struct MyEventStream: StreamingAPIDefinition {
///     typealias Output = ServerSentEvent
///
///     var method: HTTPMethod { .get }
///     var path: String { "/events" }
///     var sessionAuthentication: SessionAuthentication { .anonymous }
///     var headers: HTTPHeaders {
///         HTTPHeaders([HTTPHeader(name: "Accept", value: "text/event-stream")])
///     }
///
///     func makeDecoder() -> @Sendable (String) throws -> ServerSentEvent? {
///         let decoder = ServerSentEventDecoder()
///         return { try decoder.decode(line: $0, maximumEventBytes: 1024 * 1024) }
///     }
/// }
/// ```
///
/// Create one decoder per response attempt with ``StreamingAPIDefinition/makeDecoder()``.
/// Its lock provides memory safety, not isolation between independent streams.
/// The nonthrowing overload remains unbounded for source compatibility; prefer
/// ``decode(line:maximumEventBytes:)`` for untrusted or long-lived streams.
public final class ServerSentEventDecoder: Sendable {
    private static let logger = Logger(subsystem: "innosquad.network", category: "Streaming")

    private struct State {
        var current = ServerSentEvent()
        var hasProcessedFirstLine = false
        var dataByteCount = 0
        var exceededLimit = false
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    public init() {}

    /// Discard all response state, including an incomplete event, inherited ID,
    /// BOM position, and a latched size error. Call only between responses.
    /// Concurrent streams must use separate instances instead of resetting a
    /// shared decoder while it is in use.
    public func reset() {
        state.withLock { $0 = State() }
    }

    /// Process one line (without trailing `\n`). Returns a fully-formed
    /// ``ServerSentEvent`` when a blank dispatch line completes the
    /// current frame, otherwise `nil`.
    ///
    /// - Parameter inputLine: One UTF-8 line from the SSE response stream.
    /// - Returns: A dispatched event, or `nil` while still aggregating
    ///   the current frame.
    public func decode(line inputLine: String) -> ServerSentEvent? {
        try? process(line: inputLine, maximumEventBytes: nil)
    }

    /// Decode with a positive UTF-8 byte cap on retained data and ID/event
    /// metadata. Data-line separators count toward the cap; comments and
    /// ignored fields do not. The transport's separate line cap still applies.
    ///
    /// Exceeding the cap releases buffered data and throws `DecodingError` with
    /// no payload in its diagnostic. Failure stays latched until ``reset()``;
    /// callers must terminate the current response rather than skip the error.
    public func decode(line: String, maximumEventBytes: Int) throws -> ServerSentEvent? {
        guard maximumEventBytes > 0 else {
            throw Self.limitError("SSE event byte limit must be positive.")
        }
        return try process(line: line, maximumEventBytes: maximumEventBytes)
    }

    private static func limitError(_ message: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: message))
    }

    private func process(line inputLine: String, maximumEventBytes: Int?) throws -> ServerSentEvent? {
        try state.withLock { state in
            guard !state.exceededLimit else {
                throw Self.limitError("SSE event byte limit exceeded; reset required.")
            }
            func checkCapacity(adding bytes: Int, replacing replacedBytes: Int = 0) throws {
                guard let limit = maximumEventBytes else { return }
                let retained = state.dataByteCount
                    + (state.current.id?.utf8.count ?? 0)
                    + (state.current.event?.utf8.count ?? 0) - replacedBytes
                guard retained <= limit, bytes <= limit - retained else {
                    state.current = ServerSentEvent()
                    state.dataByteCount = 0
                    state.exceededLimit = true
                    throw Self.limitError("SSE event exceeded the configured \(limit)-byte limit.")
                }
            }
            try checkCapacity(adding: 0)
            let line: String
            if state.hasProcessedFirstLine {
                line = inputLine
            } else {
                state.hasProcessedFirstLine = true
                line = inputLine.hasPrefix("\u{FEFF}") ? String(inputLine.dropFirst()) : inputLine
            }

            // Blank line dispatches the current event.
            if line.isEmpty {
                let frame = state.current
                state.current = ServerSentEvent(id: frame.id)
                state.dataByteCount = 0
                if frame.data.isEmpty {
                    return nil
                }
                var dispatched = frame
                // SSE spec: strip a single trailing newline appended by
                // the data-line aggregator above, since that newline was
                // a separator, not user content.
                if dispatched.data.hasSuffix("\n") {
                    dispatched.data.removeLast()
                }
                return dispatched
            }

            // Lines starting with ":" are comments per spec.
            if line.hasPrefix(":") {
                return nil
            }

            let field: String
            let value: String
            if let colon = line.firstIndex(of: ":") {
                field = String(line[..<colon])
                var rest = line[line.index(after: colon)...]
                if rest.hasPrefix(" ") {
                    rest = rest.dropFirst()
                }
                value = String(rest)
            } else {
                field = line
                value = ""
            }

            switch field {
            case "id":
                // SSE id is echoed back to the server as `Last-Event-ID`
                // on resume. A server (or an upstream proxy) that
                // injected newlines or other control characters into the
                // id field could trigger header smuggling on the
                // reconnect — refuse to accept any id that contains
                // characters disallowed by the HTTP header grammar
                // (RFC 9110 §5.5 `field-value`). Bytes outside the
                // visible ASCII range, plus CR/LF and NUL, are dropped.
                if Self.isSanitizedSSEID(value) {
                    try checkCapacity(adding: value.utf8.count, replacing: state.current.id?.utf8.count ?? 0)
                    state.current.id = value
                }
            case "event":
                try checkCapacity(adding: value.utf8.count, replacing: state.current.event?.utf8.count ?? 0)
                state.current.event = value
            case "data":
                let addedBytes = value.utf8.count + 1
                try checkCapacity(adding: addedBytes)
                state.current.data.append(value)
                state.current.data.append("\n")
                state.dataByteCount += addedBytes
            case "retry":
                if value.allSatisfy(\.isASCIIDigit), let ms = Int(value) {
                    state.current.retry = ms
                }
            default:
                // Unknown fields are ignored per spec.
                break
            }
            return nil
        }
    }

    /// Validates an SSE `id` field's contents against the safe subset
    /// allowed inside the `Last-Event-ID` HTTP header on resume.
    ///
    /// Reject `\r`, `\n`, `\u{0000}`, and any byte outside the visible
    /// ASCII range (`0x20`–`0x7E`). The visible-ASCII bound is stricter
    /// than RFC 9110 §5.5 strictly requires — but it is the conservative
    /// subset every HTTP stack we ship against accepts, so we trade off
    /// permissiveness for guaranteed header transparency.
    static func isSanitizedSSEID(_ value: String) -> Bool {
        for scalar in value.unicodeScalars {
            let codePoint = scalar.value
            if codePoint < 0x20 || codePoint > 0x7E {
                logger.debug(
                    "Rejected SSE id for Last-Event-ID: invalid scalar U+\(String(codePoint, radix: 16), privacy: .public), length \(value.count, privacy: .public)"
                )
                return false
            }
        }
        return true
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        guard unicodeScalars.count == 1, let scalar = unicodeScalars.first else { return false }
        return scalar.value >= 0x30 && scalar.value <= 0x39
    }
}
