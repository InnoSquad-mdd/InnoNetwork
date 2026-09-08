//
//  Response.swift
//  Network
//
//  Created by Chang Woo Son on 6/20/24.
//

import Foundation

public struct Response: CustomDebugStringConvertible, Equatable, Sendable {

    /// Whether the response carries a fully-buffered body or is the
    /// header-only handshake of a streaming response whose body is
    /// delivered out-of-band through an `AsyncSequence`.
    ///
    /// Response interceptors that inspect ``data`` (e.g. for error-body
    /// shape detection) should branch on this — for ``Kind/headersOnly``
    /// the data field is intentionally empty and must not be treated as a
    /// successfully-decoded empty body.
    public enum Kind: Sendable, Equatable {
        /// Standard request/response: ``Response/data`` carries the full
        /// (possibly empty) body bytes received from the server.
        case body
        /// Streaming handshake: ``Response/data`` is empty because the
        /// body is delivered through an `AsyncSequence` rather than
        /// buffered. Interceptors must not draw conclusions from
        /// ``Response/data`` in this case.
        case headersOnly
    }

    /// The status code of the response.
    public let statusCode: Int

    /// The response data.
    public let data: Data

    /// The original URLRequest for the response.
    public let request: URLRequest?

    /// The HTTPURLResponse object.
    public let response: HTTPURLResponse?

    /// Whether this response represents a buffered body or a
    /// streaming-handshake marker. See ``Response/Kind`` for the
    /// semantics interceptors should follow.
    public let kind: Kind

    /// Correlates an executor-produced response with its physical transport
    /// timing while it passes through custom execution policies. Publicly
    /// constructed or transformed responses intentionally have no identity.
    package let transportTimingID: UUID?

    public init(
        statusCode: Int,
        data: Data,
        request: URLRequest? = nil,
        response: HTTPURLResponse,
        kind: Kind = .body
    ) {
        self.init(
            statusCode: statusCode,
            data: data,
            request: request,
            response: response,
            kind: kind,
            transportTimingID: nil
        )
    }

    package init(
        statusCode: Int,
        data: Data,
        request: URLRequest? = nil,
        response: HTTPURLResponse,
        kind: Kind = .body,
        transportTimingID: UUID?
    ) {
        self.statusCode = statusCode
        self.data = data
        self.request = request
        self.response = response
        self.kind = kind
        self.transportTimingID = transportTimingID
    }

    /// A text description of the `Response`.
    public var description: String {
        "Status Code: \(statusCode), Data Length: \(data.count)"
    }

    /// A text description of the `Response`. Suitable for debugging.
    public var debugDescription: String { description }

    public static func == (lhs: Response, rhs: Response) -> Bool {
        lhs.statusCode == rhs.statusCode
            && lhs.data == rhs.data
            && lhs.response == rhs.response
            && lhs.kind == rhs.kind
    }

    /// Returns a copy of the response with `data` zeroed out, used by the
    /// failure-payload redaction path so callers cannot accidentally observe
    /// the raw response body when failure-payload capture is disabled through
    /// ``CachePack``. Status code and HTTPURLResponse metadata are preserved;
    /// any `user:password@` userinfo on the request URL is stripped so
    /// embedded credentials cannot leak to crash logs or analytics.
    public func redactingData() -> Response {
        guard let response else { return self }
        return Response(
            statusCode: statusCode,
            data: Data(),
            request: request.map(Self.strippingURLCredentials),
            response: response,
            kind: kind
        )
    }

    static func strippingURLCredentials(_ request: URLRequest) -> URLRequest {
        guard let url = request.url,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.user != nil || components.password != nil
        else {
            return request
        }
        components.user = nil
        components.password = nil
        guard let stripped = components.url else { return request }
        var copy = request
        copy.url = stripped
        return copy
    }
}
