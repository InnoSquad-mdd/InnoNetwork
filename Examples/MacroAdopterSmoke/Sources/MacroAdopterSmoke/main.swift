import Foundation
import InnoNetwork
import InnoNetworkTestSupport

struct User: Codable, Equatable, Sendable {
    let id: Int
    let name: String
}

struct UserQuery: Codable, Equatable, Sendable {
    let page: Int
    let includeArchived: Bool
}

struct CreateUserBody: Codable, Equatable, Sendable {
    let name: String
    let role: String
}

protocol CatalogRequest {
    var featureName: String { get }
}

extension CatalogRequest where Self: APIDefinition {
    var headers: HTTPHeaders {
        var headers = HTTPHeaders.default
        headers[HTTPHeaderName<SingleValueHeader>("X-Feature")] = featureName
        return headers
    }
}

@APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
struct GetUser {
    typealias APIResponse = User

    let id: String
    let query: UserQuery
}

@APIDefinition(method: .post, path: "/users", auth: .required)
struct CreateUser {
    typealias APIResponse = User

    let body: CreateUserBody
}

@APIDefinition(method: .get, path: "/users", auth: .anonymous)
struct ListUsers: CatalogRequest {
    typealias APIResponse = [User]

    var featureName: String { "Directory" }
}

enum SmokeFailure: Error {
    case invalidBaseURL
    case unexpectedRequestCount(Int)
    case invalidGetURL
    case missingPostBody
}

guard let baseURL = URL(string: "https://api.example.com/v1") else {
    throw SmokeFailure.invalidBaseURL
}

let fetchedUser = User(id: 42, name: "Blob")
let createdUser = User(id: 43, name: "Ada")
let encoder = JSONEncoder()
let session = MockURLSession()
session.setScriptedResponses([
    .http(
        statusCode: 200,
        data: try encoder.encode(fetchedUser),
        headers: ["Content-Type": "application/json"],
        url: baseURL
    ),
    .http(
        statusCode: 200,
        data: try encoder.encode(createdUser),
        headers: ["Content-Type": "application/json"],
        url: baseURL
    ),
    .http(
        statusCode: 200,
        data: try encoder.encode([fetchedUser, createdUser]),
        headers: ["Content-Type": "application/json"],
        url: baseURL
    ),
])

let refreshPolicy = RefreshTokenPolicy(
    currentToken: { "consumer-token" },
    refreshToken: { "consumer-token" }
)
let client = DefaultNetworkClient(
    configuration: .advanced(
        baseURL: baseURL,
        auth: AuthPack(refreshToken: refreshPolicy)
    ),
    session: session
)

let fetched = try await client.request(
    GetUser(
        id: "team/a",
        query: UserQuery(page: 2, includeArchived: true)
    )
)
let createBody = CreateUserBody(name: "Ada", role: "admin")
let created = try await client.request(CreateUser(body: createBody))
let listed = try await client.request(ListUsers())

precondition(fetched == fetchedUser)
precondition(created == createdUser)
precondition(listed == [fetchedUser, createdUser])

let requests = session.capturedRequestsInOrder
guard requests.count == 3 else {
    throw SmokeFailure.unexpectedRequestCount(requests.count)
}

let getRequest = requests[0]
guard
    let getURL = getRequest.url,
    let getComponents = URLComponents(url: getURL, resolvingAgainstBaseURL: false),
    let queryItems = getComponents.queryItems
else {
    throw SmokeFailure.invalidGetURL
}
precondition(getRequest.httpMethod == "GET")
precondition(getComponents.percentEncodedPath == "/v1/users/team%2Fa")
precondition(queryItems.contains(URLQueryItem(name: "page", value: "2")))
precondition(queryItems.contains(URLQueryItem(name: "includeArchived", value: "true")))
precondition(getRequest.value(forHTTPHeaderField: "Authorization") == nil)

let postRequest = requests[1]
precondition(postRequest.httpMethod == "POST")
precondition(postRequest.url?.absoluteString == "https://api.example.com/v1/users")
precondition(postRequest.value(forHTTPHeaderField: "Authorization") == "Bearer consumer-token")
precondition(
    postRequest.value(forHTTPHeaderField: "Content-Type")
        == "application/json; charset=UTF-8"
)
guard let postBody = postRequest.httpBody else {
    throw SmokeFailure.missingPostBody
}
let decodedPostBody = try JSONDecoder().decode(CreateUserBody.self, from: postBody)
precondition(decodedPostBody == createBody)

let listRequest = requests[2]
precondition(listRequest.url?.absoluteString == "https://api.example.com/v1/users")
precondition(listRequest.value(forHTTPHeaderField: "X-Feature") == "Directory")

print("MacroAdopterSmoke OK")
