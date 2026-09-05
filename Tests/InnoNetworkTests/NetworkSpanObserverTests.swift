import Foundation
import Testing

@testable import InnoNetwork

private actor SpanCollector: NetworkSpanExporting {
    private(set) var spans: [NetworkSpan] = []
    func export(_ spans: [NetworkSpan]) async { self.spans.append(contentsOf: spans) }
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
