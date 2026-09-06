import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

private actor BufferedCallbackGate {
    private let entered = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?

    func hold() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.continuation.yield()
        }
    }

    func waitUntilEntered() async {
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor BufferedCallbackRecorder {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}

private struct HeldBufferedRequestInterceptor: RequestInterceptor {
    let gate: BufferedCallbackGate
    let recorder: BufferedCallbackRecorder

    func adapt(_ request: URLRequest) async throws -> URLRequest {
        await recorder.record("first")
        await gate.hold()
        return request
    }
}

private struct RecordingBufferedRequestInterceptor: RequestInterceptor {
    let recorder: BufferedCallbackRecorder

    func adapt(_ request: URLRequest) async throws -> URLRequest {
        await recorder.record("second")
        return request
    }
}

private struct HeldBufferedRequestSigner: RequestSigner {
    let gate: BufferedCallbackGate
    let recorder: BufferedCallbackRecorder

    func signatureHeaders(for request: URLRequest, body: RequestBody) async throws -> HTTPHeaders {
        await recorder.record("first")
        await gate.hold()
        return HTTPHeaders()
    }
}

private struct RecordingBufferedRequestSigner: RequestSigner {
    let recorder: BufferedCallbackRecorder

    func signatureHeaders(for request: URLRequest, body: RequestBody) async throws -> HTTPHeaders {
        await recorder.record("second")
        return HTTPHeaders()
    }
}

private struct HeldBufferedResponseInterceptor: ResponseInterceptor {
    let gate: BufferedCallbackGate
    let recorder: BufferedCallbackRecorder

    func adapt(_ response: Response, request: URLRequest) async throws -> Response {
        await recorder.record("first")
        await gate.hold()
        return response
    }
}

private struct RecordingBufferedResponseInterceptor: ResponseInterceptor {
    let recorder: BufferedCallbackRecorder

    func adapt(_ response: Response, request: URLRequest) async throws -> Response {
        await recorder.record("second")
        return response
    }
}

private struct HeldBufferedDecodingInterceptor: DecodingInterceptor {
    let gate: BufferedCallbackGate
    let recorder: BufferedCallbackRecorder

    func willDecode(data: Data, response: Response) async throws -> Data {
        await recorder.record("first")
        await gate.hold()
        return data
    }
}

private struct RecordingBufferedDecodingInterceptor: DecodingInterceptor {
    let recorder: BufferedCallbackRecorder

    func willDecode(data: Data, response: Response) async throws -> Data {
        await recorder.record("second")
        return data
    }
}

private struct BufferedCancellationEndpoint: APIDefinition {
    typealias APIResponse = Int

    let endpointRequestInterceptors: [RequestInterceptor]
    let endpointRequestSigners: [RequestSigner]
    let endpointResponseInterceptors: [ResponseInterceptor]
    let authentication: SessionAuthentication

    var method: HTTPMethod { .get }
    var path: String { "/value" }
    var sessionAuthentication: SessionAuthentication { authentication }
    var requestInterceptors: [RequestInterceptor] { endpointRequestInterceptors }
    var requestSigners: [RequestSigner] { endpointRequestSigners }
    var responseInterceptors: [ResponseInterceptor] { endpointResponseInterceptors }
}

@Suite("Buffered Callback Cancellation", .serialized)
struct BufferedCallbackCancellationTests {
    enum Callback: String, CaseIterable, Sendable {
        case requestInterceptor
        case requestSigner
        case responseInterceptor
        case willDecode
        case currentToken
    }

    @Test(
        "Cancellation stops the buffered callback chain",
        arguments: Callback.allCases
    )
    func cancellationStopsNextCallback(callback: Callback) async throws {
        let gate = BufferedCallbackGate()
        let recorder = BufferedCallbackRecorder()
        let session = MockURLSession()
        session.setMockResponse(statusCode: 200, data: Data("1".utf8))

        let requestInterceptors: [RequestInterceptor]
        let endpointRequestInterceptors: [RequestInterceptor]
        let requestSigners: [RequestSigner]
        let endpointRequestSigners: [RequestSigner]
        let responseInterceptors: [ResponseInterceptor]
        let endpointResponseInterceptors: [ResponseInterceptor]
        let decodingInterceptors: [DecodingInterceptor]
        let refreshTokenPolicy: RefreshTokenPolicy?
        let authentication: SessionAuthentication

        switch callback {
        case .requestInterceptor:
            requestInterceptors = [
                HeldBufferedRequestInterceptor(gate: gate, recorder: recorder)
            ]
            endpointRequestInterceptors = [
                RecordingBufferedRequestInterceptor(recorder: recorder)
            ]
            requestSigners = []
            endpointRequestSigners = []
            responseInterceptors = []
            endpointResponseInterceptors = []
            decodingInterceptors = []
            refreshTokenPolicy = nil
            authentication = .anonymous
        case .requestSigner:
            requestInterceptors = []
            endpointRequestInterceptors = []
            requestSigners = [HeldBufferedRequestSigner(gate: gate, recorder: recorder)]
            endpointRequestSigners = [RecordingBufferedRequestSigner(recorder: recorder)]
            responseInterceptors = []
            endpointResponseInterceptors = []
            decodingInterceptors = []
            refreshTokenPolicy = nil
            authentication = .anonymous
        case .responseInterceptor:
            requestInterceptors = []
            endpointRequestInterceptors = []
            requestSigners = []
            endpointRequestSigners = []
            responseInterceptors = [RecordingBufferedResponseInterceptor(recorder: recorder)]
            endpointResponseInterceptors = [
                HeldBufferedResponseInterceptor(gate: gate, recorder: recorder)
            ]
            decodingInterceptors = []
            refreshTokenPolicy = nil
            authentication = .anonymous
        case .willDecode:
            requestInterceptors = []
            endpointRequestInterceptors = []
            requestSigners = []
            endpointRequestSigners = []
            responseInterceptors = []
            endpointResponseInterceptors = []
            decodingInterceptors = [
                HeldBufferedDecodingInterceptor(gate: gate, recorder: recorder),
                RecordingBufferedDecodingInterceptor(recorder: recorder),
            ]
            refreshTokenPolicy = nil
            authentication = .anonymous
        case .currentToken:
            requestInterceptors = []
            endpointRequestInterceptors = []
            requestSigners = [RecordingBufferedRequestSigner(recorder: recorder)]
            endpointRequestSigners = []
            responseInterceptors = []
            endpointResponseInterceptors = []
            decodingInterceptors = []
            refreshTokenPolicy = RefreshTokenPolicy(
                currentToken: {
                    await recorder.record("first")
                    await gate.hold()
                    return "token"
                },
                refreshToken: { "refreshed" }
            )
            authentication = .optional
        }

        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                requestInterceptors: requestInterceptors,
                requestSigners: requestSigners,
                responseInterceptors: responseInterceptors,
                decodingInterceptors: decodingInterceptors,
                refreshTokenPolicy: refreshTokenPolicy
            ),
            session: session
        )

        let task = Task {
            try await client.request(
                BufferedCancellationEndpoint(
                    endpointRequestInterceptors: endpointRequestInterceptors,
                    endpointRequestSigners: endpointRequestSigners,
                    endpointResponseInterceptors: endpointResponseInterceptors,
                    authentication: authentication
                )
            )
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation after the held callback returned")
        } catch {
            #expect(NetworkError.isCancellation(error))
        }
        #expect(await recorder.values == ["first"])
        await client.shutdown()
    }
}
