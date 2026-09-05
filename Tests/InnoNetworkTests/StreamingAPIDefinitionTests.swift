import Foundation
import InnoNetworkTestSupport
import Network
import Testing

@testable import InnoNetwork

private struct LineCounterStream: StreamingAPIDefinition {
    typealias Output = String

    var sessionAuthentication: SessionAuthentication = .anonymous
    var method: HTTPMethod { .get }
    var path: String { "/events" }

    func decode(line: String) throws -> String? {
        guard !line.isEmpty else { return nil }
        return line
    }
}

private struct AuthenticatedLineCounterStream: StreamingAPIDefinition {
    typealias Output = String

    var method: HTTPMethod { .get }
    var path: String { "/events" }
    var sessionAuthentication: SessionAuthentication { .required }

    func decode(line: String) throws -> String? {
        guard !line.isEmpty else { return nil }
        return line
    }
}

private struct PathCounterStream: StreamingAPIDefinition {
    typealias Output = String

    let path: String
    var method: HTTPMethod { .get }
    var sessionAuthentication: SessionAuthentication { .anonymous }

    func decode(line: String) throws -> String? {
        guard !line.isEmpty else { return nil }
        return line
    }
}

private struct DuplicateAuthHeaderStream: StreamingAPIDefinition {
    typealias Output = String

    var method: HTTPMethod { .get }
    var path: String { "/events" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
    var headers: HTTPHeaders {
        var headers = HTTPHeaders.default
        headers.add(name: "Authorization", value: "Bearer stale")
        headers.add(name: "authorization", value: "Bearer fresh")
        return headers
    }

    func decode(line: String) throws -> String? {
        guard !line.isEmpty else { return nil }
        return line
    }
}


private final class ThrowingBytesSession: URLSessionProtocol, Sendable {
    let error: URLError

    init(error: URLError) {
        self.error = error
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw error
    }

    func bytes(for request: URLRequest, context: NetworkRequestContext) async throws -> (
        URLSession.AsyncBytes, URLResponse
    ) {
        throw error
    }
}

private actor InspectingStreamingSession: URLSessionProtocol {
    let session: URLSession
    var redirectPermissions: [Bool] = []
    var tasks: [URLSessionTask] = []

    init(session: URLSession) { self.session = session }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    func bytes(for request: URLRequest, context: NetworkRequestContext) async throws -> (
        URLSession.AsyncBytes, URLResponse
    ) {
        redirectPermissions.append(context.allowsAutomaticRedirects)
        let result = try await session.bytes(for: request, context: context)
        tasks.append(result.0.task)
        return result
    }

    func allTasksStopped() -> Bool {
        !tasks.isEmpty && tasks.allSatisfy { $0.state == .canceling || $0.state == .completed }
    }
}


private final class DelayedTimedOutBytesSession: URLSessionProtocol, Sendable {
    private let delay: Duration

    init(delay: Duration = .milliseconds(20)) {
        self.delay = delay
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        _ = request
        throw URLError(.badServerResponse)
    }

    func bytes(for request: URLRequest, context: NetworkRequestContext) async throws -> (
        URLSession.AsyncBytes, URLResponse
    ) {
        _ = (request, context)
        try await Task.sleep(for: delay)
        throw URLError(.timedOut)
    }
}


private final class DelayedFailingBytesSession: URLSessionProtocol, Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.badServerResponse)
    }

    func bytes(for request: URLRequest, context: NetworkRequestContext) async throws -> (
        URLSession.AsyncBytes, URLResponse
    ) {
        try await Task.sleep(for: .milliseconds(200))
        throw URLError(.badServerResponse)
    }
}


/// URLProtocol that delivers a scripted sequence of clean responses for the
/// same URL. Used by resume-policy tests that only need handshake success/failure.
private final class SequencedStreamingURLProtocol: URLProtocol {
    enum Step: Sendable {
        case success(statusCode: Int, data: Data)
        case successWithHeaders(statusCode: Int, data: Data, headers: [String: String])
        case failure(URLError)
    }

    nonisolated(unsafe) private static var queue: [String: [Step]] = [:]
    nonisolated(unsafe) private static var captured: [String: [URLRequest]] = [:]
    private static let lock = NSLock()

    static func enqueue(url: URL, steps: [Step]) {
        lock.lock()
        defer { lock.unlock() }
        queue[url.absoluteString] = steps
        captured[url.absoluteString] = []
    }

    static func capturedRequests(for url: URL) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured[url.absoluteString] ?? []
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        queue.removeAll()
        captured.removeAll()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        Self.captured[url.absoluteString, default: []].append(request)
        let next: Step?
        if var steps = Self.queue[url.absoluteString], !steps.isEmpty {
            next = steps.removeFirst()
            Self.queue[url.absoluteString] = steps
        } else {
            next = nil
        }
        Self.lock.unlock()

        switch next {
        case .success(let code, let data):
            guard let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .successWithHeaders(let code, let data, let headers):
            guard let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: headers)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .none:
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
        }
    }
}


/// Decoded "event" used by the resume tests. Each line is `id|payload`.
private struct ResumableEvent: Sendable, Equatable {
    let id: String
    let payload: String
}


/// Streaming definition that parses the lightweight `id|payload` line format.
private struct ResumableStream: StreamingAPIDefinition {
    typealias Output = ResumableEvent

    var method: HTTPMethod { .get }
    var path: String { "/sse" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
    var resumePolicy: StreamingResumePolicy

    init(resumePolicy: StreamingResumePolicy = .disabled) {
        self.resumePolicy = resumePolicy
    }

    func decode(line: String) throws -> ResumableEvent? {
        guard !line.isEmpty else { return nil }
        let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return ResumableEvent(id: String(parts[0]), payload: String(parts[1]))
    }

    func eventID(from output: ResumableEvent) -> String? {
        output.id
    }
}

private struct ResponseScopedSSEStream: StreamingAPIDefinition {
    var method: HTTPMethod { .get }
    var path: String { "/sse" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
    var resumePolicy: StreamingResumePolicy { .lastEventID(maxAttempts: 1, retryDelay: 0) }
    var maximumEventBytes = 1024

    func makeDecoder() -> @Sendable (String) throws -> ServerSentEvent? {
        let decoder = ServerSentEventDecoder()
        return { try decoder.decode(line: $0, maximumEventBytes: maximumEventBytes) }
    }

    func eventID(from output: ServerSentEvent) -> String? { output.id }
}

private struct CursorNDJSONStream: StreamingAPIDefinition {
    struct Output: Decodable, Sendable, Equatable {
        let cursor: String
        let value: Int
    }

    var method: HTTPMethod { .get }
    var path: String { "/changes" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
    var resumePolicy: StreamingResumePolicy = .cursor(header: "X-Resume-Cursor", maxAttempts: 1, retryDelay: 0)
    var headers = HTTPHeaders()

    func decode(line: String) throws -> Output? {
        guard !line.isEmpty else { return nil }
        return try JSONDecoder().decode(Output.self, from: Data(line.utf8))
    }

    func eventID(from output: Output) -> String? { output.cursor }
}


private struct ResumableDecodeError: LocalizedError {
    let line: String

    var errorDescription: String? {
        "Malformed resumable stream line: \(line)"
    }
}


private struct ThrowingResumableStream: StreamingAPIDefinition {
    typealias Output = ResumableEvent

    var method: HTTPMethod { .get }
    var path: String { "/sse" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
    var resumePolicy: StreamingResumePolicy { .lastEventID(maxAttempts: 2, retryDelay: 0) }

    func decode(line: String) throws -> ResumableEvent? {
        guard !line.isEmpty else { return nil }
        let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw ResumableDecodeError(line: line) }
        return ResumableEvent(id: String(parts[0]), payload: String(parts[1]))
    }

    func eventID(from output: ResumableEvent) -> String? {
        output.id
    }
}


private struct UnsafeEventIDResumableStream: StreamingAPIDefinition {
    typealias Output = ResumableEvent

    var method: HTTPMethod { .get }
    var path: String { "/sse" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
    var resumePolicy: StreamingResumePolicy { .lastEventID(maxAttempts: 2, retryDelay: 0) }

    func decode(line: String) throws -> ResumableEvent? {
        guard !line.isEmpty else { return nil }
        let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return ResumableEvent(id: String(parts[0]), payload: String(parts[1]))
    }

    func eventID(from output: ResumableEvent) -> String? {
        "\(output.id)\r\nInjected: true"
    }
}


private struct MixedSafetyEventIDResumableStream: StreamingAPIDefinition {
    typealias Output = ResumableEvent

    var method: HTTPMethod { .get }
    var path: String { "/sse" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
    var resumePolicy: StreamingResumePolicy { .lastEventID(maxAttempts: 2, retryDelay: 0) }

    func decode(line: String) throws -> ResumableEvent? {
        guard !line.isEmpty else { return nil }
        let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return ResumableEvent(id: String(parts[0]), payload: String(parts[1]))
    }

    func eventID(from output: ResumableEvent) -> String? {
        if output.payload == "unsafe" {
            return "\(output.id)\r\nInjected: true"
        }
        return output.id
    }
}


private func makeSequencedStreamingURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SequencedStreamingURLProtocol.self]
    return URLSession(configuration: configuration)
}


private final class StreamingResumeHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "innonetwork.streaming-resume-http-server")
    private let firstAttemptBody: String
    private let resumedBody: String
    private var handledConnectionCount = 0
    private var capturedHeaderBlocks: [String] = []
    private var portValue: UInt16 = 0

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(portValue)")!
    }

    init(firstAttemptBody: String = "1|alpha\n", resumedBody: String = "2|beta\n") throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        self.firstAttemptBody = firstAttemptBody
        self.resumedBody = resumedBody

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 2) == .success,
            let port = listener.port
        else {
            throw URLError(.cannotConnectToHost)
        }
        self.portValue = port.rawValue
    }

    func stop() {
        listener.cancel()
    }

    func capturedRequests() -> [String] {
        queue.sync { capturedHeaderBlocks }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            if let data, let headerBlock = String(data: data, encoding: .utf8) {
                self.capturedHeaderBlocks.append(headerBlock)
            } else {
                self.capturedHeaderBlocks.append("")
            }
            self.handledConnectionCount += 1

            if self.handledConnectionCount == 1 {
                var partialResponse = Data(
                    ("HTTP/1.1 200 OK\r\n"
                        + "Content-Type: text/plain\r\n"
                        + "Content-Length: 1000000\r\n"
                        + "\r\n"
                        + self.firstAttemptBody).utf8)
                partialResponse.append(contentsOf: repeatElement(UInt8(ascii: "x"), count: 128 * 1024))
                connection.send(
                    content: partialResponse,
                    completion: .contentProcessed { _ in
                        self.queue.asyncAfter(deadline: .now() + 0.05) {
                            connection.cancel()
                        }
                    })
            } else {
                let response =
                    "HTTP/1.1 200 OK\r\n"
                    + "Content-Type: text/plain\r\n"
                    + "Content-Length: \(self.resumedBody.utf8.count)\r\n"
                    + "\r\n"
                    + self.resumedBody
                connection.send(
                    content: Data(response.utf8),
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    })
            }
        }
    }
}


private final class StreamingURLProtocol: URLProtocol {
    enum ResponseSpec {
        case success(statusCode: Int, data: Data)
        case failure(Error)
    }

    nonisolated(unsafe) private static var responses: [String: ResponseSpec] = [:]
    private static let lock = NSLock()

    static func register(url: URL, response: ResponseSpec) {
        lock.lock()
        responses[url.absoluteString] = response
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        switch Self.dequeue(url: url) {
        case .success(let statusCode, let data):
            guard let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .none:
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
        }
    }

    override func stopLoading() {}

    private static func dequeue(url: URL) -> ResponseSpec? {
        lock.lock()
        let response = responses.removeValue(forKey: url.absoluteString)
        lock.unlock()
        return response
    }
}


private actor StreamingEventStore {
    private var events: [NetworkEvent] = []

    func append(_ event: NetworkEvent) {
        events.append(event)
    }

    func snapshot() -> [NetworkEvent] {
        events
    }
}


private struct StreamingEventObserver: NetworkEventObserving {
    let store: StreamingEventStore

    func handle(_ event: NetworkEvent) async {
        await store.append(event)
    }
}


private struct StreamingStatusRewritingInterceptor: ResponseInterceptor {
    let statusCode: Int

    func adapt(_ urlResponse: Response, request: URLRequest) async throws -> Response {
        guard let httpResponse = urlResponse.response else {
            throw NetworkError.configuration(
                reason: .invalidRequest("Missing HTTPURLResponse for stream response rewrite."))
        }
        return Response(
            statusCode: statusCode,
            data: urlResponse.data,
            request: urlResponse.request,
            response: httpResponse
        )
    }
}


private func makeStreamingURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StreamingURLProtocol.self]
    return URLSession(configuration: configuration)
}


private func uniqueStreamingBaseURL() -> URL {
    URL(string: "https://stream-\(UUID().uuidString).example.com/v1")!
}


private func waitForStreamingEvents(
    store: StreamingEventStore,
    minimumCount: Int,
    timeout: TimeInterval = 1.0
) async -> [NetworkEvent] {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let events = await store.snapshot()
        if events.count >= minimumCount {
            return events
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await store.snapshot()
}


private func streamingEventName(_ event: NetworkEvent) -> String {
    switch event {
    case .requestStart:
        return "start"
    case .requestAdapted:
        return "adapted"
    case .responseReceived:
        return "response"
    case .retryScheduled:
        return "retry"
    case .requestFinished:
        return "finished"
    case .requestFailed:
        return "failed"
    case .cacheRevalidation:
        return "cache_revalidation"
    case .decision:
        return "decision"
    }
}


@Suite("Streaming API Definition Tests")
struct StreamingAPIDefinitionTests {

    @Test("stream() throws when the URL session does not implement bytes()")
    func streamUnsupportedTransportThrows() async throws {
        let mockSession = MockURLSession()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        let stream = client.stream(LineCounterStream())
        var iterator = stream.makeAsyncIterator()
        await #expect(throws: NetworkError.self) {
            _ = try await iterator.next()
        }
    }

    @Test("stream() uses the shared endpoint path builder")
    func streamUsesSharedEndpointPathBuilder() async throws {
        let definition = PathCounterStream(path: "/events/raw space/\u{2713}")
        let baseURL = uniqueStreamingBaseURL()
        let streamURL = URL(string: baseURL.absoluteString + "/events/raw%20space/%E2%9C%93")!
        StreamingURLProtocol.register(
            url: streamURL,
            response: .success(statusCode: 200, data: Data("one\n".utf8))
        )
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: baseURL),
            session: makeStreamingURLSession()
        )

        var values: [String] = []
        for try await value in client.stream(definition) {
            values.append(value)
        }

        #expect(values == ["one"])
    }

    @Test("stream() decode(line:) returning nil filters lines")
    func decodeNilFiltersLines() throws {
        let definition = LineCounterStream()

        // Empty line → nil (filtered)
        #expect(try definition.decode(line: "") == nil)
        // Non-empty → echoed
        #expect(try definition.decode(line: "data: ping") == "data: ping")
    }

    @Test("stream() emits the request lifecycle events")
    func streamEmitsLifecycleEvents() async throws {
        let definition = LineCounterStream()
        let baseURL = uniqueStreamingBaseURL()
        let streamURL = baseURL.appendingPathComponent(definition.path)
        StreamingURLProtocol.register(
            url: streamURL,
            response: .success(statusCode: 200, data: Data("one\ntwo\n".utf8))
        )
        let store = StreamingEventStore()
        let configuration = NetworkConfiguration(
            baseURL: baseURL,
            eventObservers: [StreamingEventObserver(store: store)]
        )
        let client = DefaultNetworkClient(configuration: configuration, session: makeStreamingURLSession())

        var values: [String] = []
        for try await value in client.stream(definition) {
            values.append(value)
        }

        #expect(values == ["one", "two"])
        let events = await waitForStreamingEvents(store: store, minimumCount: 4)
        #expect(events.map(streamingEventName) == ["start", "adapted", "response", "finished"])
        let finishedByteCounts = events.compactMap { event -> Int? in
            if case .requestFinished(_, _, let byteCount) = event { return byteCount }
            return nil
        }
        #expect(finishedByteCounts == ["one".utf8.count + "two".utf8.count])
    }

    @Test("stream(bufferingPolicy:) can bound output buffering for slow consumers")
    func streamBufferingPolicyCanBoundOutputBufferingForSlowConsumers() async throws {
        let definition = LineCounterStream()
        let baseURL = uniqueStreamingBaseURL()
        let streamURL = baseURL.appendingPathComponent(definition.path)
        StreamingURLProtocol.register(
            url: streamURL,
            response: .success(statusCode: 200, data: Data("one\ntwo\nthree\n".utf8))
        )
        let store = StreamingEventStore()
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                eventObservers: [StreamingEventObserver(store: store)]
            ),
            session: makeStreamingURLSession()
        )

        let stream = client.stream(definition, bufferingPolicy: .bufferingNewest(1))
        _ = await waitForStreamingEvents(store: store, minimumCount: 4)

        var values: [String] = []
        for try await value in stream {
            values.append(value)
        }

        #expect(values == ["three"])
    }

    @Test(
        "stream(bufferingPolicy:) rejects bounded buffers with cursor resume",
        arguments: [
            StreamingResumePolicy.lastEventID(maxAttempts: 2, retryDelay: 0),
            .cursor(header: "X-Resume-Cursor", maxAttempts: 2, retryDelay: 0),
        ])
    func streamBufferingPolicyRejectsBoundedResumeCombination(policy: StreamingResumePolicy) async throws {
        let baseURL = uniqueStreamingBaseURL()
        let definition = ResumableStream(resumePolicy: policy)
        let streamURL = baseURL.appendingPathComponent(definition.path)
        SequencedStreamingURLProtocol.enqueue(
            url: streamURL,
            steps: [
                .success(statusCode: 200, data: Data("1|alpha\n".utf8))
            ])
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: baseURL, timeout: 5),
            session: makeSequencedStreamingURLSession()
        )

        var iterator = client.stream(definition, bufferingPolicy: .bufferingNewest(1)).makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("Expected invalid request configuration for bounded resumable stream")
        } catch {
            switch error {
            case .configuration(reason: .invalidRequest(let message)):
                #expect(message.contains("unbounded output buffering"))
            default:
                Issue.record("Expected invalidRequestConfiguration, got \(error)")
            }
        }

        #expect(SequencedStreamingURLProtocol.capturedRequests(for: streamURL).isEmpty)
    }

    @Test("stream() failures are always NetworkError even after shutdown")
    func streamFailureTypeContractAfterShutdown() async throws {
        // The documented API contract (API_STABILITY.md) guarantees that the
        // AsyncThrowingStream failure is always a NetworkError even though
        // the stdlib forces the channel to be declared as `any Error`. Pin
        // the synchronous rejection path here; transport-side failures are
        // covered by streamUnsupportedTransportThrows.
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: MockURLSession()
        )
        await client.shutdown()

        var iterator = client.stream(LineCounterStream()).makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("Expected a failure from a shut-down client stream")
        } catch {
            #expect(error.category == .cancellation)
        }
    }

    @Test("stream() response interceptor status rewrite controls validation")
    func streamResponseInterceptorStatusRewriteControlsValidation() async throws {
        let definition = LineCounterStream()
        let baseURL = uniqueStreamingBaseURL()
        let streamURL = baseURL.appendingPathComponent(definition.path)
        StreamingURLProtocol.register(
            url: streamURL,
            response: .success(statusCode: 500, data: Data("accepted\n".utf8))
        )
        let configuration = NetworkConfiguration(
            baseURL: baseURL,
            responseInterceptors: [StreamingStatusRewritingInterceptor(statusCode: 200)]
        )
        let client = DefaultNetworkClient(configuration: configuration, session: makeStreamingURLSession())

        var values: [String] = []
        for try await value in client.stream(definition) {
            values.append(value)
        }

        #expect(values == ["accepted"])
    }

    @Test("stream() rejects an oversized line before buffering it unbounded")
    func streamRejectsOversizedLine() async throws {
        let definition = LineCounterStream()
        let baseURL = uniqueStreamingBaseURL()
        let streamURL = baseURL.appendingPathComponent(definition.path)
        let oversizedLine = Data(
            repeating: UInt8(ascii: "x"),
            count: NetworkConfiguration.defaultStreamingLineByteLimit + 1
        )
        StreamingURLProtocol.register(
            url: streamURL,
            response: .success(statusCode: 200, data: oversizedLine)
        )
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: baseURL),
            session: makeStreamingURLSession()
        )

        do {
            for try await _ in client.stream(definition) {}
            Issue.record("Expected oversized stream line to fail")
        } catch {
            switch error {
            case .decoding(let stage, let underlying, let response):
                #expect(stage == .streamFrame)
                #expect(underlying.code == NetworkErrorCode.streamFrameTooLarge.rawValue)
                #expect(response.kind == .headersOnly)
                #expect(response.data.isEmpty)
            default:
                Issue.record("Expected NetworkError.decoding(stage: .streamFrame), got \(error)")
            }
        }
    }

    @Test("stream() uses configured line byte limit")
    func streamUsesConfiguredLineByteLimit() async throws {
        let definition = LineCounterStream()
        let baseURL = uniqueStreamingBaseURL()
        let streamURL = baseURL.appendingPathComponent(definition.path)
        StreamingURLProtocol.register(
            url: streamURL,
            response: .success(statusCode: 200, data: Data("12345".utf8))
        )
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                streamingLineByteLimit: 4
            ),
            session: makeStreamingURLSession()
        )

        do {
            for try await _ in client.stream(definition) {}
            Issue.record("Expected configured stream line limit to fail")
        } catch {
            switch error {
            case .decoding(let stage, let underlying, _):
                #expect(stage == .streamFrame)
                #expect(underlying.code == NetworkErrorCode.streamFrameTooLarge.rawValue)
                #expect(underlying.message.contains("4 bytes"))
            default:
                Issue.record("Expected NetworkError.decoding(stage: .streamFrame), got \(error)")
            }
        }
    }

    @Test("stream() applies current token from RefreshTokenPolicy")
    func streamAppliesCurrentRefreshTokenPolicyToken() async throws {
        let definition = LineCounterStream(sessionAuthentication: .optional)
        let baseURL = uniqueStreamingBaseURL()
        let streamURL = baseURL.appendingPathComponent(definition.path)

        SequencedStreamingURLProtocol.enqueue(
            url: streamURL,
            steps: [
                .success(statusCode: 200, data: Data("authorized\n".utf8))
            ])

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                refreshTokenPolicy: RefreshTokenPolicy(
                    currentToken: { "stream-token" },
                    refreshToken: { "unused" }
                )
            ),
            session: makeSequencedStreamingURLSession()
        )

        var values: [String] = []
        for try await value in client.stream(definition) {
            values.append(value)
        }

        let captured = SequencedStreamingURLProtocol.capturedRequests(for: streamURL)
        #expect(values == ["authorized"])
        #expect(captured.count == 1)
        #expect(captured.first?.value(forHTTPHeaderField: "Authorization") == "Bearer stream-token")
    }

    @Test("Auth-required stream fails before transport without RefreshTokenPolicy")
    func authRequiredStreamRequiresRefreshTokenPolicy() async throws {
        let definition = AuthenticatedLineCounterStream()
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: uniqueStreamingBaseURL()),
            session: ThrowingBytesSession(error: URLError(.badServerResponse))
        )

        do {
            for try await _ in client.stream(definition) {}
            Issue.record("Expected auth-required stream to fail before transport")
        } catch {
            guard case .configuration(let reason) = error else {
                Issue.record("Expected NetworkError.configuration, got \(error)")
                return
            }
            #expect(String(describing: reason).contains("refreshTokenPolicy"))
        }
    }

    @Test("Auth-required stream applies current token when RefreshTokenPolicy is configured")
    func authRequiredStreamAppliesCurrentToken() async throws {
        let definition = AuthenticatedLineCounterStream()
        let baseURL = uniqueStreamingBaseURL()
        let streamURL = baseURL.appendingPathComponent(definition.path)

        SequencedStreamingURLProtocol.enqueue(
            url: streamURL,
            steps: [
                .success(statusCode: 200, data: Data("authorized\n".utf8))
            ])

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                refreshTokenPolicy: RefreshTokenPolicy(
                    currentToken: { "auth-stream-token" },
                    refreshToken: { "unused" }
                )
            ),
            session: makeSequencedStreamingURLSession()
        )

        var values: [String] = []
        for try await value in client.stream(definition) {
            values.append(value)
        }

        let captured = SequencedStreamingURLProtocol.capturedRequests(for: streamURL)
        #expect(values == ["authorized"])
        #expect(captured.count == 1)
        #expect(captured.first?.value(forHTTPHeaderField: "Authorization") == "Bearer auth-stream-token")
    }

    @Test("Auth-required stream proactively refreshes a missing current token")
    func authRequiredStreamRefreshesBeforeTransport() async throws {
        actor RefreshProbe {
            private(set) var currentCalls = 0
            private(set) var refreshCalls = 0

            func currentToken() -> String? {
                currentCalls += 1
                return nil
            }

            func refreshToken() -> String {
                refreshCalls += 1
                return "proactive-stream-token"
            }
        }

        let definition = AuthenticatedLineCounterStream()
        let baseURL = uniqueStreamingBaseURL()
        let streamURL = baseURL.appendingPathComponent(definition.path)
        let probe = RefreshProbe()

        SequencedStreamingURLProtocol.enqueue(
            url: streamURL,
            steps: [
                .success(statusCode: 200, data: Data("authorized\n".utf8))
            ]
        )

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                refreshTokenPolicy: RefreshTokenPolicy(
                    currentToken: { await probe.currentToken() },
                    refreshToken: { await probe.refreshToken() }
                )
            ),
            session: makeSequencedStreamingURLSession()
        )

        var values: [String] = []
        for try await value in client.stream(definition) {
            values.append(value)
        }

        let captured = SequencedStreamingURLProtocol.capturedRequests(for: streamURL)
        #expect(values == ["authorized"])
        #expect(captured.count == 1)
        #expect(
            captured.first?.value(forHTTPHeaderField: "Authorization")
                == "Bearer proactive-stream-token"
        )
        #expect(await probe.currentCalls == 1)
        #expect(await probe.refreshCalls == 1)
    }

    @Test("stream() does not refresh-replay handshake authorization failures")
    func streamDoesNotRefreshReplayHandshakeAuthorizationFailures() async throws {
        actor RefreshCounter {
            private(set) var count = 0
            func bump() -> String {
                count += 1
                return "refreshed"
            }
        }

        let definition = LineCounterStream(sessionAuthentication: .optional)
        let baseURL = uniqueStreamingBaseURL()
        let streamURL = baseURL.appendingPathComponent(definition.path)
        let counter = RefreshCounter()

        SequencedStreamingURLProtocol.enqueue(
            url: streamURL,
            steps: [
                .success(statusCode: 401, data: Data())
            ])

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                refreshTokenPolicy: RefreshTokenPolicy(
                    currentToken: { "expired" },
                    refreshToken: { await counter.bump() }
                )
            ),
            session: makeSequencedStreamingURLSession()
        )

        do {
            for try await _ in client.stream(definition) {}
            Issue.record("Expected stream handshake 401 to throw")
        } catch {
            guard case .statusCode(let response) = error else {
                Issue.record("Expected NetworkError.statusCode, got \(error)")
                return
            }
            #expect(response.statusCode == 401)
        }

        let captured = SequencedStreamingURLProtocol.capturedRequests(for: streamURL)
        #expect(captured.count == 1)
        #expect(captured.first?.value(forHTTPHeaderField: "Authorization") == "Bearer expired")
        #expect(await counter.count == 0)
    }

    @Test("stream() retries handshake failures through RetryPolicy before reading the body")
    func streamRetriesHandshakeFailureThroughRetryPolicy() async throws {
        let definition = LineCounterStream()
        let baseURL = uniqueStreamingBaseURL()
        let streamURL = baseURL.appendingPathComponent(definition.path)

        SequencedStreamingURLProtocol.enqueue(
            url: streamURL,
            steps: [
                .successWithHeaders(
                    statusCode: 503,
                    data: Data(),
                    headers: ["Retry-After": "0"]
                ),
                .success(statusCode: 200, data: Data("recovered\n".utf8)),
            ])

        let store = StreamingEventStore()
        let configuration = NetworkConfiguration(
            baseURL: baseURL,
            retryPolicy: ExponentialBackoffRetryPolicy(
                maxRetries: 1,
                retryDelay: 0,
                maxRetryAfterDelay: 0,
                maxDelay: 0,
                jitterRatio: 0
            ),
            eventObservers: [StreamingEventObserver(store: store)]
        )
        let client = DefaultNetworkClient(
            configuration: configuration,
            session: makeSequencedStreamingURLSession()
        )

        var values: [String] = []
        for try await value in client.stream(definition) {
            values.append(value)
        }

        let captured = SequencedStreamingURLProtocol.capturedRequests(for: streamURL)
        #expect(values == ["recovered"])
        #expect(captured.count == 2)
        let events = await waitForStreamingEvents(store: store, minimumCount: 8)
        let retryDelays = events.compactMap { event -> TimeInterval? in
            if case .retryScheduled(_, _, let delay, _) = event { return delay }
            return nil
        }
        let startRetryIndexes = events.compactMap { event -> Int? in
            if case .requestStart(_, _, _, let retryIndex) = event { return retryIndex }
            return nil
        }
        #expect(retryDelays == [0])
        #expect(startRetryIndexes == [0, 1])
        #expect(
            events.map(streamingEventName) == [
                "start",
                "adapted",
                "response",
                "retry",
                "start",
                "adapted",
                "response",
                "finished",
            ])
    }

    @Test("stream() retries pre-handshake transport failures through RetryPolicy")
    func streamRetriesPreHandshakeTransportFailureThroughRetryPolicy() async throws {
        let definition = LineCounterStream()
        let baseURL = uniqueStreamingBaseURL()
        let streamURL = baseURL.appendingPathComponent(definition.path)

        SequencedStreamingURLProtocol.enqueue(
            url: streamURL,
            steps: [
                .failure(URLError(.timedOut)),
                .success(statusCode: 200, data: Data("recovered\n".utf8)),
            ])

        let store = StreamingEventStore()
        let configuration = NetworkConfiguration(
            baseURL: baseURL,
            retryPolicy: ExponentialBackoffRetryPolicy(
                maxRetries: 1,
                retryDelay: 0,
                maxRetryAfterDelay: 0,
                maxDelay: 0,
                jitterRatio: 0
            ),
            eventObservers: [StreamingEventObserver(store: store)]
        )
        let client = DefaultNetworkClient(
            configuration: configuration,
            session: makeSequencedStreamingURLSession()
        )

        var values: [String] = []
        for try await value in client.stream(definition) {
            values.append(value)
        }

        let captured = SequencedStreamingURLProtocol.capturedRequests(for: streamURL)
        #expect(values == ["recovered"])
        #expect(captured.count == 2)
        let events = await waitForStreamingEvents(store: store, minimumCount: 7)
        #expect(
            events.map(streamingEventName) == [
                "start",
                "adapted",
                "retry",
                "start",
                "adapted",
                "response",
                "finished",
            ])
    }

    @Test("stream() applies single-value header semantics")
    func streamDuplicateSingleValueHeadersUseLastValue() async throws {
        let definition = DuplicateAuthHeaderStream()
        let baseURL = uniqueStreamingBaseURL()
        let streamURL = baseURL.appendingPathComponent(definition.path)

        SequencedStreamingURLProtocol.enqueue(
            url: streamURL,
            steps: [
                .success(statusCode: 200, data: Data("authorized\n".utf8))
            ])

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: baseURL),
            session: makeSequencedStreamingURLSession()
        )

        var values: [String] = []
        for try await value in client.stream(definition) {
            values.append(value)
        }

        let captured = SequencedStreamingURLProtocol.capturedRequests(for: streamURL)
        #expect(values == ["authorized"])
        #expect(captured.count == 1)
        #expect(captured.first?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
    }

    @Test("stream() maps URLError.timedOut to NetworkError.timeout(.requestTimeout)")
    func streamMapsTimedOutToRequestTimeout() async throws {
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: ThrowingBytesSession(error: URLError(.timedOut))
        )

        let stream = client.stream(LineCounterStream())
        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("Expected stream timeout error")
        } catch {
            switch error {
            case .timeout(.requestTimeout, let underlying):
                #expect(underlying?.domain == NSURLErrorDomain)
                #expect(underlying?.code == URLError.Code.timedOut.rawValue)
            default:
                Issue.record("Expected NetworkError.timeout(.requestTimeout), got \(error)")
            }
        }
    }

    @Test("stream() keeps URLRequest timeout as requestTimeout after the measured attempt exceeds it")
    func streamRequestTimeoutBudgetDoesNotMapToResourceTimeout() async throws {
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                timeout: 0.001
            ),
            session: DelayedTimedOutBytesSession()
        )

        let stream = client.stream(LineCounterStream())
        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("Expected stream timeout error")
        } catch {
            switch error {
            case .timeout(.requestTimeout, let underlying):
                #expect(underlying?.domain == NSURLErrorDomain)
                #expect(underlying?.code == URLError.Code.timedOut.rawValue)
            default:
                Issue.record("Expected URLRequest.timeoutInterval to stay .requestTimeout, got \(error)")
            }
        }
    }

    @Test("stream() maps URLError.cannotConnectToHost to NetworkError.timeout(.connectionTimeout)")
    func streamMapsCannotConnectToConnectionTimeout() async throws {
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: ThrowingBytesSession(error: URLError(.cannotConnectToHost))
        )

        let stream = client.stream(LineCounterStream())
        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("Expected stream connection timeout error")
        } catch {
            switch error {
            case .timeout(.connectionTimeout, let underlying):
                #expect(underlying?.domain == NSURLErrorDomain)
                #expect(underlying?.code == URLError.Code.cannotConnectToHost.rawValue)
            default:
                Issue.record("Expected NetworkError.timeout(.connectionTimeout), got \(error)")
            }
        }
    }

    @Test("stream() registered immediately is cancelled by cancelAll")
    func streamCancelAllImmediatelyCancelsRegisteredTask() async throws {
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: DelayedFailingBytesSession()
        )

        let stream = client.stream(LineCounterStream())
        await client.cancelAll()

        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("Expected stream cancellation error")
        } catch {
            switch error {
            case .cancelled:
                break
            default:
                Issue.record("Expected NetworkError.cancelled, got \(error)")
            }
        }
    }

    // MARK: - Last-Event-ID resume policy

    // URLSession.AsyncBytes can report local URLProtocol/socket failures
    // before exposing a partially delivered line to the consumer, so the
    // deterministic checks below pin the public surface and retry policy
    // accessors without claiming live end-to-end coverage.

    @Test("StreamingResumePolicy default is .disabled")
    func resumePolicyDefaultsToDisabled() {
        let definition = LineCounterStream()
        switch definition.resumePolicy {
        case .disabled: break
        default: Issue.record("Expected default to be .disabled, got \(definition.resumePolicy)")
        }
    }

    @Test("ResumableStream exposes id via eventID(from:)")
    func eventIDExtractedFromDecodedOutput() throws {
        let definition = ResumableStream(resumePolicy: .lastEventID(maxAttempts: 2))
        let event = try definition.decode(line: "42|payload")
        #expect(event == ResumableEvent(id: "42", payload: "payload"))
        #expect(definition.eventID(from: event!) == "42")
    }

    @Test("StreamingResumePolicy.lastEventID exposes maxAttempts and retryDelay")
    func resumePolicyAccessorsRoundTrip() {
        let policy = StreamingResumePolicy.lastEventID(maxAttempts: 5, retryDelay: 2.5)
        #expect(policy.maxAttempts == 5)
        #expect(policy.retryDelay == 2.5)

        let disabled = StreamingResumePolicy.disabled
        #expect(disabled.maxAttempts == 0)
        #expect(disabled.retryDelay == 0)
    }

    @Test("EventSource policy reconnects once after a clean EOF")
    func eventSourceReconnectsAfterEOF() async throws {
        let baseURL = uniqueStreamingBaseURL()
        let definition = ResumableStream(
            resumePolicy: .serverSentEvents(maxAttempts: 1, retryDelay: 0)
        )
        let streamURL = baseURL.appendingPathComponent(definition.path)
        SequencedStreamingURLProtocol.enqueue(
            url: streamURL,
            steps: [
                .success(statusCode: 200, data: Data("1|alpha\n".utf8)),
                .success(statusCode: 200, data: Data("2|beta\n".utf8)),
            ]
        )
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: baseURL, timeout: 5),
            session: makeSequencedStreamingURLSession()
        )

        var values: [ResumableEvent] = []
        for try await value in client.stream(definition) { values.append(value) }

        #expect(values.map(\.id) == ["1", "2"])
        #expect(SequencedStreamingURLProtocol.capturedRequests(for: streamURL).count == 2)
    }

    @Test("StreamingResumePolicy clamps negative parameters")
    func resumePolicyClampsNegatives() {
        let policy = StreamingResumePolicy.lastEventID(maxAttempts: -3, retryDelay: -1)
        #expect(policy.maxAttempts == 0)
        #expect(policy.retryDelay == 0)
    }

    @Test("StreamingResumePolicy is Equatable")
    func resumePolicyEquatable() {
        #expect(
            StreamingResumePolicy.lastEventID(maxAttempts: 3, retryDelay: 1)
                == StreamingResumePolicy.lastEventID(maxAttempts: 3, retryDelay: 1)
        )
        #expect(StreamingResumePolicy.disabled == .disabled)
        #expect(
            StreamingResumePolicy.disabled
                != StreamingResumePolicy.lastEventID(maxAttempts: 1, retryDelay: 1)
        )
    }

    @Test("stream() success path with .lastEventID issues exactly one request and no Last-Event-ID header")
    func resumePolicySuccessPathDoesNotAttachHeader() async throws {
        let baseURL = uniqueStreamingBaseURL()
        let definition = ResumableStream(resumePolicy: .lastEventID(maxAttempts: 2, retryDelay: 0))
        let streamURL = baseURL.appendingPathComponent(definition.path)

        SequencedStreamingURLProtocol.enqueue(
            url: streamURL,
            steps: [
                .success(statusCode: 200, data: Data("1|alpha\n2|beta\n".utf8))
            ])

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: baseURL, timeout: 5),
            session: makeSequencedStreamingURLSession()
        )

        var collected: [ResumableEvent] = []
        for try await event in client.stream(definition) {
            collected.append(event)
        }

        #expect(
            collected == [
                ResumableEvent(id: "1", payload: "alpha"),
                ResumableEvent(id: "2", payload: "beta"),
            ])

        let captured = SequencedStreamingURLProtocol.capturedRequests(for: streamURL)
        #expect(captured.count == 1)
        #expect(captured.first?.value(forHTTPHeaderField: "Last-Event-ID") == nil)
    }

    @Test("StreamingExecutor waits on injected clock before resume")
    func resumeDelayUsesInjectedClock() async throws {
        let clock = TestClock()
        let runtime = RequestExecutionRuntime(
            configuration: NetworkConfiguration(baseURL: URL(string: "https://example.com")!),
            inFlight: InFlightRegistry(),
            clock: clock
        )

        async let waited: Void = StreamingExecutor.waitBeforeResume(
            delay: 5,
            executionRuntime: runtime
        )

        #expect(await clock.waitForWaiters(count: 1))

        clock.advance(by: .seconds(5))
        try await waited
    }

    @Test("StreamingExecutor skips injected clock when resume delay is zero")
    func zeroResumeDelaySkipsInjectedClock() async throws {
        let clock = TestClock()
        let runtime = RequestExecutionRuntime(
            configuration: NetworkConfiguration(baseURL: URL(string: "https://example.com")!),
            inFlight: InFlightRegistry(),
            clock: clock
        )

        try await StreamingExecutor.waitBeforeResume(
            delay: 0,
            executionRuntime: runtime
        )

        #expect(clock.enqueuedCount == 0)
    }

    @Test("StreamingExecutor propagates injected clock cancellation")
    func resumeDelayPropagatesClockCancellation() async {
        let clock = TestClock()
        let runtime = RequestExecutionRuntime(
            configuration: NetworkConfiguration(baseURL: URL(string: "https://example.com")!),
            inFlight: InFlightRegistry(),
            clock: clock
        )
        let waitTask = Task {
            try await StreamingExecutor.waitBeforeResume(
                delay: 5,
                executionRuntime: runtime
            )
        }

        #expect(await clock.waitForWaiters(count: 1))

        waitTask.cancel()

        await #expect(throws: CancellationError.self) {
            try await waitTask.value
        }
    }

    @Test("Streaming resume state does not reuse a stale Last-Event-ID after an attempt sees no new cursor")
    func resumePolicyRequiresCurrentAttemptCursor() async throws {
        var state = StreamingResumeState()

        state.beginAttempt()
        state.observe(eventID: "1")
        #expect(state.lastSeenEventID == "1")
        #expect(state.canResume(maxAttempts: 2, completedResumeAttempts: 0))

        state.beginAttempt()
        state.observe(eventID: nil)
        #expect(state.lastSeenEventID == "1")
        #expect(!state.canResume(maxAttempts: 2, completedResumeAttempts: 1))
    }

    @Test("Streaming resume state distinguishes an explicit cursor reset from an invalid cursor")
    func resumePolicyDistinguishesExplicitResetFromInvalidCursor() {
        var state = StreamingResumeState()

        state.beginAttempt()
        state.observe(eventID: "1")
        state.observe(eventID: "")
        #expect(state.lastSeenEventID == nil)
        #expect(state.canResume(maxAttempts: 2, completedResumeAttempts: 0))

        state.rejectEventID()
        #expect(state.lastSeenEventID == nil)
        #expect(!state.canResume(maxAttempts: 2, completedResumeAttempts: 0))
    }

    @Test("stream() resumes with Last-Event-ID after a mid-stream transport failure")
    func resumePolicyAttachesLastEventIDAfterMidStreamTransportFailure() async throws {
        let server = try StreamingResumeHTTPServer()
        defer { server.stop() }

        let baseURL = server.baseURL
        let definition = ResumableStream(resumePolicy: .lastEventID(maxAttempts: 2, retryDelay: 0))

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: baseURL,
                timeout: 5,
                allowsInsecureHTTP: true
            ),
            session: URLSession(configuration: .ephemeral)
        )

        var collected: [ResumableEvent] = []
        for try await event in client.stream(definition) {
            collected.append(event)
        }

        #expect(
            collected == [
                ResumableEvent(id: "1", payload: "alpha"),
                ResumableEvent(id: "2", payload: "beta"),
            ])
        let captured = server.capturedRequests()
        #expect(captured.count == 2)
        #expect(captured.first?.localizedCaseInsensitiveContains("Last-Event-ID:") == false)
        #expect(captured.dropFirst().first?.localizedCaseInsensitiveContains("Last-Event-ID: 1") == true)
    }

    @Test("stream() drops custom event ids that are unsafe for Last-Event-ID")
    func resumePolicyDropsUnsafeCustomEventID() async throws {
        let server = try StreamingResumeHTTPServer()
        defer { server.stop() }

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: server.baseURL,
                timeout: 5,
                allowsInsecureHTTP: true
            ),
            session: URLSession(configuration: .ephemeral)
        )

        var collected: [ResumableEvent] = []
        do {
            for try await event in client.stream(UnsafeEventIDResumableStream()) {
                collected.append(event)
            }
            Issue.record("Expected mid-stream transport failure")
        } catch {
            switch error {
            case .reachability, .underlying:
                break
            default:
                Issue.record("Expected transport failure, got \(error)")
            }
        }

        #expect(collected == [ResumableEvent(id: "1", payload: "alpha")])
        let captured = server.capturedRequests()
        #expect(captured.count == 1)
        #expect(captured.first?.localizedCaseInsensitiveContains("Last-Event-ID:") == false)
    }

    @Test("stream() clears stale Last-Event-ID when an attempt observes an empty event id")
    func resumePolicyClearsStaleLastEventIDOnEmptyCursor() async throws {
        let server = try StreamingResumeHTTPServer(firstAttemptBody: "1|alpha\n|reset\n")
        defer { server.stop() }

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: server.baseURL,
                timeout: 5,
                allowsInsecureHTTP: true
            ),
            session: URLSession(configuration: .ephemeral)
        )

        var collected: [ResumableEvent] = []
        for try await event in client.stream(
            ResumableStream(resumePolicy: .lastEventID(maxAttempts: 2, retryDelay: 0))
        ) {
            collected.append(event)
        }

        #expect(
            collected == [
                ResumableEvent(id: "1", payload: "alpha"),
                ResumableEvent(id: "", payload: "reset"),
                ResumableEvent(id: "2", payload: "beta"),
            ])
        let captured = server.capturedRequests()
        #expect(captured.count == 2)
        #expect(captured.first?.localizedCaseInsensitiveContains("Last-Event-ID:") == false)
        #expect(captured.dropFirst().first?.localizedCaseInsensitiveContains("Last-Event-ID:") == false)
    }

    @Test("stream() clears stale Last-Event-ID when a later custom event id is unsafe")
    func resumePolicyClearsStaleLastEventIDOnUnsafeCursor() async throws {
        let server = try StreamingResumeHTTPServer(firstAttemptBody: "1|alpha\n2|unsafe\n")
        defer { server.stop() }

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: server.baseURL,
                timeout: 5,
                allowsInsecureHTTP: true
            ),
            session: URLSession(configuration: .ephemeral)
        )

        var collected: [ResumableEvent] = []
        do {
            for try await event in client.stream(MixedSafetyEventIDResumableStream()) {
                collected.append(event)
            }
            Issue.record("Expected mid-stream transport failure")
        } catch {
            switch error {
            case .reachability, .underlying:
                break
            default:
                Issue.record("Expected transport failure, got \(error)")
            }
        }

        #expect(
            collected == [
                ResumableEvent(id: "1", payload: "alpha"),
                ResumableEvent(id: "2", payload: "unsafe"),
            ])
        let captured = server.capturedRequests()
        #expect(captured.count == 1)
        #expect(captured.first?.localizedCaseInsensitiveContains("Last-Event-ID:") == false)
    }

    @Test("stream() does not resume Last-Event-ID after decode errors")
    func resumePolicyDoesNotResumeAfterDecodeError() async throws {
        let baseURL = uniqueStreamingBaseURL()
        let definition = ThrowingResumableStream()
        let streamURL = baseURL.appendingPathComponent(definition.path)

        SequencedStreamingURLProtocol.enqueue(
            url: streamURL,
            steps: [
                .success(statusCode: 200, data: Data("1|alpha\nmalformed\n".utf8)),
                .success(statusCode: 200, data: Data("2|beta\n".utf8)),
            ])

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: baseURL, timeout: 5, captureFailurePayload: true),
            session: makeSequencedStreamingURLSession()
        )

        var collected: [ResumableEvent] = []
        do {
            for try await event in client.stream(definition) {
                collected.append(event)
            }
            Issue.record("Expected decode error to surface")
        } catch {
            switch error {
            case .decoding(let stage, let underlying, let response):
                #expect(stage == .streamFrame)
                #expect(underlying.message.contains("Malformed resumable stream line"))
                #expect(String(data: response.data, encoding: .utf8) == "malformed")
            default:
                Issue.record("Expected NetworkError.decoding(stage: .streamFrame), got \(error)")
            }
        }

        #expect(collected == [ResumableEvent(id: "1", payload: "alpha")])
        let captured = SequencedStreamingURLProtocol.capturedRequests(for: streamURL)
        #expect(captured.count == 1)
        #expect(captured.first?.value(forHTTPHeaderField: "Last-Event-ID") == nil)
    }

    @Test(
        "NDJSON resumes with the caller's cursor header and clears seeded headers on reset",
        arguments: ["page-2", ""])
    func ndjsonCursorResume(cursor: String) async throws {
        let body = "{\"cursor\":\"\(cursor)\",\"value\":1}\n"
        let server = try StreamingResumeHTTPServer(
            firstAttemptBody: body, resumedBody: "{\"cursor\":\"page-3\",\"value\":2}\n"
        )
        defer { server.stop() }
        let definition = CursorNDJSONStream(
            headers: HTTPHeaders([
                HTTPHeader(name: "X-Resume-Cursor", value: "seed")
            ]))
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: server.baseURL, timeout: 5, allowsInsecureHTTP: true),
            session: URLSession(configuration: .ephemeral)
        )
        var values: [CursorNDJSONStream.Output] = []
        for try await value in client.stream(definition) { values.append(value) }
        #expect(values == [.init(cursor: cursor, value: 1), .init(cursor: "page-3", value: 2)])
        let requests = server.capturedRequests()
        #expect(requests.count == 2)
        #expect(requests.first?.contains("X-Resume-Cursor: seed") == true)
        #expect(requests.last?.contains("Last-Event-ID:") == false)
        if cursor.isEmpty {
            #expect(requests.last?.contains("X-Resume-Cursor:") == false)
        } else {
            #expect(requests.last?.contains("X-Resume-Cursor: page-2") == true)
        }
    }

    @Test("Invalid cursor configuration fails before network dispatch")
    func invalidCursorConfigurationDoesNotDispatch() async throws {
        let baseURL = uniqueStreamingBaseURL()
        let definition = CursorNDJSONStream(resumePolicy: .cursor(header: "Authorization", maxAttempts: 1))
        let streamURL = baseURL.appendingPathComponent(definition.path)
        SequencedStreamingURLProtocol.enqueue(url: streamURL, steps: [.success(statusCode: 200, data: Data())])
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: baseURL), session: makeSequencedStreamingURLSession()
        )
        do {
            for try await _ in client.stream(definition) {}
            Issue.record("Expected invalid cursor configuration")
        } catch {
            guard case .configuration = error else {
                Issue.record("Expected configuration failure, got \(error)")
                return
            }
        }
        #expect(SequencedStreamingURLProtocol.capturedRequests(for: streamURL).isEmpty)
    }

    @Test("Resumable streams forbid automatic redirects and cancel rejected response bodies")
    func resumeContextAndHandshakeCleanup() async throws {
        let baseURL = uniqueStreamingBaseURL()
        let definition = CursorNDJSONStream()
        let streamURL = baseURL.appendingPathComponent(definition.path)
        SequencedStreamingURLProtocol.enqueue(url: streamURL, steps: [.success(statusCode: 403, data: Data())])
        let session = InspectingStreamingSession(session: makeSequencedStreamingURLSession())
        let client = DefaultNetworkClient(configuration: NetworkConfiguration(baseURL: baseURL), session: session)
        do {
            for try await _ in client.stream(definition) {}
            Issue.record("Expected rejected handshake")
        } catch {
            guard case .statusCode = error else {
                Issue.record("Expected status-code failure, got \(error)")
                return
            }
        }
        #expect(await session.redirectPermissions == [false])
        #expect(await session.allTasksStopped())
    }

    @Test("Identical SSE definitions used concurrently get separate response decoders")
    func concurrentSSEStreamsAreIndependent() async throws {
        let definition = ResponseScopedSSEStream()
        let firstURL = uniqueStreamingBaseURL()
        let secondURL = uniqueStreamingBaseURL()
        StreamingURLProtocol.register(
            url: firstURL.appendingPathComponent(definition.path),
            response: .success(statusCode: 200, data: Data("id: first\ndata: alpha\n\n".utf8))
        )
        StreamingURLProtocol.register(
            url: secondURL.appendingPathComponent(definition.path),
            response: .success(statusCode: 200, data: Data("id: second\ndata: beta\n\n".utf8))
        )
        @Sendable func collect(baseURL: URL) async throws -> [ServerSentEvent] {
            let client = DefaultNetworkClient(
                configuration: NetworkConfiguration(baseURL: baseURL), session: makeStreamingURLSession()
            )
            var events: [ServerSentEvent] = []
            for try await event in client.stream(definition) { events.append(event) }
            return events
        }
        async let first = collect(baseURL: firstURL)
        async let second = collect(baseURL: secondURL)
        #expect(try await first == [.init(id: "first", data: "alpha")])
        #expect(try await second == [.init(id: "second", data: "beta")])
    }

    @Test("Oversized cursor prevents resume even when a subsequent cursor is valid")
    func oversizedCursorDoesNotResume() async throws {
        let server = try StreamingResumeHTTPServer(
            firstAttemptBody: String(repeating: "x", count: 4097) + "|alpha\n2|beta\n"
        )
        defer { server.stop() }
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: server.baseURL, timeout: 5, allowsInsecureHTTP: true),
            session: URLSession(configuration: .ephemeral)
        )
        var count = 0
        do {
            for try await _ in client.stream(ResumableStream(resumePolicy: .lastEventID(maxAttempts: 1, retryDelay: 0)))
            {
                count += 1
            }
            Issue.record("Expected terminal transport error")
        } catch {
            guard case .reachability = error else {
                Issue.record("Expected reachability failure, got \(error)")
                return
            }
        }
        #expect(count == 2)
        #expect(server.capturedRequests().count == 1)
    }

    @Test("SSE factory isolates decoder state across interrupted responses")
    func sseFactoryResetsOnResume() async throws {
        let server = try StreamingResumeHTTPServer(
            firstAttemptBody: "\u{FEFF}id: 1\ndata: alpha\n\ndata: unfinished\n",
            resumedBody: "\u{FEFF}id: 2\ndata: beta\n\n"
        )
        defer { server.stop() }
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: server.baseURL, timeout: 5, allowsInsecureHTTP: true),
            session: URLSession(configuration: .ephemeral)
        )
        var events: [ServerSentEvent] = []
        for try await event in client.stream(ResponseScopedSSEStream()) { events.append(event) }
        #expect(events == [.init(id: "1", data: "alpha"), .init(id: "2", data: "beta")])
        #expect(server.capturedRequests().count == 2)
        #expect(server.capturedRequests().last?.contains("Last-Event-ID: 1") == true)
    }

    @Test(
        "SSE accepts CR, LF and CRLF, including empty data and unterminated final events",
        arguments: ["\r", "\n", "\r\n"])
    func sseLineEndings(separator: String) async throws {
        let baseURL = uniqueStreamingBaseURL()
        let definition = ResponseScopedSSEStream()
        let streamURL = baseURL.appendingPathComponent(definition.path)
        let body = ["data:", "data: x", "", "data: unterminated"].joined(separator: separator)
        StreamingURLProtocol.register(url: streamURL, response: .success(statusCode: 200, data: Data(body.utf8)))
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: baseURL), session: makeStreamingURLSession()
        )
        var events: [ServerSentEvent] = []
        for try await event in client.stream(definition) { events.append(event) }
        #expect(events == [.init(data: "\nx")])
    }

    @Test("An oversized multi-line SSE event fails with redacted decoding error, without resume")
    func oversizedSSEDoesNotResume() async throws {
        let baseURL = uniqueStreamingBaseURL()
        let definition = ResponseScopedSSEStream(maximumEventBytes: 9)
        let streamURL = baseURL.appendingPathComponent(definition.path)
        SequencedStreamingURLProtocol.enqueue(
            url: streamURL,
            steps: [
                .success(statusCode: 200, data: Data("id: 1\ndata: ok\n\ndata: secret\ndata: secret\n\n".utf8)),
                .success(statusCode: 200, data: Data("data: unexpected\n\n".utf8)),
            ])
        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: baseURL), session: makeSequencedStreamingURLSession()
        )
        var events: [ServerSentEvent] = []
        do {
            for try await event in client.stream(definition) { events.append(event) }
            Issue.record("Expected event size failure")
        } catch {
            guard case .decoding(let stage, let underlying, let response) = error else {
                Issue.record("Expected decoding error, got \(error)")
                return
            }
            #expect(stage == .streamFrame)
            #expect(!underlying.message.contains("secret"))
            #expect(response.data.isEmpty)
        }
        #expect(events == [.init(id: "1", data: "ok")])
        #expect(SequencedStreamingURLProtocol.capturedRequests(for: streamURL).count == 1)
    }

    @Test("Two factories from the same definition do not share partial events")
    func sseFactoriesAreIndependent() throws {
        let definition = ResponseScopedSSEStream()
        let first = definition.makeDecoder()
        let second = definition.makeDecoder()
        _ = try first("id: first")
        _ = try first("data: alpha")
        _ = try second("\u{FEFF}data: beta")
        #expect(try second("") == .init(data: "beta"))
        #expect(try first("") == .init(id: "first", data: "alpha"))
    }

    @Test("stream() handshake error does not trigger Last-Event-ID resume")
    func resumePolicyDoesNotResumeOnHandshakeError() async throws {
        let baseURL = uniqueStreamingBaseURL()
        let definition = ResumableStream(resumePolicy: .lastEventID(maxAttempts: 2, retryDelay: 0))
        let streamURL = baseURL.appendingPathComponent(definition.path)

        SequencedStreamingURLProtocol.enqueue(
            url: streamURL,
            steps: [
                // 500 fails the acceptable-status guard before any bytes are
                // consumed. Resume is reserved for mid-stream transport faults,
                // not server-driven handshake decisions.
                .success(statusCode: 500, data: Data()),
                .success(statusCode: 200, data: Data("1|alpha\n".utf8)),
            ])

        let client = DefaultNetworkClient(
            configuration: NetworkConfiguration(baseURL: baseURL, timeout: 5),
            session: makeSequencedStreamingURLSession()
        )

        do {
            for try await _ in client.stream(definition) {}
            Issue.record("Expected handshake error to surface")
        } catch {
            switch error {
            case .statusCode(let response):
                #expect(response.statusCode == 500)
            default:
                Issue.record("Expected NetworkError.statusCode(500), got \(error)")
            }
        }

        let captured = SequencedStreamingURLProtocol.capturedRequests(for: streamURL)
        // Exactly one request — no resume.
        #expect(captured.count == 1)
    }
}
