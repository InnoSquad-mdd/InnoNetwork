import Foundation

/// Serializes cache mutations per target URI and invalidates write tokens
/// captured before an unsafe response or a storage-prohibiting response.
///
/// `ResponseCache` is intentionally open to external implementations, so the
/// executor cannot assume that `set` and `invalidate` share one actor. Holding
/// this coordinator's per-target lease across each cache mutation prevents an
/// older GET from being stored after a newer mutation has invalidated it.
package actor ResponseCacheMutationCoordinator {
    package struct WriteToken: Sendable {
        let targetURI: String
        let generation: UUID
    }

    private var generations: [String: UUID] = [:]
    private var activeTargets: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    package func writeToken(for targetURI: String) -> WriteToken {
        let generation = generations[targetURI] ?? UUID()
        generations[targetURI] = generation
        return WriteToken(targetURI: targetURI, generation: generation)
    }

    package func acquire(targetURI: String) async {
        if activeTargets.insert(targetURI).inserted {
            return
        }
        await withCheckedContinuation { continuation in
            waiters[targetURI, default: []].append(continuation)
        }
    }

    package func isCurrent(_ token: WriteToken) -> Bool {
        generations[token.targetURI] == token.generation
    }

    package func advanceGeneration(for targetURI: String) {
        generations[targetURI] = UUID()
    }

    package func release(targetURI: String) {
        guard var queued = waiters[targetURI], !queued.isEmpty else {
            activeTargets.remove(targetURI)
            waiters.removeValue(forKey: targetURI)
            return
        }
        let next = queued.removeFirst()
        if queued.isEmpty {
            waiters.removeValue(forKey: targetURI)
        } else {
            waiters[targetURI] = queued
        }
        next.resume()
    }
}
