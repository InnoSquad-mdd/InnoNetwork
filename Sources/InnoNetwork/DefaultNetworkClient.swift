import Foundation
import os

public protocol NetworkClient: Sendable {
    /// Executes a standard typed request modeled with ``APIDefinition``.
    ///
    /// Prefer this entry point for normal request/response APIs.
    ///
    /// - Parameter request: The typed request definition to execute.
    /// - Returns: The decoded `APIResponse` produced by the request definition.
    /// - Throws: A ``NetworkError`` produced while encoding, sending,
    ///   validating, or decoding the request. Foreign errors (e.g. raw
    ///   `URLError`, `CancellationError`) are mapped to the closest
    ///   ``NetworkError`` case at the client boundary.
    func request<T: APIDefinition>(_ request: T) async throws(NetworkError) -> T.APIResponse

    /// Executes a typed request and registers it under the supplied
    /// ``CancellationTag`` so it can later be cancelled together with other
    /// requests bearing the same tag (typically via
    /// ``DefaultNetworkClient/cancelAll(matching:)``).
    ///
    /// Conformers must implement this overload explicitly. A tag-aware call
    /// that silently falls back to ``request(_:)`` would make grouped
    /// cancellation appear to succeed while leaving the work unreachable from
    /// the tag registry.
    ///
    /// - Parameters:
    ///   - request: The typed request definition to execute.
    ///   - tag: Optional cancellation tag; pass `nil` for ungrouped requests.
    /// - Returns: The decoded `APIResponse` produced by the request definition.
    /// - Throws: A ``NetworkError`` produced while encoding, sending,
    ///   validating, or decoding the request.
    func request<T: APIDefinition>(_ request: T, tag: CancellationTag?) async throws(NetworkError) -> T.APIResponse

}

extension NetworkClient {
    /// Emits a targeted diagnostic when an endpoint declaration reaches the
    /// request boundary without conforming to ``APIDefinition``.
    ///
    /// Swift cannot infer that an otherwise ordinary struct was intended to
    /// be an endpoint until it is used as one. This unavailable fallback keeps
    /// the valid constrained overload preferred while replacing the generic
    /// conformance error at that first provable boundary with an actionable
    /// macro-first correction.
    @available(
        *,
        unavailable,
        message: """
            Request types must conform to APIDefinition. \
            Add @APIDefinition(method:path:auth:) to the endpoint struct, or provide a manual conformance.
            """
    )
    public func request<T>(_: T) async throws(NetworkError) -> Never {
        fatalError("unavailable")
    }

    /// Emits the same endpoint diagnostic for the cancellation-tag overload.
    @available(
        *,
        unavailable,
        message: """
            Request types must conform to APIDefinition. \
            Add @APIDefinition(method:path:auth:) to the endpoint struct, or provide a manual conformance.
            """
    )
    public func request<T>(_: T, tag _: CancellationTag?) async throws(NetworkError) -> Never {
        fatalError("unavailable")
    }

    /// Default forwarder that calls ``request(_:tag:)`` with `tag: nil`.
    ///
    /// Conformers that need explicit observation of ungrouped requests may
    /// override this overload, but most mocks and stubs only need to
    /// implement the tag-aware path. The forwarder eliminates the boiler-
    /// plate of mirroring two methods in every test double — there is no
    /// silent-fallback risk because the implementation explicitly passes
    /// `tag: nil`, the same value the caller would have to pass anyway.
    public func request<T: APIDefinition>(_ request: T) async throws(NetworkError) -> T.APIResponse {
        try await self.request(request, tag: nil)
    }

}

/// Multipart-upload capability for clients that execute
/// ``MultipartAPIDefinition`` values.
///
/// Keep request-only dependencies typed as ``NetworkClient``. Require this
/// protocol only at boundaries that actually upload multipart content; the
/// narrower contract lets lightweight clients and test doubles implement one
/// capability without inheriting unrelated requirements.
public protocol UploadNetworkClient: Sendable {
    /// Executes a multipart request modeled with ``MultipartAPIDefinition``.
    func upload<T: MultipartAPIDefinition>(_ request: T) async throws(NetworkError) -> T.APIResponse

    /// Executes a multipart upload and registers it under the supplied
    /// ``CancellationTag``.
    ///
    /// Conformers implement this tag-aware primitive explicitly so grouped
    /// cancellation cannot silently discard its tag.
    func upload<T: MultipartAPIDefinition>(_ request: T, tag: CancellationTag?) async throws(NetworkError)
        -> T.APIResponse
}

extension UploadNetworkClient {
    /// Default forwarder that calls ``upload(_:tag:)`` with `tag: nil`.
    public func upload<T: MultipartAPIDefinition>(_ request: T) async throws(NetworkError) -> T.APIResponse {
        try await self.upload(request, tag: nil)
    }
}

/// Low-level typed execution contract for framework authors and policy layers.
///
/// Application integrations should continue to depend on ``NetworkClient``
/// for ordinary requests and ``UploadNetworkClient`` for multipart uploads.
/// Reach for this protocol only when you need direct access to the execution
/// pipeline.
///
/// > Important: `LowLevelNetworkClient` is exposed through
/// > `@_spi(GeneratedClientSupport)` and is **best-effort**: it is not part of
/// > the default SwiftPM import contract, it is not ABI-stable across releases,
/// > and it may evolve in any minor release without a deprecation window. See
/// > `API_STABILITY.md` and `Examples/GeneratedClientRecipe` for the supported
/// > usage shape.
@_spi(GeneratedClientSupport) public protocol LowLevelNetworkClient: Sendable {
    /// Executes a standard typed request through the low-level execution
    /// pipeline.
    ///
    /// `perform(_:tag:)` is primarily intended for framework authors and
    /// policy layers that already opt into `@_spi(GeneratedClientSupport)` to
    /// adapt richer request contracts into `InnoNetwork`. Application
    /// integrations should normally prefer ``NetworkClient/request(_:)``.
    ///
    /// - Parameters:
    ///   - request: The typed request definition to execute through the
    ///     low-level pipeline.
    ///   - tag: Optional ``CancellationTag`` for grouped cancellation; pass
    ///     `nil` when the request should not be reachable through
    ///     ``DefaultNetworkClient/cancelAll(matching:)``.
    /// - Returns: The decoded `APIResponse` produced by the request definition.
    /// - Throws: A ``NetworkError`` or another execution error produced while encoding,
    ///   sending, validating, or decoding the request.
    func perform<T: APIDefinition>(_ request: T, tag: CancellationTag?) async throws -> T.APIResponse
    /// Executes a custom request executable through the low-level execution pipeline.
    ///
    /// This overload exists for higher-level networking layers that want to control
    /// request serialization and decoding while still delegating execution, retry,
    /// and observability to `InnoNetwork`.
    ///
    /// - Parameters:
    ///   - executable: The custom executable that owns request metadata,
    ///     payload creation, and response decoding.
    ///   - tag: Optional ``CancellationTag`` for grouped cancellation; pass
    ///     `nil` when the request should not be reachable through
    ///     ``DefaultNetworkClient/cancelAll(matching:)``.
    /// - Returns: The decoded `APIResponse` produced by the executable.
    /// - Throws: A ``NetworkError`` or another execution error produced while building,
    ///   sending, validating, or decoding the executable request.
    func perform<D: SingleRequestExecutable>(executable: D, tag: CancellationTag?) async throws -> D.APIResponse
}

@_spi(GeneratedClientSupport) public extension LowLevelNetworkClient {
    /// Convenience overload that calls ``perform(_:tag:)`` with `tag = nil`.
    func perform<T: APIDefinition>(_ request: T) async throws -> T.APIResponse {
        try await perform(request, tag: nil)
    }

    /// Convenience overload that calls ``perform(executable:tag:)`` with
    /// `tag = nil`.
    func perform<D: SingleRequestExecutable>(executable: D) async throws -> D.APIResponse {
        try await perform(executable: executable, tag: nil)
    }
}


package struct StreamingResumeState: Sendable {
    private enum AttemptCursorObservation: Sendable {
        case unobserved
        case valid
        case explicitReset
        case invalid

        var permitsResume: Bool {
            switch self {
            case .valid, .explicitReset:
                return true
            case .unobserved, .invalid:
                return false
            }
        }
    }

    package private(set) var lastSeenEventID: String?
    private var attemptCursorObservation = AttemptCursorObservation.unobserved

    package init() {}

    package mutating func beginAttempt() {
        attemptCursorObservation = .unobserved
    }

    package mutating func observe(eventID: String?) {
        guard let eventID, attemptCursorObservation != .invalid else { return }
        if eventID.isEmpty {
            lastSeenEventID = nil
            attemptCursorObservation = .explicitReset
        } else {
            lastSeenEventID = eventID
            attemptCursorObservation = .valid
        }
    }

    package mutating func rejectEventID() {
        lastSeenEventID = nil
        attemptCursorObservation = .invalid
    }

    package func canResume(maxAttempts: Int, completedResumeAttempts: Int) -> Bool {
        maxAttempts > 0
            && completedResumeAttempts < maxAttempts
            && attemptCursorObservation.permitsResume
    }
}


/// The default ``NetworkClient`` and ``UploadNetworkClient`` implementation.
///
/// `DefaultNetworkClient` keeps request execution non-actor-isolated so
/// concurrent `request(_:)` invocations execute in parallel as soon as they
/// reach the underlying URL transport. Shared lifecycle state
/// lives behind small lock/actor boundaries: in-flight request cancellation,
/// event publication, refresh coordination, and the terminal shutdown latch.
public final class DefaultNetworkClient: NetworkClient, UploadNetworkClient, Sendable {
    private let configuration: NetworkConfiguration
    private let session: any URLSessionProtocol
    private let ownedSession: URLSession?
    private let requestBuilder = RequestBuilder()
    private let eventHub: NetworkEventHub
    package let inFlight = InFlightRegistry()
    private let executionRuntime: RequestExecutionRuntime
    private let shutdownLock = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Creates a client with ``NetworkConfiguration/safeDefaults(baseURL:)``.
    ///
    /// Use this focused entry point for small integrations that need no custom
    /// retry, cache, authentication, observability, or transport policy. Move
    /// to ``init(configuration:)`` only when the server contract justifies one
    /// of those explicit policies.
    public convenience init(baseURL: URL) {
        self.init(configuration: .safeDefaults(baseURL: baseURL))
    }

    /// Creates a client backed by a fresh `URLSession` derived from the
    /// provided configuration.
    ///
    /// - Parameters:
    ///   - configuration: The ``NetworkConfiguration`` describing the
    ///     base URL, interceptors, retry policy, and observability hooks.
    ///
    /// The default session is constructed with
    /// ``NetworkConfiguration/makeURLSessionConfiguration()`` plus per-client
    /// cookie storage and an in-memory URL cache. Pass `URLSession.shared` or
    /// another explicit session only when process-wide session state is
    /// intentional.
    public convenience init(configuration: NetworkConfiguration) {
        let session = Self.makeDefaultURLSession(configuration: configuration)
        self.init(
            configuration: configuration,
            session: session,
            ownedSession: session
        )
    }

    /// Creates a client backed by the given URL session.
    ///
    /// - Parameters:
    ///   - configuration: The ``NetworkConfiguration`` describing the
    ///     base URL, interceptors, retry policy, and observability hooks.
    ///   - session: The URL session that issues requests.
    ///
    /// > Recommended explicit-session form:
    /// >
    /// > ```swift
    /// > let urlConfig = URLSessionConfiguration.ephemeral // isolated in-memory storage
    /// > urlConfig.timeoutIntervalForRequest = 30
    /// > let session = URLSession(
    /// >     configuration: urlConfig,
    /// >     delegate: nil,
    /// >     delegateQueue: nil
    /// > )
    /// > let client = DefaultNetworkClient(
    /// >     configuration: myAPI,
    /// >     session: session
    /// > )
    /// > ```
    public convenience init(
        configuration: NetworkConfiguration,
        session: URLSession
    ) {
        self.init(configuration: configuration, session: session, ownedSession: nil)
    }

    /// Package seam used by first-party benchmarks, tests, and the optional
    /// `InnoNetworkTestSupport` product. Production consumers inject the
    /// concrete `URLSession` overload above.
    package convenience init(
        configuration: NetworkConfiguration,
        session: any URLSessionProtocol
    ) {
        self.init(configuration: configuration, session: session, ownedSession: nil)
    }

    static func makeDefaultURLSession(configuration: NetworkConfiguration) -> URLSession {
        let urlConfiguration = configuration.makeURLSessionConfiguration()
        urlConfiguration.httpCookieStorage = HTTPCookieStorage()
        urlConfiguration.urlCache = URLCache(
            memoryCapacity: URLCache.shared.memoryCapacity,
            diskCapacity: 0,
            diskPath: nil
        )
        return URLSession(configuration: urlConfiguration)
    }

    package convenience init(
        configuration: NetworkConfiguration,
        clock: any InnoNetworkClock
    ) {
        let session = Self.makeDefaultURLSession(configuration: configuration)
        self.init(
            configuration: configuration,
            session: session,
            ownedSession: session,
            clock: clock
        )
    }

    package convenience init(
        configuration: NetworkConfiguration,
        session: any URLSessionProtocol,
        clock: any InnoNetworkClock
    ) {
        self.init(configuration: configuration, session: session, ownedSession: nil, clock: clock)
    }

    private init(
        configuration: NetworkConfiguration,
        session: any URLSessionProtocol,
        ownedSession: URLSession?,
        clock: any InnoNetworkClock = SystemClock()
    ) {
        self.configuration = configuration
        self.session = session
        self.ownedSession = ownedSession
        self.executionRuntime = RequestExecutionRuntime(
            configuration: configuration,
            inFlight: inFlight,
            clock: clock
        )
        self.eventHub = NetworkEventHub(
            policy: configuration.eventDeliveryPolicy,
            metricsReporter: configuration.eventMetricsReporter,
            hubKind: .networkRequest,
            clock: clock
        )
    }

    /// Begins a long-lived streaming request and returns decoded line payloads
    /// through a lossless, backpressured sequence.
    ///
    /// Streaming requests bypass the configured ``RetryPolicy`` because a
    /// half-consumed stream cannot be replayed transparently. The producer
    /// reads at most one output ahead of the consumer. Outer-task cancellation
    /// propagates to the underlying transport, and ``cancelAll()`` reaches
    /// stream tasks the same way it reaches request tasks.
    ///
    /// Response interceptors on ``NetworkConfiguration`` receive only the
    /// response metadata for streaming requests. Their ``Response/data`` is
    /// empty because stream contents are decoded line-by-line after headers
    /// arrive; body-inspecting interceptors should stay on non-streaming
    /// ``request(_:)``/``upload(_:)`` paths. Per-endpoint response
    /// interceptors are not part of ``StreamingAPIDefinition`` and therefore
    /// are not run for streams.
    ///
    /// The returned sequence's `Failure` is ``NetworkError``: a plain
    /// `catch` around iteration binds the typed error directly and
    /// `do throws(NetworkError)` blocks compose without casts.
    ///
    /// - Parameter request: The streaming endpoint to subscribe to.
    /// - Returns: A ``StreamingOutputSequence`` whose values are the
    ///   non-nil results of ``StreamingAPIDefinition/decode(line:)``.
    public func stream<T: StreamingAPIDefinition>(_ request: T) -> StreamingOutputSequence<T.Output> {
        makeStreamingSequence(request, buffering: .backpressured)
    }

    /// Subscribes to a streaming endpoint with an explicit output buffering policy.
    ///
    /// Use the default ``stream(_:)`` for lossless delivery. Pick a bounded
    /// ``StreamingBufferingPolicy`` only when the stream can tolerate dropped
    /// decoded outputs and capped memory is more important than replaying
    /// every server-emitted line. Bounded buffering is rejected when
    /// ``StreamingResumePolicy/lastEventID(maxAttempts:retryDelay:)`` is active
    /// because the resume cursor must not advance past values a slow consumer
    /// never received.
    ///
    /// The returned sequence's `Failure` is ``NetworkError``; see
    /// ``stream(_:)`` for the typed-error details.
    public func stream<T: StreamingAPIDefinition>(
        _ request: T,
        bufferingPolicy: StreamingBufferingPolicy
    ) -> StreamingOutputSequence<T.Output> {
        if let incompatibleBufferingError = Self.incompatibleStreamingBufferingError(
            resumePolicy: request.resumePolicy,
            bufferingPolicy: bufferingPolicy
        ) {
            return .failure(incompatibleBufferingError)
        }
        return makeStreamingSequence(request, buffering: StreamingOutputBuffering(bufferingPolicy))
    }

    private func makeStreamingSequence<T: StreamingAPIDefinition>(
        _ request: T,
        buffering: StreamingOutputBuffering
    ) -> StreamingOutputSequence<T.Output> {
        guard !isShutdown else { return .failure(.cancelled) }

        let (sequence, sink) = StreamingOutputSequence<T.Output>.make(buffering: buffering)
        let requestID = UUID()
        let inFlight = self.inFlight
        let configuration = self.configuration
        let executionRuntime = self.executionRuntime
        let executor = StreamingExecutor(session: self.session, eventHub: self.eventHub)
        let startGate = TaskStartGate()
        let generation = inFlight.generation()

        let work = Task<Void, Never> {
            guard await startGate.wait() else {
                inFlight.deregister(id: requestID)
                sink.finish(throwing: .cancelled)
                return
            }
            // This task exclusively owns the in-flight registration. The
            // executor owns protocol events and sequence completion only.
            defer { inFlight.deregister(id: requestID) }
            guard !self.isShutdown else {
                sink.finish(throwing: .cancelled)
                return
            }
            await executor.run(
                request: request,
                requestID: requestID,
                configuration: configuration,
                executionRuntime: executionRuntime,
                sink: sink
            )
        }

        sink.onTermination { work.cancel() }
        inFlight.register(id: requestID, generation: generation, cancelHandler: { work.cancel() })
        startGate.open()
        return sequence
    }

    private static func incompatibleStreamingBufferingError(
        resumePolicy: StreamingResumePolicy,
        bufferingPolicy: StreamingBufferingPolicy
    ) -> NetworkError? {
        // Compatibility belongs to the concrete value policy. There is no
        // public strategy protocol because the executor cannot accept an
        // alternative implementation: adding one would advertise a
        // substitution point that does not exist.
        guard !resumePolicy.isCompatible(with: bufferingPolicy) else { return nil }
        return .configuration(
            reason: .invalidRequest(
                "StreamingResumePolicy requires unbounded output buffering for the configured resume strategy. Use stream(_:) or disable resume before choosing a bounded buffering policy."
            )
        )
    }

    /// Cancels every request currently dispatched through this client.
    ///
    /// Each in-flight request is interrupted at its next cooperative
    /// cancellation checkpoint and surfaces ``NetworkError/cancelled`` to its
    /// caller. Requests that have already produced a result before cancellation
    /// reaches them complete normally.
    ///
    /// Typical use is during sign-out, screen disposal, or auth invalidation:
    /// the client can be drained without waiting for individual `Task`
    /// references to be tracked by the call site.
    public func cancelAll() async {
        inFlight.cancelAll()
    }

    /// Cancels every in-flight request that was dispatched with the supplied
    /// ``CancellationTag``. Untagged requests, and requests with a different
    /// tag, are left alone.
    ///
    /// Use this when a screen, feature, or user session goes away and the
    /// caller wants to drop only its own requests without disturbing the rest
    /// of the app.
    public func cancelAll(matching tag: CancellationTag) async {
        inFlight.cancelAll(matching: tag)
    }

    /// Terminates this concrete client instance.
    ///
    /// The shutdown is idempotent. It cancels every in-flight request and any
    /// in-flight auth refresh, then invalidates only the `URLSession` created
    /// by ``init(configuration:)``. Sessions supplied through
    /// ``init(configuration:session:)`` remain caller-owned and are not
    /// invalidated. After shutdown, new request/upload/stream calls fail with
    /// ``NetworkError/cancelled``; create a fresh client for more work.
    public func shutdown() async {
        guard markShutdownIfNeeded() else { return }
        inFlight.shutdownAll()
        await executionRuntime.shutdown()
        await eventHub.shutdown()
        ownedSession?.invalidateAndCancel()
    }

    public func request<T: APIDefinition>(_ request: T) async throws(NetworkError) -> T.APIResponse {
        try await Self.mappingTransportErrors {
            try await self.perform(request, tag: nil)
        }
    }

    /// Executes a typed request and registers it under the supplied
    /// ``CancellationTag`` so it can later be cancelled with
    /// ``cancelAll(matching:)``.
    public func request<T: APIDefinition>(
        _ request: T,
        tag: CancellationTag?
    ) async throws(NetworkError) -> T.APIResponse {
        try await Self.mappingTransportErrors {
            try await self.perform(request, tag: tag)
        }
    }

    public func upload<T: MultipartAPIDefinition>(_ request: T) async throws(NetworkError) -> T.APIResponse {
        try await Self.mappingTransportErrors {
            try await self.perform(executable: MultipartSingleRequestExecutable(base: request), tag: nil)
        }
    }

    /// Executes a multipart upload and registers it under the supplied
    /// ``CancellationTag``.
    public func upload<T: MultipartAPIDefinition>(
        _ request: T,
        tag: CancellationTag?
    ) async throws(NetworkError) -> T.APIResponse {
        try await Self.mappingTransportErrors {
            try await self.perform(executable: MultipartSingleRequestExecutable(base: request), tag: tag)
        }
    }

    /// Funnels an untyped-throwing pipeline call into a typed
    /// `NetworkError` boundary. The retry coordinator already publishes
    /// `NetworkError` for every classified failure; this trap only catches
    /// foreign errors that bypass that normalization (e.g. raw
    /// `CancellationError` from a custom `RequestExecutionPolicy`) and
    /// maps them via ``NetworkError/mapTransportError(_:)``.
    @Sendable
    private static func mappingTransportErrors<Response: Sendable>(
        _ work: @Sendable () async throws -> Response
    ) async throws(NetworkError) -> Response {
        do {
            return try await work()
        } catch let error as NetworkError {
            throw error
        } catch {
            throw NetworkError.mapTransportError(error)
        }
    }

    /// Low-level typed execution entry point for standard ``APIDefinition`` requests.
    ///
    /// Use this when you need to make the execution pipeline itself the dependency
    /// boundary. Most app integrations should still prefer ``request(_:)``.
    ///
    /// - Parameters:
    ///   - request: The typed request definition to execute through the
    ///     low-level pipeline.
    ///   - tag: Optional ``CancellationTag`` so the request is reachable via
    ///     ``cancelAll(matching:)``.
    /// - Returns: The decoded `APIResponse` produced by the request definition.
    /// - Throws: A ``NetworkError`` or another execution error produced while encoding,
    ///   sending, validating, or decoding the request.
    @_spi(GeneratedClientSupport) public func perform<T: APIDefinition>(
        _ request: T,
        tag: CancellationTag? = nil
    ) async throws -> T.APIResponse {
        try await perform(executable: APISingleRequestExecutable(base: request), tag: tag)
    }

    /// Low-level typed execution entry point for custom ``SingleRequestExecutable`` values.
    ///
    /// This API is intended for upper networking layers that need full control over
    /// serialization and decoding but still want `InnoNetwork` to own request
    /// building, retry coordination, trust handling, and observability.
    ///
    /// - Parameters:
    ///   - executable: The custom executable that owns request metadata,
    ///     payload creation, and response decoding.
    ///   - tag: Optional ``CancellationTag`` so the request is reachable via
    ///     ``cancelAll(matching:)``.
    /// - Returns: The decoded `APIResponse` produced by the executable.
    /// - Throws: A ``NetworkError`` or another execution error produced while building,
    ///   sending, validating, or decoding the executable request.
    @_spi(GeneratedClientSupport)
    public func perform<D: SingleRequestExecutable>(
        executable: D,
        tag: CancellationTag? = nil
    ) async throws -> D.APIResponse {
        let requestID = UUID()
        let startGate = TaskStartGate()
        let generation = inFlight.generation(for: tag)
        // Wrap the work in an unstructured Task so cancelAll() can reach it
        // without the call site having to track individual Task handles.
        // Outer-task cancellation is forwarded via withTaskCancellationHandler.
        let work = Task<D.APIResponse, Error> { [eventHub, configuration, session, requestBuilder, executionRuntime] in
            guard await startGate.wait() else { throw NetworkError.cancelled }
            let retryCoordinator = RetryCoordinator(eventHub: eventHub, clock: executionRuntime.clock)
            return try await retryCoordinator.execute(
                retryPolicy: configuration.retryPolicy,
                networkMonitor: configuration.networkMonitor,
                requestID: requestID,
                eventObservers: configuration.eventObservers
            ) { retryIndex, requestID in
                try await RequestExecutor(session: session, eventHub: eventHub).execute(
                    executable,
                    configuration: configuration,
                    requestBuilder: requestBuilder,
                    runtime: executionRuntime,
                    retryIndex: retryIndex,
                    requestID: requestID
                )
            }
        }
        inFlight.register(id: requestID, tag: tag, generation: generation, cancelHandler: { work.cancel() })
        defer { inFlight.deregister(id: requestID) }
        startGate.open()

        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private var isShutdown: Bool {
        shutdownLock.withLock { $0 }
    }

    private func markShutdownIfNeeded() -> Bool {
        shutdownLock.withLock { state in
            guard !state else { return false }
            state = true
            return true
        }
    }
}

@_spi(GeneratedClientSupport) extension DefaultNetworkClient: LowLevelNetworkClient {}
