import Foundation

/// Scheme policy applied by ``NetworkURLValidator``.
public enum NetworkURLPolicy: Sendable, Equatable {
    case http(allowsInsecure: Bool = false)
    case webSocket(allowsInsecure: Bool = false)
}

/// Validates absolute transport URLs before they reach Foundation.
public enum NetworkURLValidator {
    @discardableResult
    public static func validate(
        _ url: URL,
        policy: NetworkURLPolicy
    ) throws -> URL {
        try NetworkURLAdmission.validate(url, policy: policy.internalPolicy)
    }

    @discardableResult
    public static func validate(
        _ request: URLRequest,
        policy: NetworkURLPolicy
    ) throws -> URLRequest {
        try NetworkURLAdmission.validate(
            request,
            policy: policy.internalPolicy
        )
    }
}

private extension NetworkURLPolicy {
    var internalPolicy: NetworkURLAdmission.Policy {
        switch self {
        case .http(let allowsInsecure):
            .http(allowsInsecure: allowsInsecure)
        case .webSocket(let allowsInsecure):
            .webSocket(allowsInsecure: allowsInsecure)
        }
    }
}
