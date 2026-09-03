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
}
