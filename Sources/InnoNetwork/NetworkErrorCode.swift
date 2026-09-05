import Foundation

/// Catalog of stable integer error codes surfaced by ``NetworkError`` through
/// its `CustomNSError` bridge.
///
/// This enum is the single source of truth for the numeric codes that pair
/// with ``NetworkError/errorDomain``. Codes appear in ``NetworkError/errorCode``,
/// in NSError-bridged failures handed to Cocoa APIs, and in the `errorCode`
/// field of executor-emitted underlying errors. The raw values are part of the
/// public contract; do not renumber an existing case.
///
/// `2001` is intentionally unused. The slot was retired before this enum
/// existed and is preserved as a gap so historical logs that reference `2001`
/// remain unambiguous.
public enum NetworkErrorCode: Int, Sendable {
    // 1xxx — request configuration failures (caller-side).
    case configurationInvalidBaseURL = 1001
    case configurationInvalidRequest = 1002
    case configurationOffline = 1003

    // 2xxx — decoding failures.
    // 2001 intentionally unused (retired before this enum existed).
    case decoding = 2002
    case streamFrameTooLarge = 2003

    // 3xxx — protocol-level response failures.
    case statusCode = 3001
    case nonHTTPResponse = 3002

    // 4xxx — transport / pipeline failures surfaced through `.underlying`.
    case underlying = 4001
    case reachability = 4002
    case responseBodyLimitExceeded = 4003
    case cancelled = 4004
    case timeout = 4005
    case requestAdmissionRejected = 4006
    case requestAdmissionWaitExpired = 4007
    case rateLimitQueueRejected = 4008
    case rateLimitScopeRejected = 4009

    // 5xxx — trust evaluation failures.
    case trustEvaluationFailed = 5001
}
