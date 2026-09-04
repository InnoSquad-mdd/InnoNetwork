import Foundation

/// High-level classification for operation failures.
public enum NetworkFailureKind: String, Sendable, Equatable {
    case configuration
    case transport
    case http
    case decoding
    case connectivity
    case trust
    case timeout
    case cancelled
}

/// Declares whether restarting an operation can safely repeat its request.
///
/// This value governs only the high-level recovery recommendation surfaced by
/// ``NetworkFailure``. The built-in retry policy remains independently
/// responsible for attempt budgets, backoff, and the request actually sent.
public enum NetworkOperationReplaySafety: String, Sendable, Equatable {
    /// Infer replay safety from the HTTP method. GET, HEAD, OPTIONS, and TRACE
    /// are replayable; other methods are not.
    case methodDefault

    /// The caller guarantees that every operation restart reuses the same
    /// application-owned idempotency key.
    ///
    /// A key generated from InnoNetwork's per-operation request identifier is
    /// not sufficient because a restarted operation receives a new identifier.
    case stableIdempotencyKey

    /// Never recommend restarting the operation, including for safe methods.
    case never
}

/// Recommended application response to a failure.
public enum NetworkRecoveryDisposition: String, Sendable, Equatable {
    /// The request can be replayed, but the caller still owns its retry budget
    /// and backoff. Do not turn this value into an unbounded retry loop.
    case retry
    /// Wait for connectivity before offering or scheduling another attempt.
    case waitForConnectivity
    /// Re-establish the user session. This does not authorize automatic replay
    /// of a request after authentication succeeds.
    case reauthenticate
    /// The same operation should not be replayed automatically.
    case doNotRetry
    /// No recovery action applies, for example after caller cancellation.
    case none
}

/// Value-only error surfaced by the operation-first contract.
///
/// The type deliberately omits response bodies, headers, raw URLs, and
/// arbitrary underlying error strings. Applications receive a stable kind,
/// numeric diagnostic code, optional HTTP status, and recovery disposition.
public struct NetworkFailure: Error, Sendable, Equatable {
    public let kind: NetworkFailureKind
    public let code: Int
    public let statusCode: Int?
    public let recovery: NetworkRecoveryDisposition

    public init(
        kind: NetworkFailureKind,
        code: Int,
        statusCode: Int? = nil,
        recovery: NetworkRecoveryDisposition
    ) {
        self.kind = kind
        self.code = code
        self.statusCode = statusCode
        self.recovery = recovery
    }

    /// Converts a legacy ``NetworkError`` without retaining sensitive payloads.
    ///
    /// Because this initializer has no endpoint method or authentication
    /// context, it deliberately avoids recommending replay or session
    /// reauthentication. ``OperationNetworkClient`` supplies that context for
    /// failures produced by an operation handle.
    public init(migratingV5 error: NetworkError) {
        self.init(
            migratingV5: error,
            requestMethod: nil,
            sessionAuthentication: nil,
            replaySafety: .never
        )
    }

    package init(
        migratingV5 error: NetworkError,
        requestMethod: HTTPMethod,
        sessionAuthentication: SessionAuthentication,
        replaySafety: NetworkOperationReplaySafety
    ) {
        self.init(
            migratingV5: error,
            requestMethod: Optional(requestMethod),
            sessionAuthentication: Optional(sessionAuthentication),
            replaySafety: replaySafety
        )
    }

    private init(
        migratingV5 error: NetworkError,
        requestMethod: HTTPMethod?,
        sessionAuthentication: SessionAuthentication?,
        replaySafety: NetworkOperationReplaySafety
    ) {
        let code = Self.diagnosticCode(for: error)
        let allowsReplay = Self.allowsReplay(
            method: requestMethod,
            replaySafety: replaySafety
        )
        switch error {
        case .configuration(let reason):
            switch reason {
            case .offline:
                self.init(
                    kind: .connectivity,
                    code: code,
                    recovery: .waitForConnectivity
                )
            case .invalidBaseURL, .invalidRequest:
                self.init(kind: .configuration, code: code, recovery: .doNotRetry)
            }
        case .statusCode(let response):
            let statusCode = response.statusCode
            self.init(
                kind: .http,
                code: code,
                statusCode: statusCode,
                recovery: Self.recovery(
                    forHTTPStatus: statusCode,
                    sessionAuthentication: sessionAuthentication,
                    allowsReplay: allowsReplay
                )
            )
        case .decoding:
            self.init(kind: .decoding, code: code, recovery: .doNotRetry)
        case .underlying:
            self.init(kind: .transport, code: code, recovery: .doNotRetry)
        case .reachability:
            self.init(
                kind: .connectivity,
                code: code,
                recovery: allowsReplay ? .waitForConnectivity : .doNotRetry
            )
        case .trustEvaluationFailed:
            self.init(kind: .trust, code: code, recovery: .doNotRetry)
        case .cancelled:
            self.init(kind: .cancelled, code: code, recovery: .none)
        case .timeout:
            self.init(
                kind: .timeout,
                code: code,
                recovery: allowsReplay ? .retry : .doNotRetry
            )
        }
    }

    private static func recovery(
        forHTTPStatus statusCode: Int,
        sessionAuthentication: SessionAuthentication?,
        allowsReplay: Bool
    ) -> NetworkRecoveryDisposition {
        switch statusCode {
        case 401 where sessionAuthentication == .optional || sessionAuthentication == .required:
            return .reauthenticate
        case 408, 429, 500...599:
            return allowsReplay ? .retry : .doNotRetry
        default:
            return .doNotRetry
        }
    }

    private static func allowsReplay(
        method: HTTPMethod?,
        replaySafety: NetworkOperationReplaySafety
    ) -> Bool {
        switch replaySafety {
        case .methodDefault:
            guard let method else { return false }
            return method == .get || method == .head || method == .options || method == .trace
        case .stableIdempotencyKey:
            return true
        case .never:
            return false
        }
    }

    private static func diagnosticCode(for error: NetworkError) -> Int {
        if case .underlying(let underlying, _) = error,
            underlying.domain == NetworkError.errorDomain,
            NetworkErrorCode(rawValue: underlying.code) != nil
        {
            return underlying.code
        }
        return (error as NSError).code
    }
}

extension NetworkFailure: LocalizedError {
    public var errorDescription: String? {
        switch kind {
        case .configuration: "The request configuration is invalid."
        case .transport: "The network transport failed."
        case .http: "The server returned an unsuccessful response."
        case .decoding: "The response could not be decoded."
        case .connectivity: "A usable network connection is unavailable."
        case .trust: "The server trust policy rejected the connection."
        case .timeout: "The request timed out."
        case .cancelled: "The request was cancelled."
        }
    }
}
