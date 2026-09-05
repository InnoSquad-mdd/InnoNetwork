import Foundation

/// Source-owned request or attempt timing exported without URL, headers, or body data.
public struct NetworkSpan: Sendable, Equatable {
    public enum Kind: String, Sendable { case request, attempt }
    public enum Outcome: String, Sendable { case succeeded, failed, retried }

    public let id: UUID
    public let parentID: UUID?
    public let requestID: UUID
    /// Zero-based physical transport order within the logical request.
    /// This is independent of retry-policy indices because authentication
    /// recovery and custom execution policies can dispatch more than once
    /// inside one retry-policy attempt.
    public let attemptIndex: Int?
    public let kind: Kind
    public let outcome: Outcome
    public let startedAt: Date
    public let endedAt: Date
    public let statusCode: Int?
    public let errorCode: Int?

    public var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
}

public protocol NetworkSpanExporting: Sendable {
    func export(_ spans: [NetworkSpan]) async
}

/// Converts source lifecycle events into separate logical-request and physical-attempt spans.
/// Export is drained asynchronously through a bounded queue; request execution never awaits
/// the exporter. When saturated, the oldest completed span is discarded.
public actor NetworkSpanObserver: NetworkEventObserving {
    public struct Policy: Sendable, Equatable {
        public var maximumBufferedSpans: Int {
            didSet { maximumBufferedSpans = max(1, maximumBufferedSpans) }
        }
        public var batchSize: Int {
            didSet { batchSize = max(1, batchSize) }
        }

        public init(maximumBufferedSpans: Int = 1_024, batchSize: Int = 32) {
            self.maximumBufferedSpans = max(1, maximumBufferedSpans)
            self.batchSize = max(1, batchSize)
        }
    }

    private struct RequestState {
        let spanID: UUID
        let startedAt: Date
        var attempts: [Int: (id: UUID, startedAt: Date)] = [:]
        var nextAttemptIndex = 0
    }

    private let exporter: any NetworkSpanExporting
    private let policy: Policy
    private let now: @Sendable () -> Date
    private var requests: [UUID: RequestState] = [:]
    private var buffer: [NetworkSpan] = []
    private var draining = false
    public private(set) var droppedSpanCount = 0

    public init(
        exporter: any NetworkSpanExporting,
        policy: Policy = Policy()
    ) {
        self.exporter = exporter
        self.policy = Policy(
            maximumBufferedSpans: policy.maximumBufferedSpans,
            batchSize: policy.batchSize
        )
        self.now = Date.init
    }

    package init(
        exporter: any NetworkSpanExporting,
        policy: Policy = Policy(),
        now: @escaping @Sendable () -> Date
    ) {
        self.exporter = exporter
        self.policy = Policy(
            maximumBufferedSpans: policy.maximumBufferedSpans,
            batchSize: policy.batchSize
        )
        self.now = now
    }

    public func handle(_ event: NetworkEvent) async {
        let timestamp = now()
        switch event {
        case .requestStart(let requestID, _, _, _):
            if requests[requestID] == nil {
                requests[requestID] = RequestState(spanID: UUID(), startedAt: timestamp)
            }

        case .decision(let decision)
        where decision.kind == .dispatch && decision.outcome == .allowed:
            // A second dispatch before the logical retry coordinator emits a
            // retry event is an inner replay (for example, a 401 refresh or a
            // custom policy calling `next.execute()` again). Close the prior
            // physical attempt before opening the next one so it cannot be
            // overwritten by a reused retry-policy index.
            finishOpenAttempts(requestID: decision.requestID, outcome: .retried, at: timestamp)
            guard var request = requests[decision.requestID] else { return }
            let attemptIndex = request.nextAttemptIndex
            request.nextAttemptIndex += 1
            request.attempts[attemptIndex] = (
                UUID(), decision.occurredAt ?? timestamp
            )
            requests[decision.requestID] = request

        case .retryScheduled(let requestID, _, _, _):
            finishOpenAttempts(requestID: requestID, outcome: .retried, at: timestamp)

        case .requestFinished(let requestID, let statusCode, _):
            finishTerminal(
                requestID: requestID,
                outcome: .succeeded,
                statusCode: statusCode,
                errorCode: nil,
                at: timestamp
            )

        case .requestFailed(let requestID, let errorCode, _):
            finishTerminal(
                requestID: requestID,
                outcome: .failed,
                statusCode: nil,
                errorCode: errorCode,
                at: timestamp
            )

        case .requestAdapted, .responseReceived, .cacheRevalidation, .decision:
            break
        }
    }

    package func flush() async {
        while draining {
            await Task.yield()
        }
    }

    private func finishTerminal(
        requestID: UUID,
        outcome: NetworkSpan.Outcome,
        statusCode: Int?,
        errorCode: Int?,
        at endedAt: Date
    ) {
        guard let state = requests.removeValue(forKey: requestID) else { return }
        for (index, attempt) in state.attempts {
            enqueue(
                NetworkSpan(
                    id: attempt.id,
                    parentID: state.spanID,
                    requestID: requestID,
                    attemptIndex: index,
                    kind: .attempt,
                    outcome: outcome,
                    startedAt: attempt.startedAt,
                    endedAt: endedAt,
                    statusCode: statusCode,
                    errorCode: errorCode
                ))
        }
        enqueue(
            NetworkSpan(
                id: state.spanID,
                parentID: nil,
                requestID: requestID,
                attemptIndex: nil,
                kind: .request,
                outcome: outcome,
                startedAt: state.startedAt,
                endedAt: endedAt,
                statusCode: statusCode,
                errorCode: errorCode
            ))
    }

    private func finishAttempt(
        requestID: UUID,
        attemptIndex: Int,
        outcome: NetworkSpan.Outcome,
        at endedAt: Date
    ) {
        guard let request = requests[requestID],
            let attempt = requests[requestID]?.attempts.removeValue(forKey: attemptIndex)
        else { return }
        enqueue(
            NetworkSpan(
                id: attempt.id,
                parentID: request.spanID,
                requestID: requestID,
                attemptIndex: attemptIndex,
                kind: .attempt,
                outcome: outcome,
                startedAt: attempt.startedAt,
                endedAt: endedAt,
                statusCode: nil,
                errorCode: nil
            ))
    }

    private func finishOpenAttempts(
        requestID: UUID,
        outcome: NetworkSpan.Outcome,
        at endedAt: Date
    ) {
        guard let attemptIndices = requests[requestID]?.attempts.keys.sorted(),
            !attemptIndices.isEmpty
        else { return }
        for attemptIndex in attemptIndices {
            finishAttempt(
                requestID: requestID,
                attemptIndex: attemptIndex,
                outcome: outcome,
                at: endedAt
            )
        }
    }

    private func enqueue(_ span: NetworkSpan) {
        if buffer.count >= policy.maximumBufferedSpans {
            buffer.removeFirst()
            droppedSpanCount += 1
        }
        buffer.append(span)
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    private func drain() async {
        while !buffer.isEmpty {
            let count = min(policy.batchSize, buffer.count)
            let batch = Array(buffer.prefix(count))
            buffer.removeFirst(count)
            await exporter.export(batch)
        }
        draining = false
    }
}
