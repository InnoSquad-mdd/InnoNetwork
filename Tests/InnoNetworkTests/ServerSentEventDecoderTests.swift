import Foundation
import Testing

@testable import InnoNetwork

@Suite("Server-Sent Event Decoder Tests")
struct ServerSentEventDecoderTests {

    @Test("Blank line dispatches the accumulated event")
    func blankLineDispatchesEvent() {
        let decoder = ServerSentEventDecoder()

        #expect(decoder.decode(line: "data: hello") == nil)
        let event = decoder.decode(line: "")
        #expect(event == ServerSentEvent(data: "hello"))
    }

    @Test("Multi-line data is joined with newlines and stripped of the trailing separator")
    func multiLineDataIsJoined() {
        let decoder = ServerSentEventDecoder()

        _ = decoder.decode(line: "data: first")
        _ = decoder.decode(line: "data: second")
        _ = decoder.decode(line: "data: third")
        let event = decoder.decode(line: "")

        #expect(event?.data == "first\nsecond\nthird")
    }

    @Test("id, event, and retry fields populate alongside data")
    func metadataFieldsPopulate() {
        let decoder = ServerSentEventDecoder()

        _ = decoder.decode(line: "id: 42")
        _ = decoder.decode(line: "event: ping")
        _ = decoder.decode(line: "retry: 5000")
        _ = decoder.decode(line: "data: payload")
        let event = decoder.decode(line: "")

        #expect(event == ServerSentEvent(id: "42", event: "ping", data: "payload", retry: 5000))
    }

    @Test("UTF-8 BOM on first line is stripped")
    func firstLineBOMIsStripped() async {
        let decoder = ServerSentEventDecoder()

        _ = decoder.decode(line: "\u{FEFF}data: hello")
        let event = decoder.decode(line: "")

        #expect(event == ServerSentEvent(data: "hello"))
    }

    @Test("UTF-8 BOM stripped again after reconnect on the same decoder")
    func bomStrippedOnSecondStreamAfterReconnect() async {
        let decoder = ServerSentEventDecoder()

        // First stream: BOM stripped on the leading line as before.
        _ = decoder.decode(line: "\u{FEFF}data: first")
        let firstEvent = decoder.decode(line: "")
        #expect(firstEvent == ServerSentEvent(data: "first"))

        _ = decoder.decode(line: "id: discarded")
        _ = decoder.decode(line: "data: incomplete")
        decoder.reset()
        _ = decoder.decode(line: "\u{FEFF}data: second")
        let secondEvent = decoder.decode(line: "")
        #expect(secondEvent == ServerSentEvent(data: "second"))
    }

    @Test("retry field accepts only ASCII digits")
    func retryAcceptsOnlyASCIIDigits() async {
        let decoder = ServerSentEventDecoder()

        _ = decoder.decode(line: "retry: -100")
        _ = decoder.decode(line: "retry: +100")
        _ = decoder.decode(line: "retry: 10.5")
        _ = decoder.decode(line: "retry: ５")
        _ = decoder.decode(line: "retry: 0050")
        _ = decoder.decode(line: "data: payload")
        let event = decoder.decode(line: "")

        #expect(event == ServerSentEvent(data: "payload", retry: 50))
    }

    @Test("id field containing NUL is ignored")
    func idContainingNULIsIgnored() async {
        let decoder = ServerSentEventDecoder()

        _ = decoder.decode(line: "id: bad\u{0000}id")
        _ = decoder.decode(line: "data: payload")
        let event = decoder.decode(line: "")

        #expect(event == ServerSentEvent(data: "payload"))
    }

    @Test("Comment lines are ignored")
    func commentLinesIgnored() {
        let decoder = ServerSentEventDecoder()

        _ = decoder.decode(line: ": keep-alive")
        _ = decoder.decode(line: "data: real")
        let event = decoder.decode(line: "")

        #expect(event?.data == "real")
    }

    @Test("Empty frame on initial blank line is filtered")
    func leadingBlankLineFilters() {
        let decoder = ServerSentEventDecoder()
        #expect(decoder.decode(line: "") == nil)
    }

    @Test("A data field without colon dispatches empty data; metadata alone does not")
    func fieldWithoutColon() {
        let decoder = ServerSentEventDecoder()

        _ = decoder.decode(line: "data")
        let event = decoder.decode(line: "")
        #expect(event == ServerSentEvent(data: ""))

        _ = decoder.decode(line: "event: heartbeat")
        let heartbeat = decoder.decode(line: "")
        #expect(heartbeat == nil)
    }

    @Test("Empty data lines preserve leading, trailing, and repeated newlines",
          arguments: [
            (["data:"], ""),
            (["data:", "data: next"], "\nnext"),
            (["data: first", "data:"], "first\n"),
            (["data:", "data:", "data:"], "\n\n"),
          ])
    func emptyDataLines(lines: [String], expected: String) {
        let decoder = ServerSentEventDecoder()
        for line in lines { #expect(decoder.decode(line: line) == nil) }
        #expect(decoder.decode(line: "")?.data == expected)
    }

    @Test("BOM is special only at the start of a response, not every event")
    func bomInsideStreamIsNotStripped() {
        let decoder = ServerSentEventDecoder()
        _ = decoder.decode(line: "data: first")
        _ = decoder.decode(line: "")
        _ = decoder.decode(line: "\u{FEFF}data: not-a-data-field")
        #expect(decoder.decode(line: "") == nil)
    }

    @Test("Data resets after dispatch but the last ID persists until explicitly cleared")
    func decoderResetsAfterDispatch() {
        let decoder = ServerSentEventDecoder()

        _ = decoder.decode(line: "id: 1")
        _ = decoder.decode(line: "data: first")
        let first = decoder.decode(line: "")
        #expect(first == ServerSentEvent(id: "1", data: "first"))

        _ = decoder.decode(line: "data: second")
        let second = decoder.decode(line: "")
        #expect(second == ServerSentEvent(id: "1", data: "second"))
        _ = decoder.decode(line: "id:")
        #expect(decoder.decode(line: "") == nil)
        _ = decoder.decode(line: "data: third")
        #expect(decoder.decode(line: "") == ServerSentEvent(id: "", data: "third"))
    }

    @Test("Metadata-only blocks update ID without dispatching an event")
    func metadataOnlyBlock() {
        let decoder = ServerSentEventDecoder()
        _ = decoder.decode(line: "id: 42")
        _ = decoder.decode(line: "event: discarded")
        #expect(decoder.decode(line: "") == nil)
        _ = decoder.decode(line: "data: payload")
        #expect(decoder.decode(line: "") == ServerSentEvent(id: "42", data: "payload"))
    }

    @Test("Event limit counts UTF-8 bytes and separators across short data lines")
    func boundedEvent() throws {
        let decoder = ServerSentEventDecoder()
        _ = try decoder.decode(line: "data: é", maximumEventBytes: 4)
        _ = try decoder.decode(line: "data:", maximumEventBytes: 4)
        #expect(try decoder.decode(line: "", maximumEventBytes: 4)?.data == "é\n")
        _ = try decoder.decode(line: "data: é", maximumEventBytes: 4)
        #expect(throws: DecodingError.self) {
            try decoder.decode(line: "data: secret", maximumEventBytes: 4)
        }
        #expect(throws: DecodingError.self) {
            try decoder.decode(line: "", maximumEventBytes: 4)
        }
        #expect(decoder.decode(line: "data: cannot-bypass-latch") == nil)
        decoder.reset()
        _ = try decoder.decode(line: "data: ok", maximumEventBytes: 4)
        #expect(try decoder.decode(line: "", maximumEventBytes: 4)?.data == "ok")
    }

    @Test("Limit accounts for metadata replacement but not comments or unknown fields")
    func boundedMetadata() throws {
        let decoder = ServerSentEventDecoder()
        for _ in 0..<100 {
            _ = try decoder.decode(line: ": keepalive", maximumEventBytes: 5)
            _ = try decoder.decode(line: "ignored: not-retained", maximumEventBytes: 5)
        }
        _ = try decoder.decode(line: "id: 12345", maximumEventBytes: 5)
        _ = try decoder.decode(line: "id: 1", maximumEventBytes: 5)
        _ = try decoder.decode(line: "event: x", maximumEventBytes: 5)
        _ = try decoder.decode(line: "data: ok", maximumEventBytes: 5)
        #expect(try decoder.decode(line: "", maximumEventBytes: 5)?.data == "ok")
        #expect(throws: DecodingError.self) {
            try decoder.decode(line: "event: secret", maximumEventBytes: 5)
        }
    }

    @Test("Nonpositive limit is rejected without consuming input", arguments: [0, -1])
    func invalidLimit(limit: Int) throws {
        let decoder = ServerSentEventDecoder()
        #expect(throws: DecodingError.self) {
            try decoder.decode(line: "data: ignored", maximumEventBytes: limit)
        }
        _ = try decoder.decode(line: "\u{FEFF}data: ok", maximumEventBytes: 3)
        #expect(try decoder.decode(line: "", maximumEventBytes: 3)?.data == "ok")
    }

    @Test("Single-space prefix on values is consumed")
    func valuePrefixSpaceIsConsumed() {
        let decoder = ServerSentEventDecoder()

        _ = decoder.decode(line: "data:no-space")
        let noSpace = decoder.decode(line: "")
        #expect(noSpace?.data == "no-space")

        _ = decoder.decode(line: "data: with-space")
        let withSpace = decoder.decode(line: "")
        #expect(withSpace?.data == "with-space")
    }
}
