# Platform Support

## Supported platforms

InnoNetwork ships against the current Apple platforms only:

- iOS 16.0+
- macOS 14.0+
- tvOS 16.0+
- watchOS 9.0+
- visionOS 1.0+

The package targets these versions intentionally so the codebase can rely on
modern Swift Concurrency semantics, strict Sendable checking, and the latest
URLSession surface without compatibility shims. There is no Linux toolchain
support and no plan to add one in 5.x.

## Toolchain support

The root package manifest requires Swift 6.2 and the canonical compatibility
lane uses Xcode 26.0.1. The Xcode 27-only decoded-audio HLS surface moved to
the separate InnoStream package.

## Why no Linux

The library leans on `URLSession`, `OSAllocatedUnfairLock`, `OSLog`,
`Network.framework`, and `UniformTypeIdentifiers`. Each of those is either
Apple-only at the framework level or available on Linux only through partial
shims (`Foundation` on Linux ships a different `URLSession` implementation
that does not match Apple's behaviour, and `OSLog`/`os.unfair_lock` have no
counterpart). Plugging swift-corelibs-foundation or rewriting the storage
primitives would compromise the package's existing isolation contract for an
audience that is better served by `swift-server` ecosystem libraries.

## Sharing models with Linux server code

If you need to share request/response models between an Apple client and a
Linux server (for example, a Vapor backend), keep the model types in a
separate package that depends on neither InnoNetwork nor server-side
frameworks. InnoNetwork itself should stay an Apple-only consumer of those
shared model types.

```text
ProductKit (Linux + Apple)         ← shared Decodable/Encodable models
  ├── InnoNetwork (Apple-only)     ← API definitions, transport policy
  └── VaporServer  (Linux-only)    ← server handlers
```

## CI matrix

The canonical SwiftPM and bounded-shard compatibility lanes run on `macos-15`
with Xcode 26.0.1. A second required SwiftPM lane, dead-code analysis, docs
contract validation, and HLS-audio tests run on GitHub's `xcode-27` image so
the SDK-only surface cannot be hidden by its compatibility guards. Adding a
Linux build leg is intentionally out of scope; it would not catch a supported
regression because the package does not compile on Linux.

## Supply-chain provenance

Tagged releases produce trait-profile artifacts that consumers can verify:

- `sbom.cdx.json` — CycloneDX 1.5 software bill of materials describing the
  default-trait package graph and build inputs. It includes the root macro
  toolchain inputs. The root manifest also records `swift-http-types` and
  `swift-openapi-runtime` for the optional `InnoNetworkOpenAPI` companion
  product; those types do not replace the core request/header/response API.
- `sbom-core-only.cdx.json` — the root manifest's core-only (`traits: []`)
  profile. Macro products and compiler plug-in compilation are excluded, but
  SwiftPM may still resolve or fetch package-level manifest dependencies.
- `benchmarks.json` — frozen benchmark output from the release validation
  job.

All three artifacts are signed with sigstore cosign keyless signatures. See
[SECURITY.md](../SECURITY.md) for the exact `cosign verify-blob` invocation.
