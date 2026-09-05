import Foundation

/// A policy boundary that made an observable execution decision.
public enum NetworkDecisionKind: String, Sendable, Equatable {
    case dispatch
    case retry
    case cache
    case streamingResume
    case admission
    case rateLimit
}

/// The result selected by a policy boundary.
public enum NetworkDecisionOutcome: String, Sendable, Equatable {
    case allowed
    case denied
    case delayed
    case bypassed
}

/// A payload-free explanation for a networking policy decision.
public enum NetworkDecisionReason: String, Sendable, Equatable {
    case policyAllowed
    case policyDenied
    case policyNotConfigured
    case retryBudgetExhausted
    case idempotencyRequired
    case deadlineExceeded
    case cacheHit
    case cacheUnavailable
    case requestNotShareable
    case invalidResumeCursor
    case resumeBudgetExhausted
    case queueFull
    case queueWaitExpired
    case clientShutdown
    case localQuota
    case serverCooldown
    case customPolicy
}

/// Structured, redacted diagnostics for one policy choice.
public struct NetworkDecision: Sendable, Equatable {
    public let requestID: UUID
    public let attemptIndex: Int
    public let kind: NetworkDecisionKind
    public let outcome: NetworkDecisionOutcome
    public let reason: NetworkDecisionReason
    public let delay: TimeInterval?
    package let occurredAt: Date?

    public init(
        requestID: UUID,
        attemptIndex: Int,
        kind: NetworkDecisionKind,
        outcome: NetworkDecisionOutcome,
        reason: NetworkDecisionReason,
        delay: TimeInterval? = nil
    ) {
        self.requestID = requestID
        self.attemptIndex = attemptIndex
        self.kind = kind
        self.outcome = outcome
        self.reason = reason
        self.delay = delay
        self.occurredAt = nil
    }

    package init(
        requestID: UUID,
        attemptIndex: Int,
        kind: NetworkDecisionKind,
        outcome: NetworkDecisionOutcome,
        reason: NetworkDecisionReason,
        delay: TimeInterval? = nil,
        occurredAt: Date
    ) {
        self.requestID = requestID
        self.attemptIndex = attemptIndex
        self.kind = kind
        self.outcome = outcome
        self.reason = reason
        self.delay = delay
        self.occurredAt = occurredAt
    }
}
