import Foundation
import Testing

@testable import InnoNetwork

@Suite("Network origin normalization")
struct NetworkOriginNormalizerTests {
    @Test(
        "Equivalent origins produce the same key",
        arguments: [
            ("https://EXAMPLE.test/path", "https://example.test:443/other"),
            ("http://example.test/path", "http://example.test:80/other"),
            ("wss://example.test/socket", "wss://example.test:443/other"),
            ("https://[2001:db8::1]/path", "https://[2001:db8::1]:443/other"),
        ]
    )
    func equivalentOrigins(lhs: String, rhs: String) throws {
        let lhsURL = try #require(URL(string: lhs))
        let rhsURL = try #require(URL(string: rhs))
        #expect(NetworkOriginNormalizer.key(for: lhsURL) == NetworkOriginNormalizer.key(for: rhsURL))
    }

    @Test(
        "Distinct origins remain partitioned",
        arguments: [
            ("https://example.test", "http://example.test"),
            ("https://example.test:443", "https://example.test:8443"),
            ("https://example.test", "https://other.example.test"),
        ]
    )
    func distinctOrigins(lhs: String, rhs: String) throws {
        let lhsURL = try #require(URL(string: lhs))
        let rhsURL = try #require(URL(string: rhs))
        #expect(NetworkOriginNormalizer.key(for: lhsURL) != NetworkOriginNormalizer.key(for: rhsURL))
    }
}
