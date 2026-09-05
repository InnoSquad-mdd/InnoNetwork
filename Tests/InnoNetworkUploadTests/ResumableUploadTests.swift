import Foundation
import Testing

@testable import InnoNetworkUpload

private actor MemoryCheckpointStore: ResumableUploadCheckpointStoring {
    var values: [String: ResumableUploadCheckpoint] = [:]
    func load(uploadID: String) async throws -> ResumableUploadCheckpoint? { values[uploadID] }
    func save(_ checkpoint: ResumableUploadCheckpoint) async throws { values[checkpoint.uploadID] = checkpoint }
    func remove(uploadID: String) async throws { values[uploadID] = nil }
}

private actor FakeResumableAdapter: ResumableUploadAdapting {
    var confirmedOffset: Int64
    var ranges: [Range<Int64>] = []
    var createCount = 0
    var finalized = false

    init(confirmedOffset: Int64 = 0) { self.confirmedOffset = confirmedOffset }

    func createSession(request: URLRequest, fileSize: Int64, fileSHA256: String) async throws -> String {
        createCount += 1
        return "server-session"
    }

    func probe(sessionIdentifier: String, request: URLRequest, fileSize: Int64) async throws -> Int64 {
        confirmedOffset
    }

    func uploadChunk(
        _ data: Data,
        range: Range<Int64>,
        fileSize: Int64,
        sessionIdentifier: String,
        request: URLRequest
    ) async throws -> Int64 {
        ranges.append(range)
        confirmedOffset = range.upperBound
        return confirmedOffset
    }

    func finalize(
        sessionIdentifier: String,
        request: URLRequest,
        fileSize: Int64,
        fileSHA256: String
    ) async throws { finalized = true }
}

private struct SimulatedInterruption: Error {}

private actor InterruptingResumableAdapter: ResumableUploadAdapting {
    var confirmedOffset: Int64 = 0
    var calls = 0
    func createSession(request: URLRequest, fileSize: Int64, fileSHA256: String) async throws -> String { "session" }
    func probe(sessionIdentifier: String, request: URLRequest, fileSize: Int64) async throws -> Int64 {
        confirmedOffset
    }
    func uploadChunk(
        _ data: Data,
        range: Range<Int64>,
        fileSize: Int64,
        sessionIdentifier: String,
        request: URLRequest
    ) async throws -> Int64 {
        calls += 1
        if calls == 2 { throw SimulatedInterruption() }
        confirmedOffset = range.upperBound
        return confirmedOffset
    }
    func finalize(sessionIdentifier: String, request: URLRequest, fileSize: Int64, fileSHA256: String) async throws {}
}

private actor ReplacingSourceAdapter: ResumableUploadAdapting {
    let source: URL
    private(set) var uploaded = Data()

    init(source: URL) { self.source = source }

    func createSession(request: URLRequest, fileSize: Int64, fileSHA256: String) async throws -> String {
        try Data("WXYZ".utf8).write(to: source, options: .atomic)
        return "session"
    }

    func probe(sessionIdentifier: String, request: URLRequest, fileSize: Int64) async throws -> Int64 { 0 }

    func uploadChunk(
        _ data: Data,
        range: Range<Int64>,
        fileSize: Int64,
        sessionIdentifier: String,
        request: URLRequest
    ) async throws -> Int64 {
        uploaded.append(data)
        return range.upperBound
    }

    func finalize(
        sessionIdentifier: String,
        request: URLRequest,
        fileSize: Int64,
        fileSHA256: String
    ) async throws {}
}

private actor RemoveFailingCheckpointStore: ResumableUploadCheckpointStoring {
    private var value: ResumableUploadCheckpoint?
    func load(uploadID: String) async throws -> ResumableUploadCheckpoint? { value }
    func save(_ checkpoint: ResumableUploadCheckpoint) async throws { value = checkpoint }
    func remove(uploadID: String) async throws { throw CocoaError(.fileWriteUnknown) }
}

@Suite("Resumable Upload Tests", .serialized)
struct ResumableUploadTests {
    @Test("Engine starts at the server-probed offset and checkpoints confirmations")
    func resumesFromServerOffset() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("payload.bin")
        try Data("abcdefghij".utf8).write(to: file)
        let store = MemoryCheckpointStore()
        let adapter = FakeResumableAdapter(confirmedOffset: 4)
        let engine = try ResumableUploadEngine(chunkSize: 3, adapter: adapter, checkpointStore: store)
        let request = URLRequest(url: URL(string: "https://upload.example.test/files")!)

        let result = try await engine.upload(id: "job", fileURL: file, request: request)

        #expect(result.bytesConfirmed == 10)
        #expect(await adapter.ranges == [4..<7, 7..<10])
        #expect(await adapter.createCount == 1)
        #expect(await adapter.finalized)
        #expect(try await store.load(uploadID: "job") == nil)
    }

    @Test("A changed file fails before resuming the persisted session")
    func changedFileIsRejected() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("payload.bin")
        try Data("new-file".utf8).write(to: file)
        let store = MemoryCheckpointStore()
        try await store.save(
            ResumableUploadCheckpoint(
                uploadID: "job",
                sessionIdentifier: "session",
                fileSize: 8,
                fileSHA256: "wrong",
                confirmedOffset: 4
            ))
        let adapter = FakeResumableAdapter()
        let engine = try ResumableUploadEngine(adapter: adapter, checkpointStore: store)

        await #expect(throws: ResumableUploadError.fileChanged) {
            try await engine.upload(
                id: "job",
                fileURL: file,
                request: URLRequest(url: URL(string: "https://upload.example.test/files")!)
            )
        }
        #expect(await adapter.createCount == 0)
    }

    @Test("An interrupted upload persists only the last server-confirmed offset")
    func interruptionKeepsConfirmedCheckpoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("payload.bin")
        try Data("abcdefghij".utf8).write(to: file)
        let store = MemoryCheckpointStore()
        let adapter = InterruptingResumableAdapter()
        let engine = try ResumableUploadEngine(chunkSize: 4, adapter: adapter, checkpointStore: store)

        await #expect(throws: SimulatedInterruption.self) {
            try await engine.upload(
                id: "job",
                fileURL: file,
                request: URLRequest(url: URL(string: "https://upload.example.test/files")!)
            )
        }
        #expect(try await store.load(uploadID: "job")?.confirmedOffset == 4)
    }

    @Test("An already-cancelled empty upload never creates or finalizes a server session")
    func alreadyCancelledEmptyUploadStopsBeforeServerWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("empty.bin")
        try Data().write(to: file)
        let adapter = FakeResumableAdapter()
        let engine = try ResumableUploadEngine(
            adapter: adapter,
            checkpointStore: MemoryCheckpointStore(),
            snapshotDirectory: directory.appendingPathComponent("snapshots")
        )

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.upload(
                id: "cancelled",
                fileURL: file,
                request: URLRequest(url: URL(string: "https://upload.example.test/files")!)
            )
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await adapter.createCount == 0)
        #expect(!(await adapter.finalized))
    }

    @Test("Hashing and chunk reads use one immutable file snapshot")
    func sourceReplacementDoesNotChangeUploadedBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("payload.bin")
        try Data("abcd".utf8).write(to: file)
        let snapshots = directory.appendingPathComponent("snapshots")
        let adapter = ReplacingSourceAdapter(source: file)
        let engine = try ResumableUploadEngine(
            chunkSize: 2,
            adapter: adapter,
            checkpointStore: MemoryCheckpointStore(),
            snapshotDirectory: snapshots
        )

        let result = try await engine.upload(
            id: "snapshot",
            fileURL: file,
            request: URLRequest(url: URL(string: "https://upload.example.test/files")!)
        )

        #expect(await adapter.uploaded == Data("abcd".utf8))
        #expect(result.fileSHA256 == "88d4266fd4e6338d13b845fcf289579d209c897823b9217da3e161936f031589")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test("A finalized upload succeeds when local checkpoint cleanup fails")
    func checkpointCleanupFailureDoesNotMisreportRemoteFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("payload.bin")
        try Data("data".utf8).write(to: file)
        let adapter = FakeResumableAdapter()
        let engine = try ResumableUploadEngine(
            chunkSize: 4,
            adapter: adapter,
            checkpointStore: RemoveFailingCheckpointStore(),
            snapshotDirectory: directory.appendingPathComponent("snapshots")
        )

        let result = try await engine.upload(
            id: "cleanup",
            fileURL: file,
            request: URLRequest(url: URL(string: "https://upload.example.test/files")!)
        )

        #expect(result.bytesConfirmed == 4)
        #expect(await adapter.finalized)
    }
}
