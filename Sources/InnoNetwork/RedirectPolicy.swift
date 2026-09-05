import Foundation

/// Decides how the networking layer reacts when `URLSession` reports an
/// HTTP redirect (3xx + `Location`) for an in-flight request.
///
/// Apple's default `URLSession` behavior follows redirects automatically.
/// ``DefaultRedirectPolicy`` adds explicit security boundaries around that
/// behavior: it rejects HTTPS downgrades, prevents any cross-origin redirect
/// that retains an unsafe method, and strips every caller-prepared original
/// header plus credential-bearing session headers when the target origin
/// (scheme + host + port) differs from the original request's.
///
/// Custom adopters can implement this protocol to forbid redirects entirely,
/// limit redirect depth, restrict allowed schemes, or perform tenant-specific
/// header rewriting before the follow-up request is dispatched.
public protocol RedirectPolicy: Sendable {
    /// Called for every 3xx response with a `Location` header that
    /// `URLSession` is about to follow.
    ///
    /// - Parameters:
    ///   - request: The redirect-target request `URLSession` proposes to
    ///     send. Mutate (or replace) it before returning to alter headers,
    ///     method, or URL.
    ///   - response: The original 3xx response that triggered the redirect.
    ///   - originalRequest: The request the client originally dispatched
    ///     before any redirects were followed. Used to detect cross-origin
    ///     hops independent of intermediate redirects.
    /// - Returns: The request to follow, or `nil` to cancel the redirect
    ///   chain. Returning `nil` causes `URLSession` to deliver the 3xx
    ///   response to the caller verbatim.
    func redirect(
        request: URLRequest,
        response: HTTPURLResponse,
        originalRequest: URLRequest
    ) -> URLRequest?
}

/// The default ``RedirectPolicy`` shipped with InnoNetwork.
///
/// Behavior:
/// - HTTPS-to-HTTP redirects are rejected.
/// - Cross-origin redirects that preserve an unsafe method are rejected,
///   regardless of status code. This covers nonstandard 301/302 handling as
///   well as 307/308 body replay.
/// - Other cross-origin redirects (different scheme, host, or port from the
///   original request) strip every header present on the original request,
///   plus built-in and configured sensitive session headers.
/// - Same-origin redirects pass through unchanged.
/// - Non-HTTP(S) redirect targets are rejected (returns `nil`).
///
/// The ``init(additionalSensitiveHeaders:allowsHTTPSDowngrade:allowsCrossOriginUnsafeMethodRedirects:)``
/// initializer provides explicit escape hatches for controlled environments.
/// Enabling either `allows...` option weakens the default transport boundary;
/// sensitive headers are still stripped when the target crosses origins.
public struct DefaultRedirectPolicy: RedirectPolicy {
    /// Built-in header names (case-insensitive) considered credential-bearing
    /// and stripped on cross-origin redirects.
    ///
    /// These defaults cover standardized authorization/cookie fields and
    /// common API-key, bearer-token, CSRF-token, session-token, and AWS
    /// temporary-credential carriers. They cannot be removed by configuration.
    package static let sensitiveHeaders: Set<String> = [
        "authorization",
        "cookie",
        "proxy-authorization",
        "x-access-token",
        "x-amz-security-token",
        "x-api-key",
        "x-auth-token",
        "x-csrf-token",
        "x-refresh-token",
        "x-session-token",
        "x-token",
    ]

    /// Additional application-specific header names to strip on
    /// cross-origin redirects. Values are trimmed and lowercased at
    /// initialization so matching remains case-insensitive.
    public let additionalSensitiveHeaders: Set<String>

    /// Whether automatic redirects may move a request from HTTPS to HTTP.
    /// Defaults to `false`.
    ///
    /// Set this only for a controlled development or LAN environment. Even
    /// when enabled, cross-origin sensitive headers are still stripped.
    public let allowsHTTPSDowngrade: Bool

    /// Whether a redirect may automatically preserve an unsafe method across
    /// origins. Defaults to `false`.
    ///
    /// `URLSession` does not reliably expose every streamed upload body in the
    /// proposed redirect request. The secure default therefore rejects every
    /// cross-origin proposal that still carries an unsafe method instead of
    /// relying on status-specific rewrite assumptions. Set this only when the
    /// target origins are independently trusted and the replay is intentional.
    public let allowsCrossOriginUnsafeMethodRedirects: Bool

    /// Creates the default redirect policy.
    ///
    /// - Parameters:
    ///   - additionalSensitiveHeaders: Application-specific session-injected
    ///     header names to strip in addition to the built-in sensitive-header
    ///     set and every header present on the original request. Built-in names
    ///     cannot be removed.
    ///   - allowsHTTPSDowngrade: Whether HTTPS-to-HTTP redirects may be
    ///     followed. Enabling this can expose the redirected request to a
    ///     plaintext transport.
    ///   - allowsCrossOriginUnsafeMethodRedirects: Whether a cross-origin
    ///     redirect may preserve an unsafe method and its body.
    public init(
        additionalSensitiveHeaders: Set<String> = [],
        allowsHTTPSDowngrade: Bool = false,
        allowsCrossOriginUnsafeMethodRedirects: Bool = false
    ) {
        self.additionalSensitiveHeaders = Set(
            additionalSensitiveHeaders.compactMap { name in
                let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized.isEmpty ? nil : normalized
            }
        )
        self.allowsHTTPSDowngrade = allowsHTTPSDowngrade
        self.allowsCrossOriginUnsafeMethodRedirects = allowsCrossOriginUnsafeMethodRedirects
    }

    public func redirect(
        request: URLRequest,
        response: HTTPURLResponse,
        originalRequest: URLRequest
    ) -> URLRequest? {
        guard let targetURL = request.url,
            let scheme = targetURL.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            return nil
        }

        let redirectSourceURL = response.url ?? originalRequest.url
        if !allowsHTTPSDowngrade,
            Self.isHTTPSDowngrade(from: redirectSourceURL, to: targetURL)
        {
            return nil
        }

        if !allowsCrossOriginUnsafeMethodRedirects,
            !Self.isSameOrigin(redirectSourceURL, targetURL),
            !Self.isSafeMethod(request.httpMethod)
        {
            return nil
        }

        guard !Self.isSameOrigin(originalRequest.url, targetURL) else { return request }

        var stripped = request
        let originalHeaderNames = Set(
            (originalRequest.allHTTPHeaderFields?.keys ?? [:].keys).map { $0.lowercased() }
        )
        let protectedHeaderNames =
            Self.sensitiveHeaders
            .union(additionalSensitiveHeaders)
            .union(originalHeaderNames)
        let headerNames = stripped.allHTTPHeaderFields?.keys ?? [:].keys
        for name in Array(headerNames) where protectedHeaderNames.contains(name.lowercased()) {
            stripped.setValue(nil, forHTTPHeaderField: name)
        }
        return stripped
    }

    private static func isHTTPSDowngrade(from sourceURL: URL?, to targetURL: URL) -> Bool {
        sourceURL?.scheme?.lowercased() == "https" && targetURL.scheme?.lowercased() == "http"
    }

    private static func isSafeMethod(_ method: String?) -> Bool {
        switch method ?? HTTPMethod.get.rawValue {
        case "GET", "HEAD", "OPTIONS", "TRACE": return true
        default: return false
        }
    }

    /// Two URLs share an origin when their scheme, host (case-insensitive),
    /// and effective port match. A missing explicit port resolves to the
    /// scheme's default (80 for http, 443 for https).
    package static func isSameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        NetworkOriginNormalizer.isSameOrigin(lhs, rhs)
    }
}
