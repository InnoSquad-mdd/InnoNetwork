import Foundation
import Testing
import os

@testable import InnoNetwork

struct ResilienceUser: Codable, Sendable, Equatable {
    let id: Int
    let name: String
}


struct ResilienceGetRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = ResilienceUser

    var sessionAuthentication: SessionAuthentication = .anonymous
    var method: HTTPMethod { .get }
    var path: String { "/users/1" }
}

struct ResilienceCacheableEmptyRequest: APIDefinition, HTTPEmptyResponseDecodable {
    typealias Parameter = EmptyParameter
    typealias APIResponse = ResilienceCacheableEmptyRequest

    var method: HTTPMethod { .get }
    var path: String { "/empty" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
    var acceptableStatusCodes: Set<Int>? { [204] }

    static func emptyResponseValue() -> ResilienceCacheableEmptyRequest {
        ResilienceCacheableEmptyRequest()
    }
}


struct AuthorizedResilienceGetRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = ResilienceUser

    let token: String
    var method: HTTPMethod { .get }
    var path: String { "/users/1" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
    var requestInterceptors: [RequestInterceptor] {
        [ResilienceStaticAuthorizationInterceptor(token: token)]
    }
}


struct InterceptedResilienceGetRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = ResilienceUser

    let interceptors: [RequestInterceptor]
    var sessionAuthentication: SessionAuthentication = .anonymous

    var method: HTTPMethod { .get }
    var path: String { "/users/1" }
    var requestInterceptors: [RequestInterceptor] { interceptors }
}

actor ResilienceResponseRecorder {
    private var responses: [Response] = []

    func record(_ response: Response) {
        responses.append(response)
    }

    func response(at index: Int = 0) -> Response? {
        guard responses.indices.contains(index) else { return nil }
        return responses[index]
    }
}

struct ResilienceRecordingResponseInterceptor: ResponseInterceptor {
    let recorder: ResilienceResponseRecorder

    func adapt(_ urlResponse: Response, request: URLRequest) async throws -> Response {
        _ = request
        await recorder.record(urlResponse)
        return urlResponse
    }
}


actor ResilienceCountingResponseCache: ResponseCache {
    private let cached: CachedResponse?
    private(set) var getCount = 0
    private(set) var setCount = 0
    private(set) var invalidateCount = 0
    private(set) var lastSetKey: ResponseCacheKey?

    init(cached: CachedResponse? = nil) {
        self.cached = cached
    }

    func get(_ key: ResponseCacheKey) async -> CachedResponse? {
        _ = key
        getCount += 1
        return cached
    }

    func set(_ key: ResponseCacheKey, _ value: CachedResponse) async {
        _ = value
        lastSetKey = key
        setCount += 1
    }

    func invalidate(_ key: ResponseCacheKey) async {
        _ = key
        invalidateCount += 1
    }
}


struct ResiliencePostRequest: APIDefinition {
    struct Body: Encodable, Sendable {
        let name: String
    }

    typealias Parameter = Body
    typealias APIResponse = ResilienceUser

    let parameters: Body?
    var method: HTTPMethod { .post }
    var path: String { "/users" }
    var sessionAuthentication: SessionAuthentication { .anonymous }

    init(name: String = "Jane") {
        self.parameters = Body(name: name)
    }
}


struct ResilienceMutationRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = ResilienceUser

    let mutationMethod: HTTPMethod
    let acceptedStatusCodes: Set<Int>?

    var method: HTTPMethod { mutationMethod }
    var path: String { "/users/1" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
    var acceptableStatusCodes: Set<Int>? { acceptedStatusCodes }

    init(method: HTTPMethod, acceptedStatusCodes: Set<Int>? = nil) {
        self.mutationMethod = method
        self.acceptedStatusCodes = acceptedStatusCodes
    }
}


struct IdempotentResiliencePostRequest: APIDefinition {
    struct Body: Encodable, Sendable {
        let name: String
    }

    typealias Parameter = Body
    typealias APIResponse = ResilienceUser

    let parameters: Body?
    var method: HTTPMethod { .post }
    var path: String { "/users" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
    var headers: HTTPHeaders {
        var headers = HTTPHeaders.default
        headers.add(name: "Idempotency-Key", value: "create-user-1")
        return headers
    }

    init(name: String = "Jane") {
        self.parameters = Body(name: name)
    }
}


struct ResilienceHeaderSettingInterceptor: RequestInterceptor {
    let field: String
    let value: String

    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        request.setValue(value, forHTTPHeaderField: field)
        return request
    }
}


struct ResilienceHTTPMethodOverrideInterceptor: RequestInterceptor {
    let method: String

    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        request.httpMethod = method
        return request
    }
}


struct ResilienceStaticAuthorizationInterceptor: RequestInterceptor {
    let token: String

    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}


struct ResilienceQueuedHTTPResponse: Sendable {
    let data: Data
    let response: HTTPURLResponse
}


actor ResilienceCounter {
    private var value = 0

    func increment() {
        value += 1
    }

    var count: Int {
        value
    }
}


actor ResilienceSequenceURLSessionState {
    private var queue: [ResilienceQueuedHTTPResponse]
    private var requests: [URLRequest] = []
    private let delay: Duration

    init(queue: [ResilienceQueuedHTTPResponse], delay: Duration) {
        self.queue = queue
        self.delay = delay
    }

    func record(_ request: URLRequest) -> Duration {
        requests.append(request)
        return delay
    }

    func dequeue() throws -> (Data, URLResponse) {
        guard !queue.isEmpty else {
            throw NetworkError.configuration(reason: .invalidRequest("No queued response."))
        }
        let next = queue.removeFirst()
        return (next.data, next.response)
    }

    var requestCount: Int {
        requests.count
    }

    var capturedRequests: [URLRequest] {
        requests
    }
}


final class ResilienceSequenceURLSession: URLSessionProtocol, Sendable {
    private let state: ResilienceSequenceURLSessionState

    init(queue: [ResilienceQueuedHTTPResponse], delay: Duration = .zero) {
        self.state = ResilienceSequenceURLSessionState(queue: queue, delay: delay)
    }

    var requestCount: Int {
        get async {
            await state.requestCount
        }
    }

    var capturedRequests: [URLRequest] {
        get async {
            await state.capturedRequests
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let delay = await state.record(request)
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return try await state.dequeue()
    }
}


actor ResilienceTokenStore {
    private var token: String

    init(_ token: String) {
        self.token = token
    }

    func read() -> String {
        token
    }

    func replace(with token: String) {
        self.token = token
    }
}


actor RefreshTestGate {
    private struct EntryWaiter {
        let minimumCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var entryCount = 0
    private var entryWaiters: [EntryWaiter] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func enterAndWait() async {
        entryCount += 1
        let ready = entryWaiters.filter { entryCount >= $0.minimumCount }
        entryWaiters.removeAll { entryCount >= $0.minimumCount }
        ready.forEach { $0.continuation.resume() }

        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered(count: Int = 1) async {
        guard entryCount < count else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(EntryWaiter(minimumCount: count, continuation: continuation))
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    var totalEntryCount: Int {
        entryCount
    }
}


actor AuthorizationRoutingState {
    private struct OldRequestWaiter {
        let minimumCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let oldTokenResponse: ResilienceQueuedHTTPResponse
    private let newTokenResponse: ResilienceQueuedHTTPResponse
    private var oldTokenRequestCount = 0
    private var oldRequestWaiters: [OldRequestWaiter] = []

    init(oldTokenResponse: ResilienceQueuedHTTPResponse, newTokenResponse: ResilienceQueuedHTTPResponse) {
        self.oldTokenResponse = oldTokenResponse
        self.newTokenResponse = newTokenResponse
    }

    func response(for request: URLRequest) -> ResilienceQueuedHTTPResponse {
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer new" {
            return newTokenResponse
        }

        oldTokenRequestCount += 1
        let ready = oldRequestWaiters.filter { oldTokenRequestCount >= $0.minimumCount }
        oldRequestWaiters.removeAll { oldTokenRequestCount >= $0.minimumCount }
        ready.forEach { $0.continuation.resume() }
        return oldTokenResponse
    }

    func waitForOldTokenRequests(count: Int) async {
        guard oldTokenRequestCount < count else { return }
        await withCheckedContinuation { continuation in
            oldRequestWaiters.append(
                OldRequestWaiter(minimumCount: count, continuation: continuation)
            )
        }
    }
}


final class AuthorizationRoutingURLSession: URLSessionProtocol, Sendable {
    private let state: AuthorizationRoutingState

    init(oldTokenResponse: ResilienceQueuedHTTPResponse, newTokenResponse: ResilienceQueuedHTTPResponse) {
        self.state = AuthorizationRoutingState(
            oldTokenResponse: oldTokenResponse,
            newTokenResponse: newTokenResponse
        )
    }

    func waitForOldTokenRequests(count: Int) async {
        await state.waitForOldTokenRequests(count: count)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = await state.response(for: request)
        return (response.data, response.response)
    }
}

final class ResilienceCacheInvalidatingURLSession: URLSessionProtocol, Sendable {
    private let cache: InMemoryResponseCache
    private let cacheKey: ResponseCacheKey
    private let resilienceQueuedResponse: ResilienceQueuedHTTPResponse

    init(
        cache: InMemoryResponseCache,
        cacheKey: ResponseCacheKey,
        resilienceQueuedResponse: ResilienceQueuedHTTPResponse
    ) {
        self.cache = cache
        self.cacheKey = cacheKey
        self.resilienceQueuedResponse = resilienceQueuedResponse
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        _ = request
        await cache.invalidate(cacheKey)
        return (resilienceQueuedResponse.data, resilienceQueuedResponse.response)
    }
}


actor CancellationFirstURLSessionState {
    private var queue: [ResilienceQueuedHTTPResponse]
    private var requests: [URLRequest] = []
    private var cancellationCount = 0

    init(queue: [ResilienceQueuedHTTPResponse]) {
        self.queue = queue
    }

    func recordAndShouldWaitForCancellation(_ request: URLRequest) -> Bool {
        requests.append(request)
        return requests.count == 1
    }

    func recordCancellation() {
        cancellationCount += 1
    }

    func dequeue() throws -> (Data, URLResponse) {
        guard !queue.isEmpty else {
            throw NetworkError.configuration(reason: .invalidRequest("No queued response."))
        }
        let next = queue.removeFirst()
        return (next.data, next.response)
    }

    var requestCount: Int {
        requests.count
    }

    var cancelledRequestCount: Int {
        cancellationCount
    }
}


final class CancellationFirstURLSession: URLSessionProtocol, Sendable {
    private let state: CancellationFirstURLSessionState

    init(queue: [ResilienceQueuedHTTPResponse]) {
        self.state = CancellationFirstURLSessionState(queue: queue)
    }

    var requestCount: Int {
        get async {
            await state.requestCount
        }
    }

    var cancelledRequestCount: Int {
        get async {
            await state.cancelledRequestCount
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let shouldWaitForCancellation = await state.recordAndShouldWaitForCancellation(request)

        if shouldWaitForCancellation {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                await state.recordCancellation()
                throw error
            }
            throw NetworkError.configuration(
                reason: .invalidRequest("Expected the first queued request to be cancelled."))
        }

        return try await state.dequeue()
    }
}


func resilienceQueuedResponse(
    statusCode: Int,
    body: ResilienceUser? = nil,
    headers: [String: String] = [:]
) throws -> ResilienceQueuedHTTPResponse {
    let data = try body.map { try JSONEncoder().encode($0) } ?? Data()
    return ResilienceQueuedHTTPResponse(
        data: data,
        response: HTTPURLResponse(
            url: URL(string: "https://api.example.com/users/1")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
    )
}


let cacheFixtureAcceptLanguage = "en-US"


func resilienceUserCacheKey() -> ResponseCacheKey {
    ResponseCacheKey(
        method: "GET",
        url: "https://api.example.com/users/1",
        headers: ["Accept-Language": cacheFixtureAcceptLanguage]
    )
}

func authorizedResilienceUserCacheKey(token: String) -> ResponseCacheKey {
    ResponseCacheKey(
        method: "GET",
        url: "https://api.example.com/users/1",
        headers: [
            "Accept-Language": cacheFixtureAcceptLanguage,
            "Authorization": "Bearer \(token)",
        ]
    )
}


func resilienceResponseHeader(_ response: Response, named name: String) -> String? {
    guard
        let pair = response.response?.allHeaderFields.first(where: { pair in
            guard let key = pair.key as? String else { return false }
            return key.caseInsensitiveCompare(name) == .orderedSame
        })
    else {
        return nil
    }
    return pair.value as? String ?? String(describing: pair.value)
}


func resilienceOriginalRequestID(from event: NetworkEvent) -> UUID? {
    guard case .requestStart(let requestID, _, _, _) = event else { return nil }
    return requestID
}


func resilienceRecordedRevalidationEvents(
    in store: NetworkEventStore
) async -> [(originalID: UUID, state: CacheRevalidationState)] {
    await store.snapshot().compactMap { event in
        guard case .cacheRevalidation(let originalID, let state) = event else { return nil }
        return (originalID: originalID, state: state)
    }
}


func resilienceMakeLocalizedCacheConfiguration(
    responseCachePolicy: ResponseCachePolicy,
    responseCache: any ResponseCache,
    retryPolicy: (any RetryPolicy)? = nil,
    acceptableStatusCodes: Set<Int> = NetworkConfiguration.defaultAcceptableStatusCodes,
    requestInterceptors additionalRequestInterceptors: [RequestInterceptor] = [],
    responseInterceptors: [ResponseInterceptor] = [],
    eventObservers: [any NetworkEventObserving] = []
) -> NetworkConfiguration {
    NetworkConfiguration(
        baseURL: URL(string: "https://api.example.com")!,
        retryPolicy: retryPolicy,
        eventObservers: eventObservers,
        acceptableStatusCodes: acceptableStatusCodes,
        requestInterceptors: [
            ResilienceHeaderSettingInterceptor(field: "Accept-Language", value: cacheFixtureAcceptLanguage)
        ] + additionalRequestInterceptors,
        responseInterceptors: responseInterceptors,
        responseCachePolicy: responseCachePolicy,
        responseCache: responseCache,
        responseBodyBufferingPolicy: .buffered(maxBytes: nil)
    )
}


@Suite("Resilience policies")
struct ResiliencePolicyTests {
    func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for asynchronous condition.")
    }

    func expectCancelled(_ task: Task<ResilienceUser, Error>) async {
        do {
            _ = try await task.value
            Issue.record("Expected request cancellation.")
        } catch NetworkError.cancelled {
            return
        } catch {
            Issue.record("Expected NetworkError.cancelled, got \(error).")
        }
    }
}
