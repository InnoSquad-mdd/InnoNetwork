import Foundation
import os

/// Opt-in bearer-token refresh policy used by ``DefaultNetworkClient``.
///
/// The policy keeps storage decisions outside the library. Callers provide
/// closures for reading the current token and refreshing it; InnoNetwork owns
/// only the single-flight coordination and one-time replay after configured
/// authentication status codes.
public struct RefreshTokenPolicy: Sendable {
    package let realmResolver: @Sendable (URLRequest) -> AuthenticationRealm?
    package let currentTokenProvider: @Sendable (AuthenticationRealm, URLRequest) async throws -> String?
    package let refreshTokenProvider: @Sendable (AuthenticationRealm, URLRequest) async throws -> String
    package let tokenApplicator: @Sendable (AuthenticationRealm, String, URLRequest) -> URLRequest
    package let refreshStatusCodes: Set<Int>
    package let failureCooldown: RefreshFailureCooldown

    /// Creates a token refresh policy.
    ///
    /// - Parameters:
    ///   - refreshStatusCodes: Status codes that should trigger a refresh
    ///     and one request replay. Defaults to `401`.
    ///   - appliesTo: Returns whether this policy should attach tokens and
    ///     refresh for a request. Defaults to every request.
    ///   - failureCooldown: Throttle policy used after a refresh failure to
    ///     suppress thundering-herd retries against a known-bad refresh
    ///     token. Default is exponential backoff (1s base, 30s cap).
    ///   - currentToken: Returns the currently cached token, or `nil` when
    ///     the request should be sent without an authorization header.
    ///   - refreshToken: Refreshes and returns a new token. Concurrent
    ///     refreshes are collapsed into one task by the client.
    ///   - applyToken: Applies a token to a request. Defaults to a Bearer
    ///     `Authorization` header.
    public init(
        refreshStatusCodes: Set<Int> = [401],
        appliesTo: @escaping @Sendable (URLRequest) -> Bool = { _ in true },
        failureCooldown: RefreshFailureCooldown = .exponentialBackoff(base: 1.0, max: 30.0),
        currentToken: @escaping @Sendable () async throws -> String?,
        refreshToken: @escaping @Sendable () async throws -> String,
        applyToken: @escaping @Sendable (String, URLRequest) -> URLRequest = { token, request in
            var request = request
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
    ) {
        self.refreshStatusCodes = refreshStatusCodes
        self.failureCooldown = failureCooldown
        self.realmResolver = { request in
            appliesTo(request) ? .default : nil
        }
        self.currentTokenProvider = { _, _ in try await currentToken() }
        self.refreshTokenProvider = { _, _ in try await refreshToken() }
        self.tokenApplicator = { _, token, request in applyToken(token, request) }
    }

    /// Creates a realm-aware token refresh policy.
    ///
    /// Requests that resolve to `nil` are outside this policy. Each non-nil
    /// realm receives an independent single-flight refresh generation and
    /// failure cooldown, so a failed tenant refresh cannot block another
    /// tenant or identity provider.
    public init(
        refreshStatusCodes: Set<Int> = [401],
        realmForRequest: @escaping @Sendable (URLRequest) -> AuthenticationRealm?,
        failureCooldown: RefreshFailureCooldown = .exponentialBackoff(base: 1.0, max: 30.0),
        currentToken: @escaping @Sendable (AuthenticationRealm) async throws -> String?,
        refreshToken: @escaping @Sendable (AuthenticationRealm) async throws -> String,
        applyToken: @escaping @Sendable (AuthenticationRealm, String, URLRequest) -> URLRequest = {
            _, token, request in
            var request = request
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
    ) {
        self.refreshStatusCodes = refreshStatusCodes
        self.failureCooldown = failureCooldown
        self.realmResolver = realmForRequest
        self.currentTokenProvider = { realm, _ in try await currentToken(realm) }
        self.refreshTokenProvider = { realm, _ in try await refreshToken(realm) }
        self.tokenApplicator = applyToken
    }
}


/// Throttle policy applied after a refresh failure. Suppresses retries
/// against a refresh token that the IdP just rejected so a flapping
/// upstream auth service does not turn into a request stampede.
public struct RefreshFailureCooldown: Sendable {
    package let base: TimeInterval
    package let cap: TimeInterval

    /// `cooldown(after:)` returns `base * 2^(failures-1)` clamped at `cap`.
    /// `failures == 0` returns zero — no cooldown until the *first* failure
    /// has occurred.
    public static func exponentialBackoff(base: TimeInterval, max cap: TimeInterval) -> RefreshFailureCooldown {
        let normalizedBase = max(0, base)
        let normalizedCap = max(normalizedBase, cap)
        return RefreshFailureCooldown(base: normalizedBase, cap: normalizedCap)
    }

    /// Disables cooldown entirely; every failure is immediately retryable.
    public static var disabled: RefreshFailureCooldown {
        RefreshFailureCooldown(base: 0, cap: 0)
    }

    func cooldown(afterConsecutiveFailures failures: Int) -> TimeInterval {
        guard failures > 0, base > 0 else { return 0 }
        let exponent = Double(min(failures - 1, 30))
        let raw = base * pow(2.0, exponent)
        return min(max(raw, base), cap)
    }
}


package actor RefreshTokenCoordinator {
    private let policy: RefreshTokenPolicy
    private let now: @Sendable () -> Date
    private struct RealmState: Sendable {
        var lifecycle: RefreshLifecycleState = .initial
        var successfulRefreshGeneration: UInt64 = 0
    }

    private var realmStates: [AuthenticationRealm: RealmState] = [:]

    package init(
        policy: RefreshTokenPolicy,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.policy = policy
        self.now = now
    }

    deinit {
        for realmState in realmStates.values {
            if case .inFlight(_, let task) = realmState.lifecycle.phase {
                task.cancel()
            }
        }
    }

    /// Whether a refresh task is currently in flight.
    ///
    /// Reads are point-in-time. The intended consumer is
    /// ``RequestExecutor`` segregating coalescer lanes during a refresh
    /// window so a stale 401 result cannot leak across callers when
    /// `Authorization` is excluded from the dedup key.
    package var isRefreshInProgress: Bool {
        realmStates.values.contains { $0.lifecycle.isRefreshInProgress }
    }

    package func applyCurrentToken(to request: URLRequest) async throws -> URLRequest {
        try await applyCurrentTokenWithGeneration(to: request).request
    }

    package func applyCurrentTokenWithGeneration(
        to request: URLRequest
    ) async throws -> RefreshTokenApplication {
        guard let realm = policy.realmResolver(request) else {
            return RefreshTokenApplication(
                request: request,
                generation: 0,
                didApplyToken: false
            )
        }

        // The provider is external async work, so the actor may process a
        // successful refresh while it is suspended. Re-read until the token
        // and generation come from one stable refresh epoch.
        while true {
            let generation = realmState(for: realm).successfulRefreshGeneration
            let token = try await policy.currentTokenProvider(realm, request)
            guard generation == realmState(for: realm).successfulRefreshGeneration else { continue }
            guard let token else {
                return RefreshTokenApplication(
                    request: request,
                    generation: generation,
                    didApplyToken: false
                )
            }
            return RefreshTokenApplication(
                request: policy.tokenApplicator(
                    realm,
                    token,
                    Self.removingAuthorizationHeaders(from: request)
                ),
                generation: generation,
                didApplyToken: true
            )
        }
    }

    /// Applies an existing token or proactively refreshes before transport.
    /// Required-auth endpoints use this path so a missing current token cannot
    /// silently turn their first attempt into an anonymous request.
    package func applyRequiredTokenWithGeneration(
        to request: URLRequest
    ) async throws -> RefreshTokenApplication {
        guard let realm = policy.realmResolver(request) else {
            throw NetworkError.configuration(
                reason: .invalidRequest(
                    "Session-auth-required endpoint is outside RefreshTokenPolicy.appliesTo or the configured authentication realms."
                )
            )
        }

        let current = try await applyCurrentTokenWithGeneration(to: request)
        if current.didApplyToken { return current }

        try Task.checkCancellation()
        let resolution = try await resolveRefresh(
            for: realm,
            request: request,
            expectedGeneration: nil
        )
        guard case .refreshed(let token) = resolution else {
            // `expectedGeneration == nil` always starts or joins a refresh.
            return try await applyRequiredTokenWithGeneration(to: request)
        }
        try Task.checkCancellation()
        return RefreshTokenApplication(
            request: policy.tokenApplicator(
                realm,
                token,
                Self.removingAuthorizationHeaders(from: request)
            ),
            generation: realmState(for: realm).successfulRefreshGeneration,
            didApplyToken: true
        )
    }

    package func refreshAndApply(to request: URLRequest) async throws -> URLRequest {
        try Task.checkCancellation()
        guard let realm = policy.realmResolver(request) else { return request }
        let resolution = try await resolveRefresh(
            for: realm,
            request: request,
            expectedGeneration: nil
        )
        guard case .refreshed(let token) = resolution else {
            // `expectedGeneration == nil` never produces this branch. Keep the
            // fallback total so the invariant remains explicit if resolution
            // gains another case in the future.
            return try await applyCurrentTokenWithGeneration(to: request).request
        }
        try Task.checkCancellation()
        return policy.tokenApplicator(
            realm,
            token,
            Self.removingAuthorizationHeaders(from: request)
        )
    }

    package func recoverAfterAuthenticationFailure(
        request: URLRequest,
        observedGeneration: UInt64
    ) async throws -> RefreshTokenApplication {
        try Task.checkCancellation()
        guard let realm = policy.realmResolver(request) else {
            return RefreshTokenApplication(
                request: request,
                generation: 0,
                didApplyToken: false
            )
        }

        // `resolveRefresh` checks the generation in the same actor-isolated
        // segment that joins or creates the refresh task. Keeping those two
        // decisions together closes the reentrancy window where a refresh
        // could complete after this method checked the generation but before
        // a second refresh task was registered.
        let resolution = try await resolveRefresh(
            for: realm,
            request: request,
            expectedGeneration: observedGeneration
        )
        guard case .refreshed(let token) = resolution else {
            return try await applyCurrentTokenWithGeneration(to: request)
        }
        try Task.checkCancellation()
        return RefreshTokenApplication(
            request: policy.tokenApplicator(
                realm,
                token,
                Self.removingAuthorizationHeaders(from: request)
            ),
            generation: realmState(for: realm).successfulRefreshGeneration,
            didApplyToken: true
        )
    }

    package func shutdown() {
        for realmState in realmStates.values {
            if case .inFlight(_, let task) = realmState.lifecycle.phase {
                task.cancel()
            }
        }
        realmStates.removeAll()
    }

    package func shouldRefresh(statusCode: Int, request: URLRequest) -> Bool {
        policy.realmResolver(request) != nil && policy.refreshStatusCodes.contains(statusCode)
    }

    private static func removingAuthorizationHeaders(from request: URLRequest) -> URLRequest {
        // Strip every existing `Authorization` header — case-insensitively —
        // before applying a current or refreshed token. This keeps custom
        // applicators that use `addValue` from stacking endpoint-provided
        // credentials alongside the policy credential.
        var sanitized = request
        if let headers = sanitized.allHTTPHeaderFields {
            for key in headers.keys where key.caseInsensitiveCompare("Authorization") == .orderedSame {
                sanitized.setValue(nil, forHTTPHeaderField: key)
            }
        }
        return sanitized
    }

    private enum RefreshResolution {
        case generationAdvanced
        case refreshed(String)
    }

    private func resolveRefresh(
        for realm: AuthenticationRealm,
        request: URLRequest,
        expectedGeneration: UInt64?
    ) async throws -> RefreshResolution {
        var realmState = realmState(for: realm)
        if let expectedGeneration,
            expectedGeneration != realmState.successfulRefreshGeneration
        {
            return .generationAdvanced
        }

        realmState.lifecycle =
            RefreshLifecycleReducer.reduce(
                state: realmState.lifecycle,
                event: .expireCooldownIfNeeded,
                context: lifecycleContext()
            ).state
        realmStates[realm] = realmState

        switch realmState.lifecycle.phase {
        case .cooldown(let until, let lastError):
            if now() < until { throw lastError }
        case .inFlight(_, let task):
            return .refreshed(try await RefreshTokenTaskAwaitBridge().value(of: task))
        case .idle:
            break
        }

        let refreshTokenProvider = policy.refreshTokenProvider
        let id = UUID()
        // State transitions are driven by the detached task's own completion
        // (success/failure/cancel) rather than by the awaiter's catch arms.
        // If the *caller* of `resolveRefresh(...)` is cancelled while awaiting the
        // detached task, the task keeps running, so resetting state here would
        // let a follow-up caller launch a duplicate refresh. Routing the
        // transition through the task itself preserves single-flight even under
        // aggressive caller cancellation.
        //
        // The task body awaits `refreshDidSucceed`/`refreshDidCancel`/
        // `refreshDidFail` *before* re-throwing or returning. That ordering
        // guarantees that by the time any awaiter on `task.value` observes
        // the result, the actor's state has already been reconciled
        // through the reducer — so a follow-up caller entering
        // `resolveRefresh(...)` after the failed/cancelled refresh sees
        // `.idle` (or `.cooldown`) and can start a fresh refresh without
        // racing the prior task's terminal callback.
        //
        // No explicit priority: `Task.currentPriority` previously hard-coded
        // the actor's caller priority into the detached task, which inverted
        // priority when a low-priority caller forced a high-priority refresh
        // to wait. Falling back to the runtime default lets the cooperative
        // pool reorder the refresh under the prevailing priority.
        let task = Task.detached { [weak self] () async throws -> String in
            do {
                let token = try await refreshTokenProvider(realm, request)
                await self?.refreshDidSucceed(realm: realm, id: id)
                return token
            } catch is CancellationError {
                await self?.refreshDidCancel(realm: realm, id: id)
                throw CancellationError()
            } catch {
                await self?.refreshDidFail(realm: realm, id: id, error: error)
                throw error
            }
        }
        realmState.lifecycle =
            RefreshLifecycleReducer.reduce(
                state: realmState.lifecycle,
                event: .start(id: id, task: task),
                context: lifecycleContext()
            ).state
        realmStates[realm] = realmState
        return .refreshed(try await RefreshTokenTaskAwaitBridge().value(of: task))
    }

    private func refreshDidSucceed(realm: AuthenticationRealm, id: UUID) {
        var realmState = realmState(for: realm)
        let reduction = RefreshLifecycleReducer.reduce(
            state: realmState.lifecycle,
            event: .succeed(id: id),
            context: lifecycleContext()
        )
        realmState.lifecycle = reduction.state
        if !reduction.effects.contains(.ignoreStaleCompletion) {
            realmState.successfulRefreshGeneration &+= 1
        }
        realmStates[realm] = realmState
    }

    private func refreshDidCancel(realm: AuthenticationRealm, id: UUID) {
        var realmState = realmState(for: realm)
        realmState.lifecycle =
            RefreshLifecycleReducer.reduce(
                state: realmState.lifecycle,
                event: .cancel(id: id),
                context: lifecycleContext()
            ).state
        realmStates[realm] = realmState
    }

    private func refreshDidFail(
        realm: AuthenticationRealm,
        id: UUID,
        error: any Error & Sendable
    ) {
        var realmState = realmState(for: realm)
        realmState.lifecycle =
            RefreshLifecycleReducer.reduce(
                state: realmState.lifecycle,
                event: .fail(id: id, error: error),
                context: lifecycleContext()
            ).state
        realmStates[realm] = realmState
    }

    private func lifecycleContext() -> RefreshLifecycleContext {
        RefreshLifecycleContext(now: now(), failureCooldown: policy.failureCooldown)
    }

    private func realmState(for realm: AuthenticationRealm) -> RealmState {
        realmStates[realm] ?? RealmState()
    }
}


package struct RefreshTokenApplication: Sendable {
    package let request: URLRequest
    package let generation: UInt64
    package let didApplyToken: Bool
}


private final class RefreshTokenTaskAwaitBridge: Sendable {
    private enum Outcome: Sendable {
        case success(String)
        case failure(any Error & Sendable)
    }

    private struct State: Sendable {
        var continuation: CheckedContinuation<String, any Error>?
        var outcome: Outcome?
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    func value(of task: Task<String, any Error>) async throws -> String {
        let relay = Task { [self] in
            do {
                let value = try await task.value
                finish(.success(value))
            } catch {
                finish(.failure(error))
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(continuation)
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
            relay.cancel()
        }
    }

    private func install(
        _ continuation: CheckedContinuation<String, any Error>
    ) {
        let outcome = state.withLock { state -> Outcome? in
            if let outcome = state.outcome {
                return outcome
            }
            state.continuation = continuation
            return nil
        }
        if let outcome {
            resume(continuation, with: outcome)
        }
    }

    private func finish(_ outcome: Outcome) {
        let continuation = state.withLock { state -> CheckedContinuation<String, any Error>? in
            if state.outcome != nil {
                return nil
            }
            state.outcome = outcome
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        if let continuation {
            resume(continuation, with: outcome)
        }
    }

    private func resume(_ continuation: CheckedContinuation<String, any Error>, with outcome: Outcome) {
        switch outcome {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}


package struct RefreshLifecycleState: Sendable {
    package var phase: RefreshLifecyclePhase
    package var consecutiveFailures: Int

    package static var initial: Self {
        RefreshLifecycleState(phase: .idle, consecutiveFailures: 0)
    }

    package var isRefreshInProgress: Bool {
        if case .inFlight = phase { return true }
        return false
    }
}


package enum RefreshLifecyclePhase: Sendable {
    case idle
    case inFlight(id: UUID, task: Task<String, Error>)
    case cooldown(until: Date, lastError: any Error & Sendable)
}


package enum RefreshLifecycleEvent: Sendable {
    case expireCooldownIfNeeded
    case start(id: UUID, task: Task<String, Error>)
    case succeed(id: UUID)
    case cancel(id: UUID)
    case fail(id: UUID, error: any Error & Sendable)
}


package struct RefreshLifecycleContext: Sendable {
    package let now: Date
    package let failureCooldown: RefreshFailureCooldown

    package init(now: Date, failureCooldown: RefreshFailureCooldown) {
        self.now = now
        self.failureCooldown = failureCooldown
    }
}


package enum RefreshLifecycleEffect: Sendable, Equatable {
    case ignoreStaleCompletion
}


package enum RefreshLifecycleReducer: StateReducer {
    package static func reduce(
        state: RefreshLifecycleState,
        event: RefreshLifecycleEvent,
        context: RefreshLifecycleContext
    ) -> StateReduction<RefreshLifecycleState, RefreshLifecycleEffect> {
        switch event {
        case .expireCooldownIfNeeded:
            return expireCooldownIfNeeded(state: state, now: context.now)
        case .start(let id, let task):
            return start(state: state, id: id, task: task)
        case .succeed(let id):
            return complete(state: state, id: id, result: .success(()), context: context)
        case .cancel(let id):
            return cancel(state: state, id: id)
        case .fail(let id, let error):
            return complete(state: state, id: id, result: .failure(error), context: context)
        }
    }

    private static func expireCooldownIfNeeded(
        state: RefreshLifecycleState,
        now: Date
    ) -> StateReduction<RefreshLifecycleState, RefreshLifecycleEffect> {
        guard case .cooldown(let until, _) = state.phase, now >= until else {
            return StateReduction(state: state)
        }
        return StateReduction(
            state: RefreshLifecycleState(
                phase: .idle,
                consecutiveFailures: state.consecutiveFailures
            )
        )
    }

    private static func start(
        state: RefreshLifecycleState,
        id: UUID,
        task: Task<String, Error>
    ) -> StateReduction<RefreshLifecycleState, RefreshLifecycleEffect> {
        guard case .idle = state.phase else { return StateReduction(state: state) }
        return StateReduction(
            state: RefreshLifecycleState(
                phase: .inFlight(id: id, task: task),
                consecutiveFailures: state.consecutiveFailures
            )
        )
    }

    private static func cancel(
        state: RefreshLifecycleState,
        id: UUID
    ) -> StateReduction<RefreshLifecycleState, RefreshLifecycleEffect> {
        guard case .inFlight(let currentId, _) = state.phase, currentId == id else {
            return StateReduction(state: state, effects: [.ignoreStaleCompletion])
        }
        return StateReduction(
            state: RefreshLifecycleState(
                phase: .idle,
                consecutiveFailures: state.consecutiveFailures
            )
        )
    }

    private static func complete(
        state: RefreshLifecycleState,
        id: UUID,
        result: Result<Void, any Error & Sendable>,
        context: RefreshLifecycleContext
    ) -> StateReduction<RefreshLifecycleState, RefreshLifecycleEffect> {
        guard case .inFlight(let currentId, _) = state.phase, currentId == id else {
            return StateReduction(state: state, effects: [.ignoreStaleCompletion])
        }

        switch result {
        case .success:
            return StateReduction(state: .initial)
        case .failure(let error):
            let failures = state.consecutiveFailures + 1
            let cooldown = context.failureCooldown.cooldown(afterConsecutiveFailures: failures)
            let phase: RefreshLifecyclePhase =
                cooldown > 0
                ? .cooldown(until: context.now.addingTimeInterval(cooldown), lastError: error)
                : .idle
            return StateReduction(
                state: RefreshLifecycleState(
                    phase: phase,
                    consecutiveFailures: failures
                )
            )
        }
    }
}
