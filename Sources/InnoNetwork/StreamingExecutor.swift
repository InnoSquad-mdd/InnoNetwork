import Foundation

/// Executes a ``StreamingAPIDefinition`` request as a long-lived line-delimited
/// stream. Owns per-attempt request preparation, line iteration, optional
/// Last-Event-ID resume, response interceptor application, and lifecycle event
/// publication so ``DefaultNetworkClient/stream(_:)`` stays a thin sequence
/// factory.
///
/// The body of ``run(request:requestID:configuration:executionRuntime:sink:)``
/// preserves the same observable sequence the inline `stream(_:)` body emitted
/// before extraction:
///
/// 1. `requestStart` event
/// 2. session-level then per-endpoint request interceptors, then
///    `RefreshTokenPolicy.applyCurrentToken`
/// 3. `requestAdapted` event
/// 4. transport `bytes(for:context:)` call
/// 5. `responseReceived` event
/// 6. session-level response interceptors (the `Response.data` is intentionally
///    empty because stream contents are decoded line-by-line)
/// 7. acceptable status code validation with optional retry-policy handling
///    before any stream body bytes are consumed
/// 8. line iteration with `decode(line:)` and event id tracking
/// 9. resume decision when the iterator throws mid-stream
/// 10. `requestFinished` on clean completion or `requestFailed` on terminal error
package struct StreamingExecutor: Sendable {
    package let session: URLSessionProtocol
    package let eventHub: NetworkEventHub

    package init(session: URLSessionProtocol, eventHub: NetworkEventHub) {
        self.session = session
        self.eventHub = eventHub
    }

    package func run<T: StreamingAPIDefinition>(
        request: T,
        requestID: UUID,
        configuration: NetworkConfiguration,
        executionRuntime: RequestExecutionRuntime,
        sink: StreamingOutputSink<T.Output>
    ) async {
        let resumePolicy = request.resumePolicy
        let timeoutPolicy = request.timeoutPolicy
        let logicalStart = executionRuntime.clock.monotonicNow()
        do {
            try Self.validateSessionAuthentication(request, configuration: configuration)
            try resumePolicy.validate()
        } catch {
            let mapped = Self.mapTransportError(error, startedAt: nil)
            let nsError = mapped as NSError
            await eventHub.publish(
                .requestFailed(
                    requestID: requestID,
                    errorCode: nsError.code,
                    message: mapped.observabilityCategory
                ),
                requestID: requestID,
                observers: configuration.eventObservers
            )
            await eventHub.finish(requestID: requestID)
            sink.finish(throwing: mapped)
            return
        }

        let resumeBudget = resumePolicy.maxAttempts
        var resumeState = StreamingResumeState()
        var resumeAttempts = 0
        var handshakeRetryState = StreamingHandshakeRetryState(
            snapshot: await configuration.networkMonitor?.currentSnapshot()
        )

        while true {
            do {
                let attemptRetryIndex = resumeAttempts + handshakeRetryState.retryIndex
                let attemptResult = try await runAttempt(
                    request: request,
                    requestID: requestID,
                    configuration: configuration,
                    executionRuntime: executionRuntime,
                    resumeState: &resumeState,
                    retryIndex: attemptRetryIndex,
                    resumePolicy: resumePolicy,
                    timeoutPolicy: timeoutPolicy,
                    logicalStart: logicalStart,
                    isResuming: resumeAttempts > 0,
                    sink: sink
                )

                switch attemptResult {
                case .transportFailure(let streamError, let attemptStartedAt):
                    // Mid-stream transport disconnect. Resume only when:
                    // - resume policy is active
                    // - attempt budget remains
                    // - this attempt observed a safe cursor (empty cursor
                    //   explicitly resets Last-Event-ID)
                    let hasBudget = resumeAttempts < resumeBudget
                    let canResume = resumeState.canResume(
                        maxAttempts: resumeBudget,
                        completedResumeAttempts: resumeAttempts
                    ) || (resumePolicy.permitsCursorlessReconnect && hasBudget)
                    if canResume && Self.isResumableTransportError(streamError) {
                        resumeAttempts += 1
                        let reconnectDelay = resumeState.serverRetryDelay ?? resumePolicy.retryDelay
                        try await withStreamingTimeout(
                            phase: .total,
                            phaseBudget: nil,
                            totalBudget: timeoutPolicy.total,
                            logicalStart: logicalStart,
                            clock: executionRuntime.clock
                        ) {
                            try await Self.waitBeforeResume(
                                delay: reconnectDelay,
                                executionRuntime: executionRuntime
                            )
                        }
                        try Task.checkCancellation()
                        continue
                    }
                    throw StreamingAttemptFailure(error: streamError, startedAt: attemptStartedAt)

                case .completed(let networkResponse, let streamedByteCount):
                    if resumePolicy.reconnectsAfterEOF,
                        resumeAttempts < resumeBudget
                    {
                        resumeAttempts += 1
                        let reconnectDelay = resumeState.serverRetryDelay ?? resumePolicy.retryDelay
                        try await withStreamingTimeout(
                            phase: .total,
                            phaseBudget: nil,
                            totalBudget: timeoutPolicy.total,
                            logicalStart: logicalStart,
                            clock: executionRuntime.clock
                        ) {
                            try await Self.waitBeforeResume(
                                delay: reconnectDelay,
                                executionRuntime: executionRuntime
                            )
                        }
                        continue
                    }
                    // Stream completed cleanly.
                    await eventHub.publish(
                        .requestFinished(
                            requestID: requestID,
                            statusCode: networkResponse.statusCode,
                            byteCount: streamedByteCount
                        ),
                        requestID: requestID,
                        observers: configuration.eventObservers
                    )
                    await eventHub.finish(requestID: requestID)
                    sink.finish()
                    return
                }
            } catch {
                let failure = error as? StreamingAttemptFailure
                do {
                    if let failure,
                        try await retryHandshakeIfNeeded(
                            failure,
                            state: &handshakeRetryState,
                            configuration: configuration,
                            executionRuntime: executionRuntime,
                            requestID: requestID,
                            timeoutPolicy: timeoutPolicy,
                            logicalStart: logicalStart
                        )
                    {
                        continue
                    }
                } catch {
                    let mapped = Self.mapTransportError(
                        error,
                        startedAt: failure?.startedAt
                    )
                    let surfaced = configuration.captureFailurePayload ? mapped : mapped.redactingFailurePayload()
                    let nsError = surfaced as NSError
                    await eventHub.publish(
                        .requestFailed(
                            requestID: requestID,
                            errorCode: nsError.code,
                            message: surfaced.observabilityCategory
                        ),
                        requestID: requestID,
                        observers: configuration.eventObservers
                    )
                    await eventHub.finish(requestID: requestID)
                    sink.finish(throwing: surfaced)
                    return
                }

                let mapped = Self.mapTransportError(
                    failure?.error ?? error,
                    startedAt: failure?.startedAt
                )
                let surfaced = configuration.captureFailurePayload ? mapped : mapped.redactingFailurePayload()
                let nsError = surfaced as NSError
                await eventHub.publish(
                    .requestFailed(
                        requestID: requestID,
                        errorCode: nsError.code,
                        message: surfaced.observabilityCategory
                    ),
                    requestID: requestID,
                    observers: configuration.eventObservers
                )
                await eventHub.finish(requestID: requestID)
                sink.finish(throwing: surfaced)
                return
            }
        }
    }

    // MARK: - Helpers

    private static func validateSessionAuthentication<T: StreamingAPIDefinition>(
        _ request: T,
        configuration: NetworkConfiguration
    ) throws {
        guard request.sessionAuthentication == .required,
            configuration.refreshTokenPolicy == nil
        else {
            return
        }
        throw NetworkError.configuration(
            reason: .invalidRequest(
                "Session-auth-required endpoints require NetworkConfiguration.refreshTokenPolicy."
            )
        )
    }

    private func runAttempt<T: StreamingAPIDefinition>(
        request: T,
        requestID: UUID,
        configuration: NetworkConfiguration,
        executionRuntime: RequestExecutionRuntime,
        resumeState: inout StreamingResumeState,
        retryIndex: Int,
        resumePolicy: StreamingResumePolicy,
        timeoutPolicy: StreamingTimeoutPolicy,
        logicalStart: Duration,
        isResuming: Bool,
        sink: StreamingOutputSink<T.Output>
    ) async throws -> StreamingAttemptResult {
        var attemptStartedAt: Date?
        var retryRequest: URLRequest?
        do {
            try Task.checkCancellation()
            resumeState.beginAttempt()
            var urlRequest = try Self.makeURLRequest(
                for: request,
                configuration: configuration,
                lastSeenEventID: resumeState.lastSeenEventID,
                resumeHeader: resumePolicy.headerName,
                isResuming: isResuming
            )
            retryRequest = urlRequest

            await eventHub.publish(
                .requestStart(
                    requestID: requestID,
                    method: urlRequest.httpMethod ?? "UNKNOWN",
                    url: NetworkURLMetadataRedactor.string(from: urlRequest.url),
                    retryIndex: retryIndex
                ),
                requestID: requestID,
                observers: configuration.eventObservers
            )

            urlRequest = try await applyRequestInterceptors(
                urlRequest,
                sessionInterceptors: configuration.requestInterceptors,
                endpointInterceptors: request.requestInterceptors,
                sessionSigners: configuration.requestSigners,
                endpointSigners: request.requestSigners,
                sessionAuthentication: request.sessionAuthentication,
                refreshCoordinator: executionRuntime.refreshCoordinator
            )
            retryRequest = urlRequest

            // Streaming applies endpoint/session interceptors, auth tokens,
            // and signing headers in one stage. Validate the resulting
            // request before publishing it as adapted or opening URLSession
            // bytes so no adapter can bypass the builder's URL policy.
            try NetworkURLAdmission.validate(
                urlRequest,
                policy: .http(allowsInsecure: configuration.allowsInsecureHTTP)
            )

            await eventHub.publish(
                .requestAdapted(
                    requestID: requestID,
                    method: urlRequest.httpMethod ?? "UNKNOWN",
                    url: NetworkURLMetadataRedactor.string(from: urlRequest.url),
                    retryIndex: retryIndex
                ),
                requestID: requestID,
                observers: configuration.eventObservers
            )

            let baseContext = NetworkRequestContext(
                requestID: requestID,
                retryIndex: retryIndex,
                metricsReporter: configuration.metricsReporter,
                trustPolicy: configuration.trustPolicy,
                eventObservers: configuration.eventObservers,
                redirectPolicy: configuration.redirectPolicy,
                allowsInsecureHTTP: configuration.allowsInsecureHTTP,
                allowsAutomaticRedirects: resumePolicy.headerName == nil,
                allowsURLCacheStorage: true
            )
            let hasRequestSigners =
                !configuration.requestSigners.isEmpty || !request.requestSigners.isEmpty
            let context =
                hasRequestSigners ? baseContext.restrictingSignedRequestSharing() : baseContext
            let transportRequest = urlRequest
            attemptStartedAt = Date()
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await withStreamingTimeout(
                    phase: .firstResponse,
                    phaseBudget: timeoutPolicy.firstResponse,
                    totalBudget: timeoutPolicy.total,
                    logicalStart: logicalStart,
                    clock: executionRuntime.clock
                ) {
                    try await session.bytes(for: transportRequest, context: context)
                }
            } catch {
                throw StreamingAttemptFailure(
                    error: error,
                    startedAt: attemptStartedAt,
                    phase: .handshake,
                    request: retryRequest
                )
            }
            // Stop rejected handshakes and abandoned/erroring decoders too.
            // Receiving headers does not mean the response body has completed.
            defer { bytes.task.cancel() }
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.underlying(
                    SendableUnderlyingError(
                        domain: NetworkError.errorDomain,
                        code: NetworkErrorCode.nonHTTPResponse.rawValue,
                        message:
                            "Received a non-HTTP response on streaming request to \(NetworkError.diagnosticURLString(for: urlRequest.url)); response was \(type(of: response))."
                    ),
                    nil
                )
            }
            await eventHub.publish(
                .responseReceived(
                    requestID: requestID,
                    statusCode: httpResponse.statusCode,
                    byteCount: 0
                ),
                requestID: requestID,
                observers: configuration.eventObservers
            )

            var networkResponse = Response(
                statusCode: httpResponse.statusCode,
                data: Data(),
                request: urlRequest,
                response: httpResponse,
                kind: .headersOnly
            )
            for interceptor in configuration.responseInterceptors {
                networkResponse = try await interceptor.adapt(networkResponse, request: urlRequest)
            }

            let acceptable = request.acceptableStatusCodes ?? configuration.acceptableStatusCodes
            guard acceptable.contains(networkResponse.statusCode) else {
                // Handshake failure: surface the status before consuming body
                // bytes so the outer loop can consult RetryPolicy without
                // mixing this budget with Last-Event-ID resume.
                throw StreamingAttemptFailure(
                    error: NetworkError.statusCode(networkResponse),
                    startedAt: attemptStartedAt,
                    phase: .handshake,
                    request: urlRequest
                )
            }

            let streamingLineByteLimit = max(1, configuration.streamingLineByteLimit)
            return try await consumeAttemptBytes(
                bytes,
                request: request,
                networkResponse: networkResponse,
                httpResponse: httpResponse,
                maxLineBytes: streamingLineByteLimit,
                resumeState: &resumeState,
                attemptStartedAt: attemptStartedAt,
                timeoutPolicy: timeoutPolicy,
                logicalStart: logicalStart,
                clock: executionRuntime.clock,
                sink: sink
            )
        } catch let failure as StreamingAttemptFailure {
            throw failure
        } catch {
            throw StreamingAttemptFailure(error: error, startedAt: attemptStartedAt)
        }
    }

    private func consumeAttemptBytes<T: StreamingAPIDefinition>(
        _ bytes: URLSession.AsyncBytes,
        request: T,
        networkResponse: Response,
        httpResponse: HTTPURLResponse,
        maxLineBytes: Int,
        resumeState: inout StreamingResumeState,
        attemptStartedAt: Date?,
        timeoutPolicy: StreamingTimeoutPolicy,
        logicalStart: Duration,
        clock: any InnoNetworkClock,
        sink: StreamingOutputSink<T.Output>
    ) async throws -> StreamingAttemptResult {
        var streamedByteCount = 0
        var iterator = bytes.makeAsyncIterator()
        var skipsLeadingLF = false
        let decode = request.makeFrameDecoder()
        let watchdog = StreamingTimeoutWatchdog(
            policy: timeoutPolicy,
            logicalStart: logicalStart,
            clock: clock,
            cancelTransport: { bytes.task.cancel() }
        )
        defer { watchdog.finish() }
        while true {
            let frame: BoundedStreamLine?
            do {
                frame = try await Self.nextBoundedLine(
                    from: &iterator,
                    skipsLeadingLF: &skipsLeadingLF,
                    maxBytes: maxLineBytes,
                    onActivity: { watchdog.recordNetworkActivity() }
                )
            } catch is CancellationError {
                throw NetworkError.cancelled
            } catch let error as StreamingLineTooLargeError {
                throw Self.streamFrameTooLargeError(
                    byteCount: error.byteCount,
                    maxBytes: maxLineBytes,
                    networkResponse: networkResponse,
                    fallbackResponse: httpResponse
                )
            } catch {
                if let timeout = watchdog.timeoutError { throw timeout }
                return .transportFailure(error, attemptStartedAt)
            }

            guard let frame else {
                return .completed(networkResponse, streamedByteCount)
            }
            let line = frame.line
            try Task.checkCancellation()
            streamedByteCount += frame.byteCount
            let decoded: StreamingDecodedFrame<T.Output>
            do {
                decoded = try decode(line)
            } catch {
                throw NetworkError.decoding(
                    stage: .streamFrame,
                    underlying: SendableUnderlyingError(error),
                    response: Response(
                        statusCode: networkResponse.statusCode,
                        data: Data(line.utf8),
                        request: networkResponse.request,
                        response: networkResponse.response ?? httpResponse
                    )
                )
            }
            switch decoded.control.cursor {
            case .unchanged:
                break
            case .clear:
                resumeState.observe(eventID: "")
            case .set(let eventID):
                if Self.isValidLastEventIDCursor(eventID) {
                    resumeState.observe(eventID: eventID)
                } else {
                    resumeState.rejectEventID()
                }
            }
            resumeState.observe(retryDelay: decoded.control.retryDelay)

            if let output = decoded.output {
                watchdog.recordFirstEvent()
                try await withStreamingTimeout(
                    phase: .total,
                    phaseBudget: nil,
                    totalBudget: timeoutPolicy.total,
                    logicalStart: logicalStart,
                    clock: clock
                ) {
                    try await sink.yield(output)
                }
            }
        }
    }

    package static func waitBeforeResume(
        delay: TimeInterval,
        executionRuntime: RequestExecutionRuntime
    ) async throws {
        guard delay > 0 else { return }
        try await executionRuntime.clock.sleep(for: .seconds(delay))
    }

    package static func isResumableTransportError(_ error: Error) -> Bool {
        switch NetworkError.mapTransportError(error) {
        case .timeout, .reachability: true
        default: false
        }
    }

    private func retryHandshakeIfNeeded(
        _ failure: StreamingAttemptFailure,
        state: inout StreamingHandshakeRetryState,
        configuration: NetworkConfiguration,
        executionRuntime: RequestExecutionRuntime,
        requestID: UUID,
        timeoutPolicy: StreamingTimeoutPolicy,
        logicalStart: Duration
    ) async throws -> Bool {
        guard failure.phase == .handshake,
            let policy = configuration.retryPolicy
        else {
            return false
        }

        let networkError = Self.mapTransportError(failure.error, startedAt: failure.startedAt)
        let request = networkError.underlyingRequest ?? failure.request
        let decision = policy.shouldRetry(
            error: networkError,
            retryIndex: state.retryIndex,
            request: request,
            response: networkError.underlyingHTTPResponse
        )
        if case .noRetry = decision {
            return false
        }
        guard state.totalRetries < policy.maxTotalRetries else {
            return false
        }

        let computedDelay = policy.retryDelay(for: state.retryIndex)
        let delay = Self.retryDelay(
            for: decision,
            computedDelay: computedDelay,
            policy: policy
        )
        await eventHub.publish(
            .retryScheduled(
                requestID: requestID,
                retryIndex: state.retryIndex,
                delay: delay,
                reason: networkError.observabilityCategory
            ),
            requestID: requestID,
            observers: configuration.eventObservers
        )

        var nextRetryIndex = state.retryIndex + 1
        var nextSnapshot = state.snapshot
        if policy.waitsForNetworkChanges, let monitor = configuration.networkMonitor {
            let newSnapshot = await monitor.waitForChange(
                from: nextSnapshot,
                timeout: policy.networkChangeTimeout
            )
            if policy.shouldResetAttempts(afterNetworkChangeFrom: nextSnapshot, to: newSnapshot) {
                nextRetryIndex = 0
            }
            if let newSnapshot {
                nextSnapshot = newSnapshot
            } else {
                nextSnapshot = await monitor.currentSnapshot() ?? nextSnapshot
            }
        }

        try await withStreamingTimeout(
            phase: .total,
            phaseBudget: nil,
            totalBudget: timeoutPolicy.total,
            logicalStart: logicalStart,
            clock: executionRuntime.clock
        ) {
            guard delay > 0 else { return }
            try await executionRuntime.clock.sleep(for: .seconds(delay))
        }

        state.retryIndex = nextRetryIndex
        state.totalRetries += 1
        state.snapshot = nextSnapshot
        try Task.checkCancellation()
        return true
    }

    private static func retryDelay(
        for decision: RetryDecision,
        computedDelay: TimeInterval,
        policy: RetryPolicy
    ) -> TimeInterval {
        switch decision {
        case .noRetry, .retry:
            return computedDelay
        case .retryAfter(let serverHint):
            let hintedDelay = max(serverHint, computedDelay)
            if let maxRetryAfterDelay = policy.maxRetryAfterDelay {
                return min(hintedDelay, max(maxRetryAfterDelay, computedDelay))
            }
            return hintedDelay
        }
    }

    private static func nextBoundedLine<Iterator: AsyncIteratorProtocol>(
        from iterator: inout Iterator,
        skipsLeadingLF: inout Bool,
        maxBytes: Int,
        onActivity: () -> Void = {}
    ) async throws -> BoundedStreamLine? where Iterator.Element == UInt8 {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(min(maxBytes, 4 * 1024))

        while let byte = try await iterator.next() {
            onActivity()
            if skipsLeadingLF {
                skipsLeadingLF = false
                if byte == 0x0A { continue }
            }
            if byte == 0x0A || byte == 0x0D {
                skipsLeadingLF = byte == 0x0D
                return BoundedStreamLine(
                    line: String(decoding: bytes, as: UTF8.self),
                    byteCount: bytes.count
                )
            }

            bytes.append(byte)
            if bytes.count > maxBytes {
                throw StreamingLineTooLargeError(byteCount: bytes.count)
            }
        }

        guard !bytes.isEmpty else { return nil }
        return BoundedStreamLine(
            line: String(decoding: bytes, as: UTF8.self),
            byteCount: bytes.count
        )
    }

    private func withStreamingTimeout<Value: Sendable>(
        phase: StreamingTimeoutPhase,
        phaseBudget: Duration?,
        totalBudget: Duration?,
        logicalStart: Duration,
        clock: any InnoNetworkClock,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        var budgets: [(Duration, StreamingTimeoutPhase)] = []
        if let phaseBudget { budgets.append((phaseBudget, phase)) }
        if let totalBudget {
            let remaining = logicalStart + totalBudget - clock.monotonicNow()
            budgets.append((max(.zero, remaining), .total))
        }
        guard let selected = budgets.min(by: { $0.0 < $1.0 }) else {
            return try await operation()
        }
        guard selected.0 > .zero else { throw selected.1.error }

        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await clock.sleep(for: selected.0)
                throw selected.1.error
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw NetworkError.cancelled }
            return value
        }
    }

    private static func streamFrameTooLargeError(
        byteCount: Int,
        maxBytes: Int,
        networkResponse: Response,
        fallbackResponse: HTTPURLResponse
    ) -> NetworkError {
        NetworkError.decoding(
            stage: .streamFrame,
            underlying: SendableUnderlyingError(
                domain: NetworkError.errorDomain,
                code: NetworkErrorCode.streamFrameTooLarge.rawValue,
                message:
                    "Streaming line exceeded \(maxBytes) bytes (saw \(byteCount))."
            ),
            response: Response(
                statusCode: networkResponse.statusCode,
                data: Data(),
                request: networkResponse.request,
                response: networkResponse.response ?? fallbackResponse,
                kind: .headersOnly
            )
        )
    }

    private static func makeURLRequest<T: StreamingAPIDefinition>(
        for request: T,
        configuration: NetworkConfiguration,
        lastSeenEventID: String?,
        resumeHeader: String?,
        isResuming: Bool
    ) throws -> URLRequest {
        let url = try EndpointPathBuilder.makeURL(
            baseURL: configuration.baseURL,
            endpointPath: request.path,
            allowsInsecureHTTP: configuration.allowsInsecureHTTP
        )
        var urlRequest = URLRequest(url: url)
        try RequestBuilder.assign(request.method, to: &urlRequest)
        urlRequest.headers = request.headers
        urlRequest.cachePolicy = configuration.cachePolicy
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.networkServiceType = configuration.requestPriority.networkServiceType
        urlRequest.allowsCellularAccess = configuration.allowsCellularAccess
        urlRequest.allowsExpensiveNetworkAccess = configuration.allowsExpensiveNetworkAccess
        urlRequest.allowsConstrainedNetworkAccess = configuration.allowsConstrainedNetworkAccess
        if isResuming, let resumeHeader {
            // Also removes a caller's initial header after an explicit reset.
            let value = lastSeenEventID.flatMap { Self.isValidLastEventIDHeaderValue($0) ? $0 : nil }
            urlRequest.setValue(value, forHTTPHeaderField: resumeHeader)
        }
        return urlRequest
    }

    private static func isValidLastEventIDCursor(_ value: String) -> Bool {
        value.utf8.count <= 4096 && value.unicodeScalars.allSatisfy { scalar in
            (0x20...0x7E).contains(scalar.value)
        }
    }

    private static func isValidLastEventIDHeaderValue(_ value: String) -> Bool {
        guard value.isEmpty == false else { return false }
        return isValidLastEventIDCursor(value)
    }

    private func applyRequestInterceptors(
        _ urlRequest: URLRequest,
        sessionInterceptors: [RequestInterceptor],
        endpointInterceptors: [RequestInterceptor],
        sessionSigners: [RequestSigner],
        endpointSigners: [RequestSigner],
        sessionAuthentication: SessionAuthentication,
        refreshCoordinator: RefreshTokenCoordinator?
    ) async throws -> URLRequest {
        var current = urlRequest
        for interceptor in sessionInterceptors {
            current = try await interceptor.adapt(current)
        }
        for interceptor in endpointInterceptors {
            current = try await interceptor.adapt(current)
        }
        switch sessionAuthentication {
        case .anonymous:
            break
        case .optional:
            if let refreshCoordinator {
                current = try await refreshCoordinator.applyCurrentToken(to: current)
            }
        case .required:
            guard let refreshCoordinator else {
                throw NetworkError.configuration(
                    reason: .invalidRequest(
                        "Session-auth-required endpoints require NetworkConfiguration.refreshTokenPolicy."
                    )
                )
            }
            current = try await refreshCoordinator.applyRequiredTokenWithGeneration(to: current).request
        }
        guard !sessionSigners.isEmpty || !endpointSigners.isEmpty else {
            return current
        }
        current = current.preparingForSignedTransport()
        let body = try BodySource.inline.signingBody(for: current)
        for signer in sessionSigners {
            let headers = try await signer.signatureHeaders(for: current, body: body)
            Self.apply(headers: headers, to: &current)
        }
        for signer in endpointSigners {
            let headers = try await signer.signatureHeaders(for: current, body: body)
            Self.apply(headers: headers, to: &current)
        }
        return current
    }

    private static func apply(headers: HTTPHeaders, to request: inout URLRequest) {
        for header in headers {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
    }

    private static func mapTransportError(
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

private struct BoundedStreamLine {
    let line: String
    let byteCount: Int
}

private struct StreamingHandshakeRetryState {
    var retryIndex = 0
    var totalRetries = 0
    var snapshot: NetworkSnapshot?
}

private enum StreamingAttemptResult {
    case completed(Response, Int)
    case transportFailure(Error, Date?)
}

private struct StreamingAttemptFailure: Error {
    enum Phase {
        case handshake
        case body
    }

    let error: Error
    let startedAt: Date?
    let phase: Phase
    let request: URLRequest?

    init(
        error: Error,
        startedAt: Date?,
        phase: Phase,
        request: URLRequest?
    ) {
        self.error = error
        self.startedAt = startedAt
        self.phase = phase
        self.request = request
    }

    init(error: Error, startedAt: Date?) {
        self.init(error: error, startedAt: startedAt, phase: .body, request: nil)
    }
}

private struct StreamingLineTooLargeError: Error {
    let byteCount: Int
}
