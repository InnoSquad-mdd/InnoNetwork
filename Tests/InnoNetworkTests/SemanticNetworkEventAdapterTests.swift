import Foundation
import Testing

@testable import InnoNetwork

@Suite("Semantic network event adapter")
struct SemanticNetworkEventAdapterTests {
    @Test("Request events use semantic HTTP keys and retain redacted URLs")
    func mapsRequestEvent() {
        let id = UUID()
        let mapped = SemanticNetworkEventAdapter.map(
            .requestStart(
                requestID: id,
                method: "GET",
                url: "https://api.example.test/users?token=%3Credacted%3E",
                retryIndex: 2
            )
        )

        #expect(mapped.name == "http.client.request.start")
        #expect(mapped.requestID == id)
        #expect(mapped.attributes["http.request.method"] == .string("GET"))
        #expect(mapped.attributes["server.address"] == .string("api.example.test"))
        #expect(mapped.attributes["http.request.resend_count"] == .integer(2))
        #expect(
            mapped.attributes["url.full"]
                == .string("https://api.example.test/users?token=%3Credacted%3E")
        )
    }

    @Test("Failure events expose a low-cardinality error type")
    func mapsFailureEvent() {
        let mapped = SemanticNetworkEventAdapter.map(
            .requestFailed(requestID: UUID(), errorCode: 10, message: "timeout.request")
        )

        #expect(mapped.attributes["error.type"] == .string("timeout.request"))
        #expect(mapped.attributes["innonetwork.error.code"] == .integer(10))
    }

    @Test("Adapted, response, retry, and finished events retain lifecycle attributes")
    func mapsRemainingRequestLifecycle() {
        let id = UUID()
        let adapted = SemanticNetworkEventAdapter.map(
            .requestAdapted(
                requestID: id,
                method: "POST",
                url: "https://api.example.test/users",
                retryIndex: 0
            )
        )
        let received = SemanticNetworkEventAdapter.map(
            .responseReceived(requestID: id, statusCode: 202, byteCount: 64)
        )
        let retry = SemanticNetworkEventAdapter.map(
            .retryScheduled(requestID: id, retryIndex: 1, delay: 0.5, reason: "http.503")
        )
        let finished = SemanticNetworkEventAdapter.map(
            .requestFinished(requestID: id, statusCode: 200, byteCount: 128)
        )

        #expect(adapted.name == "http.client.request.adapted")
        #expect(adapted.attributes["http.request.method"] == .string("POST"))
        #expect(adapted.attributes["http.request.resend_count"] == nil)
        #expect(received.name == "http.client.response.received")
        #expect(received.attributes["http.response.status_code"] == .integer(202))
        #expect(received.attributes["http.response.body.size"] == .integer(64))
        #expect(retry.name == "http.client.request.retry_scheduled")
        #expect(retry.attributes["http.request.resend_count"] == .integer(1))
        #expect(retry.attributes["innonetwork.retry.delay"] == .double(0.5))
        #expect(retry.attributes["innonetwork.retry.reason"] == .string("http.503"))
        #expect(finished.name == "http.client.request.finished")
        #expect(finished.attributes["http.response.status_code"] == .integer(200))
        #expect(finished.attributes["http.response.body.size"] == .integer(128))
    }

    @Test("Every cache revalidation state maps to bounded semantic attributes")
    func mapsCacheRevalidationStates() {
        let id = UUID()
        let cases: [(CacheRevalidationState, String, Int?)] = [
            (.scheduled, "scheduled", nil),
            (.completed(statusCode: 204), "completed", 204),
            (.notModified, "not_modified", 304),
            (.failed(errorCode: 7, message: "transport"), "failed", nil),
        ]

        for (state, expectedState, expectedStatus) in cases {
            let mapped = SemanticNetworkEventAdapter.map(
                .cacheRevalidation(originalID: id, state: state)
            )

            #expect(mapped.name == "http.client.cache.revalidation")
            #expect(mapped.requestID == id)
            #expect(
                mapped.attributes["innonetwork.cache.revalidation.state"]
                    == .string(expectedState)
            )
            #expect(
                mapped.attributes["http.response.status_code"]
                    == expectedStatus.map(SemanticAttributeValue.integer)
            )
        }

        let failed = SemanticNetworkEventAdapter.map(
            .cacheRevalidation(
                originalID: id,
                state: .failed(errorCode: 7, message: "transport")
            )
        )
        #expect(failed.attributes["error.type"] == .string("transport"))
        #expect(failed.attributes["innonetwork.error.code"] == .integer(7))
    }

    @Test("Adapter forwards the mapped event to its async exporter")
    func forwardsToExporter() async {
        let exported = SemanticEventRecorder()
        let adapter = SemanticNetworkEventAdapter { event in
            await exported.record(event)
        }
        let id = UUID()

        await adapter.handle(
            .requestFinished(requestID: id, statusCode: 204, byteCount: 0)
        )

        let event = await exported.last
        #expect(event?.name == "http.client.request.finished")
        #expect(event?.requestID == id)
        #expect(event?.attributes["http.response.status_code"] == .integer(204))
    }
}

private actor SemanticEventRecorder {
    private(set) var last: SemanticNetworkEvent?

    func record(_ event: SemanticNetworkEvent) {
        last = event
    }
}
