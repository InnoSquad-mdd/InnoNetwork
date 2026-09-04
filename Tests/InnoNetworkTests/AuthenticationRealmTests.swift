import Foundation
import Testing

@testable import InnoNetwork

@Suite("Authentication realm routing")
struct AuthenticationRealmTests {
    @Test("Realm-aware policy applies the selected realm token")
    func appliesSelectedRealmToken() async throws {
        let policy = RefreshTokenPolicy(
            realmForRequest: { request in
                request.url?.host == "admin.example.test" ? "admin" : "customer"
            },
            currentToken: { realm in "token-\(realm.rawValue)" },
            refreshToken: { realm in "refreshed-\(realm.rawValue)" }
        )
        let coordinator = RefreshTokenCoordinator(policy: policy)

        let customer = try await coordinator.applyCurrentToken(
            to: URLRequest(url: URL(string: "https://api.example.test/me")!)
        )
        let admin = try await coordinator.applyCurrentToken(
            to: URLRequest(url: URL(string: "https://admin.example.test/me")!)
        )

        #expect(customer.value(forHTTPHeaderField: "Authorization") == "Bearer token-customer")
        #expect(admin.value(forHTTPHeaderField: "Authorization") == "Bearer token-admin")
    }

    @Test("Different realms refresh independently")
    func refreshesRealmsIndependently() async throws {
        let calls = RealmRefreshCalls()
        let policy = RefreshTokenPolicy(
            realmForRequest: { request in
                request.url?.host == "a.example.test" ? "a" : "b"
            },
            currentToken: { _ in nil },
            refreshToken: { realm in
                await calls.record(realm)
                return "fresh-\(realm.rawValue)"
            }
        )
        let coordinator = RefreshTokenCoordinator(policy: policy)

        async let a = coordinator.refreshAndApply(
            to: URLRequest(url: URL(string: "https://a.example.test/value")!)
        )
        async let b = coordinator.refreshAndApply(
            to: URLRequest(url: URL(string: "https://b.example.test/value")!)
        )
        let (aRequest, bRequest) = try await (a, b)

        #expect(aRequest.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-a")
        #expect(bRequest.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-b")
        #expect(await calls.snapshot() == ["a": 1, "b": 1])
    }

    @Test("A nil realm excludes the request from refresh")
    func nilRealmExcludesRequest() async throws {
        let policy = RefreshTokenPolicy(
            realmForRequest: { _ in nil },
            currentToken: { _ in "unused" },
            refreshToken: { _ in "unused" }
        )
        let coordinator = RefreshTokenCoordinator(policy: policy)
        let request = URLRequest(url: URL(string: "https://public.example.test/value")!)

        #expect(try await coordinator.applyCurrentToken(to: request) == request)
        #expect(await !coordinator.shouldRefresh(statusCode: 401, request: request))
    }

    @Test("One realm's refresh cooldown does not block another realm")
    func cooldownIsIsolatedByRealm() async throws {
        let calls = RealmRefreshCalls()
        let now = Date(timeIntervalSince1970: 1_000)
        let policy = RefreshTokenPolicy(
            realmForRequest: { request in
                request.url?.host == "a.example.test" ? "a" : "b"
            },
            failureCooldown: .exponentialBackoff(base: 60, max: 60),
            currentToken: { _ in nil },
            refreshToken: { realm in
                await calls.record(realm)
                if realm == "a" { throw RealmRefreshFailure.denied }
                return "fresh-\(realm.rawValue)"
            }
        )
        let coordinator = RefreshTokenCoordinator(policy: policy, now: { now })
        let aRequest = URLRequest(url: URL(string: "https://a.example.test/value")!)
        let bRequest = URLRequest(url: URL(string: "https://b.example.test/value")!)

        await #expect(throws: RealmRefreshFailure.self) {
            _ = try await coordinator.refreshAndApply(to: aRequest)
        }

        let refreshedB = try await coordinator.refreshAndApply(to: bRequest)
        #expect(refreshedB.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-b")

        await #expect(throws: RealmRefreshFailure.self) {
            _ = try await coordinator.refreshAndApply(to: aRequest)
        }
        #expect(await calls.snapshot() == ["a": 1, "b": 1])
    }
}

private enum RealmRefreshFailure: Error, Sendable {
    case denied
}

private actor RealmRefreshCalls {
    private var counts: [String: Int] = [:]

    func record(_ realm: AuthenticationRealm) {
        counts[realm.rawValue, default: 0] += 1
    }

    func snapshot() -> [String: Int] {
        counts
    }
}
