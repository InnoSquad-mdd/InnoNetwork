# Bounded, resumable line streams

Keep response decoder state isolated and make replay an explicit server contract.

## Decode SSE per response

For stateful decoding, implement ``StreamingAPIDefinition/makeDecoder()``.
The executor calls it once for each accepted HTTP response, including resume
attempts. Allocate the decoder inside the factory, not in a shared endpoint
property. Existing stateless `decode(line:)` definitions need no migration.

```swift
struct Updates: StreamingAPIDefinition {
    var method: HTTPMethod { .get }
    var path: String { "/updates" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
    var resumePolicy: StreamingResumePolicy {
        .serverSentEvents(maxAttempts: 3, retryDelay: 1)
    }

    func makeFrameDecoder() -> @Sendable (String) throws -> StreamingDecodedFrame<ServerSentEvent> {
        let decoder = ServerSentEventDecoder()
        return { try decoder.decodeFrame(line: $0, maximumEventBytes: 1024 * 1024) }
    }

    var timeoutPolicy: StreamingTimeoutPolicy {
        .init(firstResponse: .seconds(10), firstEvent: .seconds(15), idle: .seconds(30))
    }
}

for try await event in client.stream(Updates()) {
    // Apply or deduplicate the event according to the server's contract.
    print(event.data)
}
```

The byte cap covers retained UTF-8 data (including data-line separators) and
ID/event metadata. It is separate from the transport's per-line limit.
Overflow releases retained data and throws a redacted decoding failure;
catching it and continuing the same decoder does not bypass the limit.
Comments and unknown fields do not consume retained-event capacity. The
nonthrowing `decode(line:)` overload remains unbounded for compatibility.
`reset()` is for manual use between responses, not concurrent streams.

SSE parsing follows the data-event framing in the
[WHATWG interpretation rules](https://html.spec.whatwg.org/multipage/server-sent-events.html#event-stream-interpretation):
empty `data` fields produce empty payloads, repeated data fields preserve
significant newlines, metadata-only blocks produce no output, and IDs persist
until changed or cleared. A BOM is special only at the response start.
CR, LF, and CRLF delimit lines; an incomplete final event is not dispatched.

The control-aware decoder preserves metadata-only `id:` updates and resets,
and bounded nonnegative `retry:` hints replace the endpoint fallback delay.
The EventSource policy can reconnect after clean EOF as well as transient
disconnects. Attempts remain bounded and the optional total timeout never
resets across reconnects. IDs use a deliberately conservative printable-ASCII
subset. Resolve redirecting endpoints before enabling resume.

First-response, first-event, idle-byte, and total budgets are independent.
Only configured budgets run. The idle watchdog uses byte activity, so SSE
comments count as connection liveness without being emitted as application data.

## Resume a custom NDJSON protocol

For a server that accepts a custom reconnect header:

```swift
struct Changes: StreamingAPIDefinition {
    struct Output: Decodable, Sendable {
        let cursor: String
        let value: Int
    }
    var method: HTTPMethod { .get }
    var path: String { "/changes" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
    var resumePolicy: StreamingResumePolicy {
        .cursor(header: "X-Resume-Cursor", maxAttempts: 3, retryDelay: 1)
    }
    func decode(line: String) throws -> Output? {
        guard !line.isEmpty else { return nil }
        return try JSONDecoder().decode(Output.self, from: Data(line.utf8))
    }
    func eventID(from output: Output) -> String? { output.cursor }
}
```

Header names are bounded ASCII HTTP tokens; reserved authentication, framing,
routing, cache, and trace fields are rejected before dispatch. Cursor values
must be at most 4,096 printable ASCII bytes. An empty cursor clears an initial
header; malformed/oversized cursors disable recovery for the entire attempt,
even if a later output supplies a valid cursor. Decoder failures, cancellation,
TLS/trust failures, and arbitrary errors never trigger mid-stream resume.

The default sequence is lossless and backpressured. Explicit lossy buffering
cannot be combined with either resume policy. `.unbounded` is permitted only
as an explicit memory-growth tradeoff. Neither mode is a durable processing
acknowledgement: applications still own cursor persistence, replay safety,
duplicate handling, and gap detection. A server may legitimately replay the
last delivered output; the library does not silently deduplicate it.
