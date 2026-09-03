import Foundation
import Testing

@testable import InnoNetwork

@Suite("InnoNetwork 6 companion contract")
struct CompanionContractTests {
    @Test("URL validation keeps insecure HTTP opt-in")
    func validatesHTTPPolicy() throws {
        let insecureURL = try #require(URL(string: "http://media.example.test/stream.m3u8"))

        #expect(throws: NetworkError.self) {
            try NetworkURLValidator.validate(insecureURL, policy: .http())
        }
        #expect(
            try NetworkURLValidator.validate(
                insecureURL,
                policy: .http(allowsInsecure: true)
            ) == insecureURL
        )
    }

    @Test("Bounded transfer rejects an invalid limit before transport")
    func rejectsNonPositiveTransferLimit() async throws {
        let request = URLRequest(
            url: try #require(URL(string: "https://media.example.test/stream.m3u8"))
        )

        await #expect(throws: NetworkError.self) {
            _ = try await URLSession.shared.boundedTransfer(
                for: request,
                maximumResponseBytes: 0
            )
        }
    }

    @Test("Retry executor preserves one logical request across attempts")
    func retriesWithStableIdentity() async throws {
        let recorder = RetryRecorder()
        let executor = NetworkRetryExecutor(
            sleep: { duration in
                await recorder.recordSleep(duration)
            },
            now: { Date(timeIntervalSince1970: 0) }
        )
        let policy = ExponentialBackoffRetryPolicy(
            maxRetries: 1,
            retryDelay: 0.25,
            jitterRatio: 0
        )
        let requestID = UUID()
        let request = URLRequest(
            url: try #require(URL(string: "https://api.example.test/value"))
        )

        let result: String = try await executor.execute(
            retryPolicy: policy,
            networkMonitor: nil,
            request: request,
            requestID: requestID
        ) { retryIndex, observedRequestID in
            await recorder.recordAttempt(
                retryIndex: retryIndex,
                requestID: observedRequestID
            )
            if retryIndex == 0 {
                throw NetworkError.timeout(reason: .requestTimeout)
            }
            return "complete"
        }

        #expect(result == "complete")
        #expect(await recorder.attemptIndices == [0, 1])
        #expect(await recorder.requestIDs == [requestID, requestID])
        #expect(await recorder.sleepCount == 1)
    }
}

private actor RetryRecorder {
    private(set) var attemptIndices: [Int] = []
    private(set) var requestIDs: [UUID] = []
    private(set) var sleepCount = 0

    func recordAttempt(retryIndex: Int, requestID: UUID) {
        attemptIndices.append(retryIndex)
        requestIDs.append(requestID)
    }

    func recordSleep(_ duration: Duration) {
        _ = duration
        sleepCount += 1
    }
}
