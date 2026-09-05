import Foundation
import InnoNetwork

/// Memory and lifecycle limits applied before upload delegate events enter
/// the manager actor.
public struct UploadResourcePolicy: Sendable, Equatable {
    public let maximumTrackedTasks: Int
    public let maximumBufferedDelegateEvents: Int
    public let maximumBufferedDelegateBytes: Int
    public let maximumPendingUnknownTasks: Int
    public let maximumRetainedTerminalTasks: Int?

    /// A conservative process-local resource profile.
    public static let safeDefaults = UploadResourcePolicy(
        maximumTrackedTasks: 256,
        maximumBufferedDelegateEvents: 512,
        maximumBufferedDelegateBytes: 2 * 1_048_576,
        maximumPendingUnknownTasks: 64,
        maximumRetainedTerminalTasks: nil
    )

    /// Creates an explicit upload resource profile.
    ///
    /// Pass `nil` for `maximumRetainedTerminalTasks` to preserve every
    /// terminal task until the manager is released. Other limits must be
    /// positive and are clamped to one when necessary.
    public init(
        maximumTrackedTasks: Int,
        maximumBufferedDelegateEvents: Int,
        maximumBufferedDelegateBytes: Int,
        maximumPendingUnknownTasks: Int,
        maximumRetainedTerminalTasks: Int? = nil
    ) {
        self.maximumTrackedTasks = max(1, maximumTrackedTasks)
        self.maximumBufferedDelegateEvents = max(1, maximumBufferedDelegateEvents)
        self.maximumBufferedDelegateBytes = max(1, maximumBufferedDelegateBytes)
        self.maximumPendingUnknownTasks = max(1, maximumPendingUnknownTasks)
        self.maximumRetainedTerminalTasks = maximumRetainedTerminalTasks.map { max(0, $0) }
    }
}

/// Configures file-upload transport, response buffering, and event delivery.
///
/// The configuration is an opaque command. Use ``safeDefaults()`` for a
/// foreground session, ``advanced(allowsCellularAccess:maximumResponseBytes:acceptableStatusCodes:eventDeliveryPolicy:eventMetricsReporter:)``
/// for a tuned foreground session, or
/// ``background(sessionIdentifier:sharedContainerIdentifier:allowsCellularAccess:maximumResponseBytes:acceptableStatusCodes:eventDeliveryPolicy:eventMetricsReporter:)``
/// for process-independent transfer continuation.
public struct UploadConfiguration: Sendable {
    package enum SessionMode: Sendable, Equatable {
        case foreground
        case background
    }

    package let sessionMode: SessionMode
    package let sessionIdentifier: String?
    package let sharedContainerIdentifier: String?
    package let allowsCellularAccess: Bool
    package let maximumResponseBytes: Int
    package let acceptableStatusCodes: Set<Int>
    package let eventDeliveryPolicy: EventDeliveryPolicy
    package let eventMetricsReporter: (any EventPipelineMetricsReporting)?
    package let resourcePolicy: UploadResourcePolicy

    /// Creates the secure foreground configuration.
    ///
    /// HTTPS is always required. Response bodies are capped at 1 MiB and
    /// status codes in `200...299` are accepted.
    public static func safeDefaults() -> Self {
        Self(
            sessionMode: .foreground,
            sessionIdentifier: nil,
            sharedContainerIdentifier: nil,
            allowsCellularAccess: false,
            maximumResponseBytes: 1_048_576,
            acceptableStatusCodes: Set(200...299),
            eventDeliveryPolicy: .default,
            eventMetricsReporter: nil,
            resourcePolicy: .safeDefaults
        )
    }

    /// Creates a tuned foreground upload configuration.
    public static func advanced(
        allowsCellularAccess: Bool = false,
        maximumResponseBytes: Int = 1_048_576,
        acceptableStatusCodes: Set<Int> = Set(200...299),
        eventDeliveryPolicy: EventDeliveryPolicy = .default,
        eventMetricsReporter: (any EventPipelineMetricsReporting)? = nil,
        resourcePolicy: UploadResourcePolicy = .safeDefaults
    ) -> Self {
        Self(
            sessionMode: .foreground,
            sessionIdentifier: nil,
            sharedContainerIdentifier: nil,
            allowsCellularAccess: allowsCellularAccess,
            maximumResponseBytes: max(0, maximumResponseBytes),
            acceptableStatusCodes: acceptableStatusCodes,
            eventDeliveryPolicy: eventDeliveryPolicy,
            eventMetricsReporter: eventMetricsReporter,
            resourcePolicy: resourcePolicy
        )
    }

    /// Creates a background file-upload configuration.
    ///
    /// Background requests containing `Authorization`, `Cookie`, or
    /// `Proxy-Authorization` are rejected because Foundation can follow a
    /// background redirect without giving the library a per-hop admission
    /// callback. Prefer short-lived, origin-bound pre-signed HTTPS URLs.
    public static func background(
        sessionIdentifier: String,
        sharedContainerIdentifier: String? = nil,
        allowsCellularAccess: Bool = false,
        maximumResponseBytes: Int = 1_048_576,
        acceptableStatusCodes: Set<Int> = Set(200...299),
        eventDeliveryPolicy: EventDeliveryPolicy = .default,
        eventMetricsReporter: (any EventPipelineMetricsReporting)? = nil,
        resourcePolicy: UploadResourcePolicy = .safeDefaults
    ) -> Self {
        Self(
            sessionMode: .background,
            sessionIdentifier: sessionIdentifier,
            sharedContainerIdentifier: sharedContainerIdentifier,
            allowsCellularAccess: allowsCellularAccess,
            maximumResponseBytes: max(0, maximumResponseBytes),
            acceptableStatusCodes: acceptableStatusCodes,
            eventDeliveryPolicy: eventDeliveryPolicy,
            eventMetricsReporter: eventMetricsReporter,
            resourcePolicy: resourcePolicy
        )
    }

    package func makeURLSessionConfiguration() -> URLSessionConfiguration {
        let configuration: URLSessionConfiguration
        switch sessionMode {
        case .foreground:
            configuration = .ephemeral
        case .background:
            guard let sessionIdentifier else {
                preconditionFailure("Background upload configuration requires a session identifier")
            }
            configuration = .background(withIdentifier: sessionIdentifier)
            configuration.sessionSendsLaunchEvents = true
            configuration.isDiscretionary = false
            configuration.sharedContainerIdentifier = sharedContainerIdentifier
        }
        configuration.allowsCellularAccess = allowsCellularAccess
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }
}
