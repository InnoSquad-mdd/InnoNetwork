import Foundation
import Testing

@testable import InnoNetworkWebSocket

@Suite("Typed WebSocket Message Codec Tests")
struct WebSocketMessageCodecTests {
    @Test("JSON codec sends typed values as text frames")
    func sendsTypedJSONMessage() async throws {
        let harness = StubMessagingHarness()
        let task = try await harness.connectAndReady()
        let codec = JSONWebSocketMessageCodec<ServerEvent, ClientCommand>()
        let channel = WebSocketTypedChannel(manager: harness.manager, task: task, codec: codec)

        try await channel.send(ClientCommand(action: "subscribe", channel: "orders"))

        let sent = try #require(harness.stubTask.sentMessages.first)
        guard case .string(let text) = sent else {
            Issue.record("Expected a text frame")
            await harness.tearDown(task: task)
            return
        }
        let data = Data(text.utf8)
        let command = try JSONDecoder().decode(ClientCommand.self, from: data)
        #expect(command == ClientCommand(action: "subscribe", channel: "orders"))

        await harness.tearDown(task: task)
    }

    @Test("Decoded message sequence lazily decodes inbound JSON")
    func decodesInboundJSONMessage() async throws {
        let harness = StubMessagingHarness()
        let task = try await harness.connectAndReady()
        let codec = JSONWebSocketMessageCodec<ServerEvent, ClientCommand>()
        let channel = WebSocketTypedChannel(manager: harness.manager, task: task, codec: codec)
        let messages = await channel.messages()
        let receive = Task {
            var iterator = messages.makeAsyncIterator()
            return try await iterator.next()
        }

        harness.stubTask.scriptReceive(
            .success(.string(#"{"kind":"snapshot","count":3}"#))
        )

        let message = try #require(try await receive.value)
        #expect(message == ServerEvent(kind: "snapshot", count: 3))

        await harness.tearDown(task: task)
    }

    @Test("Decoded message sequence reports a frame-kind mismatch")
    func reportsUnexpectedFrameKind() async throws {
        let harness = StubMessagingHarness()
        let task = try await harness.connectAndReady()
        let codec = JSONWebSocketMessageCodec<ServerEvent, ClientCommand>(frameKind: .binary)
        let channel = WebSocketTypedChannel(manager: harness.manager, task: task, codec: codec)
        let messages = await channel.messages()
        let receive = Task {
            var iterator = messages.makeAsyncIterator()
            return try await iterator.next()
        }

        harness.stubTask.scriptReceive(
            .success(.string(#"{"kind":"snapshot","count":3}"#))
        )

        do {
            _ = try await receive.value
            Issue.record("Expected a frame-kind mismatch")
        } catch let error as WebSocketMessageCodingError {
            #expect(error == .unexpectedFrame(expected: .binary, actual: .text))
        } catch {
            Issue.record("Expected WebSocketMessageCodingError, got \(error)")
        }

        await harness.tearDown(task: task)
    }

    @Test("JSON codec reports malformed payloads without disconnecting")
    func reportsMalformedJSON() async throws {
        let harness = StubMessagingHarness()
        let task = try await harness.connectAndReady()
        let codec = JSONWebSocketMessageCodec<ServerEvent, ClientCommand>()
        let channel = WebSocketTypedChannel(manager: harness.manager, task: task, codec: codec)
        let messages = await channel.messages()
        let receive = Task {
            var iterator = messages.makeAsyncIterator()
            return try await iterator.next()
        }

        harness.stubTask.scriptReceive(.success(.string("not-json")))

        do {
            _ = try await receive.value
            Issue.record("Expected a JSON decoding failure")
        } catch let error as WebSocketMessageCodingError {
            guard case .decodingFailed = error else {
                Issue.record("Expected decodingFailed, got \(error)")
                await harness.tearDown(task: task)
                return
            }
        } catch {
            Issue.record("Expected WebSocketMessageCodingError, got \(error)")
        }
        #expect(await task.state == .connected)

        await harness.tearDown(task: task)
    }
}

private struct ClientCommand: Codable, Sendable, Equatable {
    let action: String
    let channel: String
}

private struct ServerEvent: Codable, Sendable, Equatable {
    let kind: String
    let count: Int
}
