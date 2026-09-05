import Foundation
import Testing

@testable import InnoNetworkUpload

@Suite("Upload Delegate Event Channel Tests", .serialized)
struct UploadDelegateEventChannelTests {
    @Test("Queued progress is coalesced to the newest snapshot")
    func coalescesProgress() async throws {
        let channel = UploadDelegateEventChannel()
        channel.send(.progress(taskIdentifier: 7, bytesSent: 1, totalBytesSent: 1, expected: 10))
        channel.send(.progress(taskIdentifier: 7, bytesSent: 4, totalBytesSent: 5, expected: 10))

        guard case .progress(let identifier, let bytesSent, let total, let expected) = await channel.next()
        else {
            Issue.record("Expected a progress event")
            return
        }
        #expect(identifier == 7)
        #expect(bytesSent == 4)
        #expect(total == 5)
        #expect(expected == 10)
        channel.finish()
    }

    @Test("Response data overflow becomes an explicit task failure signal")
    func reportsDataOverflow() async throws {
        let limits = UploadResourcePolicy(
            maximumTrackedTasks: 2,
            maximumBufferedDelegateEvents: 2,
            maximumBufferedDelegateBytes: 4,
            maximumPendingUnknownTasks: 2
        )
        let channel = UploadDelegateEventChannel(limits: limits)
        channel.send(.data(taskIdentifier: 9, data: Data([1, 2, 3])))
        channel.send(.data(taskIdentifier: 9, data: Data([4, 5])))

        guard case .overflow(let identifier, let byteLimit) = await channel.next() else {
            Issue.record("Expected an overflow event")
            return
        }
        #expect(identifier == 9)
        #expect(byteLimit == 4)
        channel.finish()
    }

    @Test("Finishing releases a suspended consumer exactly once")
    func finishReleasesConsumer() async {
        let channel = UploadDelegateEventChannel()
        let consumer = Task { await channel.next() }
        await Task.yield()
        channel.finish()
        #expect(await consumer.value.map { _ in true } == nil)
        #expect(await channel.next().map { _ in true } == nil)
    }
}
