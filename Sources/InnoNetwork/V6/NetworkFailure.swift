import Foundation

/// Stable high-level classification for operation failures.
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

/// Recommended application response to a failure.
public enum NetworkRecoveryDisposition: String, Sendable, Equatable {
    case retry
    case waitForConnectivity
    case refreshCredentials
    case doNotRetry
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
    public init(migratingV5 error: NetworkError) {
        let code = (error as NSError).code
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
                recovery: Self.recovery(forHTTPStatus: statusCode)
            )
        case .decoding:
            self.init(kind: .decoding, code: code, recovery: .doNotRetry)
        case .underlying:
            self.init(kind: .transport, code: code, recovery: .retry)
        case .reachability:
            self.init(kind: .connectivity, code: code, recovery: .waitForConnectivity)
        case .trustEvaluationFailed:
            self.init(kind: .trust, code: code, recovery: .doNotRetry)
        case .cancelled:
            self.init(kind: .cancelled, code: code, recovery: .none)
        case .timeout:
            self.init(kind: .timeout, code: code, recovery: .retry)
        }
    }

    private static func recovery(forHTTPStatus statusCode: Int) -> NetworkRecoveryDisposition {
        switch statusCode {
        case 401, 403:
            return .refreshCredentials
        case 408, 425, 429, 500...599:
            return .retry
        default:
            return .doNotRetry
        }
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
