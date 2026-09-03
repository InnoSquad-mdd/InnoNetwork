# Typed WebSocket Messages

Encode outbound application values and lazily decode inbound frames without
adding a second relay task or message buffer.

## JSON messages

Declare separate types for the server-to-client and client-to-server
directions, then create a ``JSONWebSocketMessageCodec``:

```swift
struct ServerEvent: Decodable, Sendable {
    let kind: String
    let count: Int
}

struct ClientCommand: Encodable, Sendable {
    let action: String
    let channel: String
}

let codec = JSONWebSocketMessageCodec<ServerEvent, ClientCommand>()
let channel = WebSocketTypedChannel(manager: manager, task: task, codec: codec)

try await channel.send(ClientCommand(action: "subscribe", channel: "orders"))

for try await event in await channel.messages() {
    render(event)
}
```

The JSON codec uses text frames by default. Pass `frameKind: .binary` when the
peer's application protocol carries JSON in binary frames.

## Delivery and failure behavior

``WebSocketDecodedMessages`` is a lazy view over the existing
``WebSocketManager/events(for:)`` stream. Decoding happens when its iterator
requests the next value, so it inherits the manager's configured event
delivery policy instead of creating an unbounded intermediate queue.

The typed sequence skips connection, heartbeat, and send-pressure events.
Observe those independently through ``WebSocketManager/events(for:)`` when the
feature needs lifecycle telemetry. An invalid payload throws
``WebSocketMessageCodingError`` from the iterator but does not disconnect the
underlying socket.

Typed sends report encoding and transport failures separately through
``WebSocketTypedSendError``. The manager's configured send-overflow behavior
still applies after encoding.

## Custom application protocols

Implement ``WebSocketMessageCodec`` for protobuf, MessagePack, encrypted
envelopes, custom JSON strategies, or any other application-level protocol.
The codec explicitly returns a ``WebSocketFrame`` so text-versus-binary wire
semantics stay visible at the boundary.

## See Also

- ``WebSocketMessageCodec``
- ``JSONWebSocketMessageCodec``
- ``WebSocketTypedChannel``
- ``WebSocketDecodedMessages``
- ``WebSocketFrame``
- <doc:FeatureScopedManagers>
