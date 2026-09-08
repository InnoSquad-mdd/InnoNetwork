import Foundation

/// Algorithm used by the built-in physical-dispatch rate limiter.
public enum AdvancedRateLimitAlgorithm: Sendable, Equatable {
    /// Allows bursts up to `capacity`, then replenishes continuously.
    case tokenBucket(capacity: Double, refillPerSecond: Double)
    /// Enforces an exact weighted limit in every interval-sized window.
    case slidingWindow(limit: Double, interval: Duration)
}

/// Optional server signals that may make the local limiter more restrictive.
public enum RateLimitServerFeedbackPolicy: Sendable, Equatable {
    case disabled
    case retryAfter(maximumDelay: TimeInterval)
    /// Parses the constrained `RateLimit` shape from draft revision 11.
    /// The adapter is versioned because the specification is not yet an RFC.
    case ietfDraft11(maximumDelay: TimeInterval)
}

/// Process-local rate limiting applied immediately before physical transport.
public struct AdvancedRateLimitPolicy: Sendable, Equatable {
    public let algorithm: AdvancedRateLimitAlgorithm
    public let defaultRequestCost: Double
    public let maximumPendingRequests: Int
    public let scope: RequestAdmissionScope
    public let maximumScopes: Int
    public let serverFeedback: RateLimitServerFeedbackPolicy

    public init(
        algorithm: AdvancedRateLimitAlgorithm,
        defaultRequestCost: Double = 1,
        maximumPendingRequests: Int = 512,
        scope: RequestAdmissionScope = .origin,
        maximumScopes: Int = 128,
        serverFeedback: RateLimitServerFeedbackPolicy = .disabled
    ) {
        self.algorithm = algorithm
        self.defaultRequestCost = defaultRequestCost
        self.maximumPendingRequests = max(0, maximumPendingRequests)
        self.scope = scope
        self.maximumScopes = max(1, maximumScopes)
        self.serverFeedback = serverFeedback
    }

    package func validate(requestCost: Double? = nil) throws {
        let cost = requestCost ?? defaultRequestCost
        guard cost.isFinite, cost > 0 else {
            throw RateLimitAdmissionFailure.invalidConfiguration(
                "Rate-limit request cost must be finite and greater than zero."
            )
        }
        switch algorithm {
        case .tokenBucket(let capacity, let refill):
            guard capacity.isFinite, capacity > 0,
                refill.isFinite, refill > 0,
                capacity / refill <= Double(Int64.max),
                cost <= capacity
            else {
                throw RateLimitAdmissionFailure.invalidConfiguration(
                    "Token-bucket capacity, refill, and request cost must be finite, positive, representable, and cost must not exceed capacity."
                )
            }
        case .slidingWindow(let limit, let interval):
            guard limit.isFinite, limit > 0, interval > .zero, cost <= limit else {
                throw RateLimitAdmissionFailure.invalidConfiguration(
                    "Sliding-window limit, interval, and request cost must be positive and finite, and cost must not exceed the limit."
                )
            }
        }
        switch serverFeedback {
        case .disabled:
            break
        case .retryAfter(let maximumDelay), .ietfDraft11(let maximumDelay):
            guard maximumDelay.isFinite, maximumDelay >= 0,
                maximumDelay <= Double(Int64.max)
            else {
                throw RateLimitAdmissionFailure.invalidConfiguration(
                    "Server-feedback maximum delay must be finite, nonnegative, and representable."
                )
            }
        }
    }
}

package enum RateLimitAdmissionFailure: Error, Sendable, Equatable {
    case queueFull
    case scopeLimitReached
    case invalidConfiguration(String)
}

package struct RateLimitReservation: Sendable {
    let id: UUID
    let scope: String
    let cost: Double
    let wasDelayed: Bool
}

package actor AdvancedRateLimitCoordinator {
    private struct SlidingEntry: Sendable {
        let id: UUID
        let instant: Duration
        let cost: Double
    }

    private struct ScopeState: Sendable {
        var tokens: Double?
        var lastRefill: Duration?
        var slidingEntries: [SlidingEntry] = []
        var dispatchTokens: Double?
        var lastDispatchRefill: Duration?
        var dispatchedSlidingEntries: [(instant: Duration, cost: Double)] = []
        var cooldownUntil: Duration?
        var uncommittedReservations: Set<UUID> = []
        var committedReservations: Set<UUID> = []
        var activeReserveCalls = 0
    }

    private let policy: AdvancedRateLimitPolicy
    private let clock: any InnoNetworkClock
    private var scopes: [String: ScopeState] = [:]
    private var pending = 0

    package init(policy: AdvancedRateLimitPolicy, clock: any InnoNetworkClock) {
        self.policy = policy
        self.clock = clock
    }

    package func reserve(for request: URLRequest, cost requestedCost: Double? = nil) async throws
        -> RateLimitReservation
    {
        try policy.validate(requestCost: requestedCost)
        let scope = scopeKey(for: request)
        let cost = requestedCost ?? policy.defaultRequestCost
        if scopes[scope] == nil {
            pruneDormantScopes(at: clock.monotonicNow())
            guard scopes.count < policy.maximumScopes else {
                throw RateLimitAdmissionFailure.scopeLimitReached
            }
            scopes[scope] = ScopeState()
        }
        scopes[scope]?.activeReserveCalls += 1
        defer { finishReserveCall(scope: scope) }

        var wasDelayed = false
        while true {
            try Task.checkCancellation()
            let now = clock.monotonicNow()
            let reservationID = UUID()
            if let wait = try reserveIfPossible(
                scope: scope,
                cost: cost,
                reservationID: reservationID,
                now: now
            ) {
                guard pending < policy.maximumPendingRequests else {
                    throw RateLimitAdmissionFailure.queueFull
                }
                pending += 1
                defer { pending -= 1 }
                wasDelayed = true
                try await clock.sleep(for: wait)
                continue
            }

            scopes[scope]?.uncommittedReservations.insert(reservationID)
            return RateLimitReservation(
                id: reservationID,
                scope: scope,
                cost: cost,
                wasDelayed: wasDelayed
            )
        }
    }

    /// Commits a reservation at the actual dispatch boundary. A non-nil
    /// duration means the reservation remains valid, but transport must release
    /// its concurrency slot and wait before trying to commit again.
    package func commit(_ reservation: RateLimitReservation) -> Duration? {
        guard scopes[reservation.scope]?.uncommittedReservations.contains(reservation.id) == true else {
            return nil
        }
        let now = clock.monotonicNow()
        if let wait = dispatchWaitIfNeeded(
            scope: reservation.scope,
            cost: reservation.cost,
            now: now
        ) {
            return wait
        }
        scopes[reservation.scope]?.uncommittedReservations.remove(reservation.id)
        scopes[reservation.scope]?.committedReservations.insert(reservation.id)
        return nil
    }

    package func refund(_ reservation: RateLimitReservation) {
        guard scopes[reservation.scope]?.uncommittedReservations.remove(reservation.id) != nil else {
            return
        }
        switch policy.algorithm {
        case .tokenBucket(let capacity, _):
            let current = scopes[reservation.scope]?.tokens ?? 0
            scopes[reservation.scope]?.tokens = min(capacity, current + reservation.cost)
        case .slidingWindow:
            scopes[reservation.scope]?.slidingEntries.removeAll { $0.id == reservation.id }
        }
    }

    package func finish(_ reservation: RateLimitReservation) {
        scopes[reservation.scope]?.committedReservations.remove(reservation.id)
    }

    package func observe(
        response: HTTPURLResponse,
        for request: URLRequest,
        reservation: RateLimitReservation
    ) {
        let scope = scopeKey(for: request)
        guard scope == reservation.scope,
            scopes[scope]?.committedReservations.remove(reservation.id) != nil
        else { return }
        let maximumDelay: TimeInterval
        let delay: TimeInterval?
        switch policy.serverFeedback {
        case .disabled:
            return
        case .retryAfter(let maximum):
            maximumDelay = max(0, maximum)
            delay = retryAfterDelay(response: response, maximumDelay: maximumDelay)
        case .ietfDraft11(let maximum):
            maximumDelay = max(0, maximum)
            delay =
                retryAfterDelay(response: response, maximumDelay: maximumDelay)
                ?? RateLimitHeaderAdapterV11.cooldown(
                    response: response,
                    maximumDelay: maximumDelay
                )
        }
        guard let delay, delay > 0 else { return }
        let proposed = clock.monotonicNow() + .seconds(delay)
        if let current = scopes[scope]?.cooldownUntil, current >= proposed { return }
        scopes[scope]?.cooldownUntil = proposed
    }

    package var snapshot: (scopes: Int, pending: Int) { (scopes.count, pending) }

    /// Returns `nil` after charging the request, or the monotonic delay until
    /// the next safe admission.
    private func reserveIfPossible(
        scope: String,
        cost: Double,
        reservationID: UUID,
        now: Duration
    ) throws -> Duration? {
        guard var state = scopes[scope] else {
            throw RateLimitAdmissionFailure.invalidConfiguration(
                "Rate-limit scope state was released while admission was active."
            )
        }
        if let cooldown = state.cooldownUntil, cooldown > now {
            return cooldown - now
        }
        state.cooldownUntil = nil

        switch policy.algorithm {
        case .tokenBucket(let capacity, let refillPerSecond):
            let previous = state.lastRefill ?? now
            let elapsed = max(0, (now - previous).rateLimitSeconds)
            let available = min(capacity, (state.tokens ?? capacity) + elapsed * refillPerSecond)
            state.lastRefill = now
            if available >= cost {
                state.tokens = available - cost
                scopes[scope] = state
                return nil
            }
            state.tokens = available
            scopes[scope] = state
            return .seconds((cost - available) / refillPerSecond)

        case .slidingWindow(let limit, let interval):
            state.slidingEntries.removeAll {
                now - $0.instant >= interval
            }
            let used = state.slidingEntries.reduce(0) { $0 + $1.cost }
            if used + cost <= limit {
                state.slidingEntries.append(
                    SlidingEntry(id: reservationID, instant: now, cost: cost)
                )
                scopes[scope] = state
                return nil
            }
            guard let oldest = state.slidingEntries.first else { return .zero }
            scopes[scope] = state
            return oldest.instant + interval - now
        }
    }

    private func dispatchWaitIfNeeded(
        scope: String,
        cost: Double,
        now: Duration
    ) -> Duration? {
        guard var state = scopes[scope] else { return .zero }
        if let cooldown = state.cooldownUntil, cooldown > now {
            return cooldown - now
        }

        switch policy.algorithm {
        case .tokenBucket(let capacity, let refillPerSecond):
            let previous = state.lastDispatchRefill ?? now
            let elapsed = max(0, (now - previous).rateLimitSeconds)
            let available = min(
                capacity,
                (state.dispatchTokens ?? capacity) + elapsed * refillPerSecond
            )
            state.lastDispatchRefill = now
            if available >= cost {
                state.dispatchTokens = available - cost
                scopes[scope] = state
                return nil
            }
            state.dispatchTokens = available
            scopes[scope] = state
            return .seconds((cost - available) / refillPerSecond)

        case .slidingWindow(let limit, let interval):
            state.dispatchedSlidingEntries.removeAll { now - $0.instant >= interval }
            let used = state.dispatchedSlidingEntries.reduce(0) { $0 + $1.cost }
            if used + cost <= limit {
                state.dispatchedSlidingEntries.append((now, cost))
                scopes[scope] = state
                return nil
            }
            guard let oldest = state.dispatchedSlidingEntries.first else { return .zero }
            scopes[scope] = state
            return oldest.instant + interval - now
        }
    }

    /// Reclaims only scope state whose reservation and dispatch ledgers both
    /// represent a fully available quota. Partially refilled buckets, live
    /// windows, cooldowns, and outstanding reservations retain their scope so
    /// eviction can never increase the configured allowance.
    private func pruneDormantScopes(at now: Duration) {
        var removable: [String] = []
        var refreshed: [String: ScopeState] = [:]
        for (scope, var state) in scopes {
            guard state.activeReserveCalls == 0,
                state.uncommittedReservations.isEmpty,
                state.committedReservations.isEmpty,
                state.cooldownUntil.map({ $0 <= now }) ?? true
            else { continue }

            switch policy.algorithm {
            case .tokenBucket(let capacity, let refillPerSecond):
                let reservationElapsed = max(
                    0,
                    (now - (state.lastRefill ?? now)).rateLimitSeconds
                )
                let dispatchElapsed = max(
                    0,
                    (now - (state.lastDispatchRefill ?? now)).rateLimitSeconds
                )
                let reservationTokens = min(
                    capacity,
                    (state.tokens ?? capacity) + reservationElapsed * refillPerSecond
                )
                let dispatchTokens = min(
                    capacity,
                    (state.dispatchTokens ?? capacity) + dispatchElapsed * refillPerSecond
                )
                if reservationTokens >= capacity, dispatchTokens >= capacity {
                    removable.append(scope)
                }

            case .slidingWindow(_, let interval):
                state.slidingEntries.removeAll { now - $0.instant >= interval }
                state.dispatchedSlidingEntries.removeAll { now - $0.instant >= interval }
                if state.slidingEntries.isEmpty, state.dispatchedSlidingEntries.isEmpty {
                    removable.append(scope)
                } else {
                    refreshed[scope] = state
                }
            }
        }
        for scope in removable { scopes.removeValue(forKey: scope) }
        for (scope, state) in refreshed { scopes[scope] = state }
    }

    private func finishReserveCall(scope: String) {
        guard let active = scopes[scope]?.activeReserveCalls, active > 0 else { return }
        scopes[scope]?.activeReserveCalls = active - 1
    }

    private func retryAfterDelay(response: HTTPURLResponse, maximumDelay: TimeInterval) -> TimeInterval? {
        guard response.statusCode == 429 || response.statusCode == 503,
            let value = response.value(forHTTPHeaderField: "Retry-After")
        else { return nil }
        return ExponentialBackoffRetryPolicy.parseRetryAfter(
            value,
            now: clock.now(),
            maxSeconds: maximumDelay
        )
    }

    private func scopeKey(for request: URLRequest) -> String {
        guard policy.scope == .origin else { return "global" }
        return NetworkOriginNormalizer.key(for: request.url) ?? "global"
    }
}

package enum RateLimitHeaderAdapterV11 {
    /// Accepts the constrained draft-11 Structured Field form `RateLimit:
    /// "name";r=0;t=seconds`. The first list member is the policy closest to
    /// exhaustion. A malformed member invalidates the complete field, while
    /// unknown syntactically valid parameters are ignored. Server feedback can
    /// delay local traffic but never increase capacity.
    static func cooldown(response: HTTPURLResponse, maximumDelay: TimeInterval) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "RateLimit") else { return nil }
        guard raw.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        guard let members = splitTopLevel(raw, separator: ","), !members.isEmpty else { return nil }

        var parsed: [(remaining: Int?, reset: Int?)] = []
        parsed.reserveCapacity(members.count)
        for member in members {
            guard let policy = parsePolicy(member) else { return nil }
            parsed.append(policy)
        }
        guard let first = parsed.first,
            first.remaining == 0,
            let reset = first.reset
        else { return nil }
        return min(TimeInterval(reset), max(0, maximumDelay))
    }

    private enum ParsedParameter {
        case implicitTrue
        case bareItem(String)
    }

    private static func parsePolicy(_ raw: String) -> (remaining: Int?, reset: Int?)? {
        guard !raw.contains("\t"), !raw.contains("\r"), !raw.contains("\n") else { return nil }
        guard let components = splitTopLevel(raw, separator: ";", trimmingParts: false),
            let policyName = components.first,
            isValidString(policyName)
        else { return nil }

        var parameters: [String: ParsedParameter] = [:]
        for component in components.dropFirst() {
            let parameter = component.drop(while: { $0 == " " })
            let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(pair[0])
            guard isValidKey(name) else { return nil }
            let value =
                pair.count == 2
                ? String(pair[1])
                : nil
            guard value.map(isValidBareItem) ?? true else { return nil }
            parameters[name] = value.map(ParsedParameter.bareItem) ?? .implicitTrue
        }

        guard case .bareItem(let remainingValue)? = parameters["r"],
            let remaining = parseInteger(remainingValue)
        else { return nil }
        let reset: Int?
        if let resetParameter = parameters["t"] {
            guard case .bareItem(let resetValue) = resetParameter,
                let parsedReset = parseInteger(resetValue)
            else { return nil }
            reset = parsedReset
        } else {
            reset = nil
        }
        if let partitionKey = parameters["pk"] {
            guard case .bareItem(let value) = partitionKey,
                isValidByteSequence(value)
            else { return nil }
        }
        return (remaining, reset)
    }

    private static func splitTopLevel(
        _ raw: String,
        separator: Character,
        trimmingParts: Bool = true
    ) -> [String]? {
        enum QuoteMode {
            case string
            case displayString
        }

        var parts: [String] = []
        var current = ""
        var quoteMode: QuoteMode?
        var escaped = false

        for character in raw {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if quoteMode == .string, character == "\\" {
                current.append(character)
                escaped = true
                continue
            }
            if character == "\"" {
                current.append(character)
                if quoteMode != nil {
                    quoteMode = nil
                } else {
                    quoteMode = current.dropLast().last == "%" ? .displayString : .string
                }
                continue
            }
            if character == separator, quoteMode == nil {
                let part = trimmingParts ? current.trimmingCharacters(in: .whitespacesAndNewlines) : current
                guard !part.isEmpty else { return nil }
                parts.append(part)
                current = ""
                continue
            }
            current.append(character)
        }

        guard quoteMode == nil, !escaped else { return nil }
        let part = trimmingParts ? current.trimmingCharacters(in: .whitespacesAndNewlines) : current
        guard !part.isEmpty else { return nil }
        parts.append(part)
        return parts
    }

    private static func isValidString(_ value: String) -> Bool {
        guard value.first == "\"", value.last == "\"", value.count >= 2 else { return false }
        let bytes = Array(value.dropFirst().dropLast().utf8)
        var escaped = false
        for byte in bytes {
            if escaped {
                guard byte == 0x22 || byte == 0x5C else { return false }
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 || !(0x20...0x7E).contains(byte) {
                return false
            }
        }
        return !escaped
    }

    private static func isValidKey(_ value: String) -> Bool {
        guard let first = value.first,
            first == "*" || (first >= "a" && first <= "z")
        else { return false }
        return value.dropFirst().allSatisfy {
            ($0 >= "a" && $0 <= "z") || ($0.isASCII && $0.isNumber) || "_-.*".contains($0)
        }
    }

    private static func isValidBareItem(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if value.first == "\"" { return isValidString(value) }
        if value.hasPrefix("%\"") { return isValidDisplayString(value) }
        if value == "?0" || value == "?1" { return true }
        if value.first == ":" { return isValidByteSequence(value) }
        if value.first == "@" { return isValidDate(String(value.dropFirst())) }
        if parseStructuredNumber(value) { return true }
        guard let first = value.first,
            first.isASCII && (first.isLetter || first == "*")
        else { return false }
        return value.dropFirst().allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || "_-.*/:!#$%&'*+^`|~".contains($0))
        }
    }

    private static func parseInteger(_ value: String) -> Int? {
        guard !value.isEmpty,
            value.count <= 15,
            value.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return Int(value)
    }

    private static func parseStructuredNumber(_ value: String) -> Bool {
        var body = value[...]
        if body.first == "-" { body = body.dropFirst() }
        guard !body.isEmpty else { return false }
        let components = body.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count <= 2,
            components.allSatisfy({
                !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber }
            })
        else { return false }
        if components.count == 1 {
            return components[0].count <= 15
        }
        return components[0].count <= 12 && (1...3).contains(components[1].count)
    }

    private static func isValidDate(_ value: String) -> Bool {
        var digits = value[...]
        if digits.first == "-" { digits = digits.dropFirst() }
        return !digits.isEmpty
            && digits.count <= 15
            && digits.allSatisfy({ $0.isASCII && $0.isNumber })
    }

    private static func isValidByteSequence(_ value: String) -> Bool {
        guard value.first == ":", value.last == ":", value.count >= 2 else { return false }
        let encoded = String(value.dropFirst().dropLast())
        guard
            encoded.utf8.allSatisfy({
                (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0)
                    || (0x30...0x39).contains($0) || $0 == 0x2B || $0 == 0x2F || $0 == 0x3D
            })
        else { return false }
        return Data(base64Encoded: encoded) != nil
    }

    private static func isValidDisplayString(_ value: String) -> Bool {
        guard value.hasPrefix("%\""), value.last == "\"", value.count >= 3 else { return false }
        let bytes = Array(value.dropFirst(2).dropLast().utf8)
        var decoded: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x25 {
                guard index + 2 < bytes.count,
                    let high = hexadecimalValue(bytes[index + 1]),
                    let low = hexadecimalValue(bytes[index + 2])
                else { return false }
                decoded.append(high << 4 | low)
                index += 3
                continue
            }
            guard
                byte == 0x20 || byte == 0x21 || byte == 0x23 || byte == 0x24
                    || (0x26...0x7E).contains(byte)
            else { return false }
            decoded.append(byte)
            index += 1
        }
        return String(bytes: decoded, encoding: .utf8) != nil
    }

    private static func hexadecimalValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
}

private extension Duration {
    var rateLimitSeconds: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
