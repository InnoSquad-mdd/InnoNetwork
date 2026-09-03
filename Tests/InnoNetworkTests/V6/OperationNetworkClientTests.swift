import Foundation
import InnoNetworkTestSupport
import Testing

@testable import InnoNetwork

@Suite("Operation-first client")
struct OperationNetworkClientTests {
    @Test("Operation returns a typed value and a bounded lifecycle")
    func returnsTypedValueAndLifecycle() async throws {
        let endpoint = PreviewEndpoint()
        let stub = StubNetworkClient()
        stub.register(PreviewResponse(id: "42"), for: endpoint)
        let client = OperationNetworkClient(client: stub)

        let operation = client.start(endpoint)
        let value = try await operation.value()
        var events: [NetworkOperationEvent] = []
        for await event in operation.events {
            events.append(event)
        }

        #expect(value == PreviewResponse(id: "42"))
        #expect(events == [.started(id: operation.id), .succeeded(id: operation.id)])
    }

    @Test("Cancellation maps to the value-only failure contract")
    func mapsCancellation() async throws {
        let endpoint = PreviewEndpoint()
        let stub = StubNetworkClient()
        stub.register(
            PreviewResponse(id: "never"),
            for: endpoint,
            behavior: .delayed(seconds: 60)
        )
        let operation = OperationNetworkClient(client: stub).start(endpoint)
        operation.cancel()

        await #expect(throws: NetworkFailure.self) {
            _ = try await operation.value()
        }
        do {
            _ = try await operation.value()
        } catch {
            #expect(error.kind == .cancelled)
            #expect(error.recovery == .none)
            #expect(operation.isCancelled)
        }
    }

    @Test("Migration failure mapping removes response payload details")
    func mapsLegacyConfigurationFailure() {
        let failure = NetworkFailure(
            migratingV5: .configuration(reason: .invalidRequest("secret detail"))
        )

        #expect(failure.kind == .configuration)
        #expect(failure.recovery == .doNotRetry)
        #expect(failure.statusCode == nil)
        #expect(failure.errorDescription == "The request configuration is invalid.")
    }

    @Test("Configuration facade preserves an incremental migration bridge")
    func preservesConfigurationBridge() {
        let legacy = NetworkConfiguration.safeDefaults(
            baseURL: URL(string: "https://api.example.test")!
        )
        let preview = NetworkClientConfiguration(migratingV5: legacy)

        _ = preview.legacyConfiguration
    }
}

private struct PreviewEndpoint: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = PreviewResponse

    let method: HTTPMethod = .get
    let path = "/preview"
    let sessionAuthentication: SessionAuthentication = .anonymous
    let parameters: EmptyParameter? = nil
}

private struct PreviewResponse: Codable, Sendable, Equatable {
    let id: String
}
