import Foundation

/// The configuration façade for the operation-first networking contract.
///
/// The value intentionally exposes construction rather than a mutable mirror
/// of every runtime field. Keep application-owned configuration inputs when
/// they also need to be displayed or edited after client construction.
public struct NetworkClientConfiguration: Sendable {
    package let v5Configuration: NetworkConfiguration

    /// Creates the secure production baseline: HTTPS admission, system trust,
    /// bounded response collection, and no automatic retry.
    public static func secure(baseURL: URL) -> Self {
        Self(v5Configuration: .safeDefaults(baseURL: baseURL))
    }

    /// Composes explicit policy packs on top of the production baseline.
    public static func production(
        baseURL: URL,
        resilience: ResiliencePack = ResiliencePack(),
        authentication: AuthPack = AuthPack(),
        observability: ObservabilityPack = ObservabilityPack(),
        cache: CachePack = CachePack(),
        transport: TransportPack = TransportPack()
    ) -> Self {
        Self(
            v5Configuration: .advanced(
                baseURL: baseURL,
                resilience: resilience,
                auth: authentication,
                observability: observability,
                cache: cache,
                transport: transport
            )
        )
    }

    /// Wraps an existing legacy configuration during incremental migration.
    public init(migratingV5 configuration: NetworkConfiguration) {
        self.v5Configuration = configuration
    }

    /// Returns the wrapped legacy value for code paths that have not migrated to
    /// ``OperationNetworkClient`` yet.
    public var legacyConfiguration: NetworkConfiguration {
        v5Configuration
    }

    package init(v5Configuration: NetworkConfiguration) {
        self.v5Configuration = v5Configuration
    }
}
