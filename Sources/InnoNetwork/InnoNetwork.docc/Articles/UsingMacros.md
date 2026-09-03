# Using Macros

Define an endpoint as an explicit value and let ``APIDefinition(method:path:auth:)``
derive only its repetitive protocol witnesses. The struct remains the source of
truth for the endpoint contract: its stored inputs and explicit `APIResponse`
show what goes in and what comes back.

```swift
import InnoNetwork

@APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
struct GetUser {
    typealias APIResponse = User

    let id: Int
}

let user = try await client.request(GetUser(id: 42))
```

The macro is part of the root `InnoNetwork` product. The package's default
`Macros` trait enables it, so macro users need neither another package nor
another import.

## Stability contract

`@APIDefinition(method:path:auth:)`, the default-enabled `Macros` trait, and
the explicit `traits: []` opt-out are Stable in InnoNetwork 6. Existing
accepted declarations keep their generated method, percent-encoded path,
authentication, conformance, and payload-witness meaning throughout 6.x. New
macro arguments may be added only with defaults. Manual ``APIDefinition``
conformance remains the supported non-macro fallback.

Exact generated-source formatting, diagnostic prose, and Fix-It wording may
improve in a minor release. The accepted-source boundary and fail-closed
diagnostic categories remain protected.

## What the macro owns

The macro adds ``APIDefinition`` conformance and derives:

- `method` and a percent-encoded `path`
- `Parameter` and `parameters` for the supported simple payload shape
- `sessionAuthentication` from the explicit `auth:` choice

It deliberately does **not** synthesize `APIResponse`, headers, interceptors,
signers, transport, decoding, or execution policies. Keep those decisions on
the endpoint struct when it owns them. Authentication is also mandatory at the
attribute: every endpoint must choose `.anonymous`, `.optional`, or `.required`
rather than silently inheriting a security policy.

`path:` must be an ordinary single-line string literal; raw and multiline
literals fail with a targeted diagnostic because their source spelling cannot
be safely re-emitted as generated interpolation. Path placeholders must match
stored properties declared directly on the struct. Values pass through
``EndpointPathEncoding/percentEncodedSegment(_:)-(String)``, so a slash, space, percent
sign, or non-ASCII scalar stays inside one path segment.

Placeholder values must be non-optional. The macro diagnoses direct `T?`,
`Optional<T>`, and `Swift.Optional<T>` declarations during expansion. If a
property uses an alias that resolves to Optional, the generated path witness
adds a type-check-time diagnostic with the same action: unwrap the value and
define what nil means before constructing the endpoint.

## Query and body inference

A stored `query` property is the simple GET or HEAD shape:

```swift
@APIDefinition(method: .get, path: "/users", auth: .anonymous)
struct ListUsers {
    typealias APIResponse = [User]

    let query: ListUsersQuery
}
```

A stored `body` property is the simple POST, PUT, PATCH, or DELETE shape:

```swift
@APIDefinition(method: .post, path: "/users", auth: .required)
struct CreateUser {
    typealias APIResponse = User

    let body: CreateUserRequest
}
```

An endpoint cannot infer both roles. GET/HEAD bodies, query inference for the
body methods, and simple payload inference for OPTIONS, CONNECT, TRACE, custom,
or dynamic methods are rejected because their transport meaning is not safe to
guess. Optional `body` or `query` aliases are supported; `nil` means no payload.

For an advanced payload shape, declare the complete `Parameter` + `parameters`
pair. That pair is authoritative and turns off simple body/query inference:

```swift
@APIDefinition(method: .get, path: "/users/search", auth: .anonymous)
struct SearchUsers {
    typealias APIResponse = [User]
    typealias Parameter = SearchPayload

    let filters: SearchPayload

    var parameters: Parameter? { filters }
    var transport: TransportPolicy<[User]> { .query() }
}
```

This escape hatch keeps custom encoding, computed payloads, and endpoint policy
explicit without giving up compile-time path and auth validation. Multipart
and streaming endpoints continue to use their dedicated protocols.

## Custom HTTP methods

``HTTPMethod/init(rawValue:)`` validates an RFC 9110 method token and returns
`nil` for whitespace, control characters, separators, non-ASCII values, or an
empty string. Handle that result when a method comes from configuration instead
of passing unchecked text to the transport:

```swift
enum ConfigurationError: Error {
    case invalidHTTPMethod(String)
}

guard let method = HTTPMethod(rawValue: configuredMethod) else {
    throw ConfigurationError.invalidHTTPMethod(configuredMethod)
}

let result = try await client.request(
    EndpointBuilder<EmptyResponse>(method: method, path: "/resources")
        .authentication(.anonymous)
        .decoding([Resource].self)
)
```

For a fixed custom method in `@APIDefinition`, keep the payload contract
explicit with a complete `Parameter` + `parameters` pair. Simple `body` or
`query` inference intentionally accepts only GET/HEAD, while `body` inference
accepts only POST/PUT/PATCH/DELETE. The macro cannot safely guess where
OPTIONS, CONNECT, TRACE, custom, or dynamic methods carry their payload.

## Diagnostics are fail closed

`@APIDefinition` emits a compile error when the declaration would be ambiguous
or incomplete, including:

- attaching the macro to anything other than a struct
- omitting `typealias APIResponse`
- omitting `auth:` or passing anything other than `.anonymous`, `.optional`, or
  `.required`; `SessionAuthentication.required` and
  `InnoNetwork.SessionAuthentication.required` are also accepted
- using an alias or arbitrary qualified base for a standard method used in
  simple payload inference; `.get`, `HTTPMethod.get`, and
  `InnoNetwork.HTTPMethod.get` are canonicalized to the same generated witness
- duplicating generated conformance, `method`, `path`, or
  `sessionAuthentication` witnesses
- using a missing, optional, opaque, or unsupported generic path placeholder;
  Optional aliases receive the same targeted error during generated-code type
  checking
- putting query/fragment text or an invalid percent escape in `path:`
- using a raw or multiline `path:` literal
- using computed, static, or lazy `body` / `query` properties in simple mode
- declaring only one half of the manual `Parameter` + `parameters` pair
- asking a custom or dynamic method to infer a simple `body` / `query` payload
- declaring a simple-mode stored property that is not consumed by a path
  placeholder or the inferred payload
- using tuple or other destructuring bindings in simple mode

Declare a complete `Parameter` + `parameters` pair when a custom payload model
needs stored values or binding shapes that simple inference cannot consume.
That explicit contract is the escape hatch from simple-mode inference.

Simple string interpolation in `path:` receives a Fix-It to use `{property}`
placeholder syntax. A redundant `typealias Parameter = EmptyParameter` emits a
warning because the macro already derives it for an empty request.

Swift cannot distinguish an endpoint that accidentally omitted the attribute
from an ordinary struct at its declaration. When that value first reaches
`NetworkClient.request`, both the ordinary and cancellation-tag overloads fail
with a targeted diagnostic:

> Request types must conform to APIDefinition. Add
> @APIDefinition(method:path:auth:) to the endpoint struct, or provide a manual
> conformance.

This keeps the explicit struct as the source of truth while turning the first
provable misuse into an actionable macro-first correction.

The 4.x `#endpoint` expression macro is removed in 5.0. For an unnamed or
runtime-composed request, use the stable ``EndpointBuilder`` API. For generated
OpenAPI clients, keep `swift-http-types` and OpenAPI Runtime integration behind
the optional `InnoNetworkOpenAPI` companion product rather than exposing those
types through the core endpoint contract.

## Disabling macro support

Consumers that never use macros can disable the default trait on the package
dependency:

```swift
dependencies: [
    .package(
        url: "https://github.com/InnoSquadCorp/InnoNetwork.git",
        .upToNextMajor(from: "5.0.0"),
        traits: []
    )
]
```

Use `exact: "5.0.0"` when a reproducible release build must not accept any
dependency update. The 4.x package does not expose the 5.0 macro contract
shown here.

With `traits: []`, the macro declaration is absent and the compiler plug-in
products are excluded from the target graph and compilation. SwiftPM still
resolves package-level manifest dependencies, so it may resolve or fetch the
`swift-syntax` source package even though it does not build the macro plug-in.
This is a SwiftPM manifest-resolution limitation, not a runtime dependency of
`InnoNetwork`. Traits are unified for each package across the resolved graph;
if another dependency enables the default `Macros` trait, it is enabled for
that shared package instance. A core-only graph must therefore request
`traits: []` consistently along every dependency path.
