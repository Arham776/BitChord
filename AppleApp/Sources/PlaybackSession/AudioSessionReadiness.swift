import Foundation

/// Activation can finish after an interruption/reset invalidated it. Keep the
/// event generation as well as the success flag so that late success cannot
/// make an interrupted audio session appear ready to the engine or Now Playing.
final class AudioSessionReadiness: @unchecked Sendable {
    enum ActivationError: Error { case invalidatedDuringActivation }
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var active = false

    var isActive: Bool { lock.withLock { active } }

    func invalidate() {
        lock.withLock {
            generation &+= 1
            active = false
        }
    }

    func activate<T>(_ operation: () throws -> T) throws -> T {
        let intent = lock.withLock { () -> UInt64 in
            generation &+= 1
            active = false
            return generation
        }
        // A thrown category/activation error leaves readiness false. The
        // operation runs outside the lock so notifications can invalidate it.
        let result = try operation()
        try lock.withLock {
            guard generation == intent else { throw ActivationError.invalidatedDuringActivation }
            active = true
        }
        return result
    }
}
