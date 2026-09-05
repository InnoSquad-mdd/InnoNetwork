import Foundation
import Testing

@testable import InnoNetwork

private actor DecodeCancellationGate {
    let entered = AsyncStream<Void>.makeStream()
    let cancelled = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered.continuation.yield()
            }
        } onCancel: {
            cancelled.continuation.yield()
        }
    }

    func waitUntilEntered() async {
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func waitUntilCancelled() async {
        var iterator = cancelled.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Decoding Interceptor Tests")
struct DecodingInterceptorTests {

    private struct EnvelopeBody: Codable, Sendable, Equatable {
        let value: Int
    }

    private struct GetEnvelope: APIDefinition {
        var sessionAuthentication: SessionAuthentication { .anonymous }
        typealias Parameter = EmptyParameter
        typealias APIResponse = EnvelopeBody
        var method: HTTPMethod { .get }
        var path: String { "/envelope" }
    }

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _willDecode = 0
        private var _didDecode = 0

        var willDecode: Int { lock.withLock { _willDecode } }
        var didDecode: Int { lock.withLock { _didDecode } }

        func incrementWill() { lock.withLock { _willDecode += 1 } }
        func incrementDid() { lock.withLock { _didDecode += 1 } }
    }

    private struct EnvelopeUnwrapper: DecodingInterceptor {
        let counter: CallCounter
        func willDecode(data: Data, response: Response) async throws -> Data {
            counter.incrementWill()
            // Strip a `{ "data": <inner> }` envelope so the decoder sees
            // the inner object directly.
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let inner = object?["data"] as Any? ?? object as Any
            return try JSONSerialization.data(withJSONObject: inner as Any)
        }

        func didDecode<APIResponse>(
            _ value: APIResponse,
            response: Response
        ) async throws -> APIResponse where APIResponse: Sendable {
            counter.incrementDid()
            return value
        }
    }

    private struct HeldDidDecode: DecodingInterceptor {
        let gate: DecodeCancellationGate

        func didDecode<APIResponse>(
            _ value: APIResponse,
            response: Response
        ) async throws -> APIResponse where APIResponse: Sendable {
            await gate.wait()
            return value
        }
    }

    private func makeHeldClient(gate: DecodeCancellationGate) -> DefaultNetworkClient {
        let session = MockURLSession()
        session.setMockResponse(statusCode: 200, data: #"{"value":1}"#.data(using: .utf8)!)
        return DefaultNetworkClient(
            configuration: NetworkConfiguration(
                baseURL: URL(string: "https://api.example.com/v1")!,
                networkMonitor: nil,
                decodingInterceptors: [HeldDidDecode(gate: gate)]
            ),
            session: session
        )
    }

    @Test("willDecode unwraps envelope and didDecode observes typed value")
    func envelopeUnwrap() async throws {
        let payload = #"{"data":{"value":42}}"#.data(using: .utf8)!
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: payload)

        let counter = CallCounter()
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            networkMonitor: nil,
            decodingInterceptors: [EnvelopeUnwrapper(counter: counter)]
        )
        let client = DefaultNetworkClient(configuration: configuration, session: mockSession)

        let received = try await client.request(GetEnvelope())
        #expect(received == EnvelopeBody(value: 42))
        #expect(counter.willDecode == 1)
        #expect(counter.didDecode == 1)
    }

    @Test("Caller cancellation during didDecode cannot return success")
    func callerCancellationDuringDidDecode() async {
        let gate = DecodeCancellationGate()
        let client = makeHeldClient(gate: gate)
        let task = Task { try await client.request(GetEnvelope()) }

        await gate.waitUntilEntered()
        task.cancel()
        await gate.waitUntilCancelled()
        await gate.release()

        switch await task.result {
        case .success(let value):
            Issue.record("Cancelled request returned success: \(value)")
        case .failure(let error):
            #expect(NetworkError.isCancellation(error))
        }
        await client.shutdown()
    }

    @Test("Tagged cancellation during didDecode cannot return success")
    func taggedCancellationDuringDidDecode() async {
        let gate = DecodeCancellationGate()
        let client = makeHeldClient(gate: gate)
        let tag = CancellationTag("decode")
        let task = Task { try await client.request(GetEnvelope(), tag: tag) }

        await gate.waitUntilEntered()
        await client.cancelAll(matching: tag)
        await gate.waitUntilCancelled()
        await gate.release()

        switch await task.result {
        case .success(let value):
            Issue.record("Tag-cancelled request returned success: \(value)")
        case .failure(let error):
            #expect(NetworkError.isCancellation(error))
        }
        await client.shutdown()
    }

    @Test("Operation cancellation during didDecode returns a cancelled failure")
    func operationCancellationDuringDidDecode() async {
        let gate = DecodeCancellationGate()
        let base = makeHeldClient(gate: gate)
        let operation = OperationNetworkClient(client: base).start(GetEnvelope())

        await gate.waitUntilEntered()
        operation.cancel()
        await gate.waitUntilCancelled()
        await gate.release()

        do {
            _ = try await operation.value()
            Issue.record("Cancelled operation returned success")
        } catch {
            #expect(error.kind == .cancelled)
            #expect(error.recovery == .none)
        }
        await base.shutdown()
    }

    private struct ThrowingInterceptor: DecodingInterceptor {
        struct Failure: Error, Equatable {}
        func willDecode(data: Data, response: Response) async throws -> Data {
            throw Failure()
        }
    }

    @Test("Throwing willDecode aborts the request")
    func throwingWillDecodeAborts() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: #"{"value":1}"#.data(using: .utf8)!)

        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            networkMonitor: nil,
            decodingInterceptors: [ThrowingInterceptor()]
        )
        let client = DefaultNetworkClient(configuration: configuration, session: mockSession)

        await #expect(throws: Error.self) {
            _ = try await client.request(GetEnvelope())
        }
    }

    @Test("No interceptors keeps existing decode behaviour")
    func noInterceptorsParity() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: #"{"value":7}"#.data(using: .utf8)!)

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: mockSession
        )

        let received = try await client.request(GetEnvelope())
        #expect(received == EnvelopeBody(value: 7))
    }

    private struct DoublingDidDecode: DecodingInterceptor {
        func didDecode<APIResponse>(
            _ value: APIResponse,
            response: Response
        ) async throws -> APIResponse where APIResponse: Sendable {
            guard let envelope = value as? EnvelopeBody else { return value }
            let doubled = EnvelopeBody(value: envelope.value * 2)
            guard let substituted = doubled as? APIResponse else { return value }
            return substituted
        }
    }

    @Test("didDecode can substitute a normalized value of the same type")
    func didDecodeSubstitution() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: #"{"value":5}"#.data(using: .utf8)!)

        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            networkMonitor: nil,
            decodingInterceptors: [DoublingDidDecode()]
        )
        let client = DefaultNetworkClient(configuration: configuration, session: mockSession)

        let received = try await client.request(GetEnvelope())
        #expect(received == EnvelopeBody(value: 10))
    }

    private struct ThrowingDidDecode: DecodingInterceptor {
        struct Failure: Error, Equatable {}
        func didDecode<APIResponse>(
            _ value: APIResponse,
            response: Response
        ) async throws -> APIResponse where APIResponse: Sendable {
            throw Failure()
        }
    }

    @Test("Throwing didDecode aborts the request")
    func throwingDidDecodeAborts() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: #"{"value":1}"#.data(using: .utf8)!)

        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            networkMonitor: nil,
            decodingInterceptors: [ThrowingDidDecode()]
        )
        let client = DefaultNetworkClient(configuration: configuration, session: mockSession)

        await #expect(throws: Error.self) {
            _ = try await client.request(GetEnvelope())
        }
    }

    private final class OrderRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _will: [String] = []
        private var _did: [String] = []

        var willOrder: [String] { lock.withLock { _will } }
        var didOrder: [String] { lock.withLock { _did } }

        func recordWill(_ tag: String) { lock.withLock { _will.append(tag) } }
        func recordDid(_ tag: String) { lock.withLock { _did.append(tag) } }
    }

    private struct TaggingInterceptor: DecodingInterceptor {
        let tag: String
        let recorder: OrderRecorder

        func willDecode(data: Data, response: Response) async throws -> Data {
            recorder.recordWill(tag)
            return data
        }

        func didDecode<APIResponse>(
            _ value: APIResponse,
            response: Response
        ) async throws -> APIResponse where APIResponse: Sendable {
            recorder.recordDid(tag)
            return value
        }
    }

    @Test("Interceptor chain runs in declaration order for both hooks")
    func chainFiresInDeclarationOrder() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: #"{"value":3}"#.data(using: .utf8)!)

        let recorder = OrderRecorder()
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            networkMonitor: nil,
            decodingInterceptors: [
                TaggingInterceptor(tag: "A", recorder: recorder),
                TaggingInterceptor(tag: "B", recorder: recorder),
            ]
        )
        let client = DefaultNetworkClient(configuration: configuration, session: mockSession)

        let received = try await client.request(GetEnvelope())
        #expect(received == EnvelopeBody(value: 3))
        #expect(recorder.willOrder == ["A", "B"])
        #expect(recorder.didOrder == ["A", "B"])
    }
}
