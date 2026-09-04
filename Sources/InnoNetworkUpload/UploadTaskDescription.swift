import Foundation

package enum UploadTaskIntent: String, Sendable {
    case active
    case paused
}

package struct UploadTaskDescription: Sendable, Equatable {
    private static let prefix = "innonetwork.upload.v1"

    package let id: String?
    package let intent: UploadTaskIntent

    package static func active(id: String) -> String {
        encode(id: id, intent: .active)
    }

    package static func paused(id: String) -> String {
        encode(id: id, intent: .paused)
    }

    package static func decode(_ value: String?) -> Self {
        guard let value else { return Self(id: nil, intent: .active) }
        guard value.hasPrefix(prefix + ":") else {
            return Self(id: value, intent: .active)
        }

        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 3,
            components[0] == Substring(prefix),
            let intent = UploadTaskIntent(rawValue: String(components[1])),
            let data = Data(base64Encoded: String(components[2])),
            let id = String(data: data, encoding: .utf8)
        else {
            // A malformed descriptor that claims to be ours fails closed: a
            // restored task gets a fresh logical ID and remains suspended.
            return Self(id: nil, intent: .paused)
        }
        return Self(id: id, intent: intent)
    }

    private static func encode(id: String, intent: UploadTaskIntent) -> String {
        let encodedID = Data(id.utf8).base64EncodedString()
        return "\(prefix):\(intent.rawValue):\(encodedID)"
    }
}
