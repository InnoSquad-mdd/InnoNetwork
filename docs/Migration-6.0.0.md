# Migration Guide: 6.0.0

This guide describes the unreleased InnoNetwork 6.0 draft. There is no
`6.0.0` tag yet; keep production applications on `5.1.0` until the release
notes are marked ready and the tag is published.

## Package boundary changes

InnoNetwork 6 removes the temporary `InnoNetworkNext` preview product and the
four HLS products. Operation-first APIs move into the root `InnoNetwork`
module, while HLS moves to the independently versioned InnoStream package.

Before:

```swift
dependencies: [
    .package(
        url: "https://github.com/InnoSquadCorp/InnoNetwork.git",
        .upToNextMajor(from: "5.1.0")
    )
],
targets: [
    .target(
        name: "MediaFeature",
        dependencies: [
            .product(name: "InnoNetworkNext", package: "InnoNetwork"),
            .product(name: "InnoNetworkHLS", package: "InnoNetwork"),
        ]
    )
]
```

After both release tags exist:

```swift
dependencies: [
    .package(
        url: "https://github.com/InnoSquadCorp/InnoNetwork.git",
        .upToNextMajor(from: "6.0.0")
    ),
    .package(
        url: "https://github.com/InnoSquadCorp/InnoStream.git",
        .upToNextMajor(from: "1.0.0")
    ),
],
targets: [
    .target(
        name: "MediaFeature",
        dependencies: [
            .product(name: "InnoNetwork", package: "InnoNetwork"),
            .product(name: "InnoNetworkHLS", package: "InnoStream"),
        ]
    )
]
```

Apply the same package-owner change to `InnoNetworkHLSLive`,
`InnoNetworkHLSAVFoundation`, and `InnoNetworkHLSAudio`. Source imports keep
their existing module names. Replace `import InnoNetworkNext` with
`import InnoNetwork`.

## Operation recovery contract

`OperationNetworkClient.start(_:)` infers replay safety from the HTTP method.
GET, HEAD, OPTIONS, and TRACE may recommend retry after a transient failure.
Unsafe methods stay terminal unless the application owns a stable idempotency
key that is reused across operation restarts:

```swift
let operation = client.start(
    CreateOrder(idempotencyKey: orderAttemptID),
    replaySafety: .stableIdempotencyKey
)
```

A 401 recommends `.reauthenticate` only for session-authenticated endpoints.
A 403 remains terminal. Reauthentication never authorizes automatic replay;
the application still decides whether to start another operation.

## Validation order

1. Build InnoNetwork and InnoStream together with `INNONETWORK_LOCAL_PATH`.
2. Build non-HLS consumers against the local InnoNetwork 6 candidate.
3. Publish and verify InnoNetwork `6.0.0`.
4. Resolve InnoStream without a local override, then publish and verify
   InnoStream `1.0.0`.
5. Resolve migrated HLS consumers from a clean checkout using only the two
   published tags.
6. Publish companion packages only after their clean tagged-dependency smoke
   passes.

Local-path builds prove source compatibility but do not prove remote package
identity, tag availability, or a clean resolver graph.
