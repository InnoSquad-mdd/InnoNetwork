import Foundation
import Testing

@testable import InnoNetwork

private actor SpanCollector: NetworkSpanExporting {
    private(set) var spans: [NetworkSpan] = []
    private(set) var batchSizes: [Int] = []
    func export(_ spans: [NetworkSpan]) async {
        batchSizes.append(spans.count)
        self.spans.append(contentsOf: spans)
    }
}

@Suite("Network Span Observer Tests", .serialized)
struct NetworkSpanObserverTests {
    @Test("Retries produce child attempt spans and one logical request span")
    func retryHierarchy() async throws {
        let exporter = SpanCollector()
        let dates = LockIsolatedDates()
        let observer = NetworkSpanObserver(exporter: exporter, now: { dates.next() })
        let id = UUID()

        await observer.handle(.requestStart(requestID: id, method: "GET", url: "", retryIndex: 0))
        await observer.handle(
            .decision(
                NetworkDecision(
                    requestID: id,
                    attemptIndex: 0,
                    kind: .dispatch,
                    outcome: .allowed,
                    reason: .policyAllowed
                )))
        await observer.handle(.retryScheduled(requestID: id, retryIndex: 0, delay: 1, reason: "test"))
        await observer.handle(.requestStart(requestID: id, method: "GET", url: "", retryIndex: 1))
        await observer.handle(
            .decision(
                NetworkDecision(
                    requestID: id,
                    attemptIndex: 1,
                    kind: .dispatch,
                    outcome: .allowed,
                    reason: .policyAllowed
                )))
        await observer.handle(.requestFinished(requestID: id, statusCode: 200, byteCount: 4))

        await observer.flush()
        let spans = await exporter.spans
        #expect(spans.count == 3)
        #expect(spans.filter { $0.kind == .attempt }.map(\.outcome).contains(.retried))
        let logical = try #require(spans.first { $0.kind == .request })
        #expect(spans.filter { $0.kind == .attempt }.allSatisfy { $0.parentID == logical.id })
        #expect(logical.statusCode == 200)
    }

    @Test("A cache hit produces no physical transport attempt span")
    func cacheHitHasNoAttemptSpan() async throws {
        let exporter = SpanCollector()
        let dates = LockIsolatedDates()
        let observer = NetworkSpanObserver(exporter: exporter, now: { dates.next() })
        let firstID = UUID()
        let cachedID = UUID()

        await observer.handle(.requestStart(requestID: firstID, method: "GET", url: "", retryIndex: 0))
        await observer.handle(
            .decision(
                NetworkDecision(
                    requestID: firstID,
                    attemptIndex: 0,
                    kind: .dispatch,
                    outcome: .allowed,
                    reason: .policyAllowed
                )))
        await observer.handle(.requestFinished(requestID: firstID, statusCode: 200, byteCount: 4))

        await observer.handle(.requestStart(requestID: cachedID, method: "GET", url: "", retryIndex: 0))
        await observer.handle(
            .decision(
                NetworkDecision(
                    requestID: cachedID,
                    attemptIndex: 0,
                    kind: .cache,
                    outcome: .allowed,
                    reason: .cacheHit
                )))
        await observer.handle(.requestFinished(requestID: cachedID, statusCode: 200, byteCount: 4))

        await observer.flush()
        let spans = await exporter.spans
        #expect(spans.filter { $0.kind == .request }.count == 2)
        #expect(spans.filter { $0.kind == .attempt }.count == 1)
        #expect(spans.first { $0.kind == .attempt }?.requestID == firstID)
    }

    @Test("Mutated invalid buffer values are normalized before draining")
    func mutatedPolicyCannotHangDrain() async {
        var policy = NetworkSpanObserver.Policy()
        policy.maximumBufferedSpans = 0
        policy.batchSize = -1
        #expect(policy.maximumBufferedSpans == 1)
        #expect(policy.batchSize == 1)

        let exporter = SpanCollector()
        let dates = LockIsolatedDates()
        let observer = NetworkSpanObserver(
            exporter: exporter,
            policy: policy,
            now: { dates.next() }
        )
        let requestID = UUID()

        await observer.handle(
            .requestStart(requestID: requestID, method: "GET", url: "", retryIndex: 0)
        )
        await observer.handle(
            .requestFinished(requestID: requestID, statusCode: 204, byteCount: 0)
        )
        await observer.flush()

        #expect(await exporter.spans.count == 1)
        #expect(await exporter.batchSizes == [1])
    }

    @Test("Streaming response headers do not close the physical attempt")
    func streamingHeadersKeepAttemptOpen() async throws {
        let exporter = SpanCollector()
        let observer = NetworkSpanObserver(exporter: exporter, now: Date.init)
        let requestID = UUID()
        let startedAt = Date(timeIntervalSince1970: 10)
        let headersAt = Date(timeIntervalSince1970: 12)
        let streamEndedAt = Date(timeIntervalSince1970: 20)

        await observer.handle(
            .requestStart(requestID: requestID, method: "GET", url: "", retryIndex: 0),
            occurredAt: startedAt,
            completesPhysicalTransport: false
        )
        await observer.handle(
            .decision(
                NetworkDecision(
                    requestID: requestID,
                    attemptIndex: 0,
                    kind: .dispatch,
                    outcome: .allowed,
                    reason: .policyAllowed,
                    occurredAt: startedAt
                )),
            occurredAt: startedAt,
            completesPhysicalTransport: false
        )
        await observer.handle(
            .responseReceived(requestID: requestID, statusCode: 200, byteCount: 0),
            occurredAt: headersAt,
            completesPhysicalTransport: false
        )
        await observer.handle(
            .requestFinished(requestID: requestID, statusCode: 200, byteCount: 4),
            occurredAt: streamEndedAt,
            completesPhysicalTransport: false
        )
        await observer.flush()

        let attempt = try #require(await exporter.spans.first { $0.kind == .attempt })
        #expect(attempt.startedAt == startedAt)
        #expect(attempt.endedAt == streamEndedAt)
        #expect(attempt.statusCode == 200)
    }

    @Test("Streaming reconnect delay is excluded from the completed physical attempt")
    func streamingReconnectClosesAttemptBeforeDelay() async throws {
        let exporter = SpanCollector()
        let observer = NetworkSpanObserver(exporter: exporter, now: Date.init)
        let requestID = UUID()
        let firstStartedAt = Date(timeIntervalSince1970: 10)
        let firstHeadersAt = Date(timeIntervalSince1970: 11)
        let firstBodyEndedAt = Date(timeIntervalSince1970: 12)
        let secondStartedAt = Date(timeIntervalSince1970: 22)
        let secondEndedAt = Date(timeIntervalSince1970: 23)

        await observer.handle(
            .requestStart(requestID: requestID, method: "GET", url: "", retryIndex: 0),
            occurredAt: firstStartedAt,
            completesPhysicalTransport: false
        )
        await observer.handle(
            .decision(
                NetworkDecision(
                    requestID: requestID,
                    attemptIndex: 0,
                    kind: .dispatch,
                    outcome: .allowed,
                    reason: .policyAllowed,
                    occurredAt: firstStartedAt
                )),
            occurredAt: firstStartedAt,
            completesPhysicalTransport: false
        )
        await observer.handle(
            .responseReceived(requestID: requestID, statusCode: 200, byteCount: 0),
            occurredAt: firstHeadersAt,
            completesPhysicalTransport: false
        )
        await observer.physicalTransportCompleted(
            requestID: requestID,
            statusCode: 200,
            occurredAt: firstBodyEndedAt
        )
        await observer.handle(
            .decision(
                NetworkDecision(
                    requestID: requestID,
                    attemptIndex: 1,
                    kind: .dispatch,
                    outcome: .allowed,
                    reason: .policyAllowed,
                    occurredAt: secondStartedAt
                )),
            occurredAt: secondStartedAt,
            completesPhysicalTransport: false
        )
        await observer.handle(
            .responseReceived(requestID: requestID, statusCode: 200, byteCount: 0),
            occurredAt: secondStartedAt,
            completesPhysicalTransport: false
        )
        await observer.handle(
            .requestFinished(requestID: requestID, statusCode: 200, byteCount: 4),
            occurredAt: secondEndedAt,
            completesPhysicalTransport: false
        )
        await observer.flush()

        let attempts = await exporter.spans.filter { $0.kind == .attempt }.sorted {
            ($0.attemptIndex ?? -1) < ($1.attemptIndex ?? -1)
        }
        #expect(attempts.map(\.outcome) == [.retried, .succeeded])
        #expect(attempts.map(\.statusCode) == [200, 200])
        #expect(attempts.first?.startedAt == firstStartedAt)
        #expect(attempts.first?.endedAt == firstBodyEndedAt)
        #expect(attempts.first?.duration == 2)
        #expect(attempts.last?.startedAt == secondStartedAt)
        #expect(attempts.last?.endedAt == secondEndedAt)
    }
}

private final class LockIsolatedDates: @unchecked Sendable {
    private let lock = NSLock()
    private var tick: TimeInterval = 0

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        tick += 1
        return Date(timeIntervalSince1970: tick)
    }
}
