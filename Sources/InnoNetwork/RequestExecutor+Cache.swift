import Foundation
import OSLog

// MARK: - Cache lifecycle stage
//
// Cache lookup, conditional revalidation, Not-Modified merging,
// freshness refresh, and cache-storage helpers. Grouped here so the
// central pipeline reads top-down: lookup → conditional headers →
// transport (next section) → 304 handling → store.

extension RequestExecutor {
    func prepareCacheLookup(
        cacheKey: ResponseCacheKey?,
        request: URLRequest,
        configuration: NetworkConfiguration,
        runtime: RequestExecutionRuntime
    ) async -> CachePreparation {
        let onlyIfCached =
            configuration.responseCachePolicy.honorsRequestOnlyIfCached
            && requestRequestsOnlyIfCached(request)
        guard let cacheKey,
            request.httpMethod == HTTPMethod.get.rawValue,
            let cache = configuration.responseCache,
            configuration.responseCachePolicy.allowsCacheRead
        else {
            return onlyIfCached ? .onlyIfCachedMiss : .bypass
        }

        let cached = await cachedRespectingVary(
            cache,
            key: cacheKey,
            request: request,
            sensitiveHeaderNames: configuration.responseCacheSensitiveHeaderNames
        )
        let preparation = configuration.responseCachePolicy.prepare(
            cached: cached,
            now: runtime.clock.now()
        )
        if onlyIfCached {
            switch preparation {
            case .returnCached(let entry), .returnStaleAndRevalidate(let entry):
                // only-if-cached explicitly forbids the background network
                // leg that stale-while-revalidate would normally schedule.
                return .returnCached(entry)
            case .bypass, .revalidate, .revalidateWithStaleIfError, .onlyIfCachedMiss:
                return .onlyIfCachedMiss
            }
        }
        if case .revalidate(let candidate) = preparation,
            let candidate,
            let fallback = configuration.responseCachePolicy.staleIfErrorFallback(
                cached: candidate,
                now: runtime.clock.now()
            )
        {
            return .revalidateWithStaleIfError(fallback)
        }
        return preparation
    }

    func cachedResponseIfAvailable(
        preparation: CachePreparation,
        cacheKey: ResponseCacheKey?,
        request: URLRequest,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        bodySource: BodySource,
        requestSigners: [RequestSigner],
        runtime: RequestExecutionRuntime,
        originalRequestID: UUID,
        cacheWriteToken: ResponseCacheMutationCoordinator.WriteToken?
    ) async throws -> Response? {
        switch preparation {
        case .bypass, .revalidate, .revalidateWithStaleIfError:
            return nil
        case .onlyIfCachedMiss:
            throw NetworkError.configuration(
                reason: .invalidRequest(
                    "Cache-Control: only-if-cached could not be satisfied without network access."
                )
            )
        case .returnCached(let cached):
            guard let response = response(from: cached, for: request) else { return nil }
            try enforceResponseBodyLimit(response, configuration: configuration)
            return response
        case .returnStaleAndRevalidate(let cached):
            guard let staleResponse = response(from: cached, for: request) else { return nil }
            try enforceResponseBodyLimit(staleResponse, configuration: configuration)

            guard let cacheKey else { return nil }

            let revalidationID = UUID()
            let startGate = TaskStartGate()
            let revalidationHandle = InFlightTaskHandle()
            let generation = runtime.inFlight.generation()
            runtime.inFlight.register(id: revalidationID, generation: generation) {
                revalidationHandle.cancel()
            }
            let eventHub = self.eventHub
            let revalidationTask = Task {
                guard await startGate.wait() else {
                    runtime.inFlight.deregister(id: revalidationID)
                    await eventHub.finish(requestID: revalidationID)
                    return
                }
                defer {
                    runtime.inFlight.deregister(id: revalidationID)
                }
                var revalidationStartedAt: Date?
                let observers = context.eventObservers
                await eventHub.publish(
                    .cacheRevalidation(originalID: originalRequestID, state: .scheduled),
                    requestID: revalidationID,
                    observers: observers
                )

                do {
                    try Task.checkCancellation()

                    var revalidationRequest = request
                    let revalidation: ConditionalRevalidationContext?
                    if let etag = cached.etag {
                        revalidationRequest.setValue(etag, forHTTPHeaderField: "If-None-Match")
                        // RFC 9110 §13.1.3 permits sending both validators
                        // together — origins MAY use whichever they have a
                        // strong preference for.
                        if let lastModified = validatedLastModified(cached) {
                            revalidationRequest.setValue(
                                lastModified, forHTTPHeaderField: "If-Modified-Since")
                        }
                        revalidation = ConditionalRevalidationContext(cached: cached)
                    } else if let lastModified = validatedLastModified(cached) {
                        revalidationRequest.setValue(
                            lastModified, forHTTPHeaderField: "If-Modified-Since")
                        revalidation = ConditionalRevalidationContext(cached: cached)
                    } else {
                        revalidation = nil
                    }

                    revalidationStartedAt = runtime.clock.now()
                    let result = try await revalidateInBackground(
                        request: revalidationRequest,
                        bodySource: bodySource,
                        requestSigners: requestSigners,
                        configuration: configuration,
                        context: context,
                        runtime: runtime
                    )
                    try Task.checkCancellation()

                    let response = Response(
                        statusCode: result.response.statusCode,
                        data: result.data,
                        request: revalidationRequest,
                        response: result.response
                    )
                    let terminalState: CacheRevalidationState
                    if let substitution = try await convertNotModifiedIfNeeded(
                        response,
                        cacheKey: cacheKey,
                        request: revalidationRequest,
                        configuration: configuration,
                        revalidation: revalidation
                    ) {
                        try Task.checkCancellation()
                        if notModifiedRevisesVary(
                            cached: substitution.cached,
                            notModifiedHeaders: result.response.allHeaderFields
                        ) {
                            try enforceResponseBodyLimit(
                                substitution.mergedResponse,
                                configuration: configuration
                            )
                            await invalidateCacheEntry(
                                cacheKey: cacheKey,
                                configuration: configuration,
                                runtime: runtime
                            )
                        } else {
                            try enforceResponseBodyLimit(
                                substitution.mergedResponse,
                                configuration: configuration
                            )
                            await storeCacheIfNeeded(
                                substitution.mergedResponse,
                                cacheKey: cacheKey,
                                request: revalidationRequest,
                                configuration: configuration,
                                ageHeaders: responseHeaderSnapshot(result.response),
                                requestStartedAt: result.startedAt,
                                responseReceivedAt: result.completedAt,
                                runtime: runtime,
                                writeToken: cacheWriteToken
                            )
                        }
                        terminalState = .notModified
                    } else {
                        try Task.checkCancellation()
                        try enforceResponseBodyLimit(response, configuration: configuration)
                        await storeCacheIfNeeded(
                            response,
                            cacheKey: cacheKey,
                            request: revalidationRequest,
                            configuration: configuration,
                            ageHeaders: nil,
                            requestStartedAt: result.startedAt,
                            responseReceivedAt: result.completedAt,
                            runtime: runtime,
                            writeToken: cacheWriteToken
                        )
                        terminalState = .completed(statusCode: result.response.statusCode)
                    }
                    await eventHub.publish(
                        .cacheRevalidation(originalID: originalRequestID, state: terminalState),
                        requestID: revalidationID,
                        observers: observers
                    )
                } catch {
                    if !NetworkError.isCancellation(error) {
                        let mapped = Self.mapTransportError(
                            error,
                            startedAt: revalidationStartedAt
                        )
                        let surfaced =
                            configuration.captureFailurePayload ? mapped : mapped.redactingFailurePayload()
                        Logger.API.error(
                            "Background revalidation failed: \(surfaced.observabilityCategory, privacy: .public)"
                        )
                        await eventHub.publish(
                            .cacheRevalidation(
                                originalID: originalRequestID,
                                state: .failed(
                                    errorCode: surfaced.errorCode,
                                    message: surfaced.observabilityCategory
                                )
                            ),
                            requestID: revalidationID,
                            observers: observers
                        )
                    }
                }
                await eventHub.finish(requestID: revalidationID)
            }
            revalidationHandle.attach(revalidationTask)
            startGate.open()
            return staleResponse
        }
    }

    func staleIfErrorCandidate(preparation: CachePreparation) -> CachedResponse? {
        guard case .revalidateWithStaleIfError(let cached) = preparation else {
            return nil
        }
        return cached
    }

    func staleIfErrorResponse(
        candidate: CachedResponse,
        request: URLRequest,
        policy: ResponseCachePolicy,
        now: Date
    ) -> Response? {
        guard policy.staleIfErrorFallback(cached: candidate, now: now) != nil else {
            return nil
        }
        return response(from: candidate, for: request)
    }

    private func response(from cached: CachedResponse, for request: URLRequest) -> Response? {
        guard let httpResponse = cached.response(for: request) else { return nil }
        return Response(
            statusCode: cached.statusCode,
            data: cached.data,
            request: request,
            response: httpResponse
        )
    }

    private func requestRequestsOnlyIfCached(_ request: URLRequest) -> Bool {
        guard let value = request.value(forHTTPHeaderField: "Cache-Control") else {
            return false
        }
        return HTTPListParser.split(value).contains {
            HTTPListParser.directiveName(of: $0) == "only-if-cached"
        }
    }

    func revalidateInBackground(
        request: URLRequest,
        bodySource: BodySource,
        requestSigners: [RequestSigner],
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        runtime: RequestExecutionRuntime
    ) async throws -> TransportResult {
        let revalidationContext = NetworkRequestContext(
            requestID: UUID(),
            retryIndex: context.retryIndex,
            metricsReporter: context.metricsReporter,
            trustPolicy: context.trustPolicy,
            eventObservers: context.eventObservers,
            redirectPolicy: context.redirectPolicy,
            allowsInsecureHTTP: context.allowsInsecureHTTP,
            allowsAutomaticRedirects: context.allowsAutomaticRedirects,
            allowsURLCacheStorage: context.allowsURLCacheStorage
        )
        return try await performSignedTransportResult(
            request: request,
            bodySource: bodySource,
            requestSigners: requestSigners,
            configuration: configuration,
            context: revalidationContext,
            runtime: runtime
        )
    }

    func prepareConditionalCacheHeaders(
        request: inout URLRequest,
        preparation: CachePreparation,
        configuration: NetworkConfiguration
    ) -> ConditionalRevalidationContext? {
        let candidate: CachedResponse?
        switch preparation {
        case .revalidate(let revalidationCandidate):
            candidate = revalidationCandidate
        case .revalidateWithStaleIfError(let revalidationCandidate):
            candidate = revalidationCandidate
        case .bypass, .returnCached, .returnStaleAndRevalidate, .onlyIfCachedMiss:
            candidate = nil
        }
        guard configuration.responseCachePolicy.isEnabled,
            configuration.responseCachePolicy.allowsConditionalRevalidation,
            let candidate
        else {
            return nil
        }
        var attached = false
        if let etag = candidate.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            attached = true
        }
        if let lastModified = validatedLastModified(candidate) {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            attached = true
        }
        guard attached else {
            return nil
        }
        return ConditionalRevalidationContext(cached: candidate)
    }

    private func validatedLastModified(_ cached: CachedResponse) -> String? {
        guard let value = cached.lastModified,
            HTTPDateParser.parse(value, requiresGMTZone: true) != nil
        else {
            return nil
        }
        return value
    }

    func convertNotModifiedIfNeeded(
        _ response: Response,
        cacheKey: ResponseCacheKey?,
        request: URLRequest,
        configuration: NetworkConfiguration,
        revalidation: ConditionalRevalidationContext?
    ) async throws -> NotModifiedSubstitution? {
        guard response.statusCode == 304 else {
            return nil
        }
        guard configuration.responseCachePolicy.allowsConditionalRevalidation,
            let cacheKey,
            let cache = configuration.responseCache
        else {
            return nil
        }
        guard let revalidation else {
            return nil
        }
        let preparedCached = revalidation.cached
        guard
            let cached = await cachedRespectingVary(
                cache,
                key: cacheKey,
                request: request,
                sensitiveHeaderNames: configuration.responseCacheSensitiveHeaderNames
            )
        else {
            throw cacheRevalidationFailed(
                "Cached response disappeared before 304 Not Modified substitution.",
                cached: preparedCached,
                request: request
            )
        }
        guard cached.matchesRepresentation(of: preparedCached) else {
            throw cacheRevalidationFailed(
                "Cached response changed before 304 Not Modified substitution.",
                cached: preparedCached,
                request: request
            )
        }
        if let cachedETag = preparedCached.etag,
            let notModifiedETag = response.response?.value(forHTTPHeaderField: "ETag"),
            cachedETag.trimmingCharacters(in: .whitespacesAndNewlines)
                != notModifiedETag.trimmingCharacters(in: .whitespacesAndNewlines)
        {
            throw cacheRevalidationFailed(
                "The 304 ETag did not identify the conditionally validated stored response.",
                cached: preparedCached,
                request: request
            )
        }
        guard let url = request.url else {
            throw cacheRevalidationFailed(
                "Request URL was unavailable during 304 Not Modified substitution.",
                cached: preparedCached,
                request: request
            )
        }
        guard
            let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: preparedCached.statusCode,
                httpVersion: nil,
                headerFields: mergedCachedHeaders(preparedCached.headers, notModifiedResponse: response.response)
            )
        else {
            throw cacheRevalidationFailed(
                "Merged 304 Not Modified headers could not be reconstructed.",
                cached: preparedCached,
                request: request
            )
        }
        return NotModifiedSubstitution(
            mergedResponse: Response(
                statusCode: preparedCached.statusCode,
                data: preparedCached.data,
                request: request,
                response: httpResponse
            ),
            cached: preparedCached
        )
    }

    private func cacheRevalidationFailed(
        _ message: String,
        cached: CachedResponse,
        request: URLRequest
    ) -> NetworkError {
        let fallbackURL = request.url ?? URL(fileURLWithPath: "/")
        let httpResponse =
            cached.response(for: request)
            ?? HTTPURLResponse(
                url: fallbackURL,
                mimeType: nil,
                expectedContentLength: cached.data.count,
                textEncodingName: nil
            )
        return .underlying(
            SendableUnderlyingError(
                domain: "InnoNetwork.ResponseCache",
                code: 304,
                message: "Cache revalidation against the stored response failed: \(message)"
            ),
            Response(
                statusCode: cached.statusCode,
                data: cached.data,
                request: request,
                response: httpResponse
            )
        )
    }

    func mergedCachedHeaders(
        _ cachedHeaders: [String: String],
        notModifiedResponse: HTTPURLResponse?
    ) -> [String: String] {
        var headers = cachedHeaders
        guard let notModifiedResponse else { return headers }

        for pair in notModifiedResponse.allHeaderFields {
            // `HTTPURLResponse.allHeaderFields` is documented to return string
            // values, but Foundation does not enforce it at the type level.
            // Skip any non-string slot rather than stringifying an NSNumber /
            // NSDate via `String(describing:)` — a synthesised form servers
            // do not emit would silently poison the merged header set.
            guard let key = pair.key as? String,
                let value = pair.value as? String
            else { continue }
            if let existingKey = headers.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
                headers.removeValue(forKey: existingKey)
            }
            headers[key] = value
        }
        return headers
    }

    /// RFC 9111 §4.4 requires a cache to invalidate stored responses for the
    /// target URI after a non-error response to an unsafe request method.
    ///
    /// The executor runs this before response interceptors and status-code
    /// validation so the decision reflects the origin response. Cache policies
    /// that promise "metadata untouched" (`disabled`, `networkOnly`) still skip
    /// the mutation by virtue of `allowsCacheWrite == false`.
    func invalidateUnsafeTargetURIIfNeeded(
        _ response: Response,
        request: URLRequest,
        configuration: NetworkConfiguration,
        runtime: RequestExecutionRuntime
    ) async {
        guard
            Self.shouldInvalidateCacheForUnsafeMethod(request.httpMethod, statusCode: response.statusCode),
            configuration.responseCachePolicy.allowsCacheWrite,
            let cache = configuration.responseCache,
            let targetURI = ResponseCacheKey.normalizedTargetURI(request.url)
        else {
            return
        }

        await runtime.cacheMutations.acquire(targetURI: targetURI)
        await runtime.cacheMutations.advanceGeneration(for: targetURI)
        await cache.invalidateTargetURI(targetURI)
        await runtime.cacheMutations.release(targetURI: targetURI)
    }

    /// Stores the response in cache when the policy allows writes.
    ///
    /// Only GET responses are persisted. InnoNetwork stores the RFC-cacheable
    /// status codes that are safe for whole-response reuse and honours
    /// `Cache-Control: no-store` / `private` / `no-cache`. Responses to
    /// requests carrying `Authorization` are stored only when the origin
    /// explicitly permits it with RFC 9111 §3.5 directives (`public`,
    /// `must-revalidate`, or `s-maxage`).
    func storeCacheIfNeeded(
        _ response: Response,
        cacheKey: ResponseCacheKey?,
        request: URLRequest,
        configuration: NetworkConfiguration,
        ageHeaders: [String: String]?,
        requestStartedAt: Date,
        responseReceivedAt: Date,
        runtime: RequestExecutionRuntime,
        writeToken: ResponseCacheMutationCoordinator.WriteToken?
    ) async {
        guard let cacheKey,
            request.httpMethod == HTTPMethod.get.rawValue,
            let cache = configuration.responseCache,
            configuration.responseCachePolicy.allowsCacheWrite
        else {
            return
        }
        let headerSnapshot = responseHeaderSnapshot(response.response)
        guard Self.cacheableStatusCodes.contains(response.statusCode) else {
            return
        }
        let cacheControl = cacheControlDirectives(in: headerSnapshot)
        if cacheControl.contains("no-store") || cacheControl.contains("private") {
            await invalidateCacheEntry(
                cacheKey: cacheKey,
                configuration: configuration,
                runtime: runtime
            )
            return
        }
        if ResponseCacheStoragePolicy.containsAuthorizationRequestHeader(request.allHTTPHeaderFields ?? [:]),
            !ResponseCacheStoragePolicy.responsePermitsAuthenticatedStorage(cacheControlDirectives: cacheControl)
        {
            await invalidateCacheEntry(
                cacheKey: cacheKey,
                configuration: configuration,
                runtime: runtime
            )
            return
        }
        let varyHeaders: [String: String?]?
        switch evaluateVary(
            responseHeaders: headerSnapshot,
            request: request,
            sensitiveHeaderNames: configuration.responseCacheSensitiveHeaderNames
        ) {
        case .wildcardSkipsCache:
            await invalidateCacheEntry(
                cacheKey: cacheKey,
                configuration: configuration,
                runtime: runtime
            )
            return
        case .noVary:
            varyHeaders = nil
        case .vary(let snapshot):
            varyHeaders = snapshot
        }
        guard let writeToken else { return }
        await runtime.cacheMutations.acquire(targetURI: writeToken.targetURI)
        guard await runtime.cacheMutations.isCurrent(writeToken) else {
            await runtime.cacheMutations.release(targetURI: writeToken.targetURI)
            return
        }
        await cache.set(
            cacheKey,
            CachedResponse(
                data: response.data,
                statusCode: response.statusCode,
                headers: headerSnapshot,
                storedAt: responseReceivedAt,
                rfc9111InitialAge: RFC9111ResponseAge.initialAge(
                    headers: ageHeaders ?? headerSnapshot,
                    requestTime: requestStartedAt,
                    responseTime: responseReceivedAt
                ),
                requiresRevalidation: cacheControl.contains("no-cache"),
                varyHeaders: varyHeaders
            )
        )
        await runtime.cacheMutations.release(targetURI: writeToken.targetURI)
    }

    func cacheWriteToken(
        cacheKey: ResponseCacheKey?,
        runtime: RequestExecutionRuntime
    ) async -> ResponseCacheMutationCoordinator.WriteToken? {
        guard let targetURI = cacheKey?.url else { return nil }
        return await runtime.cacheMutations.writeToken(for: targetURI)
    }

    func invalidateCacheEntry(
        cacheKey: ResponseCacheKey?,
        configuration: NetworkConfiguration,
        runtime: RequestExecutionRuntime
    ) async {
        guard let cacheKey, let cache = configuration.responseCache else { return }
        let targetURI = cacheKey.url
        await runtime.cacheMutations.acquire(targetURI: targetURI)
        await runtime.cacheMutations.advanceGeneration(for: targetURI)
        await cache.invalidate(cacheKey)
        await runtime.cacheMutations.release(targetURI: targetURI)
    }

    func responseHeaderSnapshot(_ response: HTTPURLResponse?) -> [String: String] {
        response?.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            guard let key = pair.key as? String, let value = pair.value as? String else { return }
            result[key] = value
        } ?? [:]
    }

    /// Status codes that are cacheable by default per RFC 9110 §15. `307`
    /// (Temporary Redirect) is intentionally omitted — RFC 9110 marks it as
    /// not cacheable by default, so caching it would silently change observed
    /// redirect behaviour.
    private static let cacheableStatusCodes: Set<Int> = [
        200, 203, 204, 300, 301, 308, 404, 405, 410, 414, 501,
    ]

    private static let safeCacheMethods: Set<String> = ["GET", "HEAD", "OPTIONS", "TRACE"]

    private static func shouldInvalidateCacheForUnsafeMethod(_ method: String?, statusCode: Int) -> Bool {
        guard (200..<400).contains(statusCode),
            let method
        else {
            return false
        }
        return !safeCacheMethods.contains(method)
    }

    /// Parses Cache-Control directive *names* only. Quoted-string aware
    /// (RFC 9110 §5.6.4) so qualified directives like
    /// `private="X-Foo, X-Bar"` are not shredded into spurious tokens.
    func cacheControlDirectives(in headers: [String: String]) -> Set<String> {
        let combined =
            headers
            .filter { $0.key.caseInsensitiveCompare("Cache-Control") == .orderedSame }
            .map { $0.value }
            .joined(separator: ",")
        guard !combined.isEmpty else { return [] }
        return Set(
            HTTPListParser.split(combined)
                .map(HTTPListParser.directiveName(of:))
                .filter { !$0.isEmpty }
        )
    }

    /// Returns the cached entry for `key` only when its stored vary snapshot
    /// matches `request`. Skips the result silently otherwise so the executor
    /// falls through to a fresh transport hit.
    func cachedRespectingVary(
        _ cache: any ResponseCache,
        key: ResponseCacheKey,
        request: URLRequest,
        sensitiveHeaderNames: Set<String>
    ) async -> CachedResponse? {
        guard let cached = await cache.get(key) else { return nil }
        return
            cachedResponseMatchesVary(
                cached,
                request: request,
                sensitiveHeaderNames: sensitiveHeaderNames
            ) ? cached : nil
    }
}

private extension CachedResponse {
    func matchesRepresentation(of other: CachedResponse) -> Bool {
        data == other.data
            && statusCode == other.statusCode
            && headers == other.headers
            && requiresRevalidation == other.requiresRevalidation
            && varyHeaders == other.varyHeaders
    }
}
