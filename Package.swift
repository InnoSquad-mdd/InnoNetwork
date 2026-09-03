// swift-tools-version: 6.2

import CompilerPluginSupport
import PackageDescription

/// Swift 6 language mode is enabled for every target so strict concurrency
/// checking is a permanent part of the build contract (no opt-in flag
/// required). CI no longer passes `-strict-concurrency=complete` explicitly —
/// this setting carries the same semantics and stays enforced for consumers
/// that build from source.
let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6)
]

// Platform policy: InnoNetwork is intentionally Apple-only. The library
// depends on URLSession, OSAllocatedUnfairLock, OSLog, Network.framework,
// and UniformTypeIdentifiers, none of which match Apple-platform behaviour
// on Linux. See `docs/PlatformSupport.md` for the rationale and for
// guidance on sharing models with Linux server code (e.g. Vapor).

let package = Package(
    name: "InnoNetwork",
    defaultLocalization: "en",
    platforms: [
        // 4.0.0 first public release floors. macOS 14 remains the established
        // baseline for the package's modern concurrency contract. The network
        // reachability implementation actor-isolates `NWPathMonitor`, so the
        // lower iOS/tvOS/watchOS floors do not depend on that framework type's
        // newer OS-only `Sendable` conformance.
        .iOS(.v16),
        .macOS(.v14),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "InnoNetwork",
            targets: ["InnoNetwork"]
        ),
        .library(
            name: "InnoNetworkAuthAWS",
            targets: ["InnoNetworkAuthAWS"]
        ),
        .library(
            name: "InnoNetworkDownload",
            targets: ["InnoNetworkDownload"]
        ),
        .library(
            name: "InnoNetworkUpload",
            targets: ["InnoNetworkUpload"]
        ),
        .library(
            name: "InnoNetworkWebSocket",
            targets: ["InnoNetworkWebSocket"]
        ),
        .library(
            name: "InnoNetworkPersistentCache",
            targets: ["InnoNetworkPersistentCache"]
        ),
        .library(
            name: "InnoNetworkOpenAPI",
            targets: ["InnoNetworkOpenAPI"]
        ),
        // Optional public-key pinning evaluator. Split out of the core
        // module in PR-1 so apps that don't pin (the common case) don't
        // pay the SPKI/DER surface cost. To pin, link this product and
        // wrap your `PublicKeyPinningPolicy` with
        // `PublicKeyPinningEvaluator(policy:)`, then pass it via
        // `TrustPolicy.custom(_:)`.
        .library(
            name: "InnoNetworkTrust",
            targets: ["InnoNetworkTrust"]
        ),
        // Test helpers that consumers can pull into *their* test targets to
        // assert on InnoNetwork integrations (for example
        // ``MockURLSession``, ``StubNetworkClient``, and
        // ``WebSocketEventRecorder``). Most internals remain `package`-scoped
        // so they only stay visible to the package's own test targets; only
        // the explicitly `public` symbols cross the library boundary.
        // Promoted to a public product in PR-1; see API_STABILITY.md for the
        // contract scope (Provisionally Stable).
        .library(
            name: "InnoNetworkTestSupport",
            targets: ["InnoNetworkTestSupport"]
        ),
    ],
    traits: [
        .trait(
            name: "Macros",
            description: "Enables @APIDefinition compile-time generation."
        ),
        .default(enabledTraits: ["Macros"]),
    ],
    dependencies: [
        // `InnoNetworkOpenAPI` imports HTTPTypes directly at its generated-client
        // transport boundary. Keep that dependency explicit instead of relying
        // on swift-openapi-runtime to expose its own transitive dependency.
        // OpenAPI Runtime 1.12 enables HTTP Types' FoundationURL trait, which
        // is available from 1.6.0. Keep that executable compatibility floor
        // while allowing SwiftPM to select newer compatible 1.x releases.
        .package(
            url: "https://github.com/apple/swift-http-types",
            .upToNextMajor(from: "1.6.0")
        ),
        // The root package resolves `swift-openapi-runtime` because it ships
        // the optional `InnoNetworkOpenAPI` companion product. The 1.x range
        // keeps the runtime's `ClientTransport` surface under explicit
        // major-version review.
        .package(
            url: "https://github.com/apple/swift-openapi-runtime",
            .upToNextMajor(from: "1.0.0")
        ),
        // Macro expansion formatting and diagnostic locations are part of the
        // generated-code contract and are locked by macro expansion/E2E tests.
        // Keep patch-level compatibility so apps can resolve InnoNetwork beside
        // another 603.0.x macro package without forcing identical patch pins.
        // Products and the compiler plug-in remain reachable only when the
        // Macros trait is enabled; SwiftPM still resolves manifest dependencies.
        .package(
            url: "https://github.com/swiftlang/swift-syntax.git",
            .upToNextMinor(from: "603.0.1")
        ),
        // Swift Crypto is used only by the optional cryptographic surfaces:
        // the AWS SigV4 companion product, public-key pinning, and persistent
        // cache key normalization. Core request execution continues to avoid
        // broad cryptographic policy ownership.
        .package(
            url: "https://github.com/apple/swift-crypto",
            .upToNextMajor(from: "4.0.0")
        ),
    ],
    targets: [
        .macro(
            name: "InnoNetworkMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            path: "Sources/InnoNetworkMacros",
            swiftSettings: strictSettings
        ),
        .target(
            name: "InnoNetwork",
            dependencies: [
                .target(
                    name: "InnoNetworkMacros",
                    condition: .when(traits: ["Macros"])
                )
            ],
            path: "Sources/InnoNetwork",
            // Bundles the `Resources/en.lproj/Localizable.strings`
            // catalogue that backs ``NetworkError.errorDescription``.
            // Additional locales can be added by dropping new
            // `<lang>.lproj/Localizable.strings` siblings; consumers that
            // need other languages should localize at the application
            // layer rather than wait for library-side translations.
            // Also bundles `Resources/PrivacyInfo.xcprivacy` declaring the
            // File Timestamp Required Reason API used by
            // `MultipartFormData.attributesOfItem(...)`.
            resources: [.process("Resources")],
            swiftSettings: strictSettings
        ),
        .target(
            name: "InnoNetworkAuthAWS",
            dependencies: [
                "InnoNetwork",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/InnoNetworkAuthAWS",
            exclude: ["README.md"],
            swiftSettings: strictSettings
        ),
        .target(
            name: "InnoNetworkDownload",
            dependencies: ["InnoNetwork"],
            path: "Sources/InnoNetworkDownload",
            // Bundles `Resources/PrivacyInfo.xcprivacy` declaring the
            // File Timestamp Required Reason API used by
            // `DownloadTaskPersistence.attributesOfItem(...)`.
            resources: [.process("Resources")],
            swiftSettings: strictSettings
        ),
        .target(
            name: "InnoNetworkUpload",
            dependencies: ["InnoNetwork"],
            path: "Sources/InnoNetworkUpload",
            swiftSettings: strictSettings
        ),
        .target(
            name: "InnoNetworkWebSocket",
            dependencies: ["InnoNetwork"],
            path: "Sources/InnoNetworkWebSocket",
            swiftSettings: strictSettings
        ),
        .target(
            name: "InnoNetworkPersistentCache",
            dependencies: [
                "InnoNetwork",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/InnoNetworkPersistentCache",
            // Bundles `Resources/PrivacyInfo.xcprivacy` declaring the
            // File Timestamp Required Reason API used by
            // `PersistentResponseCache.attributesOfItem(...)`.
            resources: [.process("Resources")],
            swiftSettings: strictSettings
        ),
        .target(
            name: "InnoNetworkOpenAPI",
            dependencies: [
                "InnoNetwork",
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            path: "Sources/InnoNetworkOpenAPI",
            swiftSettings: strictSettings
        ),
        .target(
            name: "InnoNetworkTrust",
            dependencies: [
                "InnoNetwork",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/InnoNetworkTrust",
            swiftSettings: strictSettings
        ),
        // Test helpers. Public symbols here form a Provisionally Stable
        // contract; the library is intended for *consumer* test targets and
        // should not be linked into production binaries. Internal helpers
        // (TestClock, anything depending on `package`-scope abstractions like
        // ``InnoNetworkClock``) remain `package`-visible for now and stay
        // available to this package's own test targets.
        .target(
            name: "InnoNetworkTestSupport",
            dependencies: [
                "InnoNetwork",
                "InnoNetworkDownload",
                "InnoNetworkPersistentCache",
                "InnoNetworkWebSocket",
            ],
            path: "Sources/InnoNetworkTestSupport",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "InnoNetworkBenchmarks",
            dependencies: [
                "InnoNetwork",
                "InnoNetworkDownload",
                "InnoNetworkWebSocket",
            ],
            path: "Benchmarks/InnoNetworkBenchmarks",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "InnoNetworkDocSmoke",
            dependencies: [
                "InnoNetwork",
                "InnoNetworkAuthAWS",
                "InnoNetworkDownload",
                "InnoNetworkUpload",
                "InnoNetworkOpenAPI",
                "InnoNetworkPersistentCache",
                "InnoNetworkWebSocket",
            ],
            path: "SmokeTests/InnoNetworkDocSmoke",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "InnoNetworkDownloadSmoke",
            dependencies: [
                "InnoNetwork",
                "InnoNetworkDownload",
            ],
            path: "SmokeTests/InnoNetworkDownloadSmoke",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "InnoNetworkWebSocketSmoke",
            dependencies: [
                "InnoNetwork",
                "InnoNetworkWebSocket",
            ],
            path: "SmokeTests/InnoNetworkWebSocketSmoke",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "InnoNetworkCacheSmoke",
            dependencies: [
                "InnoNetwork",
                "InnoNetworkPersistentCache",
            ],
            path: "SmokeTests/InnoNetworkCacheSmoke",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "InnoNetworkOpenAPISmoke",
            dependencies: [
                "InnoNetwork",
                "InnoNetworkOpenAPI",
            ],
            path: "SmokeTests/InnoNetworkOpenAPISmoke",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "InnoNetworkTests",
            dependencies: [
                "InnoNetwork",
                "InnoNetworkOpenAPI",
                "InnoNetworkTestSupport",
                "InnoNetworkTrust",
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            path: "Tests/InnoNetworkTests",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "InnoNetworkMacroTests",
            dependencies: [
                "InnoNetwork",
                "InnoNetworkTestSupport",
                .target(
                    name: "InnoNetworkMacros",
                    condition: .when(platforms: [.macOS], traits: ["Macros"])
                ),
                .product(
                    name: "SwiftDiagnostics",
                    package: "swift-syntax",
                    condition: .when(platforms: [.macOS], traits: ["Macros"])
                ),
                .product(
                    name: "SwiftSyntaxMacros",
                    package: "swift-syntax",
                    condition: .when(platforms: [.macOS], traits: ["Macros"])
                ),
                .product(
                    name: "SwiftSyntaxMacrosTestSupport",
                    package: "swift-syntax",
                    condition: .when(platforms: [.macOS], traits: ["Macros"])
                ),
            ],
            path: "Tests/InnoNetworkMacroTests",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "InnoNetworkAuthAWSTests",
            dependencies: [
                "InnoNetwork",
                "InnoNetworkAuthAWS",
            ],
            path: "Tests/InnoNetworkAuthAWSTests",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "InnoNetworkDownloadTests",
            dependencies: ["InnoNetworkDownload", "InnoNetworkTestSupport"],
            path: "Tests/InnoNetworkDownloadTests",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "InnoNetworkUploadTests",
            dependencies: ["InnoNetwork", "InnoNetworkUpload", "InnoNetworkTestSupport"],
            path: "Tests/InnoNetworkUploadTests",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "InnoNetworkWebSocketTests",
            dependencies: ["InnoNetworkWebSocket", "InnoNetworkTestSupport"],
            path: "Tests/InnoNetworkWebSocketTests",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "InnoNetworkPersistentCacheTests",
            dependencies: ["InnoNetwork", "InnoNetworkPersistentCache"],
            path: "Tests/InnoNetworkPersistentCacheTests",
            swiftSettings: strictSettings
        ),
        // Live-endpoint smoke tests. Builds unconditionally so the test
        // target stays in package resolution, but every test guards on the
        // INNO_LIVE environment variable so a default `swift test` run is
        // a fast no-op. Run with `INNO_LIVE=1 swift test --filter InnoNetworkLiveTests`
        // — typically wired into a nightly GitHub Actions schedule rather
        // than the per-PR CI to keep builds deterministic.
        .testTarget(
            name: "InnoNetworkLiveTests",
            dependencies: [
                "InnoNetwork",
                "InnoNetworkDownload",
                "InnoNetworkWebSocket",
                "InnoNetworkTestSupport",
            ],
            path: "Tests/InnoNetworkLiveTests",
            swiftSettings: strictSettings
        ),
    ]
)
