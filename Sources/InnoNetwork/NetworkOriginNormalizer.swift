import Foundation

/// Canonicalizes a URL origin for package-internal policy partitioning.
package enum NetworkOriginNormalizer {
    package static func key(
        for url: URL?,
        unknownSchemeDefaultPort: Int? = nil
    ) -> String? {
        guard let url,
            let scheme = url.scheme?.lowercased(),
            let host = url.host?.lowercased(),
            !host.isEmpty
        else {
            return nil
        }

        let normalizedHost = host.contains(":") ? "[\(host)]" : host
        let port = url.port ?? defaultPort(for: scheme) ?? unknownSchemeDefaultPort
        let portSuffix = port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(normalizedHost)\(portSuffix)"
    }

    package static func isSameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhsKey = key(for: lhs), let rhsKey = key(for: rhs) else {
            return false
        }
        return lhsKey == rhsKey
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http", "ws":
            return 80
        case "https", "wss":
            return 443
        default:
            return nil
        }
    }
}
