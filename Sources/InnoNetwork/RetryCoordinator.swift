import Foundation

package struct RequestExecutionFailure: Error {
    let error: NetworkError
    let request: URLRequest?

    package init(error: NetworkError, request: URLRequest?) {
        self.error = error
        self.request = request
    }
}


package struct RetryCoordinator {
    private let eventHub: NetworkEventHub
    private let clock: any InnoNetworkClock

    package init(
        eventHub: NetworkEventHub,
        clock: any InnoNetworkClock = SystemClock()
    ) {
        self.eventHub = eventHub
        self.clock = clock
    }

    package func execute<Response>(
        retryPolicy: RetryPolicy?,
        networkMonitor: (any NetworkMonitoring)?,
        requestID: UUID,
        eventObservers: [any NetworkEventObserving],
        operation: @Sendable (Int, UUID) async throws -> Response
    ) async throws -> Response {
        do {
            let value = try await runRetryLoop(
                retryPolicy: retryPolicy,
                networkMonitor: networkMonitor,
                requestID: requestID,
                eventObservers: eventObservers,
                operation: operation
            )
            await eventHub.finish(requestID: requestID)
            return value
        } catch {
            // Cancellation can escape any of the three catch arms in
            // `runRetryLoop` — `processRetryDecision` (clock.sleep,
            // monitor.waitForChange) can throw a raw `CancellationError`
            // that bypasses both typed catch arms. Normalize the thrown
            // error type here so callers always observe `NetworkError.cancelled`
            // regardless of which path produced the cancel, then publish
            // the terminal `.requestFailed` event exactly once.
            let propagated: Error
            if NetworkError.isCancellation(error) {
                let cancellationError = NetworkError.cancelled
                propagated = cancellationError
                await eventHub.publish(
                    .requestFailed(
                        requestID: requestID,
                        errorCode: cancellationError.errorCode,
                        message: cancellationError.observabilityCategory
                    ),
                    requestID: requestID,
                    observers: eventObservers
                )
            } else {
                propagated = error
            }
            // Awaiting `finish` before propagating the error guarantees that
            // the terminal event has crossed the partition boundary into each
            // observer queue. Observer handlers intentionally remain
            // asynchronous so a slow observer cannot delay the request.
            await eventHub.finish(requestID: requestID)
            throw propagated
        }
    }

    /// Runs `operation` under the retry policy and surfaces a single
    /// terminal outcome.
    ///
    /// ## Cancellation propagation
    ///
    /// The loop is a cancellation point at three spots:
    ///
    /// 1. `Task.checkCancellation()` at the top of each iteration short-
    ///    circuits the attempt before the next `operation(...)` runs.
    /// 2. Cancellation thrown out of `operation(...)` (typically from the
    ///    transport or its delegates) lands in one of the three `catch`
    ///    arms below. `RequestExecutionFailure` and `NetworkError` paths
    ///    let `processRetryDecision(...)` see the cancellation and decide
    ///    whether to retry — the policy generally refuses, so the error
    ///    re-throws as-is. The generic `catch` arm normalises any other
    ///    cancellation type to ``NetworkError/cancelled`` so the outer
    ///    `execute(...)` chokepoint sees a uniform shape.
    /// 3. Backoff sleeps inside `processRetryDecision(...)` honour
    ///    cancellation via `Task.sleep(...)` and propagate
    ///    `CancellationError` out of the loop.
    ///
    /// In every case the cancellation event is published **once**, at
    /// the outer `execute(...)` chokepoint — this method does not emit
    /// its own publish. The shape that ultimately re-throws is the type
    /// the public API contract guarantees: callers can expect either
    /// `NetworkError.cancelled` or a typed `CancellationError`, never a
    /// raw `URLError(.cancelled)`.
    private func runRetryLoop<Response>(
        retryPolicy: RetryPolicy?,
        networkMonitor: (any NetworkMonitoring)?,
        requestID: UUID,
        eventObservers: [any NetworkEventObserving],
        operation: @Sendable (Int, UUID) async throws -> Response
    ) async throws -> Response {
        var retryIndex = 0
        var totalRetries = 0
        var snapshot = await networkMonitor?.currentSnapshot()

        while true {
            do {
                try Task.checkCancellation()
                return try await operation(retryIndex, requestID)
            } catch let failure as RequestExecutionFailure {
                let outcome = try await processRetryDecision(
                    error: failure.error,
                    request: failure.request ?? failure.error.underlyingRequest,
                    retryPolicy: retryPolicy,
                    networkMonitor: networkMonitor,
                    requestID: requestID,
                    eventObservers: eventObservers,
                    retryIndex: retryIndex,
                    totalRetries: totalRetries,
                    snapshot: snapshot
                )
                retryIndex = outcome.nextRetryIndex
                totalRetries = outcome.nextTotalRetries
                snapshot = outcome.snapshot
            } catch let error as NetworkError {
                let outcome = try await processRetryDecision(
                    error: error,
                    request: error.underlyingRequest,
                    retryPolicy: retryPolicy,
                    networkMonitor: networkMonitor,
                    requestID: requestID,
                    eventObservers: eventObservers,
                    retryIndex: retryIndex,
                    totalRetries: totalRetries,
                    snapshot: snapshot
                )
                retryIndex = outcome.nextRetryIndex
                totalRetries = outcome.nextTotalRetries
                snapshot = outcome.snapshot
            } catch {
                // Cancellation events for *all* three catch arms are
                // published once at the `execute(...)` chokepoint. Here we
                // only normalize the thrown error type so the chokepoint's
                // `NetworkError.isCancellation` classifier sees a uniform
                // `NetworkError.cancelled`.
                if NetworkError.isCancellation(error) {
                    throw NetworkError.cancelled
                }
                // Raw transport errors (e.g. a `URLError` that escaped the
                // executor pipeline without being wrapped) used to be
                // re-thrown as ``NetworkError/underlying`` here, which retry
                // policies treat opaquely. Route the error through
                // ``NetworkError/mapTransportError(_:)`` so the resulting
                // classification (`.reachability`, `.timeout`, etc.) reaches
                // ``processRetryDecision(...)`` and can be acted upon — this
                // matches the path taken by the typed `NetworkError` catch
                // arm above.
                let normalized = NetworkError.mapTransportError(error)
                let outcome = try await processRetryDecision(
                    error: normalized,
                    request: normalized.underlyingRequest,
                    retryPolicy: retryPolicy,
                    networkMonitor: networkMonitor,
                    requestID: requestID,
                    eventObservers: eventObservers,
                    retryIndex: retryIndex,
                    totalRetries: totalRetries,
                    snapshot: snapshot
                )
                retryIndex = outcome.nextRetryIndex
                totalRetries = outcome.nextTotalRetries
                snapshot = outcome.snapshot
            }
        }
    }

    private struct RetryStepOutcome {
        var nextRetryIndex: Int
        var nextTotalRetries: Int
        var snapshot: NetworkSnapshot?
    }

    private func processRetryDecision(
        error: NetworkError,
        request: URLRequest?,
        retryPolicy: RetryPolicy?,
        networkMonitor: (any NetworkMonitoring)?,
        requestID: UUID,
        eventObservers: [any NetworkEventObserving],
        retryIndex: Int,
        totalRetries: Int,
        snapshot: NetworkSnapshot?
    ) async throws -> RetryStepOutcome {
        guard let policy = retryPolicy else { throw error }
        let policyDecision = policy.shouldRetry(
            error: error,
            retryIndex: retryIndex,
            request: request,
            response: error.underlyingHTTPResponse
        )
        // Coordinator-level safety net: even if a custom policy elects to
        // retry, never auto-retry a non-idempotent timeout when the active
        // ``RetryIdempotencyPolicy`` would reject it. A POST/PATCH that
        // timed out may already have been received and processed by the
        // server — retrying without an idempotency anchor risks duplicate
        // writes (e.g. duplicate payments). Consult the policy's exposed
        // ``RetryIdempotencyPolicy`` so callers using `.methodAgnostic`,
        // a custom safe-method set, or a custom header name are honoured
        // instead of being overridden by a hardcoded default.
        let decision = Self.applyIdempotencySafetyNet(
            decision: policyDecision,
            error: error,
            request: request,
            idempotency: policy.idempotencyPolicy
        )
        if case .noRetry = decision {
            throw error
        }
        guard totalRetries < policy.maxTotalRetries else {
            throw error
        }

        let computedDelay = policy.retryDelay(for: retryIndex)
        let delay = Self.delay(for: decision, computedDelay: computedDelay, policy: policy)
        await eventHub.publish(
            .retryScheduled(
                requestID: requestID,
                retryIndex: retryIndex,
                delay: delay,
                reason: error.observabilityCategory
            ),
            requestID: requestID,
            observers: eventObservers
        )

        var nextRetryIndex = retryIndex + 1
        var nextSnapshot = snapshot
        if policy.waitsForNetworkChanges, let monitor = networkMonitor {
            NetworkOperationDeadlineContext.mark(.connectivityWait)
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

        if delay > 0 {
            NetworkOperationDeadlineContext.mark(.retryDelay)
            try await clock.sleep(for: .seconds(delay))
        }

        return RetryStepOutcome(
            nextRetryIndex: nextRetryIndex,
            nextTotalRetries: totalRetries + 1,
            snapshot: nextSnapshot
        )
    }

    private static func applyIdempotencySafetyNet(
        decision: RetryDecision,
        error: NetworkError,
        request: URLRequest?,
        idempotency: RetryIdempotencyPolicy
    ) -> RetryDecision {
        if case .noRetry = decision { return decision }
        guard case .timeout = error else { return decision }
        // `.methodAgnostic` (or any custom policy that retries every method)
        // means the caller owns duplicate-write protection above
        // InnoNetwork — never override the policy decision.
        if idempotency.retriesAllMethods { return decision }
        // The retry coordinator's raw-`URLError` catch arm normalises into a
        // `.timeout` classification without a Response attached, so
        // `error.underlyingRequest` is `nil`. Without the request we cannot
        // prove the method is safe; defaulting to `.noRetry` preserves the
        // duplicate-write protection that the policy decision tried to grant.
        // Callers that need to retry transport-only timeouts for safe methods
        // can switch to `.methodAgnostic` and own the safety contract.
        guard let request else { return .noRetry }
        let method = request.httpMethod ?? HTTPMethod.get.rawValue
        // Methods explicitly considered safe by the active policy (e.g.
        // GET/HEAD by default) are never converted to `.noRetry`.
        if idempotency.safeMethods.contains(method) { return decision }
        // For non-safe methods, only block when the configured idempotency
        // header is missing. Custom header names are honored.
        let idempotencyKey =
            request.value(forHTTPHeaderField: idempotency.idempotencyHeaderName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasIdempotencyKey = idempotencyKey?.isEmpty == false
        if hasIdempotencyKey { return decision }
        return .noRetry
    }

    private static func delay(
        for decision: RetryDecision,
        computedDelay: TimeInterval,
        policy: RetryPolicy
    ) -> TimeInterval {
        switch decision {
        case .noRetry:
            return computedDelay
        case .retry:
            return computedDelay
        case .retryAfter(let serverHint):
            let hintedDelay = max(serverHint, computedDelay)
            if let maxRetryAfterDelay = policy.maxRetryAfterDelay {
                return min(hintedDelay, max(maxRetryAfterDelay, computedDelay))
            }
            return hintedDelay
        }
    }
}
