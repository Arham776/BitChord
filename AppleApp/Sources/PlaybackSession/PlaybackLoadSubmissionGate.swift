import Foundation

/// Resolves may run concurrently; all track mutations commit on this lane.
/// Advancing enqueues the stop behind any already-running load and before the
/// next load. The main thread never waits for a decoder or output rebuild.
final class PlaybackLoadSubmissionGate: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.example.bitchord.playback-submission")
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var revision: UInt64 = 0

    func advance(to generation: UInt64, stop: @escaping @Sendable () -> Void) {
        lock.lock()
        self.generation = generation
        queue.async(execute: stop)
        lock.unlock()
    }

    func invalidate(to generation: UInt64) {
        lock.lock()
        self.generation = generation
        lock.unlock()
    }

    func setQueueRevision(_ revision: UInt64) {
        lock.lock()
        self.revision = revision
        lock.unlock()
    }

    func isCurrent(_ generation: UInt64, revision: UInt64? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.generation == generation && (revision == nil || self.revision == revision)
    }

    func performIfCurrent<T>(generation: UInt64, revision: UInt64? = nil,
                             _ operation: () throws -> T) rethrows -> T? {
        try queue.sync {
            guard isCurrent(generation, revision: revision) else { return nil }
            return try operation()
        }
    }

    /// Short fire-and-forget mutations, e.g. clearing the queued successor.
    func submit(generation: UInt64, revision: UInt64? = nil,
                _ operation: @escaping @Sendable () -> Void) {
        queue.async {
            guard self.isCurrent(generation, revision: revision) else { return }
            operation()
        }
    }
}
