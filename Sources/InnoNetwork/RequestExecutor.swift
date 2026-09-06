import Foundation
import OSLog

/// Conditional revalidation product used by the cache stage when a 304 is
/// received. Carries both a merged-headers `Response` (for storage when the
/// `Vary` dimension matches) and a preserved-headers `Response` (for return
/// when the `Vary` dimension changes), plus the original cached entry.
struct NotModifiedSubstitution {
    let mergedResponse: Response
    let preservedResponse: Response
    let cached: CachedResponse
}

/// Cached snapshot that produced conditional request headers for the
/// transport attempt. A later 304 is valid only while this entry still
/// exists; otherwise the executor has no representation to substitute.
struct ConditionalRevalidationContext {
    let cached: CachedResponse
}

private struct PreparedExecutionRequest {
    var request: URLRequest
    let refreshGeneration: UInt64?
    let refreshCoordinator: RefreshTokenCoordinator?
    let bodySource: BodySource
    let requestSigners: [RequestSigner]
    let cleanupFileURL: URL?
    let context: NetworkRequestContext
}

/// Per-request execution coordinator.
///
/// The struct itself only owns the URLSession transport and event hub
/// references plus the `execute(...)` entrypoint. The rest of the pipeline
/// — auth-scope validation, the cache stage, the transport stage, the
/// custom-policy chain, and the event-publication shims — lives in three
/// adjacent extension files (`RequestExecutor+Pipeline.swift`,
/// `RequestExecutor+Cache.swift`, `RequestExecutor+Transport.swift`).
package struct RequestExecutor {
    let session: URLSessionProtocol
    let eventHub: NetworkEventHub

    package init(session: URLSessionProtocol, eventHub: NetworkEventHub) {
        self.session = session
        self.eventHub = eventHub
    }

    package func execute<D: SingleRequestExecutable>(
        _ executable: D,
        configuration: NetworkConfiguration,
        requestBuilder: RequestBuilder,
        runtime: RequestExecutionRuntime,
        retryIndex: Int,
        requestID: UUID
    ) async throws -> D.APIResponse {
        try Task.checkCancellation()

        var retryRequest: URLRequest?
        var attemptStartedAt: Date?
        var preparedForRecovery: PreparedExecutionRequest?
        do {
            let prepared = try await prepareRequestStage(
                executable,
                configuration: configuration,
                requestBuilder: requestBuilder,
                runtime: runtime,
                retryIndex: retryIndex,
                requestID: requestID
            )
            preparedForRecovery = prepared
            defer {
                if let cleanupFileURL = prepared.cleanupFileURL {
                    try? FileManager.default.removeItem(at: cleanupFileURL)
                }
            }
            retryRequest = prepared.request
            attemptStartedAt = runtime.clock.now()
            let networkResponse = try await responseStage(
                executable,
                prepared: prepared,
                configuration: configuration,
                runtime: runtime,
                requestID: requestID
            )
            let decoded = try await decodeStage(
                executable,
                response: networkResponse,
                configuration: configuration
            )
            await notifySuccess(
                networkResponse,
                requestID: requestID,
                configuration: configuration
            )
            return decoded
        } catch let recovery as StaleIfErrorRecovery {
            let surfaced =
                configuration.captureFailurePayload
                ? recovery.failure
                : recovery.failure.redactingFailurePayload()
            executable.logger.log(error: surfaced)
            guard let prepared = preparedForRecovery else {
                throw RequestExecutionFailure(
                    error: surfaced,
                    request: retryRequest ?? surfaced.underlyingRequest
                )
            }
            let executor = self
            let recoveryAttemptStartedAt = attemptStartedAt
            throw RequestExecutionFailureWithFallback(
                error: surfaced,
                request: retryRequest ?? surfaced.underlyingRequest
            ) {
                do {
                    let recoveredResponse = try await executor.finalizeResponseStage(
                        executable,
                        networkResponse: recovery.fallback,
                        prepared: prepared,
                        configuration: configuration
                    )
                    let decoded = try await executor.decodeStage(
                        executable,
                        response: recoveredResponse,
                        configuration: configuration
                    )
                    await executor.notifySuccess(
                        recoveredResponse,
                        requestID: requestID,
                        configuration: configuration
                    )
                    return decoded
                } catch let error as NetworkError {
                    let fallbackFailure =
                        configuration.captureFailurePayload
                        ? error
                        : error.redactingFailurePayload()
                    executable.logger.log(error: fallbackFailure)
                    throw fallbackFailure
                } catch {
                    let mapped = Self.mapTransportError(error, startedAt: recoveryAttemptStartedAt)
                    let fallbackFailure =
                        configuration.captureFailurePayload
                        ? mapped
                        : mapped.redactingFailurePayload()
                    executable.logger.log(error: fallbackFailure)
                    throw fallbackFailure
                }
            }
        } catch let error as NetworkError {
            let surfaced = configuration.captureFailurePayload ? error : error.redactingFailurePayload()
            executable.logger.log(error: surfaced)
            throw RequestExecutionFailure(error: surfaced, request: retryRequest ?? surfaced.underlyingRequest)
        } catch {
            let mapped = Self.mapTransportError(
                error,
                startedAt: attemptStartedAt
            )
            let surfaced = configuration.captureFailurePayload ? mapped : mapped.redactingFailurePayload()
            executable.logger.log(error: surfaced)
            throw RequestExecutionFailure(error: surfaced, request: retryRequest ?? surfaced.underlyingRequest)
        }
    }

    @inline(__always)
    private func prepareRequestStage<D: SingleRequestExecutable>(
        _ executable: D,
        configuration: NetworkConfiguration,
        requestBuilder: RequestBuilder,
        runtime: RequestExecutionRuntime,
        retryIndex: Int,
        requestID: UUID
    ) async throws -> PreparedExecutionRequest {
        NetworkOperationDeadlineContext.mark(.requestPreparation)
        try validateSessionAuthentication(executable, configuration: configuration)
        let built = try requestBuilder.build(executable, configuration: configuration)
        var request = built.request
        let cleanupFileURL: URL?
        if case .file(let fileURL, cleanupAfterUse: true) = built.bodySource {
            cleanupFileURL = fileURL
        } else {
            cleanupFileURL = nil
        }
        do {
            configuration.idempotencyKeyPolicy.apply(to: &request, requestID: requestID)
            await notifyRequestStart(
                request, retryIndex: retryIndex, requestID: requestID, configuration: configuration)

            // Onion model: session-level interceptors run first (outer), then
            // per-request interceptors (inner). Cross-cutting concerns declared on
            // NetworkConfiguration apply to every endpoint; per-APIDefinition
            // interceptors layer on top.
            for interceptor in configuration.requestInterceptors {
                try Task.checkCancellation()
                request = try await interceptor.adapt(request)
                try Task.checkCancellation()
            }
            for interceptor in executable.requestInterceptors {
                try Task.checkCancellation()
                request = try await interceptor.adapt(request)
                try Task.checkCancellation()
            }
            let refreshCoordinator: RefreshTokenCoordinator?
            let refreshGeneration: UInt64?
            switch executable.sessionAuthentication {
            case .anonymous:
                refreshCoordinator = nil
                refreshGeneration = nil
            case .optional:
                NetworkOperationDeadlineContext.mark(.authentication)
                refreshCoordinator = runtime.refreshCoordinator
                if let refreshCoordinator {
                    try Task.checkCancellation()
                    let application = try await refreshCoordinator.applyCurrentTokenWithGeneration(to: request)
                    try Task.checkCancellation()
                    request = application.request
                    refreshGeneration = application.generation
                } else {
                    refreshGeneration = nil
                }
            case .required:
                NetworkOperationDeadlineContext.mark(.authentication)
                // The synchronous preflight above guarantees this coordinator.
                guard let requiredCoordinator = runtime.refreshCoordinator else {
                    throw NetworkError.configuration(
                        reason: .invalidRequest(
                            "Session-auth-required endpoints require NetworkConfiguration.refreshTokenPolicy."
                        )
                    )
                }
                refreshCoordinator = requiredCoordinator
                try Task.checkCancellation()
                let application = try await requiredCoordinator.applyRequiredTokenWithGeneration(to: request)
                try Task.checkCancellation()
                request = application.request
                refreshGeneration = application.generation
            }

            NetworkOperationDeadlineContext.mark(.requestPreparation)

            let requestSigners = configuration.requestSigners + executable.requestSigners
            await notifyRequestAdapted(
                request, retryIndex: retryIndex, requestID: requestID, configuration: configuration)

            executable.logger.log(request: request)

            let context = NetworkRequestContext(
                requestID: requestID,
                retryIndex: retryIndex,
                metricsReporter: configuration.metricsReporter,
                trustPolicy: configuration.trustPolicy,
                eventObservers: configuration.eventObservers,
                redirectPolicy: configuration.redirectPolicy,
                allowsInsecureHTTP: configuration.allowsInsecureHTTP,
                allowsAutomaticRedirects: true,
                allowsURLCacheStorage: true
            )

            return PreparedExecutionRequest(
                request: request,
                refreshGeneration: refreshGeneration,
                refreshCoordinator: refreshCoordinator,
                bodySource: built.bodySource,
                requestSigners: requestSigners,
                cleanupFileURL: cleanupFileURL,
                context: context
            )
        } catch {
            // Preparation may already have materialized a multipart temp file.
            // `execute` cannot install its defer
            // until this method returns, so failures/cancellation from an
            // interceptor, token provider, or signer must clean up here.
            if let cleanupFileURL {
                try? FileManager.default.removeItem(at: cleanupFileURL)
            }
            throw error
        }
    }

    @inline(__always)
    private func responseStage<D: SingleRequestExecutable>(
        _ executable: D,
        prepared: PreparedExecutionRequest,
        configuration: NetworkConfiguration,
        runtime: RequestExecutionRuntime,
        requestID: UUID
    ) async throws -> Response {
        let acceptable = executable.acceptableStatusCodes ?? configuration.acceptableStatusCodes
        let networkResponse = try await executeWithPolicies(
            request: prepared.request,
            refreshGeneration: prepared.refreshGeneration,
            refreshCoordinator: prepared.refreshCoordinator,
            bodySource: prepared.bodySource,
            requestSigners: prepared.requestSigners,
            configuration: configuration,
            context: prepared.context,
            runtime: runtime,
            requestID: requestID,
            acceptableStatusCodes: acceptable
        )
        return try await finalizeResponseStage(
            executable,
            networkResponse: networkResponse,
            prepared: prepared,
            configuration: configuration
        )
    }

    @inline(__always)
    private func finalizeResponseStage<D: SingleRequestExecutable>(
        _ executable: D,
        networkResponse initialResponse: Response,
        prepared: PreparedExecutionRequest,
        configuration: NetworkConfiguration
    ) async throws -> Response {
        var networkResponse = initialResponse
        NetworkOperationDeadlineContext.mark(.responseDecoding)

        // Onion unwinds inner→outer: per-request interceptors first,
        // session-level interceptors last. A session-level response
        // interceptor sees the same response a session-only setup would
        // produce because per-endpoint adapters have already finished.
        for interceptor in executable.responseInterceptors {
            try Task.checkCancellation()
            networkResponse = try await interceptor.adapt(networkResponse, request: prepared.request)
            try Task.checkCancellation()
        }
        for interceptor in configuration.responseInterceptors {
            try Task.checkCancellation()
            networkResponse = try await interceptor.adapt(networkResponse, request: prepared.request)
            try Task.checkCancellation()
        }
        // After response interceptors settle, give cancellation a chance
        // to short-circuit before we spend cycles on body-limit checks,
        // decode, and didDecode chains.
        try Task.checkCancellation()
        try enforceResponseBodyLimit(networkResponse, configuration: configuration)

        // Per-endpoint override wins over the session-wide configuration
        // when present. Lets one definition treat e.g. 304 as success
        // without changing the default for the rest of the client.
        let acceptable = executable.acceptableStatusCodes ?? configuration.acceptableStatusCodes
        guard acceptable.contains(networkResponse.statusCode) else {
            throw NetworkError.statusCode(networkResponse)
        }

        executable.logger.log(response: networkResponse, isError: false)
        return networkResponse
    }

    @inline(__always)
    private func decodeStage<D: SingleRequestExecutable>(
        _ executable: D,
        response networkResponse: Response,
        configuration: NetworkConfiguration
    ) async throws -> D.APIResponse {
        NetworkOperationDeadlineContext.mark(.responseDecoding)
        // willDecode runs after response interceptors have settled so adapters
        // that mutate the response observe the same payload the decoder will see.
        var decodableData = networkResponse.data
        for interceptor in configuration.decodingInterceptors {
            try Task.checkCancellation()
            decodableData = try await interceptor.willDecode(
                data: decodableData,
                response: networkResponse
            )
            try Task.checkCancellation()
        }
        try enforceResponseBodyLimit(data: decodableData, configuration: configuration)

        // Synchronous decode can block for several ms on large payloads; insert
        // a cancellation checkpoint before decoder handoff.
        try Task.checkCancellation()
        var decoded = try executable.decode(data: decodableData, response: networkResponse)
        for interceptor in configuration.decodingInterceptors {
            try Task.checkCancellation()
            decoded = try await interceptor.didDecode(decoded, response: networkResponse)
            // An async post-decoder may observe cancellation without throwing
            // (for example, a callback bridge that finishes normally). Do not
            // let that late value cross the terminal success boundary.
            try Task.checkCancellation()
        }
        // Keep the no-interceptor path consistent and close the narrow race
        // between synchronous decoding and the caller receiving success.
        try Task.checkCancellation()
        return decoded
    }

    private func notifySuccess(
        _ response: Response,
        requestID: UUID,
        configuration: NetworkConfiguration
    ) async {
        guard !configuration.eventObservers.isEmpty else { return }
        await eventHub.publishTerminal(
            .requestFinished(
                requestID: requestID,
                statusCode: response.statusCode,
                byteCount: response.data.count
            ),
            requestID: requestID,
            observers: configuration.eventObservers
        )
    }
}
