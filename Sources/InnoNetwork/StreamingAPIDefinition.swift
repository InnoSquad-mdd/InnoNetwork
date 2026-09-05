import Foundation

/// Resume policy for a ``StreamingAPIDefinition``.
///
/// Mid-stream failures bypass the configured ``RetryPolicy`` because a partial
/// event prefix cannot be replayed transparently. Handshake failures can use
/// that retry policy before any outputs are delivered. This policy describes the
/// narrow alternative: re-establish the connection after a transport-level
/// disconnect, using the most recent non-empty event id observed by the
/// client as a `Last-Event-ID` HTTP header so the server can resume from the
/// right position. Designed for Server-Sent Events but applicable to any
/// id-bearing line stream.
///
/// Both resume policies accept only bounded printable-ASCII cursors, disable
/// automatic redirects, and resume only timeout/reachability failures. They
/// require server-supported replay semantics, not arbitrary request repetition.
public enum StreamingResumePolicy: Sendable, Equatable {
    /// Do not resume after a mid-stream transport disconnect. The error is
    /// surfaced to the consumer as-is. This is the default.
    case disabled

    /// Resume up to `maxAttempts` times after a mid-stream transport
    /// disconnect. Between attempts, the client waits `retryDelay` seconds
    /// before reconnecting and attaches `Last-Event-ID: <last-seen-id>` to
    /// the new request when the cursor is non-empty. The last-seen id comes
    /// from the consumer's ``StreamingAPIDefinition/eventID(from:)`` hook.
    ///
    /// Resume is only triggered when an event id has been observed at least
    /// once during the current attempt. An empty id is treated as an explicit
    /// cursor reset: it clears any prior id and reconnects without a
    /// `Last-Event-ID` header. A malformed id disables resume for that
    /// attempt.
    case lastEventID(maxAttempts: Int, retryDelay: TimeInterval = 1.0)

    /// EventSource-style reconnect behavior. In addition to transport failures,
    /// a clean EOF reconnects while attempts remain. `retry:` control fields may
    /// replace `retryDelay` for subsequent attempts.
    case serverSentEvents(
        maxAttempts: Int,
        retryDelay: TimeInterval = 1.0,
        reconnectOnEOF: Bool = true
    )

    /// Resume an application-defined line stream (for example NDJSON) using
    /// the cursor from ``StreamingAPIDefinition/eventID(from:)`` in `header`.
    /// The server must explicitly support cursor-based replay for this endpoint;
    /// opting in is not an exactly-once or durable acknowledgement guarantee.
    ///
    /// Header names must be ASCII HTTP tokens of at most 128 bytes and must not
    /// name authentication, cookie, framing, routing, or other reserved fields.
    /// Cursors accept at most 4,096 printable ASCII bytes. Empty cursors clear
    /// the header; any invalid cursor disables resume for the entire attempt.
    /// Like `lastEventID`, this policy rejects lossy buffers. Both policies
    /// disable automatic redirects to avoid forwarding a cursor to another URL.
    case cursor(header: String, maxAttempts: Int, retryDelay: TimeInterval = 1.0)

    /// Internal accessor used by the streaming executor.
    var maxAttempts: Int {
        switch self {
        case .disabled: return 0
        case .lastEventID(let maxAttempts, _): return max(0, maxAttempts)
        case .serverSentEvents(let maxAttempts, _, _): return max(0, maxAttempts)
        case .cursor(_, let maxAttempts, _): return max(0, maxAttempts)
        }
    }

    var retryDelay: TimeInterval {
        switch self {
        case .disabled: return 0
        case .lastEventID(_, let delay): return max(0, delay)
        case .serverSentEvents(_, let delay, _): return max(0, delay)
        case .cursor(_, _, let delay): return max(0, delay)
        }
    }

    package var headerName: String? {
        switch self {
        case .disabled: nil
        case .lastEventID, .serverSentEvents: "Last-Event-ID"
        case .cursor(let header, _, _): header
        }
    }

    package func validate() throws {
        let delay: TimeInterval
        switch self {
        case .disabled: return
        case .lastEventID(_, let value), .serverSentEvents(_, let value, _), .cursor(_, _, let value): delay = value
        }
        guard delay.isFinite else {
            throw NetworkError.configuration(reason: .invalidRequest("Streaming resume delay must be finite."))
        }
        guard let header = headerName,
            !header.isEmpty, header.utf8.count <= 128,
            header.utf8.allSatisfy({ byte in
                switch byte {
                case 0x30...0x39, 0x41...0x5A, 0x61...0x7A,
                    0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x5E, 0x5F, 0x60, 0x7C, 0x7E: true
                default: false
                }
            })
        else {
            throw NetworkError.configuration(reason: .invalidRequest("Invalid streaming cursor header name."))
        }
        let name = header.lowercased()
        let reserved: Set<String> = [
            "authorization", "cookie", "set-cookie", "host", "content-length", "content-type",
            "content-encoding", "transfer-encoding", "connection", "keep-alive", "te", "trailer",
            "upgrade", "expect", "accept", "accept-encoding", "range", "if-range", "if-match",
            "if-none-match", "if-modified-since", "if-unmodified-since", "cache-control", "pragma",
            "origin", "referer", "user-agent", "idempotency-key", "x-api-key", "traceparent", "tracestate",
        ]
        guard !reserved.contains(name), !name.hasPrefix("proxy-"), !name.hasPrefix("sec-") else {
            throw NetworkError.configuration(reason: .invalidRequest("Streaming cursor cannot use a reserved header."))
        }
    }
}

/// Output buffering policy for ``DefaultNetworkClient/stream(_:bufferingPolicy:)``.
///
/// The no-argument ``DefaultNetworkClient/stream(_:)`` path is lossless and
/// backpressured: it reads at most one decoded output ahead of the consumer.
/// This policy enum belongs to the explicit overload. Choose ``unbounded``
/// only when producer suspension is undesirable and growing memory is an
/// accepted risk, or choose a bounded policy when dropped outputs are valid.
public enum StreamingBufferingPolicy: Sendable, Equatable {
    /// Preserve every decoded output without slowing the producer. Memory can
    /// grow while the consumer is slower than the server.
    case unbounded
    /// Keep the newest `limit` outputs when the consumer falls behind.
    case bufferingNewest(Int)
    /// Keep the oldest `limit` outputs when the consumer falls behind.
    case bufferingOldest(Int)

    /// Whether the policy may drop already-produced outputs when the
    /// consumer falls behind. Only ``unbounded`` returns `false`; every
    /// other case is allowed to discard frames to enforce the limit.
    public var maySilentlyDropOutputs: Bool {
        switch self {
        case .unbounded:
            return false
        case .bufferingNewest, .bufferingOldest:
            return true
        }
    }
}

extension StreamingResumePolicy {
    package func isCompatible(with bufferingPolicy: StreamingBufferingPolicy) -> Bool {
        switch self {
        case .disabled:
            // The consumer has opted out of resume entirely, so a bounded
            // buffer cannot mask lost recovery state.
            return true
        case .lastEventID, .serverSentEvents, .cursor:
            // Last-Event-ID resume re-issues against the most recent id the
            // consumer has actually observed. A bounded buffer can drop a
            // not-yet-consumed frame that carried the next id, so the
            // server would replay over the gap — bounded + lastEventID is
            // unsafe.
            return !bufferingPolicy.maySilentlyDropOutputs
        }
    }
}

public extension StreamingResumePolicy {
    var reconnectsAfterEOF: Bool {
        if case .serverSentEvents(_, _, let reconnect) = self { return reconnect }
        return false
    }

    var permitsCursorlessReconnect: Bool {
        if case .serverSentEvents = self { return true }
        return false
    }
}

/// Cursor mutation carried by a protocol control frame.
public enum StreamingCursorUpdate: Sendable, Equatable {
    case unchanged
    case set(String)
    case clear
}

/// Protocol metadata that must be applied even when no application output is emitted.
public struct StreamingFrameControl: Sendable, Equatable {
    public var cursor: StreamingCursorUpdate
    public var retryDelay: TimeInterval?

    public init(cursor: StreamingCursorUpdate = .unchanged, retryDelay: TimeInterval? = nil) {
        self.cursor = cursor
        self.retryDelay = retryDelay
    }
}

/// A decoded application output plus independently actionable protocol metadata.
public struct StreamingDecodedFrame<Output: Sendable>: Sendable {
    public var output: Output?
    public var control: StreamingFrameControl

    public init(output: Output? = nil, control: StreamingFrameControl = .init()) {
        self.output = output
        self.control = control
    }
}


/// Describes a long-lived streaming endpoint executed by
/// ``DefaultNetworkClient/stream(_:)``.
///
/// Streaming endpoints differ from ``APIDefinition`` in two ways:
///
/// 1. The transport is line-delimited bytes (Server-Sent Events, NDJSON,
///    `chunked` log feeds) rather than a single buffered body.
/// 2. The ``RetryPolicy`` is intentionally bypassed for mid-stream failures because
///    retry semantics are application-specific — a partial event prefix
///    cannot be replayed transparently. Use ``resumePolicy`` for the
///    narrow cursor-based resume behavior; deeper reconnect logic
///    belongs in the consumer.
///
/// Each line yielded by the transport is passed to ``decode(line:)``.
/// Returning `nil` skips the line (useful for SSE comment lines, blank
/// keep-alives, or NDJSON heartbeat strings); throwing terminates the
/// stream and surfaces the error to the consumer.
public protocol StreamingAPIDefinition: Sendable {
    associatedtype Output: Sendable

    var method: HTTPMethod { get }
    var path: String { get }
    /// Session bearer authentication required before opening the stream.
    var sessionAuthentication: SessionAuthentication { get }
    var headers: HTTPHeaders { get }
    var requestInterceptors: [RequestInterceptor] { get }
    var requestSigners: [RequestSigner] { get }

    /// Per-endpoint override for the set of acceptable HTTP status codes used
    /// when validating the streaming response handshake. When `nil`, falls
    /// back to the acceptable status codes supplied through ``TransportPack``.
    var acceptableStatusCodes: Set<Int>? { get }

    /// Resume policy applied when a mid-stream transport disconnect occurs.
    /// Default is ``StreamingResumePolicy/disabled``.
    var resumePolicy: StreamingResumePolicy { get }

    /// Independent first-response, first-event, idle, and total budgets.
    /// Disabled by default.
    var timeoutPolicy: StreamingTimeoutPolicy { get }

    /// Create isolated line-decoder state for one accepted HTTP response.
    /// Called once per response, including reconnects, never shared by separate
    /// calls to `stream`. Stateful SSE decoders should be allocated inside this
    /// factory so incomplete events cannot cross attempts or concurrent streams.
    /// The default forwards to ``decode(line:)`` for stateless definitions.
    func makeDecoder() -> @Sendable (String) throws -> Output?

    /// Creates a response-scoped decoder that can surface cursor/retry control
    /// metadata independently from an application output.
    func makeFrameDecoder() -> @Sendable (String) throws -> StreamingDecodedFrame<Output>

    /// Decode a single line (without trailing newline) into an `Output`,
    /// or return `nil` to skip it.
    ///
    /// - Parameter line: One line of UTF-8 text from the response stream.
    /// - Throws: Any error that should terminate the stream and surface
    ///   to the consumer.
    func decode(line: String) throws -> Output?

    /// Returns the Last-Event-ID-style identifier for a decoded event, when
    /// the underlying protocol carries one. The library tracks the most
    /// recent non-nil result and uses it in the configured cursor header on
    /// resume attempts. An empty string clears the previous cursor and is not
    /// sent as a blank header. Values containing characters unsafe for HTTP
    /// headers or exceeding 4,096 UTF-8 bytes disable resume for that attempt.
    /// Default returns `nil`, which
    /// disables resume even if ``resumePolicy`` is configured.
    func eventID(from output: Output) -> String?
}


public extension StreamingAPIDefinition {
    func makeFrameDecoder() -> @Sendable (String) throws -> StreamingDecodedFrame<Output> {
        let decode = makeDecoder()
        return { line in
            let output = try decode(line)
            let cursor: StreamingCursorUpdate
            if let output, let eventID = self.eventID(from: output) {
                cursor = eventID.isEmpty ? .clear : .set(eventID)
            } else {
                cursor = .unchanged
            }
            return StreamingDecodedFrame(output: output, control: .init(cursor: cursor))
        }
    }

    func makeDecoder() -> @Sendable (String) throws -> Output? {
        { try self.decode(line: $0) }
    }

    /// Stateful definitions may implement only ``makeDecoder()``. Direct line
    /// decoding without their response-scoped state is unsupported.
    func decode(line: String) throws -> Output? {
        throw DecodingError.dataCorrupted(.init(
            codingPath: [], debugDescription: "Implement decode(line:) or makeDecoder()."
        ))
    }
    var headers: HTTPHeaders { HTTPHeaders() }
    var requestInterceptors: [RequestInterceptor] { [] }
    var requestSigners: [RequestSigner] { [] }
    var acceptableStatusCodes: Set<Int>? { nil }
    var resumePolicy: StreamingResumePolicy { .disabled }
    var timeoutPolicy: StreamingTimeoutPolicy { .disabled }
    func eventID(from output: Output) -> String? { nil }
}
