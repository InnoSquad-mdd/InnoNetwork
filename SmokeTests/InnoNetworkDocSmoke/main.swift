import Foundation
import InnoNetwork
import InnoNetworkAuthAWS
import InnoNetworkDownload
import InnoNetworkOpenAPI
import InnoNetworkPersistentCache
import InnoNetworkUpload
import InnoNetworkWebSocket

private let smokeOperationConfiguration = NetworkClientConfiguration.secure(
    baseURL: URL(string: "https://example.com")!
)
private let smokeOperationClientType =
    OperationNetworkClient<DefaultNetworkClient>.self
private let smokeFailureKind = NetworkFailureKind.transport
private let smokeRecoveryDisposition = NetworkRecoveryDisposition.retry
private let smokeBoundedTransferType = BoundedNetworkTransfer.self
private let smokeRetryExecutor = NetworkRetryExecutor()
private let smokeURLPolicy = NetworkURLPolicy.http()
private let smokeUploadStateType = UploadState.self

private struct SmokeUser: Decodable, Sendable {
    let id: Int
    let name: String
}

private struct SmokePost: Decodable, Sendable {
    let id: Int
    let title: String
}

private struct SmokeAuthResponse: Decodable, Sendable {
    let token: String
}

private struct SmokeGetUser: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = SmokeUser

    var method: HTTPMethod { .get }
    var path: String { "/user/1" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
}

private struct SmokeLoginRequest: APIDefinition {
    struct Parameter: Encodable, Sendable {
        let email: String
        let password: String
    }

    typealias APIResponse = SmokeAuthResponse

    let parameters: Parameter?
    var method: HTTPMethod { .post }
    var path: String { "/login" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
    var contentType: ContentType { .formUrlEncoded }

    init(email: String, password: String) {
        self.parameters = Parameter(email: email, password: password)
    }
}

private struct SmokeUploadImage: MultipartAPIDefinition {
    typealias APIResponse = EmptyResponse

    let imageData: Data

    var multipartFormData: MultipartFormData {
        var formData = MultipartFormData()
        formData.append("My Image", name: "title")
        formData.append(
            imageData,
            name: "file",
            fileName: "image.jpg",
            mimeType: "image/jpeg"
        )
        return formData
    }

    var method: HTTPMethod { .post }
    var path: String { "/upload" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
}

private struct SmokeOpenAPIListUsers: OpenAPIRestOperation {
    typealias Response = [SmokeUser]

    var method: HTTPMethod { .get }
    var path: String { "/openapi/users" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
}

private struct SmokeAlamofireStyleAdapter: RequestInterceptor {
    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        request.setValue("smoke", forHTTPHeaderField: "X-Request-ID")
        return request
    }
}

private enum SmokeMoyaStyleTarget {
    case posts(userID: String, page: Int)

    func endpoint() -> SmokeUserPosts {
        switch self {
        case .posts(let userID, let page):
            SmokeUserPosts(userID: userID, page: page)
        }
    }
}

private struct SmokeUserPosts: APIDefinition {
    struct Parameter: Encodable, Sendable {
        let page: Int
    }

    typealias APIResponse = [SmokePost]

    let userID: String
    let page: Int

    var method: HTTPMethod { .get }
    var path: String { "/users/\(userID)/posts" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
    var parameters: Parameter? { Parameter(page: page) }
    var transport: TransportPolicy<[SmokePost]> { .query() }
}

private func compileBackgroundDownloadArticleExamples() async throws {
    let configuration = DownloadConfiguration.advanced(
        sessionIdentifier: "com.example.docsmoke.background.\(UUID().uuidString)",
        transfer: DownloadTransferPack(
            maxConnectionsPerHost: 4,
            allowsCellularAccess: true
        ),
        persistence: DownloadPersistencePack(
            compactionPolicy: .init(
                maxEvents: 1_000,
                maxLogBytes: 1_048_576,
                tombstoneRatio: 0.25
            )
        )
    )

    let manager = try DownloadManager(configuration: configuration)
    _ = await manager.waitForRestoration()

    let task = await manager.download(
        url: URL(string: "https://example.com/archive.zip")!,
        to: FileManager.default.temporaryDirectory.appendingPathComponent("archive.zip")
    )
    await manager.pause(task)
    await manager.resume(task)
    await manager.cancel(task)
}

private func compileWebSocketArticleExamples() async {
    let configuration = WebSocketConfiguration.advanced(
        liveness: WebSocketLivenessPack(
            heartbeatInterval: 20,
            pongTimeout: 5
        ),
        messaging: WebSocketMessagingPack(sendQueueLimit: 32)
    )
    let manager = WebSocketManager(configuration: configuration)
    let task = await manager.connect(
        url: URL(string: "wss://echo.example.com/socket")!
    )
    let events = await manager.events(for: task)
    _ = events
    await manager.disconnect(task, closeCode: .custom(4001))
}

private func runDocSmoke() {
    let client = DefaultNetworkClient(
        baseURL: URL(string: "https://api.example.com/v1")!
    )
    let typedOneOff = EndpointBuilder<SmokeUser>.get("/user/1")
    _ = client
    _ = typedOneOff

    let networkAdvanced = NetworkConfiguration.advanced(
        baseURL: URL(string: "https://api.example.com/v1")!,
        auth: AuthPack(
            additionalRequestInterceptors: [SmokeAlamofireStyleAdapter()]
        ),
        transport: TransportPack(timeout: 45, trustPolicy: .systemDefault)
    )
    _ = networkAdvanced

    let awsSigner = AWSSigV4Interceptor(
        accessKeyID: "AKIDEXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        region: "us-east-1",
        service: "execute-api"
    )
    let awsConfiguration = NetworkConfiguration.advanced(
        baseURL: URL(string: "https://api.example.com/v1")!,
        auth: AuthPack(additionalSigners: [awsSigner])
    )
    _ = awsConfiguration

    let persistentCacheConfiguration = PersistentResponseCacheConfiguration(
        directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("innonetwork-docsmoke-cache", isDirectory: true)
    )
    _ = persistentCacheConfiguration

    let downloadDefaults = DownloadConfiguration.safeDefaults(
        sessionIdentifier: "com.example.docsmoke.downloads"
    )
    let downloadAdvanced = DownloadConfiguration.advanced(
        retry: DownloadRetryPack(
            maxTotalRetries: 5,
            waitsForNetworkChanges: true
        )
    )
    _ = downloadDefaults
    _ = downloadAdvanced

    let webSocketDefaults = WebSocketConfiguration.safeDefaults()
    let webSocketAdvanced = WebSocketConfiguration.advanced(
        liveness: WebSocketLivenessPack(heartbeatInterval: 15),
        reconnect: WebSocketReconnectPack(maxAttempts: 8)
    )
    _ = webSocketDefaults
    _ = webSocketAdvanced

    let request = SmokeGetUser()
    let login = SmokeLoginRequest(email: "user@example.com", password: "password123")
    let upload = SmokeUploadImage(imageData: Data([0x00, 0x01, 0x02]))
    let openAPIRequest = OpenAPIRequest(SmokeOpenAPIListUsers())
    let alamofireStyleAdapter = SmokeAlamofireStyleAdapter()
    let moyaStyleEndpoint = SmokeMoyaStyleTarget.posts(userID: "1", page: 2).endpoint()
    _ = request
    _ = login
    _ = upload
    _ = openAPIRequest
    _ = alamofireStyleAdapter
    _ = moyaStyleEndpoint
}

_ = compileBackgroundDownloadArticleExamples
_ = compileWebSocketArticleExamples
runDocSmoke()
print("InnoNetworkDocSmoke OK")
