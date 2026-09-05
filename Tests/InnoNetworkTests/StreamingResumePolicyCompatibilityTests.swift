import Foundation
import Testing

@testable import InnoNetwork

@Suite("Streaming resume policy compatibility")
struct StreamingResumePolicyCompatibilityTests {
    @Test(".disabled is compatible with every buffering policy")
    func disabledCompatibleWithAll() async {
        let policy = StreamingResumePolicy.disabled
        #expect(policy.isCompatible(with: .unbounded))
        #expect(policy.isCompatible(with: .bufferingNewest(10)))
        #expect(policy.isCompatible(with: .bufferingOldest(10)))
    }

    @Test(".lastEventID rejects bounded buffering policies")
    func lastEventIDRejectsBounded() async {
        let policy = StreamingResumePolicy.lastEventID(maxAttempts: 3)
        #expect(policy.isCompatible(with: .unbounded))
        #expect(!policy.isCompatible(with: .bufferingNewest(50)))
        #expect(!policy.isCompatible(with: .bufferingOldest(50)))
    }

    @Test("Custom cursor policies reject lossy buffers")
    func cursorRejectsBounded() throws {
        let policy = StreamingResumePolicy.cursor(header: "X-Resume-Cursor", maxAttempts: 2, retryDelay: 0.5)
        try policy.validate()
        #expect(policy.maxAttempts == 2)
        #expect(policy.retryDelay == 0.5)
        #expect(policy.headerName == "X-Resume-Cursor")
        #expect(policy.isCompatible(with: .unbounded))
        #expect(!policy.isCompatible(with: .bufferingNewest(1)))
        #expect(!policy.isCompatible(with: .bufferingOldest(1)))
    }

    @Test(
        "Invalid cursor header names fail closed without echoing input",
        arguments: [
            "", "X-Cursor\r\nAuthorization", "x cursor", "é", String(repeating: "x", count: 129),
            "AUTHORIZATION", "Cookie", "Content-Length", "Host", "Proxy-Authorization", "Sec-Fetch-Site",
            "Transfer-Encoding", "Idempotency-Key", "Traceparent", "X-Api-Key", "If-None-Match",
        ])
    func invalidCursorHeader(header: String) {
        #expect(throws: NetworkError.self) {
            try StreamingResumePolicy.cursor(header: header, maxAttempts: 1).validate()
        }
    }

    @Test("Nonfinite resume delays fail validation", arguments: [Double.infinity, -.infinity, .nan])
    func nonfiniteDelay(delay: Double) {
        #expect(throws: NetworkError.self) {
            try StreamingResumePolicy.lastEventID(maxAttempts: 1, retryDelay: delay).validate()
        }
        #expect(throws: NetworkError.self) {
            try StreamingResumePolicy.cursor(header: "X-Cursor", maxAttempts: 1, retryDelay: delay).validate()
        }
    }

    @Test("Only transient transport failures can resume")
    func resumableFailureClassification() {
        #expect(StreamingExecutor.isResumableTransportError(URLError(.networkConnectionLost)))
        #expect(StreamingExecutor.isResumableTransportError(URLError(.timedOut)))
        #expect(!StreamingExecutor.isResumableTransportError(URLError(.cancelled)))
        #expect(!StreamingExecutor.isResumableTransportError(CancellationError()))
        #expect(!StreamingExecutor.isResumableTransportError(URLError(.serverCertificateUntrusted)))
        #expect(!StreamingExecutor.isResumableTransportError(URLError(.secureConnectionFailed)))
        #expect(!StreamingExecutor.isResumableTransportError(URLError(.badServerResponse)))
    }

    @Test("An invalid cursor cannot be rehabilitated later in the same attempt")
    func invalidCursorLatches() {
        var state = StreamingResumeState()
        state.beginAttempt()
        state.observe(eventID: "1")
        state.rejectEventID()
        state.observe(eventID: "2")
        state.observe(eventID: "")
        #expect(state.lastSeenEventID == nil)
        #expect(!state.canResume(maxAttempts: 2, completedResumeAttempts: 0))
        state.beginAttempt()
        state.observe(eventID: "3")
        #expect(state.canResume(maxAttempts: 2, completedResumeAttempts: 0))
    }

    @Test("StreamingBufferingPolicy.maySilentlyDropOutputs is true only for bounded variants")
    func bufferingPolicyDropFlag() async {
        #expect(!StreamingBufferingPolicy.unbounded.maySilentlyDropOutputs)
        #expect(StreamingBufferingPolicy.bufferingNewest(1).maySilentlyDropOutputs)
        #expect(StreamingBufferingPolicy.bufferingOldest(1).maySilentlyDropOutputs)
    }
}
