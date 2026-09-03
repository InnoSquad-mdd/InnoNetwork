# Auth Refresh

Use ``RefreshTokenPolicy`` when a client should refresh a bearer token after an
authentication response and replay the fully adapted request once.

Auth refresh is part of InnoNetwork's internal execution pipeline, not a public
retry policy. The public surface stays narrow: callers provide closures for
reading the current token, refreshing it, and optionally applying it to a
`URLRequest`.

```swift
let refreshPolicy = RefreshTokenPolicy(
    currentToken: {
        try await tokenStore.currentAccessToken()
    },
    refreshToken: {
        try await authService.refreshAccessToken()
    }
)

let client = DefaultNetworkClient(
    configuration: .advanced(
        baseURL: URL(string: "https://api.example.com")!,
        auth: AuthPack(refreshToken: refreshPolicy)
    )
)
```

The default behaviour is:

- apply the current token before transport when one is available
- refresh on `401`
- collapse concurrent refreshes into one in-flight operation
- return a cancelled waiter promptly without cancelling a shared refresh for
  other requests; releasing the coordinator cancels an orphaned in-flight
  refresh task
- replay the fully adapted request at most once, preserving session and
  endpoint interceptor headers while clearing the prior `Authorization` header
  before reapplying so custom applicators that use `addValue` stay idempotent
- surface refresh failures to every waiting request, while a *failed* refresh
  is not cached: the next 401 will start a fresh refresh attempt instead of
  replaying the previous failure

Provide `refreshStatusCodes:` or `applyToken:` only when your API differs from
standard bearer-token authentication.

## Isolate Multiple Authentication Realms

Use the realm-aware initializer when one client reaches multiple tenants,
principals, or identity providers. Returning `nil` excludes a request from the
policy. Non-nil realms keep independent refresh tasks, generations, and failure
cooldowns.

```swift
let refreshPolicy = RefreshTokenPolicy(
    realmForRequest: { request in
        switch request.url?.host {
        case "customer.example.com": "customer"
        case "operator.example.com": "operator"
        default: nil
        }
    },
    currentToken: { realm in
        try await tokenStore.currentAccessToken(for: realm.rawValue)
    },
    refreshToken: { realm in
        try await authService.refreshAccessToken(for: realm.rawValue)
    }
)
```

Realm identifiers are process-memory routing keys, not credentials. Avoid
putting access tokens or other secrets in ``AuthenticationRealm/rawValue``.

## Shared Refresh Task Ownership

The refresh operation is intentionally owned by the coordinator, not by the
first request that observes `401`. Internally that shared work may use a
detached task boundary so one caller's cancellation or priority does not
cancel or downgrade the refresh needed by other waiting requests. A cancelled
waiter returns promptly, while the coordinator keeps the refresh alive until it
succeeds, fails, or the coordinator is released.

## Mark Auth-Required Endpoints

Choose `.required` explicitly so an authenticated endpoint cannot silently run
through a client configuration that has no token provider:

```swift
struct Profile: Decodable, Sendable {
    let id: String
}

let endpoint = EndpointBuilder<EmptyResponse>
    .get("/me")
    .authentication(.required)
    .decoding(Profile.self)

let profile = try await client.request(endpoint)
```

Custom endpoint definitions can opt into the same preflight guard:

```swift
struct GetProfile: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = Profile
    let method: HTTPMethod = .get
    let path = "/me"
    let sessionAuthentication: SessionAuthentication = .required
}
```

If the client was not built with `AuthPack(refreshToken:)`, the request fails
before transport with ``NetworkError/configuration(reason:)`` and
``NetworkConfigurationFailureReason/invalidRequest(_:)``. Named manual
endpoints must also declare `sessionAuthentication`; use `.anonymous` when the
request must never participate in bearer-token refresh, or `.optional` when it
may use a configured token but is allowed to proceed without one.
