import Foundation
import InnoNetwork

/// The wire-frame kind used by a WebSocket message codec.
public enum WebSocketFrameKind: String, Sendable, Equatable {
    /// A binary WebSocket frame.
    case binary
    /// A UTF-8 text WebSocket frame.
    case text
}

/// A WebSocket application message before or after codec transformation.
public enum WebSocketFrame: Sendable, Equatable {
    /// A binary WebSocket frame.
    case binary(Data)
    /// A text WebSocket frame.
    case text(String)

    /// The frame's wire kind.
    public var kind: WebSocketFrameKind {
        switch self {
        case .binary:
            .binary
        case .text:
            .text
        }
    }
}

/// A typed failure produced while encoding or decoding an application message.
public enum WebSocketMessageCodingError: Error, Sendable, Equatable {
    /// The outbound application value could not be encoded.
    case encodingFailed(SendableUnderlyingError)
    /// The inbound frame could not be decoded as the expected application value.
    case decodingFailed(SendableUnderlyingError)
    /// The peer sent a different frame kind than the codec accepts.
    case unexpectedFrame(expected: WebSocketFrameKind, actual: WebSocketFrameKind)
}

/// A typed failure produced while sending a codec-backed message.
public enum WebSocketTypedSendError: Error, Sendable, Equatable {
    /// The application value could not be encoded.
    case coding(WebSocketMessageCodingError)
    /// The encoded frame could not be sent by the active WebSocket transport.
    case transport(WebSocketError)
}

/// Transforms application messages to and from WebSocket wire frames.
public protocol WebSocketMessageCodec: Sendable {
    /// The value decoded from an inbound frame.
    associatedtype Incoming: Sendable
    /// The value encoded into an outbound frame.
    associatedtype Outgoing: Sendable

    /// Encodes an application value into a WebSocket frame.
    func encode(_ message: Outgoing) throws(WebSocketMessageCodingError) -> WebSocketFrame

    /// Decodes an inbound WebSocket frame into an application value.
    func decode(_ frame: WebSocketFrame) throws(WebSocketMessageCodingError) -> Incoming
}

/// A stateless JSON codec for typed WebSocket application messages.
///
/// A fresh `JSONEncoder` or `JSONDecoder` is created for each operation so the
/// codec remains safe to share across concurrency domains. Applications that
/// require custom date, key, or data strategies can provide their own
/// ``WebSocketMessageCodec`` implementation.
public struct JSONWebSocketMessageCodec<Incoming, Outgoing>: WebSocketMessageCodec, Sendable
where Incoming: Decodable & Sendable, Outgoing: Encodable & Sendable {
    /// The wire-frame kind accepted and produced by this codec.
    public let frameKind: WebSocketFrameKind

    /// Creates a JSON codec that uses text frames by default.
    public init(frameKind: WebSocketFrameKind = .text) {
        self.frameKind = frameKind
    }

    public func encode(_ message: Outgoing) throws(WebSocketMessageCodingError) -> WebSocketFrame {
        let data: Data
        do {
            data = try JSONEncoder().encode(message)
        } catch {
            throw .encodingFailed(SendableUnderlyingError(error))
        }

        switch frameKind {
        case .binary:
            return .binary(data)
        case .text:
            guard let text = String(data: data, encoding: .utf8) else {
                throw .encodingFailed(
                    SendableUnderlyingError(
                        domain: "InnoNetworkWebSocket.JSONCodec",
                        code: 1,
                        message: "JSON encoder returned non-UTF-8 data"
                    )
                )
            }
            return .text(text)
        }
    }

    public func decode(_ frame: WebSocketFrame) throws(WebSocketMessageCodingError) -> Incoming {
        guard frame.kind == frameKind else {
            throw .unexpectedFrame(expected: frameKind, actual: frame.kind)
        }

        let data: Data
        switch frame {
        case .binary(let value):
            data = value
        case .text(let value):
            data = Data(value.utf8)
        }

        do {
            return try JSONDecoder().decode(Incoming.self, from: data)
        } catch {
            throw .decodingFailed(SendableUnderlyingError(error))
        }
    }
}

/// A lazy typed view over one WebSocket task's existing event stream.
///
/// Decoding occurs only when the consumer requests the next value. The
/// sequence therefore adds no relay task or second message buffer and inherits
/// the bounded delivery behavior configured on ``WebSocketManager``.
public struct WebSocketDecodedMessages<Codec>: AsyncSequence, Sendable
where Codec: WebSocketMessageCodec {
    public typealias Element = Codec.Incoming

    private let events: AsyncStream<WebSocketEvent>
    private let codec: Codec

    package init(events: AsyncStream<WebSocketEvent>, codec: Codec) {
        self.events = events
        self.codec = codec
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator(), codec: codec)
    }

    public struct Iterator: AsyncIteratorProtocol {
        private var events: AsyncStream<WebSocketEvent>.Iterator
        private let codec: Codec

        fileprivate init(events: AsyncStream<WebSocketEvent>.Iterator, codec: Codec) {
            self.events = events
            self.codec = codec
        }

        public mutating func next() async throws -> Codec.Incoming? {
            while let event = await events.next() {
                let frame: WebSocketFrame
                switch event {
                case .message(let data):
                    frame = .binary(data)
                case .string(let string):
                    frame = .text(string)
                case .connected, .disconnected, .ping, .pong, .error, .sendDropped:
                    continue
                }
                return try codec.decode(frame)
            }
            return nil
        }
    }
}

/// A typed application-message channel bound to one managed WebSocket task.
public struct WebSocketTypedChannel<Codec>: Sendable where Codec: WebSocketMessageCodec {
    private let manager: WebSocketManager
    private let task: WebSocketTask
    private let codec: Codec

    /// Creates a typed view over an existing managed WebSocket task.
    public init(manager: WebSocketManager, task: WebSocketTask, codec: Codec) {
        self.manager = manager
        self.task = task
        self.codec = codec
    }

    /// Encodes and sends a typed application message.
    public func send(_ message: Codec.Outgoing) async throws(WebSocketTypedSendError) {
        let frame: WebSocketFrame
        do {
            frame = try codec.encode(message)
        } catch {
            throw .coding(error)
        }

        do {
            switch frame {
            case .binary(let data):
                try await manager.send(task, message: data)
            case .text(let string):
                try await manager.send(task, string: string)
            }
        } catch {
            throw .transport(error)
        }
    }

    /// Returns a lazy typed view over inbound application messages.
    ///
    /// Connection, heartbeat, and send-pressure events remain available from
    /// ``events(for:)`` and are skipped by this sequence. A frame decoding
    /// failure is thrown from the iterator without disconnecting the socket.
    public func messages() async -> WebSocketDecodedMessages<Codec> {
        let source = await manager.events(for: task)
        return WebSocketDecodedMessages(events: source, codec: codec)
    }
}
