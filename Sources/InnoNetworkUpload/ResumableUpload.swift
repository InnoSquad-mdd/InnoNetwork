import Crypto
import Foundation
import InnoNetwork

public enum ResumableUploadError: Error, Sendable, Equatable {
    case unreadableFile
    case invalidChunkSize
    case invalidServerOffset(Int64)
    case fileChanged
}

/// Durable, credential-free state for a server-negotiated resumable upload.
/// `sessionIdentifier` must be a non-secret lookup identifier, never a bearer URL or token.
public struct ResumableUploadCheckpoint: Codable, Sendable, Equatable {
    public let uploadID: String
    public let sessionIdentifier: String
    public let fileSize: Int64
    public let fileSHA256: String
    public var confirmedOffset: Int64

    public init(
        uploadID: String,
        sessionIdentifier: String,
        fileSize: Int64,
        fileSHA256: String,
        confirmedOffset: Int64
    ) {
        self.uploadID = uploadID
        self.sessionIdentifier = sessionIdentifier
        self.fileSize = fileSize
        self.fileSHA256 = fileSHA256
        self.confirmedOffset = confirmedOffset
    }
}

public protocol ResumableUploadCheckpointStoring: Sendable {
    func load(uploadID: String) async throws -> ResumableUploadCheckpoint?
    func save(_ checkpoint: ResumableUploadCheckpoint) async throws
    func remove(uploadID: String) async throws
}

/// JSON checkpoint store using hashed filenames and atomic replacement.
public actor FileResumableUploadCheckpointStore: ResumableUploadCheckpointStoring {
    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) throws {
        self.directory = directory
        self.fileManager = fileManager
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func load(uploadID: String) async throws -> ResumableUploadCheckpoint? {
        let url = fileURL(uploadID: uploadID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ResumableUploadCheckpoint.self, from: Data(contentsOf: url))
    }

    public func save(_ checkpoint: ResumableUploadCheckpoint) async throws {
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(to: fileURL(uploadID: checkpoint.uploadID), options: [.atomic])
    }

    public func remove(uploadID: String) async throws {
        let url = fileURL(uploadID: uploadID)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func fileURL(uploadID: String) -> URL {
        let digest = SHA256.hash(data: Data(uploadID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension("json")
    }
}

/// Server-specific protocol adapter. Each method must authenticate independently;
/// credentials are intentionally excluded from persisted checkpoints.
public protocol ResumableUploadAdapting: Sendable {
    func createSession(
        request: URLRequest,
        fileSize: Int64,
        fileSHA256: String
    ) async throws -> String

    /// Returns the next byte offset durably accepted by the server.
    func probe(sessionIdentifier: String, request: URLRequest, fileSize: Int64) async throws -> Int64

    /// Uploads `range` and returns the next byte offset durably accepted by the server.
    func uploadChunk(
        _ data: Data,
        range: Range<Int64>,
        fileSize: Int64,
        sessionIdentifier: String,
        request: URLRequest
    ) async throws -> Int64

    /// Finalizes a fully confirmed session. Implementations must make this
    /// idempotent for the same session and file identity because a completed
    /// remote operation can be retried when local checkpoint cleanup fails.
    func finalize(
        sessionIdentifier: String,
        request: URLRequest,
        fileSize: Int64,
        fileSHA256: String
    ) async throws
}

public struct ResumableUploadResult: Sendable, Equatable {
    public let uploadID: String
    public let sessionIdentifier: String
    public let bytesConfirmed: Int64
    public let fileSHA256: String
}

/// Chunk engine that advances only from offsets explicitly confirmed by the server.
public struct ResumableUploadEngine: Sendable {
    public let chunkSize: Int
    private let adapter: any ResumableUploadAdapting
    private let checkpointStore: any ResumableUploadCheckpointStoring
    private let snapshotDirectory: URL

    public init(
        chunkSize: Int = 5 * 1024 * 1024,
        adapter: any ResumableUploadAdapting,
        checkpointStore: any ResumableUploadCheckpointStoring
    ) throws {
        guard chunkSize > 0 else { throw ResumableUploadError.invalidChunkSize }
        self.chunkSize = chunkSize
        self.adapter = adapter
        self.checkpointStore = checkpointStore
        self.snapshotDirectory = FileManager.default.temporaryDirectory
    }

    package init(
        chunkSize: Int = 5 * 1024 * 1024,
        adapter: any ResumableUploadAdapting,
        checkpointStore: any ResumableUploadCheckpointStoring,
        snapshotDirectory: URL
    ) throws {
        guard chunkSize > 0 else { throw ResumableUploadError.invalidChunkSize }
        self.chunkSize = chunkSize
        self.adapter = adapter
        self.checkpointStore = checkpointStore
        self.snapshotDirectory = snapshotDirectory
    }

    public func upload(
        id uploadID: String,
        fileURL: URL,
        request: URLRequest,
        progress: (@Sendable (_ confirmedBytes: Int64, _ totalBytes: Int64) async -> Void)? = nil
    ) async throws -> ResumableUploadResult {
        try Task.checkCancellation()
        let snapshot = try await makeFileSnapshot(at: fileURL)
        defer { try? FileManager.default.removeItem(at: snapshot.url) }
        let identity = (size: snapshot.size, sha256: snapshot.sha256)
        try Task.checkCancellation()
        var checkpoint: ResumableUploadCheckpoint
        if let stored = try await checkpointStore.load(uploadID: uploadID) {
            guard stored.fileSize == identity.size, stored.fileSHA256 == identity.sha256 else {
                throw ResumableUploadError.fileChanged
            }
            checkpoint = stored
        } else {
            try Task.checkCancellation()
            let session = try await adapter.createSession(
                request: request,
                fileSize: identity.size,
                fileSHA256: identity.sha256
            )
            checkpoint = ResumableUploadCheckpoint(
                uploadID: uploadID,
                sessionIdentifier: session,
                fileSize: identity.size,
                fileSHA256: identity.sha256,
                confirmedOffset: 0
            )
            try await checkpointStore.save(checkpoint)
        }

        try Task.checkCancellation()
        let probed = try await adapter.probe(
            sessionIdentifier: checkpoint.sessionIdentifier,
            request: request,
            fileSize: identity.size
        )
        try Self.validate(offset: probed, fileSize: identity.size)
        checkpoint.confirmedOffset = probed
        try await checkpointStore.save(checkpoint)
        await progress?(probed, identity.size)

        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: snapshot.url) } catch { throw ResumableUploadError.unreadableFile }
        defer { try? handle.close() }

        while checkpoint.confirmedOffset < identity.size {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(checkpoint.confirmedOffset))
            let remaining = identity.size - checkpoint.confirmedOffset
            let count = min(chunkSize, Int(remaining))
            guard let data = try handle.read(upToCount: count), !data.isEmpty else {
                throw ResumableUploadError.unreadableFile
            }
            let start = checkpoint.confirmedOffset
            let range = start..<(start + Int64(data.count))
            try Task.checkCancellation()
            let confirmed = try await adapter.uploadChunk(
                data,
                range: range,
                fileSize: identity.size,
                sessionIdentifier: checkpoint.sessionIdentifier,
                request: request
            )
            try Self.validate(offset: confirmed, fileSize: identity.size)
            guard confirmed > start else { throw ResumableUploadError.invalidServerOffset(confirmed) }
            checkpoint.confirmedOffset = confirmed
            try await checkpointStore.save(checkpoint)
            await progress?(confirmed, identity.size)
        }

        try Task.checkCancellation()
        try await adapter.finalize(
            sessionIdentifier: checkpoint.sessionIdentifier,
            request: request,
            fileSize: identity.size,
            fileSHA256: identity.sha256
        )
        // The server has durably finalized the upload. Local checkpoint
        // cleanup is best-effort so a storage failure cannot turn a completed
        // remote operation into a misleading upload failure.
        try? await checkpointStore.remove(uploadID: uploadID)
        return ResumableUploadResult(
            uploadID: uploadID,
            sessionIdentifier: checkpoint.sessionIdentifier,
            bytesConfirmed: identity.size,
            fileSHA256: identity.sha256
        )
    }

    private static func validate(offset: Int64, fileSize: Int64) throws {
        guard (0...fileSize).contains(offset) else {
            throw ResumableUploadError.invalidServerOffset(offset)
        }
    }

    private struct FileSnapshot {
        let url: URL
        let size: Int64
        let sha256: String
    }

    private func makeFileSnapshot(at url: URL) async throws -> FileSnapshot {
        guard url.isFileURL else { throw ResumableUploadError.unreadableFile }
        try Task.checkCancellation()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        let snapshotURL = snapshotDirectory.appendingPathComponent(
            "innonetwork-resumable-\(UUID().uuidString).snapshot"
        )
        guard fileManager.createFile(
            atPath: snapshotURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw ResumableUploadError.unreadableFile
        }
        do {
            let source = try FileHandle(forReadingFrom: url)
            let destination = try FileHandle(forWritingTo: snapshotURL)
            defer {
                try? source.close()
                try? destination.close()
            }
            var hasher = SHA256()
            var size: Int64 = 0
            while let data = try source.read(upToCount: 1024 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                try destination.write(contentsOf: data)
                hasher.update(data: data)
                size += Int64(data.count)
                await Task.yield()
            }
            try Task.checkCancellation()
            try destination.synchronize()
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return FileSnapshot(url: snapshotURL, size: size, sha256: digest)
        } catch is CancellationError {
            try? fileManager.removeItem(at: snapshotURL)
            throw CancellationError()
        } catch {
            try? fileManager.removeItem(at: snapshotURL)
            throw ResumableUploadError.unreadableFile
        }
    }
}
