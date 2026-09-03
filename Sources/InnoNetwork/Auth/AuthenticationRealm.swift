import Foundation

/// A logical authentication boundary with its own token and refresh lifecycle.
///
/// Realms let one client safely serve multiple principals or identity providers
/// without coalescing refresh work across those boundaries. Values are opaque to
/// InnoNetwork; applications commonly use names such as `"customer"`,
/// `"operator"`, or a tenant identifier that is safe to retain in memory.
public struct AuthenticationRealm: RawRepresentable, Hashable, Sendable,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    /// Realm used by the original single-token ``RefreshTokenPolicy`` API.
    public static let `default` = AuthenticationRealm(rawValue: "default")
}
