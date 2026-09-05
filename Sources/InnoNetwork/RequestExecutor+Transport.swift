import Foundation

// MARK: - Transport stage
//
// Owns the actual URLSession dispatch, body collection, circuit-breaker
// recording, and the response-body-limit enforcement helper. Custom
// policies and the surrounding pipeline live in `RequestExecutor+Pipeline`.

extension RequestExecutor {
    func enforceResponseBodyLimit(
        _ response: Response,
        configuration: NetworkConfiguration
    ) throws {
        try enforceResponseBodyLimit(data: response.data, configuration: configuration)
    }

    func enforceResponseBodyLimit(
        data: Data,
        configuration: NetworkConfiguration
    ) throws {
        guard let limit = configuration.responseBodyBufferingPolicy.maxBytes else { return }
        let observed = Int64(clamping: data.count)
        if observed > limit {
            throw NetworkError.underlying(
                SendableUnderlyingError(
                    domain: NetworkError.errorDomain,
                    code: NetworkErrorCode.responseBodyLimitExceeded.rawValue,
                    message: "Response body of \(observed) bytes exceeded the configured limit of \(limit) bytes."
                ),
                nil
            )
        }
    }

    func performTransport(
        request: URLRequest,
        identityRequest: URLRequest,
        bodySource: BodySource,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        runtime: RequestExecutionRuntime,
        requestID: UUID,
        allowsRequestCoalescing: Bool
    ) async throws -> Response {
        try await executeCustomPolicies(
            request: request,
            identityRequest: identityRequest,
            bodySource: bodySource,
            configuration: configuration,
            context: context,
            runtime: runtime,
            requestID: requestID,
            allowsRequestCoalescing: allowsRequestCoalescing
        )
    }

    func performTransportResult(
        request: URLRequest,
        identityRequest: URLRequest,
        bodySource: BodySource,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        runtime: RequestExecutionRuntime,
        allowsRequestCoalescing: Bool
    ) async throws -> TransportResult {
        let circuitProbe = try await runtime.circuitBreakers.prepare(
            request: identityRequest,
            policy: configuration.circuitBreakerPolicy
        )

        // `prepare()` may have returned ownership of a half-open probe. The
        // await on `refreshLaneIfInProgress` and
        // the coalescer dispatch below are both cancellation points; if the
        // outer task is cancelled before transport runs, no `recordX` would
        // fire and the probe slot would stay held until GC. Wrap the rest
        // of the path so any pre-transport cancellation releases the slot.
        //
        // `transportAndRecordCircuit` records its own cancellation after
        // transport. To avoid double-recording on the rethrow path, the
        // inner method wraps cancellation in `CircuitBreakerHandledError`
        // so the outer catch knows it has already been accounted for.
        do {
            // When a refresh is in flight, segregate this caller into its own
            // coalescer lane so a stale 401 from a peer's pre-refresh transport
            // cannot be delivered as our result. When `Authorization` is part
            // of the dedup key (the default policy), this is a no-op for
            // correctness but pins the invariant; under
            // ``RequestCoalescingPolicy/excludedHeaderNames`` containing
            // `Authorization` it is the actual safeguard.
            let refreshLane: UUID? = await refreshLaneIfInProgress(coordinator: runtime.refreshCoordinator)

            // A half-open probe is ownership of a real transport outcome. It
            // must not join a transport that started while the circuit was
            // closed because that older transport has no matching probe to
            // release or complete. Keep ordinary closed-state coalescing, but
            // give recovery probes their own physical dispatch.
            if circuitProbe == nil,
                allowsRequestCoalescing,
                case .inline = bodySource,
                let key = RequestDedupKey(
                    request: identityRequest,
                    policy: configuration.requestCoalescingPolicy,
                    refreshLane: refreshLane
                )
            {
                return try await runtime.requestCoalescer.run(key: key) {
                    try await self.transportAndRecordCircuit(
                        request: request,
                        identityRequest: identityRequest,
                        bodySource: bodySource,
                        configuration: configuration,
                        context: context,
                        runtime: runtime,
                        policy: configuration.circuitBreakerPolicy,
                        circuitProbe: circuitProbe
                    )
                }
            }

            return try await transportAndRecordCircuit(
                request: request,
                identityRequest: identityRequest,
                bodySource: bodySource,
                configuration: configuration,
                context: context,
                runtime: runtime,
                policy: configuration.circuitBreakerPolicy,
                circuitProbe: circuitProbe
            )
        } catch let handled as CircuitBreakerHandledError {
            // Inner already recorded (cancellation OR failure); just unwrap
            // and rethrow so callers (`RetryCoordinator`, public API,
            // `NetworkError.isCancellation`) never observe the sentinel.
            throw handled.underlying
        } catch {
            // The transport did not produce an outcome. Release only this
            // request's half-open probe for local admission/rate-limit
            // failures, coalescer errors, and cancellation alike.
            await runtime.circuitBreakers.abandon(circuitProbe)
            throw error
        }
    }

    func transportAndRecordCircuit(
        request: URLRequest,
        identityRequest: URLRequest,
        bodySource: BodySource,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        runtime: RequestExecutionRuntime,
        policy: CircuitBreakerPolicy?,
        circuitProbe: CircuitBreakerProbe?
    ) async throws -> TransportResult {
        let rateReservation: RateLimitReservation?
        do {
            rateReservation = try await runtime.rateLimit?.reserve(for: request)
            if let rateReservation {
                await eventHub.publish(
                    .decision(
                        NetworkDecision(
                            requestID: context.requestID,
                            attemptIndex: context.retryIndex,
                            kind: .rateLimit,
                            outcome: rateReservation.wasDelayed ? .delayed : .allowed,
                            reason: rateReservation.wasDelayed ? .localQuota : .policyAllowed
                        )
                    ),
                    requestID: context.requestID,
                    observers: context.eventObservers
                )
            }
        } catch RateLimitAdmissionFailure.queueFull {
            throw NetworkError.underlying(
                SendableUnderlyingError(
                    domain: NetworkError.errorDomain,
                    code: NetworkErrorCode.rateLimitQueueRejected.rawValue,
                    message: "The bounded rate-limit queue is full."
                ),
                nil
            )
        } catch RateLimitAdmissionFailure.scopeLimitReached {
            throw NetworkError.underlying(
                SendableUnderlyingError(
                    domain: NetworkError.errorDomain,
                    code: NetworkErrorCode.rateLimitScopeRejected.rawValue,
                    message: "The bounded rate-limit scope registry is full."
                ),
                nil
            )
        } catch RateLimitAdmissionFailure.invalidConfiguration(let message) {
            throw NetworkError.configuration(reason: .invalidRequest(message))
        }

        var admissionGrant: RequestAdmissionGrant?
        do {
            while true {
                admissionGrant = try await runtime.requestAdmission?.acquire(for: request)
                if let admissionGrant {
                    await eventHub.publish(
                        .decision(
                            NetworkDecision(
                                requestID: context.requestID,
                                attemptIndex: context.retryIndex,
                                kind: .admission,
                                outcome: admissionGrant.wasQueued ? .delayed : .allowed,
                                reason: .policyAllowed
                            )
                        ),
                        requestID: context.requestID,
                        observers: context.eventObservers
                    )
                }

                guard let rateReservation,
                    let dispatchWait = await runtime.rateLimit?.commit(rateReservation)
                else {
                    break
                }
                if let grant = admissionGrant {
                    await runtime.requestAdmission?.release(scope: grant.scope)
                    admissionGrant = nil
                }
                await eventHub.publish(
                    .decision(
                        NetworkDecision(
                            requestID: context.requestID,
                            attemptIndex: context.retryIndex,
                            kind: .rateLimit,
                            outcome: .delayed,
                            reason: .localQuota
                        )
                    ),
                    requestID: context.requestID,
                    observers: context.eventObservers
                )
                try await runtime.clock.sleep(for: dispatchWait)
            }
        } catch RequestAdmissionFailure.queueFull {
            if let rateReservation { await runtime.rateLimit?.refund(rateReservation) }
            await eventHub.publish(
                .decision(
                    NetworkDecision(
                        requestID: context.requestID,
                        attemptIndex: context.retryIndex,
                        kind: .admission,
                        outcome: .denied,
                        reason: .queueFull
                    )
                ),
                requestID: context.requestID,
                observers: context.eventObservers
            )
            throw NetworkError.underlying(
                SendableUnderlyingError(
                    domain: NetworkError.errorDomain,
                    code: NetworkErrorCode.requestAdmissionRejected.rawValue,
                    message: "The bounded request admission queue is full."
                ),
                nil
            )
        } catch RequestAdmissionFailure.queueWaitExpired {
            if let rateReservation { await runtime.rateLimit?.refund(rateReservation) }
            await eventHub.publish(
                .decision(
                    NetworkDecision(
                        requestID: context.requestID,
                        attemptIndex: context.retryIndex,
                        kind: .admission,
                        outcome: .denied,
                        reason: .queueWaitExpired
                    )
                ),
                requestID: context.requestID,
                observers: context.eventObservers
            )
            throw NetworkError.underlying(
                SendableUnderlyingError(
                    domain: NetworkError.errorDomain,
                    code: NetworkErrorCode.requestAdmissionWaitExpired.rawValue,
                    message: "The request admission wait expired before transport."
                ),
                nil
            )
        } catch {
            if let rateReservation { await runtime.rateLimit?.refund(rateReservation) }
            throw error
        }

        do {
            await eventHub.publish(
                .decision(
                    NetworkDecision(
                        requestID: context.requestID,
                        attemptIndex: context.retryIndex,
                        kind: .dispatch,
                        outcome: .allowed,
                        reason: .policyAllowed,
                        occurredAt: runtime.clock.now()
                    )
                ),
                requestID: context.requestID,
                observers: context.eventObservers
            )
            let result = try await transport(
                request: request,
                bodySource: bodySource,
                configuration: configuration,
                context: context
            )
            await runtime.circuitBreakers.recordStatus(
                request: identityRequest,
                policy: policy,
                statusCode: result.response.statusCode,
                probe: circuitProbe
            )
            if let admissionGrant {
                await runtime.requestAdmission?.release(scope: admissionGrant.scope)
            }
            if let rateReservation {
                await runtime.rateLimit?.observe(
                    response: result.response,
                    for: request,
                    reservation: rateReservation
                )
            }
            return result
        } catch {
            if let admissionGrant {
                await runtime.requestAdmission?.release(scope: admissionGrant.scope)
            }
            if let rateReservation {
                await runtime.rateLimit?.finish(rateReservation)
            }
            if NetworkError.isCancellation(error) {
                await runtime.circuitBreakers.abandon(circuitProbe)
            } else {
                await runtime.circuitBreakers.recordFailure(
                    request: identityRequest,
                    policy: policy,
                    error: error,
                    probe: circuitProbe
                )
            }
            // Tag the error so `runWithCircuitBreaker`'s outer catch knows
            // the circuit breaker has already been notified for this throw.
            throw CircuitBreakerHandledError(underlying: error)
        }
    }

    /// Internal sentinel that marks a thrown error as already accounted for
    /// by `transportAndRecordCircuit`. The outer wrapper unwraps it before
    /// returning to callers so the public throw shape is unchanged.
    fileprivate struct CircuitBreakerHandledError: Error {
        let underlying: Error
    }

    func transport(
        request: URLRequest,
        bodySource: BodySource,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext
    ) async throws -> TransportResult {
        let attemptStartedAt = Date()
        do {
            let (data, response): (Data, URLResponse)
            switch bodySource {
            case .inline:
                (data, response) = try await inlineData(for: request, configuration: configuration, context: context)
            case .file(let fileURL, _):
                (data, response) = try await fileUploadData(
                    for: request,
                    fromFile: fileURL,
                    configuration: configuration,
                    context: context
                )
            }

            try Task.checkCancellation()

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.underlying(
                    SendableUnderlyingError(
                        domain: NetworkError.errorDomain,
                        code: NetworkErrorCode.nonHTTPResponse.rawValue,
                        message:
                            "Received a non-HTTP response from \(NetworkError.diagnosticURLString(for: request.url)); response was \(type(of: response))."
                    ),
                    nil
                )
            }
            // Buffered transports (including explicitly buffered production
            // sessions) have already materialized the payload, but the limit
            // must still fail before response events, custom policy unwinding,
            // auth refresh, cache mutation, or circuit-breaker status updates.
            // Streaming collection enforces the same ceiling incrementally;
            // this shared boundary also protects buffered implementations.
            try enforceResponseBodyLimit(data: data, configuration: configuration)
            return TransportResult(data: data, response: httpResponse)
        } catch let networkError as NetworkError {
            // Already classified by an inner layer (e.g. responseBodyLimitExceeded
            // from `collect(bytes:response:maxBytes:)`). Rethrow as-is so the
            // task-interval contextual remap below cannot mis-attribute a
            // post-headers body-size failure as a transport timeout — the
            // bytes already arrived before the limit fired.
            throw networkError
        } catch {
            throw NetworkError.mapTransportError(
                error,
                startedAt: attemptStartedAt,
                endedAt: Date(),
                resourceTimeoutInterval: nil
            )
        }
    }

    func inlineData(
        for request: URLRequest,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext
    ) async throws -> (Data, URLResponse) {
        switch configuration.responseBodyBufferingPolicy {
        case .streaming(let maxBytes):
            // Prefer chunk-granular delivery: URLSession.AsyncBytes vends one
            // byte per resilience-boundary async call, which makes byte-wise
            // collection orders of magnitude slower than chunked delivery.
            // Custom consumer sessions without the package conformance keep
            // the byte-wise seam below.
            if let chunkedSession = session as? any ChunkedTransferSession {
                let normalizedLimit = maxBytes.map { max(0, $0) }
                // With no byte ceiling there is nothing to enforce while
                // receiving, and the producer-driven chunk stream has no
                // backpressure: a slow consumer could buffer a second copy
                // of an arbitrarily large body inside the stream. Unbounded
                // collection through the buffered transport holds exactly
                // one copy and keeps the same delegate-enforced redirect and
                // trust policy.
                guard let normalizedLimit else {
                    return try await session.data(for: request, context: context)
                }
                let transfer = try await chunkedSession.chunkedTransfer(
                    for: request,
                    context: context,
                    maxBytes: normalizedLimit
                )
                let data = try await collect(
                    transfer: transfer,
                    request: request,
                    maxBytes: normalizedLimit
                )
                return (data, transfer.response)
            }
            do {
                let (bytes, response) = try await session.bytes(for: request, context: context)
                let data = try await collect(
                    bytes: bytes,
                    response: response,
                    request: request,
                    maxBytes: maxBytes
                )
                return (data, response)
            } catch let error as NetworkError {
                switch error {
                case .configuration(reason: .invalidRequest):
                    // Falling back to a buffered transport silently bypasses
                    // the configured `maxBytes` ceiling, so honour the bound
                    // by surfacing the original error instead of collecting an
                    // unbounded body. The package's deterministic test-support
                    // sessions are the sole bounded exception: their payload is
                    // already an in-memory fixture and the executor enforces the
                    // same limit before caching, interceptors, or decoding.
                    let allowsBoundedBufferedFallback =
                        (session as? any BoundedBufferedTestSession)?.allowsBoundedBufferedFallback == true
                    guard maxBytes == nil || allowsBoundedBufferedFallback else {
                        throw error
                    }
                    let result = try await session.data(for: request, context: context)
                    // Test-support fixtures are already buffered, so enforce
                    // the configured ceiling immediately. This keeps an
                    // oversized fixture from reaching response events,
                    // execution policies, auth refresh, or cache side effects.
                    try enforceResponseBodyLimit(data: result.0, configuration: configuration)
                    return result
                default:
                    throw error
                }
            }
        case .buffered:
            return try await session.data(for: request, context: context)
        }
    }

    func fileUploadData(
        for request: URLRequest,
        fromFile fileURL: URL,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext
    ) async throws -> (Data, URLResponse) {
        guard let maxBytes = configuration.responseBodyBufferingPolicy.maxBytes else {
            // Preserve the existing upload-task behavior when the caller has
            // explicitly opted out of a response bound.
            return try await session.upload(for: request, fromFile: fileURL, context: context)
        }
        // Prefer chunk-granular response delivery for the same reason as
        // `inlineData`: byte-wise AsyncBytes collection pays a per-byte
        // resilience-boundary async call. The byte-wise seam remains the
        // fallback for custom package sessions.
        if let chunkedSession = session as? any ChunkedTransferSession {
            let transfer = try await chunkedSession.chunkedTransfer(
                for: request,
                uploadingFileAt: fileURL,
                context: context,
                maxBytes: maxBytes
            )
            let data = try await collect(
                transfer: transfer,
                request: request,
                maxBytes: maxBytes
            )
            return (data, transfer.response)
        }
        guard let boundedSession = session as? any BoundedFileUploadSession else {
            // A buffered fallback would collect an arbitrarily large response
            // before the executor could inspect it. Fail closed unless the
            // injected session explicitly supports bounded upload responses.
            throw NetworkError.configuration(
                reason: .invalidRequest(
                    "Bounded file-upload responses are not supported by this injected test transport."
                )
            )
        }

        let (bytes, response) = try await boundedSession.bytes(
            for: request,
            uploadingFileAt: fileURL,
            context: context
        )
        let data = try await collect(
            bytes: bytes,
            response: response,
            request: request,
            maxBytes: maxBytes
        )
        return (data, response)
    }

    func collect(
        bytes: URLSession.AsyncBytes,
        response: URLResponse,
        request: URLRequest,
        maxBytes: Int64?
    ) async throws -> Data {
        do {
            let normalizedLimit = maxBytes.map { max(0, $0) }
            // Redirect policies may intentionally rewrite the method. Body
            // semantics belong to the request that produced this response,
            // not the pre-redirect request originally passed to the executor.
            let responseRequest = bytes.task.currentRequest ?? request
            let responseMayCarryBody = Self.responseMayCarryBody(
                request: responseRequest,
                response: response
            )
            if let normalizedLimit,
                responseMayCarryBody,
                response.expectedContentLength > normalizedLimit
            {
                throw NetworkError.underlying(
                    SendableUnderlyingError(
                        domain: NetworkError.errorDomain,
                        code: NetworkErrorCode.responseBodyLimitExceeded.rawValue,
                        message:
                            "Response body of \(response.expectedContentLength) bytes exceeded the configured limit of \(normalizedLimit) bytes."
                    ),
                    nil
                )
            }

            var data = Data()
            if responseMayCarryBody, response.expectedContentLength > 0 {
                let expectedBytes =
                    normalizedLimit.map { min(response.expectedContentLength, $0) }
                    ?? response.expectedContentLength
                // Content-Length is remote input and only a capacity hint.
                // Keep unbounded collection semantically unbounded without
                // allowing an Int64.max-style header to force a giant eager
                // allocation before the first byte arrives.
                let safeReservationHint = min(expectedBytes, 1 * 1024 * 1024)
                data.reserveCapacity(Int(clamping: safeReservationHint))
            }
            for try await chunk in BufferedAsyncBytes(bytes, maxBytes: normalizedLimit) {
                data.append(contentsOf: chunk)
            }
            return data
        } catch {
            // Abandoning an AsyncBytes iterator is not a documented transport
            // cancellation boundary. Stop the underlying request explicitly
            // when a known Content-Length or streamed limit is exceeded (and
            // on caller cancellation) so the server cannot keep sending after
            // the API has already failed.
            bytes.task.cancel()
            throw error
        }
    }

    /// Chunk-granular twin of ``collect(bytes:response:request:maxBytes:)``.
    /// The transport bridge already enforces `maxBytes` incrementally while
    /// receiving; this consumer re-checks the Content-Length preflight and
    /// guards against returning a truncated body when the consuming task is
    /// cancelled mid-stream.
    func collect(
        transfer: ChunkedTransfer,
        request: URLRequest,
        maxBytes: Int64?
    ) async throws -> Data {
        do {
            let normalizedLimit = maxBytes.map { max(0, $0) }
            let response = transfer.response
            // Redirect policies may intentionally rewrite the method. Body
            // semantics belong to the request that produced this response,
            // not the pre-redirect request originally passed to the executor.
            let responseRequest = transfer.finalRequest ?? request
            let responseMayCarryBody = Self.responseMayCarryBody(
                request: responseRequest,
                response: response
            )
            if let normalizedLimit,
                responseMayCarryBody,
                response.expectedContentLength > normalizedLimit
            {
                throw NetworkError.underlying(
                    SendableUnderlyingError(
                        domain: NetworkError.errorDomain,
                        code: NetworkErrorCode.responseBodyLimitExceeded.rawValue,
                        message:
                            "Response body of \(response.expectedContentLength) bytes exceeded the configured limit of \(normalizedLimit) bytes."
                    ),
                    nil
                )
            }

            var data = Data()
            if responseMayCarryBody, response.expectedContentLength > 0 {
                let expectedBytes =
                    normalizedLimit.map { min(response.expectedContentLength, $0) }
                    ?? response.expectedContentLength
                // Content-Length is remote input and only a capacity hint.
                let safeReservationHint = min(expectedBytes, 1 * 1024 * 1024)
                data.reserveCapacity(Int(clamping: safeReservationHint))
            }
            for try await chunk in transfer.chunks {
                data.append(chunk)
            }
            // A cancelled consuming task ends the stream early without an
            // error; surfacing the partial body as success would hand a
            // truncated payload to interceptors and decoders.
            try Task.checkCancellation()
            return data
        } catch {
            // Abandoning the chunk stream is not a documented transport
            // cancellation boundary; stop the underlying request explicitly
            // so the server cannot keep sending after the API has failed.
            transfer.cancel()
            throw error
        }
    }

    /// `Content-Length` on HEAD, successful CONNECT, and RFC-defined no-body responses describes
    /// representation metadata rather than bytes that this request will
    /// receive. Skip only the header preflight for those responses; the actual
    /// AsyncBytes iterator still runs through `BufferedAsyncBytes` so a
    /// malformed peer that sends payload bytes remains bounded.
    static func responseMayCarryBody(request: URLRequest, response: URLResponse) -> Bool {
        let method = request.httpMethod
        if method == HTTPMethod.head.rawValue {
            return false
        }
        guard let httpResponse = response as? HTTPURLResponse else { return true }
        if method == HTTPMethod.connect.rawValue,
            (200..<300).contains(httpResponse.statusCode)
        {
            return false
        }
        switch httpResponse.statusCode {
        case 100..<200, 204, 205, 304:
            return false
        default:
            return true
        }
    }

    static func mapTransportError(
        _ error: Error,
        startedAt: Date?
    ) -> NetworkError {
        guard let startedAt else { return NetworkError.mapTransportError(error) }
        return NetworkError.mapTransportError(
            error,
            startedAt: startedAt,
            endedAt: Date(),
            resourceTimeoutInterval: nil
        )
    }
}
