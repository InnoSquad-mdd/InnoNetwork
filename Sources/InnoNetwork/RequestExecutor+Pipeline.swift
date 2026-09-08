import Foundation

struct StaleIfErrorRecovery: Error {
    let failure: NetworkError
    let fallback: CachedResponse
}

// MARK: - Pipeline stage
//
// Outer pipeline that the entrypoint `RequestExecutor.execute(...)` delegates
// to: auth-scope validation, the cache/transport pump, the custom-policy
// chain, and the refresh-lane gate. Event publication helpers that the
// pipeline calls at stage boundaries (request-start, post-adaptation,
// terminal failure) also live here so the surface stays adjacent to its
// callers.

extension RequestExecutor {
    func validateSessionAuthentication<D: SingleRequestExecutable>(
        _ executable: D,
        configuration: NetworkConfiguration
    ) throws {
        guard executable.sessionAuthentication == .required, configuration.refreshTokenPolicy == nil else {
            return
        }
        throw NetworkError.configuration(
            reason: .invalidRequest(
                "Session-auth-required endpoints require NetworkConfiguration.refreshTokenPolicy."
            )
        )
    }

    func executeWithPolicies(
        request adaptedRequest: URLRequest,
        refreshGeneration initialRefreshGeneration: UInt64?,
        refreshCoordinator: RefreshTokenCoordinator?,
        bodySource: BodySource,
        requestSigners: [RequestSigner],
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        runtime: RequestExecutionRuntime,
        requestID: UUID,
        acceptableStatusCodes: Set<Int>
    ) async throws -> Response {
        var request = adaptedRequest
        var refreshGeneration = initialRefreshGeneration
        var replayedAfterRefresh = false

        while true {
            NetworkOperationDeadlineContext.mark(.cacheLookup)
            // Interceptors and token applicators can replace the entire
            // request, and a 401 refresh creates another adapted request on
            // replay. Re-run admission for every transport iteration before
            // cache lookup, signing, coalescing, or URLSession sees it.
            try NetworkURLAdmission.validate(
                request,
                policy: .http(allowsInsecure: configuration.allowsInsecureHTTP)
            )

            // A signer may establish or change the authentication principal
            // (for example JWT Bearer or AWS SigV4). Until signers can expose
            // a stable, non-secret principal partition, an unsigned request is
            // not a safe cache identity: two endpoint signers could otherwise
            // share one response before the second signer is even invoked.
            let allowsRequestSharing = requestSigners.isEmpty
            // The key only ever feeds cache lookup, revalidation, and store —
            // every consumer additionally guards on a configured
            // `responseCache` — so skip the header/URL normalization cost
            // entirely for the common cache-less configuration. Coalescing
            // partitions on `allowsRequestSharing`, not on this key.
            let cacheKey: ResponseCacheKey? =
                allowsRequestSharing && configuration.responseCache != nil
                ? ResponseCacheKey(
                    request: request,
                    sensitiveHeaderNames: configuration.responseCacheSensitiveHeaderNames
                )
                : nil
            let cacheWriteToken = await cacheWriteToken(
                cacheKey: cacheKey,
                runtime: runtime
            )
            let cachePreparation = await prepareCacheLookup(
                cacheKey: cacheKey,
                request: request,
                configuration: configuration,
                runtime: runtime
            )
            let staleIfErrorFallback = staleIfErrorCandidate(preparation: cachePreparation)
            if let cachedResponse = try await cachedResponseIfAvailable(
                preparation: cachePreparation,
                cacheKey: cacheKey,
                request: request,
                configuration: configuration,
                context: context,
                bodySource: bodySource,
                requestSigners: requestSigners,
                runtime: runtime,
                originalRequestID: requestID,
                cacheWriteToken: cacheWriteToken
            ) {
                try Task.checkCancellation()
                return cachedResponse
            }

            let revalidation = prepareConditionalCacheHeaders(
                request: &request,
                preparation: cachePreparation,
                configuration: configuration
            )

            // Signing is deliberately the last mutation before transport.
            // Every pre-transport header must be covered by canonical
            // signatures. Signed requests conservatively bypass cache sharing
            // because their principal does not exist in the unsigned key.
            NetworkOperationDeadlineContext.mark(.transport)
            let timedNetworkResponse: TimedNetworkResponse
            do {
                timedNetworkResponse = try await performSignedTransport(
                    request: request,
                    bodySource: bodySource,
                    requestSigners: requestSigners,
                    configuration: configuration,
                    context: context,
                    runtime: runtime,
                    requestID: requestID,
                    allowsRequestCoalescing: allowsRequestSharing
                )
            } catch {
                let mapped = error as? NetworkError ?? NetworkError.mapTransportError(error)
                if let staleIfErrorFallback,
                    Self.isEligibleStaleIfErrorTransportFailure(mapped)
                {
                    throw StaleIfErrorRecovery(
                        failure: mapped,
                        fallback: staleIfErrorFallback
                    )
                }
                throw error
            }
            let networkResponse = timedNetworkResponse.response

            if let substitution = try await convertNotModifiedIfNeeded(
                networkResponse,
                cacheKey: cacheKey,
                request: request,
                configuration: configuration,
                revalidation: revalidation
            ) {
                if notModifiedRevisesVary(
                    cached: substitution.cached,
                    notModifiedHeaders: networkResponse.response?.allHeaderFields
                ) {
                    try enforceResponseBodyLimit(substitution.mergedResponse, configuration: configuration)
                    // A changed Vary dimension invalidates the selection
                    // contract under which the representation was stored.
                    // Return the successfully validated representation to
                    // this caller, but force the next request through the
                    // origin so the new variant can be stored under a fresh
                    // request-header snapshot. This also ensures a revised
                    // `no-store` directive cannot leave the old entry behind.
                    await invalidateCacheEntry(
                        cacheKey: cacheKey,
                        configuration: configuration,
                        runtime: runtime
                    )
                    return substitution.mergedResponse
                } else {
                    try enforceResponseBodyLimit(substitution.mergedResponse, configuration: configuration)
                    await storeCacheIfNeeded(
                        substitution.mergedResponse,
                        cacheKey: cacheKey,
                        request: request,
                        configuration: configuration,
                        ageHeaders: responseHeaderSnapshot(networkResponse.response),
                        requestStartedAt: timedNetworkResponse.requestStartedAt,
                        responseReceivedAt: timedNetworkResponse.responseReceivedAt,
                        runtime: runtime,
                        writeToken: cacheWriteToken
                    )
                    return substitution.mergedResponse
                }
            }

            if let refreshCoordinator,
                await refreshCoordinator.shouldRefresh(statusCode: networkResponse.statusCode, request: request),
                !replayedAfterRefresh
            {
                NetworkOperationDeadlineContext.mark(.authentication)
                // Replay from the fully adapted request so session and
                // endpoint interceptors keep their headers/signatures while
                // the auth policy replaces only the Authorization value.
                let application = try await refreshCoordinator.recoverAfterAuthenticationFailure(
                    request: adaptedRequest,
                    observedGeneration: refreshGeneration ?? 0
                )
                request = application.request
                refreshGeneration = application.generation
                try Task.checkCancellation()
                replayedAfterRefresh = true
                continue
            }

            if let staleIfErrorFallback,
                !acceptableStatusCodes.contains(networkResponse.statusCode),
                Self.isEligibleStaleIfErrorStatus(networkResponse.statusCode)
            {
                throw StaleIfErrorRecovery(
                    failure: .statusCode(networkResponse),
                    fallback: staleIfErrorFallback
                )
            }

            await invalidateUnsafeTargetURIIfNeeded(
                networkResponse,
                request: request,
                configuration: configuration,
                runtime: runtime
            )

            // Enforced before the response cache is written so an oversize
            // body cannot poison subsequent GETs that would replay it from
            // cache. The check is controlled by responseBodyBufferingPolicy;
            // nil keeps collection unbounded while still using the selected
            // streaming or buffered transport path.
            try enforceResponseBodyLimit(networkResponse, configuration: configuration)
            await storeCacheIfNeeded(
                networkResponse,
                cacheKey: cacheKey,
                request: request,
                configuration: configuration,
                ageHeaders: nil,
                requestStartedAt: timedNetworkResponse.requestStartedAt,
                responseReceivedAt: timedNetworkResponse.responseReceivedAt,
                runtime: runtime,
                writeToken: cacheWriteToken
            )
            return networkResponse
        }
    }

    private static func isEligibleStaleIfErrorTransportFailure(_ error: NetworkError) -> Bool {
        switch error {
        case .timeout, .reachability:
            return true
        default:
            return false
        }
    }

    private static func isEligibleStaleIfErrorStatus(_ statusCode: Int) -> Bool {
        statusCode == 500 || statusCode == 502 || statusCode == 503 || statusCode == 504
    }

    func executeCustomPolicies(
        request: URLRequest,
        identityRequest: URLRequest,
        bodySource: BodySource,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        runtime: RequestExecutionRuntime,
        requestID: UUID,
        allowsRequestCoalescing: Bool
    ) async throws -> TimedNetworkResponse {
        if configuration.customExecutionPolicies.isEmpty {
            let result = try await performTransportResult(
                request: request,
                identityRequest: identityRequest,
                bodySource: bodySource,
                configuration: configuration,
                context: context,
                runtime: runtime,
                allowsRequestCoalescing: allowsRequestCoalescing
            )
            let response = await response(
                from: result,
                request: request,
                requestID: requestID,
                configuration: configuration
            )
            return TimedNetworkResponse(
                response: response,
                requestStartedAt: result.startedAt,
                responseReceivedAt: result.completedAt
            )
        }

        let timingRecorder = TransportTimingRecorder()
        let baseNext = RequestExecutionNext {
            try await performPolicyTransport(
                request: request,
                identityRequest: identityRequest,
                bodySource: bodySource,
                configuration: configuration,
                context: context,
                runtime: runtime,
                requestID: requestID,
                allowsRequestCoalescing: allowsRequestCoalescing,
                timingRecorder: timingRecorder
            )
        }

        let policyContext = RequestExecutionContext(
            requestID: requestID,
            retryIndex: context.retryIndex,
            metricsReporter: context.metricsReporter,
            trustPolicy: context.trustPolicy,
            eventObservers: context.eventObservers
        )

        NetworkOperationDeadlineContext.mark(.policyAdmission)
        let chain = configuration.customExecutionPolicies.reversed().reduce(baseNext) { next, policy in
            RequestExecutionNext {
                try await policy.execute(
                    input: RequestExecutionInput(
                        request: request,
                        requestID: requestID,
                        retryIndex: context.retryIndex
                    ),
                    context: policyContext,
                    next: next
                )
            }
        }

        let response = try await chain.execute()
        if let timestamps = await timingRecorder.timestamps(for: response) {
            return TimedNetworkResponse(
                response: response,
                requestStartedAt: timestamps.startedAt,
                responseReceivedAt: timestamps.completedAt
            )
        }
        let syntheticResponseTime = runtime.clock.now()
        return TimedNetworkResponse(
            response: response,
            requestStartedAt: syntheticResponseTime,
            responseReceivedAt: syntheticResponseTime
        )
    }

    private func performPolicyTransport(
        request: URLRequest,
        identityRequest: URLRequest,
        bodySource: BodySource,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        runtime: RequestExecutionRuntime,
        requestID: UUID,
        allowsRequestCoalescing: Bool,
        timingRecorder: TransportTimingRecorder
    ) async throws -> Response {
        let result = try await performTransportResult(
            request: request,
            identityRequest: identityRequest,
            bodySource: bodySource,
            configuration: configuration,
            context: context,
            runtime: runtime,
            allowsRequestCoalescing: allowsRequestCoalescing
        )
        let transportResponse = await response(
            from: result,
            request: request,
            requestID: requestID,
            configuration: configuration
        )
        await timingRecorder.record(
            transportResponse,
            startedAt: result.startedAt,
            completedAt: result.completedAt
        )
        return transportResponse
    }

    private func response(
        from result: TransportResult,
        request: URLRequest,
        requestID: UUID,
        configuration: NetworkConfiguration
    ) async -> Response {
        if !configuration.eventObservers.isEmpty {
            await eventHub.publish(
                .responseReceived(
                    requestID: requestID,
                    statusCode: result.response.statusCode,
                    byteCount: result.data.count
                ),
                requestID: requestID,
                observers: configuration.eventObservers,
                occurredAt: result.completedAt,
                completesPhysicalTransport: true
            )
        }
        return Response(
            statusCode: result.response.statusCode,
            data: result.data,
            request: request,
            response: result.response,
            transportTimingID: UUID()
        )
    }

    func refreshLaneIfInProgress(
        coordinator: RefreshTokenCoordinator?
    ) async -> UUID? {
        guard let coordinator else { return nil }
        return await coordinator.isRefreshInProgress ? UUID() : nil
    }

    func applyRequestSigners(
        _ signers: [RequestSigner],
        to request: URLRequest,
        bodySource: BodySource
    ) async throws -> URLRequest {
        guard !signers.isEmpty else { return request }

        let body = try bodySource.signingBody(for: request)
        var signedRequest = request
        for signer in signers {
            try Task.checkCancellation()
            let headers = try await signer.signatureHeaders(for: signedRequest, body: body)
            try Task.checkCancellation()
            for header in headers {
                signedRequest.setValue(header.value, forHTTPHeaderField: header.name)
            }
        }
        return signedRequest
    }

    func performSignedTransport(
        request: URLRequest,
        bodySource: BodySource,
        requestSigners: [RequestSigner],
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        runtime: RequestExecutionRuntime,
        requestID: UUID,
        allowsRequestCoalescing: Bool
    ) async throws -> TimedNetworkResponse {
        let preparedBody = try prepareSigningBodySource(bodySource, signers: requestSigners)
        defer {
            if let snapshotURL = preparedBody.snapshotURL {
                try? FileManager.default.removeItem(at: snapshotURL)
            }
        }

        let requestForSigning =
            requestSigners.isEmpty ? request : request.preparingForSignedTransport()
        let signedRequest = try await applyRequestSigners(
            requestSigners,
            to: requestForSigning,
            bodySource: preparedBody.bodySource
        )
        let transportContext =
            requestSigners.isEmpty ? context : context.restrictingSignedRequestSharing()
        return try await performTransport(
            request: signedRequest,
            identityRequest: request,
            bodySource: preparedBody.bodySource,
            configuration: configuration,
            context: transportContext,
            runtime: runtime,
            requestID: requestID,
            allowsRequestCoalescing: allowsRequestCoalescing
        )
    }

    func performSignedTransportResult(
        request: URLRequest,
        bodySource: BodySource,
        requestSigners: [RequestSigner],
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        runtime: RequestExecutionRuntime
    ) async throws -> TransportResult {
        let preparedBody = try prepareSigningBodySource(bodySource, signers: requestSigners)
        defer {
            if let snapshotURL = preparedBody.snapshotURL {
                try? FileManager.default.removeItem(at: snapshotURL)
            }
        }

        let requestForSigning =
            requestSigners.isEmpty ? request : request.preparingForSignedTransport()
        let signedRequest = try await applyRequestSigners(
            requestSigners,
            to: requestForSigning,
            bodySource: preparedBody.bodySource
        )
        let transportContext =
            requestSigners.isEmpty ? context : context.restrictingSignedRequestSharing()
        return try await performTransportResult(
            request: signedRequest,
            identityRequest: request,
            bodySource: preparedBody.bodySource,
            configuration: configuration,
            context: transportContext,
            runtime: runtime,
            allowsRequestCoalescing: requestSigners.isEmpty
        )
    }

    private func prepareSigningBodySource(
        _ bodySource: BodySource,
        signers: [RequestSigner]
    ) throws -> (bodySource: BodySource, snapshotURL: URL?) {
        guard !signers.isEmpty,
            case .file(let callerURL, cleanupAfterUse: false) = bodySource
        else {
            return (bodySource, nil)
        }

        let snapshotURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "innonetwork.upload.snapshot.\(UUID().uuidString).\(callerURL.lastPathComponent)"
        )
        do {
            try FileManager.default.copyItem(at: callerURL, to: snapshotURL)
            return (.file(snapshotURL, cleanupAfterUse: true), snapshotURL)
        } catch {
            try? FileManager.default.removeItem(at: snapshotURL)
            throw error
        }
    }
}

// MARK: - Event publication helpers
//
// Event publication shims that the executor pipeline calls into at
// stage boundaries (request-start, post-adaptation, terminal failure).

extension RequestExecutor {
    func notifyRequestStart(
        _ request: URLRequest,
        retryIndex: Int,
        requestID: UUID,
        configuration: NetworkConfiguration
    ) async {
        // Publish is a no-op without observers, but its arguments are
        // evaluated eagerly at this call site: URL metadata redaction plus an
        // actor hop per event. Skip both for the common observer-less client.
        guard !configuration.eventObservers.isEmpty else { return }
        await eventHub.publish(
            .requestStart(
                requestID: requestID,
                method: request.httpMethod ?? "UNKNOWN",
                url: NetworkURLMetadataRedactor.string(from: request.url),
                retryIndex: retryIndex
            ),
            requestID: requestID,
            observers: configuration.eventObservers
        )
    }

    func notifyRequestAdapted(
        _ request: URLRequest,
        retryIndex: Int,
        requestID: UUID,
        configuration: NetworkConfiguration
    ) async {
        guard !configuration.eventObservers.isEmpty else { return }
        await eventHub.publish(
            .requestAdapted(
                requestID: requestID,
                method: request.httpMethod ?? "UNKNOWN",
                url: NetworkURLMetadataRedactor.string(from: request.url),
                retryIndex: retryIndex
            ),
            requestID: requestID,
            observers: configuration.eventObservers
        )
    }

}
