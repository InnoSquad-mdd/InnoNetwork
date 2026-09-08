import Foundation
import Testing

@testable import InnoNetwork

@Suite("Request Execution Policy Tests")
struct RequestExecutionPolicyTests {
    private struct DataEcho: APIDefinition {
        var sessionAuthentication: SessionAuthentication { .anonymous }
        typealias Parameter = EmptyParameter
        typealias APIResponse = Data

        var method: HTTPMethod { .get }
        var path: String { "/policy" }
        var transport: TransportPolicy<Data> {
            .custom(encoding: .json(defaultRequestEncoder)) { data, _ in data }
        }
    }

    private struct LocallyMutatingPolicy: RequestExecutionPolicy {
        func execute(
            input: RequestExecutionInput,
            context: RequestExecutionContext,
            next: RequestExecutionNext
        ) async throws -> Response {
            var request = input.request
            request.setValue("policy-\(context.retryIndex)", forHTTPHeaderField: "X-Policy")
            request.url = URL(string: "https://replacement.example.com/replaced")
            _ = request
            return try await next.execute()
        }
    }

    private struct BodyRewritePolicy: RequestExecutionPolicy {
        let body: Data

        func execute(
            input: RequestExecutionInput,
            context: RequestExecutionContext,
            next: RequestExecutionNext
        ) async throws -> Response {
            let response = try await next.execute()
            guard let httpResponse = response.response else { return response }
            return Response(
                statusCode: response.statusCode,
                data: body,
                request: response.request,
                response: httpResponse
            )
        }
    }

    @Test("Custom execution policy cannot replace the executor-owned request")
    func customPolicyCannotReplaceTransportRequest() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: Data("ok".utf8))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                customExecutionPolicies: [LocallyMutatingPolicy()]
            ),
            session: mockSession
        )

        _ = try await client.request(DataEcho())

        #expect(mockSession.capturedRequest?.value(forHTTPHeaderField: "X-Policy") == nil)
        #expect(mockSession.capturedRequest?.url?.absoluteString == "https://api.example.com/policy")
        #expect(mockSession.capturedRequestsInOrder.count == 1)
    }

    private struct SyntheticResponsePolicy: RequestExecutionPolicy {
        func execute(
            input: RequestExecutionInput,
            context: RequestExecutionContext,
            next: RequestExecutionNext
        ) async throws -> Response {
            _ = (context, next)
            let response = HTTPURLResponse(
                url: input.request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return Response(
                statusCode: response.statusCode,
                data: Data("synthetic".utf8),
                request: input.request,
                response: response
            )
        }
    }

    @Test("Custom execution policy can return a synthetic response without invoking next")
    func customPolicyCanSkipNext() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: Data("unused".utf8))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                customExecutionPolicies: [SyntheticResponsePolicy()]
            ),
            session: mockSession
        )

        let data = try await client.request(DataEcho())

        #expect(String(data: data, encoding: .utf8) == "synthetic")
        #expect(mockSession.capturedRequestsInOrder.isEmpty)
    }

    @Test("Custom execution policy can rewrite the transport response before decode")
    func customPolicyRewritesResponseBeforeDecode() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: Data("original".utf8))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                customExecutionPolicies: [BodyRewritePolicy(body: Data("rewritten".utf8))]
            ),
            session: mockSession
        )

        let data = try await client.request(DataEcho())

        #expect(String(data: data, encoding: .utf8) == "rewritten")
    }

    private actor CountingObserver: NetworkEventObserving {
        private struct Waiter {
            let minimumCount: Int
            let continuation: CheckedContinuation<Int, Never>
        }

        private var responseReceivedCount = 0
        private var waiters: [Waiter] = []

        func handle(_ event: NetworkEvent) async {
            guard case .responseReceived = event else { return }
            responseReceivedCount += 1

            let ready = waiters.filter { responseReceivedCount >= $0.minimumCount }
            waiters.removeAll { responseReceivedCount >= $0.minimumCount }
            for waiter in ready {
                waiter.continuation.resume(returning: responseReceivedCount)
            }
        }

        func waitForResponseReceivedCount(_ minimumCount: Int) async -> Int {
            if responseReceivedCount >= minimumCount { return responseReceivedCount }
            return await withCheckedContinuation { continuation in
                waiters.append(
                    Waiter(minimumCount: minimumCount, continuation: continuation)
                )
            }
        }
    }

    private struct ReplayingPolicy: RequestExecutionPolicy {
        func execute(
            input: RequestExecutionInput,
            context: RequestExecutionContext,
            next: RequestExecutionNext
        ) async throws -> Response {
            _ = try await next.execute()
            return try await next.execute()
        }
    }

    @Test("responseReceived fires per transport invocation, not per top-level call")
    func responseReceivedFiresPerTransportInvocation() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: Data("ok".utf8))
        let observer = CountingObserver()

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                eventObservers: [observer],
                customExecutionPolicies: [ReplayingPolicy()]
            ),
            session: mockSession
        )

        _ = try await client.request(DataEcho())

        #expect(await observer.waitForResponseReceivedCount(2) == 2)
        #expect(mockSession.capturedRequestsInOrder.count == 2)
    }

    private struct ThrowingPolicy: RequestExecutionPolicy {
        struct PolicyError: Error {}

        func execute(
            input: RequestExecutionInput,
            context: RequestExecutionContext,
            next: RequestExecutionNext
        ) async throws -> Response {
            _ = (input, context, next)
            throw PolicyError()
        }
    }

    @Test("Throwing policy bypasses transport and propagates the error")
    func throwingPolicyBypassesTransport() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 200, data: Data("unused".utf8))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                customExecutionPolicies: [ThrowingPolicy()]
            ),
            session: mockSession
        )

        do {
            _ = try await client.request(DataEcho())
            Issue.record("Expected ThrowingPolicy.PolicyError to propagate")
        } catch let error {
            switch error {
            case .underlying:
                // Throwing policies surface as `.underlying`; transport never fired.
                break
            default:
                Issue.record("Expected NetworkError.underlying wrapping PolicyError, got \(error)")
            }
        }
        #expect(mockSession.capturedRequest == nil)
    }

    private struct StreamingBodyPolicy: RequestExecutionPolicy {
        func execute(
            input: RequestExecutionInput,
            context: RequestExecutionContext,
            next: RequestExecutionNext
        ) async throws -> Response {
            try await next.execute()
        }
    }

    @Test("Non-HTTP response surfaces as NetworkError.underlying with the diagnostic message")
    func nonHTTPResponseSurfacesAsUnderlyingError() async throws {
        let mockSession = MockURLSession()
        mockSession.mockResponse = URLResponse(
            url: URL(string: "https://example.com")!,
            mimeType: "application/octet-stream",
            expectedContentLength: 0,
            textEncodingName: nil
        )
        mockSession.mockData = Data()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com"
            ),
            session: mockSession
        )

        do {
            _ = try await client.request(DataEcho())
            Issue.record("Expected NetworkError.underlying for non-HTTP response")
        } catch let error {
            switch error {
            case .underlying(let underlying, _):
                #expect(underlying.message.contains("non-HTTP response"))
            default:
                Issue.record("Expected NetworkError.underlying, got \(error)")
            }
        }
    }

    @Test("Streaming with maxBytes does not silently fall back to a buffered transport")
    func streamingWithMaxBytesDoesNotFallBack() async throws {
        let bufferedOnlySession = BufferedOnlyURLSession(data: Data(repeating: 0xAB, count: 8_192))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                responseBodyBufferingPolicy: .streaming(maxBytes: 1_024)
            ),
            session: bufferedOnlySession
        )

        do {
            _ = try await client.request(DataEcho())
            Issue.record("Expected NetworkError.invalidRequestConfiguration")
        } catch let error {
            switch error {
            case .configuration(reason: .invalidRequest):
                // Expected: streaming bytes() not supported, no buffered fallback.
                break
            default:
                Issue.record("Expected NetworkError.invalidRequestConfiguration, got \(error)")
            }
        }
        #expect(await bufferedOnlySession.capturedRequest == nil)
    }

    @Test("BufferedAsyncBytes emits 64 KiB chunks")
    func bufferedAsyncBytesEmitsChunks() async throws {
        var sizes: [Int] = []
        for try await chunk in BufferedAsyncBytes(CountingByteSequence(count: 150_000)) {
            sizes.append(chunk.count)
        }
        #expect(sizes == [65_536, 65_536, 18_928])
    }

    @Test("BufferedAsyncBytes throws at the first byte past maxBytes")
    func bufferedAsyncBytesThrowsAtFirstBytePastLimit() async throws {
        var iterator = BufferedAsyncBytes(
            CountingByteSequence(count: 2_048),
            maxBytes: 1_024
        ).makeAsyncIterator()

        do {
            while try await iterator.next() != nil {}
            Issue.record("Expected response-too-large NetworkError.underlying")
        } catch let error as NetworkError {
            switch error {
            case .underlying(let underlying, _)
            where underlying.code == NetworkErrorCode.responseBodyLimitExceeded.rawValue:
                #expect(underlying.message.contains("1024"))
                #expect(underlying.message.contains("1025"))
            default:
                Issue.record("Expected NetworkError.underlying with responseBodyLimitExceeded code, got \(error)")
            }
        }
    }
}


private actor BufferedOnlyURLSession: URLSessionProtocol {
    private let data: Data
    private let response: URLResponse
    private(set) var capturedRequest: URLRequest?

    init(data: Data) {
        self.data = data
        self.response = HTTPURLResponse(
            url: URL(string: "https://api.example.com/policy")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        capturedRequest = request
        return (data, response)
    }
}

private struct CountingByteSequence: AsyncSequence, Sendable {
    typealias Element = UInt8

    let count: Int

    func makeAsyncIterator() -> Iterator {
        Iterator(remaining: count)
    }

    struct Iterator: AsyncIteratorProtocol {
        private var remaining: Int

        fileprivate init(remaining: Int) {
            self.remaining = remaining
        }

        mutating func next() async -> UInt8? {
            guard remaining > 0 else { return nil }
            remaining -= 1
            return 0xA5
        }
    }
}
